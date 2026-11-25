import Foundation
import CoreGraphics

/// 统一播放引擎接口：FSPlayer（主）与 AVPlayer（兜底）均实现它，支持无感知自动回退与手动热切换。
@MainActor
public protocol PlayerEngine: AnyObject {
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

public struct MediaTrackItem: Identifiable, Hashable, Sendable {
    public let id: Int32
    public let title: String
    public let language: String
    public let codecName: String
    public let isSelected: Bool

    public init(id: Int32, title: String, language: String, codecName: String, isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.language = language
        self.codecName = codecName
        self.isSelected = isSelected
    }

    public var displayName: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        if !language.isEmpty && !title.localizedCaseInsensitiveContains(language) { parts.append(language.uppercased()) }
        if !codecName.isEmpty { parts.append("[\(codecName.uppercased())]") }
        return parts.isEmpty ? "轨道 #\(id)" : parts.joined(separator: " · ")
    }
}

public struct PlaybackTechStats: Sendable, Equatable {
    public var engineName: String = "—"
    public var videoCodec: String = "—"
    public var audioCodec: String = "—"
    public var resolution: String = "—"
    public var fps: Double = 0
    public var outputFPS: Double = 0
    public var bitrateMbps: Double = 0
    public var droppedFrames: Int32 = 0
    public var downloadSpeedMBps: Double = 0
    public var isHardwareDecode: Bool = true
    public var bufferingProgress: Int = 0

    public init() {}
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
        case .aspectFit: return "等比适配"
        case .aspectFill: return "等比裁切"
        case .fill: return "铺满拉伸"
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
