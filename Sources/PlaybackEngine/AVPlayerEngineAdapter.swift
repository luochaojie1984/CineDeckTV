import Foundation
import AVFoundation
import UIKit

/// AVPlayer 兜底引擎（系统原生解码 + 文本字幕叠加）。
/// 关键约束（设计规划 6.3 #12）：AVURLAssetPreferPreciseDurationAndTimingKey = false，
/// 且先 play() 再异步探测音轨，避免整表扫描拖慢起播。
@MainActor
public final class AVPlayerEngineAdapter: PlayerEngine {
    public private(set) var layerRevision = 0
    public private(set) var playerLayer: AVPlayerLayer
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    public var onFinish: (() -> Void)?

    public init() {
        playerLayer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
    }

    public var isPlaying: Bool { (player?.rate ?? 0) > 0 }
    public var currentTime: TimeInterval { player?.currentTime().seconds ?? 0 }
    public var duration: TimeInterval {
        guard let item = player?.currentItem, item.duration.isNumeric else { return 0 }
        return item.duration.seconds
    }

    public func load(url: String, startAt: TimeInterval, options: EngineLoadOptions) throws {
        shutdown()
        guard let remote = URL(string: url) else {
            throw PlayerEngineError.loadFailed("无效地址：\(url)")
        }
        let asset = AVURLAsset(url: remote, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 8
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = Self.gravity(options.scaling)
        self.player = player
        layerRevision &+= 1
        installObservers(for: item)
        if startAt > 0 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        player.rate = Float(options.playbackRate)
        // 先起播，再异步探测音轨（不在主路径上阻塞）。
        Task.detached { _ = try? await asset.loadTracks(withMediaType: .audio) }
    }

    public func play() { player?.play() }
    public func pause() { player?.pause() }

    public func seek(to time: TimeInterval, accurate: Bool) {
        guard let player else { return }
        let target = CMTime(seconds: time, preferredTimescale: 600)
        if accurate {
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: target, toleranceBefore: CMTime(seconds: 0.4, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.4, preferredTimescale: 600))
        }
    }

    public func shutdown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        playerLayer.player = nil
        player = nil
    }

    /// 挂到容器视图（AVPlayerLayer 作为子层）。
    public func mount(into container: UIView) {
        playerLayer.removeFromSuperlayer()
        playerLayer.frame = container.bounds
        container.layer.addSublayer(playerLayer)
    }

    private func installObservers(for item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onFinish?() }
        }
    }

    static func gravity(_ mode: ScalingMode) -> AVLayerVideoGravity {
        switch mode {
        case .aspectFit: return .resizeAspect
        case .aspectFill: return .resizeAspectFill
        case .fill: return .resize
        }
    }
}
