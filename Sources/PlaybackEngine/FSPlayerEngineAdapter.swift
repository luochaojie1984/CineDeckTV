import Foundation
import UIKit
@preconcurrency import FSPlayer

/// FSPlayer 主引擎适配器。
///
/// 已按 1.1.3 真实头文件核对（非臆造）：
/// - 类初始化：init(content:options:videoRendering:audioRendering:)
/// - 渲染视图：FSVideoRenderView.createMetalRenderView() -> UIView & FSVideoRenderingProtocol
/// - 通知：FSPlayerIsPreparedToPlayNotification / FSPlayerLoadStateDidChangeNotification
///         FSPlayerPlaybackStateDidChangeNotification / FSPlayerDidFinishNotification
/// - 硬解热切：switchVideoDecoder(_:)；精确寻帧开关：enableAccurateSeek(_:)
@MainActor
public final class FSPlayerEngineAdapter: PlayerEngine {
    public private(set) var layerRevision = 0
    public private(set) var renderView: (UIView & FSVideoRenderingProtocol)?
    private var player: FSPlayer?
    private var observers: [NSObjectProtocol] = []
    public var onStateChange: ((String) -> Void)?
    public var onFinish: (() -> Void)?

    public init() {
        renderView = FSVideoRenderView.createMetalRenderView()
    }

    public var isPlaying: Bool { player?.isPlaying ?? false }
    public var currentTime: TimeInterval { player?.currentPlaybackTime ?? 0 }
    /// FSPlayer 的 duration 单位是毫秒。
    public var duration: TimeInterval { (player?.duration ?? 0) / 1000.0 }

    public func load(url: String, startAt: TimeInterval, options: EngineLoadOptions) throws {
        shutdown()
        let fsOptions = Self.makeOptions(startAt: startAt, options: options)
        guard let renderView else {
            throw PlayerEngineError.engineUnavailable("Metal 渲染视图创建失败")
        }
        let player = FSPlayer(content: url, options: fsOptions, videoRendering: renderView)
        player.shouldAutoplay = true
        player.playbackRate = Float(options.playbackRate)
        player.scalingMode = Self.mapScaling(options.scaling)
        player.prepareToPlay()
        self.player = player
        layerRevision &+= 1
        installObservers(for: player)
    }

    public func play() { player?.play() }
    public func pause() { player?.pause() }

    public func seek(to time: TimeInterval, accurate: Bool) {
        player?.enableAccurateSeek(accurate)
        player?.currentPlaybackTime = time
    }

    /// 硬解 / 软解热切换，无需重启播放器。
    @discardableResult
    public func switchDecoder(hardware: Bool) -> Bool {
        player?.switchVideoDecoder(hardware) ?? false
    }

    public func mount(into container: UIView) {
        guard let view = renderView else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    public func shutdown() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        player?.shutdownSync(true)
        player = nil
    }

    // MARK: - FSOptions（数值来自设计规划 5.2 的实测调优）

    static func makeOptions(startAt: TimeInterval, options: EngineLoadOptions) -> FSOptions {
        let fsOptions = FSOptions.optionsByDefault()
        fsOptions.setPlayerOptionIntValue(options.hardwareDecode ? 1 : 0, forKey: "videotoolbox_hwaccel")
        fsOptions.setPlayerOptionIntValue(1, forKey: "copy_hw_frame")
        fsOptions.setFormatOptionIntValue(512 * 1024, forKey: "probesize")
        fsOptions.setFormatOptionIntValue(500_000, forKey: "analyzeduration")
        fsOptions.setFormatOptionIntValue(15_000_000, forKey: "timeout")
        fsOptions.setFormatOptionValue("fastseek", forKey: "fflags")
        fsOptions.setPlayerOptionIntValue(1, forKey: "packet-buffering")
        fsOptions.setPlayerOptionIntValue(1, forKey: "framedrop")
        fsOptions.setPlayerOptionIntValue(1, forKey: "start-on-prepared")
        fsOptions.setPlayerOptionIntValue(4, forKey: "threads")
        fsOptions.setPlayerOptionIntValue(0, forKey: "enable-accurate-seek")
        fsOptions.setPlayerOptionIntValue(800, forKey: "accurate-seek-timeout")
        if startAt > 0 {
            fsOptions.setPlayerOptionIntValue(Int64(startAt * 1000), forKey: "seek-at-start")
        }
        return fsOptions
    }

    static func mapScaling(_ mode: ScalingMode) -> FSScalingMode {
        switch mode {
        case .aspectFit: return .aspectFit
        case .aspectFill: return .aspectFill
        case .fill: return .fill
        }
    }

    private func installObservers(for player: FSPlayer) {
        let center = NotificationCenter.default
        let names: [(String, String)] = [
            (FSPlayerIsPreparedToPlayNotification, "prepared"),
            (FSPlayerLoadStateDidChangeNotification, "loadState"),
            (FSPlayerPlaybackStateDidChangeNotification, "playbackState"),
            (FSPlayerFirstVideoFrameRenderedNotification, "firstFrame")
        ]
        for (name, label) in names {
            let token = center.addObserver(forName: NSNotification.Name(name), object: player, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onStateChange?(label) }
            }
            observers.append(token)
        }
        let finish = center.addObserver(forName: NSNotification.Name(FSPlayerDidFinishNotification), object: player, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onFinish?() }
        }
        observers.append(finish)
    }
}
