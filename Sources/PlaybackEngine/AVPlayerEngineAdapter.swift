import Foundation
import AVFoundation
import AVKit
import UIKit

/// 兜底播放内核（系统 AVPlayer）：擅长杜比视界 Profile 5 / 8.4、AirPods 空间音频与系统原生硬解。
@MainActor
public final class AVPlayerEngineAdapter: PlayerEngine {
    public private(set) var layerRevision = 0
    public private(set) var isBuffering = false

    public var onStateChange: ((String) -> Void)?
    public var onTimeUpdate: ((_ position: TimeInterval, _ duration: TimeInterval) -> Void)?
    public var onTracksChanged: ((_ audio: [MediaTrackItem], _ subtitles: [MediaTrackItem]) -> Void)?
    public var onFinish: (() -> Void)?
    public var onError: ((String) -> Void)?

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var currentScaling: ScalingMode = .aspectFit
    private var targetRate: Float = 1.0

    public init() {}

    public var isPlaying: Bool { (player?.rate ?? 0) > 0 }
    public var currentTime: TimeInterval { max(0, player?.currentTime().seconds ?? 0) }
    public var duration: TimeInterval {
        guard let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0 else { return 0 }
        return d
    }

    public func load(url: String, startAt: TimeInterval, options: EngineLoadOptions) throws {
        shutdown()
        guard let nsURL = URL(string: url) else {
            throw PlayerEngineError.loadFailed("无效播放地址：\(url)")
        }

        let item = AVPlayerItem(url: nsURL)
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = true

        let layer = AVPlayerLayer(player: avPlayer)
        layer.videoGravity = mapGravity(options.scaling)

        self.player = avPlayer
        self.playerLayer = layer
        self.currentScaling = options.scaling
        self.targetRate = Float(options.playbackRate)
        self.isBuffering = true
        self.layerRevision += 1

        if startAt > 0 {
            let cm = CMTime(seconds: startAt, preferredTimescale: 600)
            avPlayer.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        installObservers(for: avPlayer, item: item)
        avPlayer.playImmediately(atRate: targetRate)
        onStateChange?("AVPlayer 加载中…")
    }

    public func play() {
        player?.playImmediately(atRate: targetRate)
    }

    public func pause() {
        player?.pause()
    }

    public func seek(to time: TimeInterval, accurate: Bool) {
        let clamped = duration > 0 ? min(max(0, time), max(0, duration - 0.5)) : max(0, time)
        let cm = CMTime(seconds: clamped, preferredTimescale: 600)
        if accurate {
            player?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let tol = CMTime(seconds: 1.5, preferredTimescale: 600)
            player?.seek(to: cm, toleranceBefore: tol, toleranceAfter: tol)
        }
    }

    public func seekToKeyframePreview(at time: TimeInterval) async -> TimeInterval {
        guard let player else { return time }
        let clamped = duration > 0 ? min(max(0, time), max(0, duration - 0.5)) : max(0, time)
        let cm = CMTime(seconds: clamped, preferredTimescale: 600)
        let tol = CMTime(seconds: 1.0, preferredTimescale: 600)
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            player.seek(to: cm, toleranceBefore: tol, toleranceAfter: tol) { done in
                cont.resume(returning: done)
            }
        }
        let actual = currentTime
        return (actual.isFinite && actual >= 0) ? actual : clamped
    }

    public func setPlaybackRate(_ rate: Double) {
        targetRate = Float(min(4.0, max(0.25, rate)))
        if isPlaying {
            player?.rate = targetRate
        }
    }

    public func setScalingMode(_ scaling: ScalingMode) {
        currentScaling = scaling
        playerLayer?.videoGravity = mapGravity(scaling)
    }

    public func setMuted(_ muted: Bool) {
        player?.isMuted = muted
    }

    public func selectAudioOption(index: Int32) async {
        guard let asset = player?.currentItem?.asset,
              let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
        let idx = Int(index)
        guard idx >= 0 && idx < group.options.count else { return }
        player?.currentItem?.select(group.options[idx], in: group)
    }

    public func captureTechStats() -> PlaybackTechStats {
        var stats = PlaybackTechStats()
        stats.engineName = "AVPlayer (原生硬解)"
        stats.isHardwareDecode = true
        if let size = player?.currentItem?.presentationSize, size.width > 0 {
            stats.resolution = "\(Int(size.width))×\(Int(size.height))"
        }
        return stats
    }

    public func mount(into container: UIView) {
        guard let layer = playerLayer else { return }
        if layer.superlayer === container.layer {
            layer.frame = container.bounds
            return
        }
        container.layer.sublayers?.forEach { if $0 is AVPlayerLayer { $0.removeFromSuperlayer() } }
        layer.frame = container.bounds
        container.layer.addSublayer(layer)
    }

    public func shutdown() {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        statusObservation = nil
        rateObservation = nil
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        isBuffering = false
    }

    private func installObservers(for avPlayer: AVPlayer, item: AVPlayerItem) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onTimeUpdate?(self.currentTime, self.duration)
            }
        }

        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onFinish?()
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            let st = observedItem.status
            let errText = observedItem.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch st {
                case .readyToPlay:
                    self.isBuffering = false
                    self.onStateChange?("正在播放")
                    await self.refreshMetadataAndDisplayCriteria(item: observedItem)
                case .failed:
                    self.isBuffering = false
                    self.onError?(errText ?? "AVPlayer 打开媒体失败")
                default:
                    break
                }
            }
        }

        rateObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let tcs = observed.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch tcs {
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = true
                    self.onStateChange?("缓冲中…")
                case .playing:
                    self.isBuffering = false
                    self.onStateChange?("正在播放")
                case .paused:
                    self.isBuffering = false
                    self.onStateChange?("已暂停")
                @unknown default:
                    break
                }
            }
        }
    }

    private func refreshMetadataAndDisplayCriteria(item: AVPlayerItem) async {
        let asset = item.asset
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let videoTrack = tracks.first {
            let rate = (try? await videoTrack.load(.nominalFrameRate)) ?? 60
            let descs = (try? await videoTrack.load(.formatDescriptions)) ?? []
            DisplayModeCoordinator.shared.apply(refreshRate: rate, formatDescription: descs.first)
        }
        if let audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible) {
            let items = audioGroup.options.enumerated().map { idx, opt in
                MediaTrackItem(
                    id: Int32(idx),
                    title: opt.displayName,
                    language: opt.locale?.identifier ?? "",
                    codecName: "Audio"
                )
            }
            onTracksChanged?(items, [])
        }
    }

    private func mapGravity(_ scaling: ScalingMode) -> AVLayerVideoGravity {
        switch scaling {
        case .aspectFit: return .resizeAspect
        case .aspectFill: return .resizeAspectFill
        case .fill: return .resize
        }
    }
}
