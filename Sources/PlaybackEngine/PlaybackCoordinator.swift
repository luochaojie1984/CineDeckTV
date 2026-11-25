import Foundation
import UIKit
import SubtitleKit

/// 引擎路由：默认 FSPlayer 优先；无论初始化失败还是运行时硬解/codec 失败，在 `.automatic` 模式下自动无感切换 AVPlayer。
@MainActor
public final class PlaybackCoordinator: ObservableObject {
    public enum EngineKind: String, Sendable {
        case fsplayer, avplayer, automatic
        public var displayName: String {
            switch self {
            case .fsplayer: return "FSPlayer"
            case .avplayer: return "AVPlayer"
            case .automatic: return "自动"
            }
        }
    }

    public let fsEngine = FSPlayerEngineAdapter()
    public let avEngine = AVPlayerEngineAdapter()

    @Published public private(set) var activeEngine: EngineKind = .fsplayer
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
    @Published public private(set) var techStats = PlaybackTechStats()

    public var onPlaybackFinished: (() -> Void)?

    private var current: (any PlayerEngine)?
    private var currentURL: String = ""
    private var currentFileName: String = ""
    private var currentOptions = EngineLoadOptions()
    private var activePreference: EngineKind = .automatic
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
        activePreference = preference
        didRetryFSForCurrentItem = false
        didFallbackForCurrentItem = false
        lastError = nil
        fallbackNotice = nil
        audioTracks = []
        embeddedSubtitleTracks = []
        currentTime = max(0, startAt)
        duration = 0
        isHardwareDecode = options.hardwareDecode

        switch preference {
        case .fsplayer:
            startFS(url: url, startAt: startAt, options: options, allowFallback: false)
        case .avplayer:
            startAV(url: url, startAt: startAt, options: options)
        case .automatic:
            startFS(url: url, startAt: startAt, options: options, allowFallback: true)
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

    public func seekToKeyframePreview(at time: TimeInterval) async -> TimeInterval {
        let actual: TimeInterval
        if activeEngine == .fsplayer {
            actual = await fsEngine.seekToKeyframePreview(at: time)
        } else {
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
        if activeEngine == .fsplayer { fsEngine.setPlaybackRate(rate) }
        else { avEngine.setPlaybackRate(rate) }
    }

    public func setScalingMode(_ scaling: ScalingMode) {
        currentOptions.scaling = scaling
        if activeEngine == .fsplayer { fsEngine.setScalingMode(scaling) }
        else { avEngine.setScalingMode(scaling) }
    }

    public func setMuted(_ muted: Bool) {
        if activeEngine == .fsplayer { fsEngine.setMuted(muted) }
        else { avEngine.setMuted(muted) }
    }

    public func selectAudioTrack(_ trackID: Int32) {
        if activeEngine == .fsplayer {
            fsEngine.selectStream(index: trackID)
        } else {
            Task { await avEngine.selectAudioOption(index: trackID) }
        }
    }

    public func selectSubtitleTrack(_ trackID: Int32) {
        if activeEngine == .fsplayer {
            fsEngine.selectStream(index: trackID)
        }
    }

    public func disableEmbeddedSubtitle() {
        if activeEngine == .fsplayer {
            fsEngine.closeSubtitleStream()
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
        guard activeEngine == .fsplayer else { return false }
        let ok = fsEngine.switchDecoder(hardware: hardware)
        if ok {
            isHardwareDecode = hardware
            currentOptions.hardwareDecode = hardware
            refreshTechStats()
        }
        return ok
    }

    public func refreshTechStats() {
        if activeEngine == .fsplayer {
            techStats = fsEngine.captureTechStats()
        } else {
            techStats = avEngine.captureTechStats()
        }
    }

    public func shutdown() {
        fsEngine.shutdown()
        avEngine.shutdown()
        current = nil
        isPlaying = false
        isBuffering = false
        DisplayModeCoordinator.shared.reset()
    }

    // MARK: - 内部路由

    private func wireCallbacks() {
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
        fsEngine.onFirstFrameRendered = { [weak self] in
            self?.refreshTechStats()
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
                let allowFallback = self.activePreference == .automatic && Self.isAVPlayerCompatibleContainer(self.currentFileName)
                self.fsEngine.shutdown()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard let self, self.currentURL == urlSnapshot else { return }
                    self.startFS(url: urlSnapshot, startAt: resumeAt, options: optsSnapshot, allowFallback: allowFallback)
                }
                return
            }

            if self.activePreference == .automatic && !self.didFallbackForCurrentItem && !self.currentURL.isEmpty && Self.isAVPlayerCompatibleContainer(self.currentFileName) {
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

    private func startFS(url: String, startAt: TimeInterval, options: EngineLoadOptions, allowFallback: Bool) {
        avEngine.shutdown()
        do {
            try fsEngine.load(url: url, startAt: startAt, options: options)
            current = fsEngine
            activeEngine = .fsplayer
            isPlaying = true
            layerRevision = fsEngine.layerRevision
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
        fsEngine.shutdown()
        do {
            try avEngine.load(url: url, startAt: startAt, options: options)
            current = avEngine
            activeEngine = .avplayer
            isPlaying = true
            layerRevision = avEngine.layerRevision + 1000
        } catch {
            lastError = error.localizedDescription
        }
    }
}
