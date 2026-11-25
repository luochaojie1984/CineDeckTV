import Foundation
import CoreGraphics

/// 统一播放引擎接口：FSPlayer（主）与 AVPlayer（兜底）都实现它，可按需热切换。
@MainActor
public protocol PlayerEngine: AnyObject {
    /// 每次重建底层播放器后自增，UI 层据此重新挂载渲染视图（防止切集/切内核黑屏）。
    var layerRevision: Int { get }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }

    func load(url: String, startAt: TimeInterval, options: EngineLoadOptions) throws
    func play()
    func pause()
    func seek(to time: TimeInterval, accurate: Bool)
    func shutdown()
}

public struct EngineLoadOptions: Sendable {
    public var hardwareDecode: Bool
    public var playbackRate: Double
    public var scaling: ScalingMode
    public var cacheBytes: Int

    public init(hardwareDecode: Bool = true, playbackRate: Double = 1.0, scaling: ScalingMode = .aspectFit, cacheBytes: Int = 96 * 1024 * 1024) {
        self.hardwareDecode = hardwareDecode
        self.playbackRate = playbackRate
        self.scaling = scaling
        self.cacheBytes = cacheBytes
    }
}

public enum ScalingMode: String, Sendable, CaseIterable {
    case aspectFit, aspectFill, fill

    public var displayName: String {
        switch self {
        case .aspectFit: return "适应"
        case .aspectFill: return "铺满"
        case .fill: return "拉伸"
        }
    }
}

public enum PlayerEngineError: Error, Sendable, LocalizedError {
    case engineUnavailable(String)
    case loadFailed(String)
    case decoderUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let name): return "播放内核不可用：\(name)"
        case .loadFailed(let reason): return "加载失败：\(reason)"
        case .decoderUnavailable(let reason): return "解码器不可用：\(reason)"
        }
    }
}
