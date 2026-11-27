import Foundation
import UIKit
import SubtitleKit

/// 三引擎路由：默认 KSPlayer 5.6.2 为主力（真机），同时完整保留 FSPlayer 与 AVPlayer；
/// 自动模式下按 KSPlayer -> FSPlayer -> AVPlayer 无感回退，亦支持播放中随时热切内核与软硬解码。
@MainActor
public final class PlaybackCoordinator: ObservableObject {
    public enum EngineKind: String, Sendable, CaseIterable {
        case automatic, ksplayer, fsplayer, avplayer
        public var displayName: String {
            switch self {
            case .automatic: return "自动 (KS 优先)"
            case .ksplayer: return "KSPlayer"
            case .fsplayer: return "FSPlayer"
            case .avplayer: return "AVPlayer"
            }
        }
    }

    public let ksEngine = KSEngineAdapter()
    public let fsEngine = FSPlayerEngineAdapter()
    public let avEngine = AVPlayerEngineAdapter()

    @Published public private(set) var activeEngine: EngineKind = KSEngineAdapter.isAvailable ? .ksplayer : .fsplayer
    @Published public private(set) var currentPreference: EngineKind = .automatic
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isBuffering = false
    @Published public private(set) var statusText = "准备中"
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var layerRevision = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var fallbackNotice: String?
    @Published public private(set) var audioTracks: [MediaTrackItem] = []
    @Published public private(set) var embeddedSubtitleTracks: [MediaTrackItem] = []
    @Published public private(set) var isHardwareDecode = true
    @Published public private(set) var currentPlaybackRate: Double = 1.0
    @Published public private(set) var currentScalingMode: ScalingMode = .aspectFit
    @Published public private(set) var techStats = PlaybackTechStats()

    public var onPlaybackFinished: (() -> Void)?
    public var onPreparedForSmokeTest: (() -> Void)?
    public var onFirstFrameForSmokeTest: (() -> Void)?

    private var current: (any PlayerEngine)?
    private var currentURL: String = ""
    private var currentFileName: String = ""
    private var currentOptions = EngineLoadOptions()
    private var didFallbackKS = false
    private var didRetryFSForCurrentItem = false
    private var didFallbackForCurrentItem = false

    private static func isAVPlayerCompatibleContainer(_ fileName: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if ext.isEmpty { return true }
        return ["mp4", "m4v", "mov", "ts", "m2ts", "m3u8", "mp3", "m4a", "aac"].contains(ext)
    }

    public init() {
        wireCallbacks()
    }

    public var engine: (any PlayerEngine)? { current }

    public func load(url: String, fileName: String = "", startAt: TimeInterval, options: EngineLoadOptions, preference: EngineKind = .automatic) {
        currentURL = url
        currentFileName = fileName
        currentOptions = options
        currentPreference = preference
        didFallbackKS = false
        didRetryFSForCurrentItem = false
        didFallbackForCurrentItem = false
        lastError = nil
        fallbackNotice = nil
        audioTracks = []
        embeddedSubtitleTracks = []
        currentTime = max(0, startAt)
        duration = 0
        isHardwareDecode = options.hardwareDecode
        currentPlaybackRate = options.playbackRate
        currentScalingMode = options.scaling

        switch preference {
        case .automatic:
            if KSEngineAdapter.isAvailable {
                startKS(url: url, startAt: startAt, options: options, allowFallback: true)
            } else {
                startFS(url: url, startAt: startAt, options: options, allowFallback: true)
            }
        case .ksplayer:
            if KSEngineAdapter.isAvailable {
                startKS(url: url, startAt: startAt, options: options, allowFallback: false)
            } else {
                fallbackNotice = "模拟器环境使用 FSPlayer，真机默认 KSPlayer"
                startFS(url: url, startAt: startAt, options: options, allowFallback: true)
            }
        case .fsplayer:
            startFS(url: url, startAt: startAt, options: options, allowFallback: false)
        case .avplayer:
            startAV(url: url, startAt: startAt, options: options)
        }
    }

    public func play() {
        current?.play()
        isPlaying = true
    }

    public func pause() {
        current?.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval, accurate: Bool = false) {
        current?.seek(to: time, accurate: accurate)
        currentTime = max(0, time)
    }

    /// 异步精准定位并等待主引擎就绪，避免快进松手后清屏黑闪。
    public func seekAndWait(to time: TimeInterval, accurate: Bool = false, resumePlaying: Bool) async {
        let clamped = duration > 0 ? min(max(0, time), max(0, duration - 0.5)) : max(0, time)
        switch activeEngine {
        case .ksplayer:
            await ksEngine.seekAsync(to: clamped, accurate: accurate, autoPlay: resumePlaying)
            if resumePlaying { ksEngine.play() }
        case .fsplayer, .automatic:
            fsEngine.seek(to: clamped, accurate: accurate)
            if resumePlaying { fsEngine.play() }
            try? await Task.sleep(nanoseconds: 140_000_000)
        case .avplayer:
            avEngine.seek(to: clamped, accurate: accurate)
            if resumePlaying { avEngine.play() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        currentTime = clamped
        isPlaying = resumePlaying
    }

    public func seekToKeyframePreview(at time: TimeInterval) async -> TimeInterval {
        let actual: TimeInterval
        switch activeEngine {
        case .ksplayer:
            actual = await ksEngine.seekToKeyframePreview(at: time)
        case .fsplayer, .automatic:
            actual = await fsEngine.seekToKeyframePreview(at: time)
        case .avplayer:
            actual = await avEngine.seekToKeyframePreview(at: time)
        }
        currentTime = actual
        return actual
    }

    public func stepToNextFrame() {
        if activeEngine == .fsplayer {
            fsEngine.stepToNextFrame()
            currentTime = fsEngine.currentTime
        }
    }

    public func setPlaybackRate(_ rate: Double) {
        currentOptions.playbackRate = rate
        currentPlaybackRate = rate
        switch activeEngine {
        case .ksplayer: ksEngine.setPlaybackRate(rate)
        case .fsplayer, .automatic: fsEngine.setPlaybackRate(rate)
        case .avplayer: avEngine.setPlaybackRate(rate)
        }
    }

    public func setScalingMode(_ scaling: ScalingMode) {
        currentOptions.scaling = scaling
        currentScalingMode = scaling
        switch activeEngine {
        case .ksplayer: ksEngine.setScalingMode(scaling)
        case .fsplayer, .automatic: fsEngine.setScalingMode(scaling)
        case .avplayer: avEngine.setScalingMode(scaling)
        }
    }

    public func setMuted(_ muted: Bool) {
        switch activeEngine {
        case .ksplayer: ksEngine.setMuted(muted)
        case .fsplayer, .automatic: fsEngine.setMuted(muted)
        case .avplayer: avEngine.setMuted(muted)
        }
    }

    public func selectAudioTrack(_ trackID: Int32) {
        switch activeEngine {
        case .ksplayer:
            ksEngine.selectAudioTrack(id: trackID)
        case .fsplayer, .automatic:
            fsEngine.selectStream(index: trackID)
        case .avplayer:
            Task { await avEngine.selectAudioOption(index: trackID) }
        }
    }

    public func selectSubtitleTrack(_ trackID: Int32) {
        switch activeEngine {
        case .ksplayer:
            ksEngine.selectSubtitleTrack(id: trackID)
        case .fsplayer, .automatic:
            fsEngine.selectStream(index: trackID)
        case .avplayer:
            break
        }
    }

    public func disableEmbeddedSubtitle() {
        switch activeEngine {
        case .ksplayer:
            ksEngine.disableEmbeddedSubtitle()
        case .fsplayer, .automatic:
            fsEngine.closeSubtitleStream()
        case .avplayer:
            break
        }
    }

    @discardableResult
    public func loadExternalSubtitle(localFileURL: URL) -> Bool {
        guard activeEngine == .fsplayer else { return false }
        return fsEngine.loadExternalSubtitle(localFileURL: localFileURL)
    }

    public func applySubtitleStyle(_ style: SubtitleStyleConfig) {
        if activeEngine == .fsplayer {
            fsEngine.applySubtitleStyle(style)
        }
    }

    @discardableResult
    public func switchDecoder(hardware: Bool) -> Bool {
        currentOptions.hardwareDecode = hardware
        switch activeEngine {
        case .ksplayer:
            let ok = ksEngine.switchDecoder(hardware: hardware)
            if ok {
                isHardwareDecode = hardware
                layerRevision = ksEngine.layerRevision
                refreshTechStats()
            }
            return ok
        case .fsplayer, .automatic:
            let ok = fsEngine.switchDecoder(hardware: hardware)
            if ok {
                isHardwareDecode = hardware
                refreshTechStats()
            }
            return ok
        case .avplayer:
            isHardwareDecode = true
            return false
        }
    }

    public func refreshTechStats() {
        switch activeEngine {
        case .ksplayer:
            techStats = ksEngine.captureTechStats()
        case .fsplayer, .automatic:
            techStats = fsEngine.captureTechStats()
        case .avplayer:
            techStats = avEngine.captureTechStats()
        }
    }

    public func shutdown() {
        ksEngine.shutdown()
        fsEngine.shutdown()
        avEngine.shutdown()
        current = nil
        isPlaying = false
        isBuffering = false
        DisplayModeCoordinator.shared.reset()
    }

    // MARK: - 内部回调与三引擎路由

    private func wireCallbacks() {
        ksEngine.onStateChange = { [weak self] text in
            guard let self, self.activeEngine == .ksplayer else { return }
            self.statusText = text
            self.isPlaying = self.ksEngine.isPlaying
            self.isBuffering = self.ksEngine.isBuffering
        }
        ksEngine.onTimeUpdate = { [weak self] pos, dur in
            guard let self, self.activeEngine == .ksplayer else { return }
            self.currentTime = pos
            if dur > 0 { self.duration = dur }
            self.isPlaying = self.ksEngine.isPlaying
        }
        ksEngine.onTracksChanged = { [weak self] audio, subs in
            guard let self, self.activeEngine == .ksplayer else { return }
            self.audioTracks = audio
            self.embeddedSubtitleTracks = subs
        }
        ksEngine.onPrepared = { [weak self] in
            self?.onPreparedForSmokeTest?()
        }
        ksEngine.onFirstFrameRendered = { [weak self] in
            self?.refreshTechStats()
            self?.onFirstFrameForSmokeTest?()
        }
        ksEngine.onFinish = { [weak self] in
            self?.onPlaybackFinished?()
        }
        ksEngine.onError = { [weak self] message in
            guard let self else { return }
            if self.currentPreference == .automatic && !self.didFallbackKS && !self.currentURL.isEmpty {
                self.didFallbackKS = true
                self.fallbackNotice = "KSPlayer 播放异常，已自动切换至 FSPlayer"
                let resumeAt = max(0, self.currentTime)
                self.ksEngine.shutdown()
                self.startFS(url: self.currentURL, startAt: resumeAt, options: self.currentOptions, allowFallback: true)
            } else {
                self.lastError = message
            }
        }

        fsEngine.onStateChange = { [weak self] text in
            guard let self, self.activeEngine == .fsplayer else { return }
            self.statusText = text
            self.isPlaying = self.fsEngine.isPlaying
            self.isBuffering = self.fsEngine.isBuffering
        }
        fsEngine.onTimeUpdate = { [weak self] pos, dur in
            guard let self, self.activeEngine == .fsplayer else { return }
            self.currentTime = pos
            if dur > 0 { self.duration = dur }
            self.isPlaying = self.fsEngine.isPlaying
        }
        fsEngine.onTracksChanged = { [weak self] audio, subs in
            guard let self, self.activeEngine == .fsplayer else { return }
            self.audioTracks = audio
            self.embeddedSubtitleTracks = subs
        }
        fsEngine.onPrepared = { [weak self] in
            self?.onPreparedForSmokeTest?()
        }
        fsEngine.onFirstFrameRendered = { [weak self] in
            self?.refreshTechStats()
            self?.onFirstFrameForSmokeTest?()
        }
        fsEngine.onFinish = { [weak self] in
            self?.onPlaybackFinished?()
        }
        fsEngine.onError = { [weak self] message in
            guard let self else { return }
            if !self.didRetryFSForCurrentItem && !self.currentURL.isEmpty {
                self.didRetryFSForCurrentItem = true
                let resumeAt = max(0, self.currentTime)
                let urlSnapshot = self.currentURL
                let optsSnapshot = self.currentOptions
                let allowFallback = self.currentPreference == .automatic && Self.isAVPlayerCompatibleContainer(self.currentFileName)
                self.fsEngine.shutdown()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard let self, self.currentURL == urlSnapshot else { return }
                    self.startFS(url: urlSnapshot, startAt: resumeAt, options: optsSnapshot, allowFallback: allowFallback)
                }
                return
            }

            if self.currentPreference == .automatic && !self.didFallbackForCurrentItem && !self.currentURL.isEmpty && Self.isAVPlayerCompatibleContainer(self.currentFileName) {
                self.didFallbackForCurrentItem = true
                self.fallbackNotice = "FSPlayer 解码异常，已自动切换到系统 AVPlayer"
                let resumeAt = max(0, self.currentTime)
                self.fsEngine.shutdown()
                self.startAV(url: self.currentURL, startAt: resumeAt, options: self.currentOptions)
            } else {
                self.lastError = message
            }
        }

        avEngine.onStateChange = { [weak self] text in
            guard let self, self.activeEngine == .avplayer else { return }
            self.statusText = text
            self.isPlaying = self.avEngine.isPlaying
            self.isBuffering = self.avEngine.isBuffering
        }
        avEngine.onTimeUpdate = { [weak self] pos, dur in
            guard let self, self.activeEngine == .avplayer else { return }
            self.currentTime = pos
            if dur > 0 { self.duration = dur }
        }
        avEngine.onTracksChanged = { [weak self] audio, subs in
            guard let self, self.activeEngine == .avplayer else { return }
            self.audioTracks = audio
            if !subs.isEmpty { self.embeddedSubtitleTracks = subs }
        }
        avEngine.onFinish = { [weak self] in
            self?.onPlaybackFinished?()
        }
        avEngine.onError = { [weak self] msg in
            self?.lastError = msg
        }
    }

    private func startKS(url: String, startAt: TimeInterval, options: EngineLoadOptions, allowFallback: Bool) {
        fsEngine.shutdown()
        avEngine.shutdown()
        do {
            try ksEngine.load(url: url, startAt: startAt, options: options)
            current = ksEngine
            activeEngine = .ksplayer
            isPlaying = true
            layerRevision = ksEngine.layerRevision
        } catch {
            lastError = error.localizedDescription
            if allowFallback && !didFallbackKS {
                didFallbackKS = true
                fallbackNotice = "KSPlayer 初始化失败，已回退至 FSPlayer"
                startFS(url: url, startAt: startAt, options: options, allowFallback: true)
            }
        }
    }

    private func startFS(url: String, startAt: TimeInterval, options: EngineLoadOptions, allowFallback: Bool) {
        ksEngine.shutdown()
        avEngine.shutdown()
        do {
            try fsEngine.load(url: url, startAt: startAt, options: options)
            current = fsEngine
            activeEngine = .fsplayer
            isPlaying = true
            layerRevision = fsEngine.layerRevision + 10_000
        } catch {
            lastError = error.localizedDescription
            if allowFallback && !didFallbackForCurrentItem {
                didFallbackForCurrentItem = true
                fallbackNotice = "FSPlayer 初始化失败，已回退至 AVPlayer"
                startAV(url: url, startAt: startAt, options: options)
            }
        }
    }

    private func startAV(url: String, startAt: TimeInterval, options: EngineLoadOptions) {
        ksEngine.shutdown()
        fsEngine.shutdown()
        do {
            try avEngine.load(url: url, startAt: startAt, options: options)
            current = avEngine
            activeEngine = .avplayer
            isPlaying = true
            layerRevision = avEngine.layerRevision + 20_000
        } catch {
            lastError = error.localizedDescription
        }
    }
}
