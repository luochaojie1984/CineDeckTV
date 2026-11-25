import Foundation

public struct AppSettings: Codable, Sendable, Equatable {
    public enum DecodePreference: String, Codable, Sendable, CaseIterable {
        case hardware, software, automatic
        public var displayName: String {
            switch self {
            case .hardware: return "硬件解码"
            case .software: return "软件解码"
            case .automatic: return "自动"
            }
        }
    }

    public enum EnginePreference: String, Codable, Sendable, CaseIterable {
        case automatic, fsplayer, avplayer
        public var displayName: String {
            switch self {
            case .automatic: return "自动（FSPlayer 优先）"
            case .fsplayer: return "FSPlayer"
            case .avplayer: return "AVPlayer"
            }
        }
    }

    public enum ScalingPreference: String, Codable, Sendable, CaseIterable {
        case aspectFit, aspectFill, fill
    }

    public var decodePreference: DecodePreference
    public var enginePreference: EnginePreference
    public var scalingPreference: ScalingPreference
    public var playbackRate: Double
    public var scrubMode: ScrubMode
    public var cacheMegabytes: Int
    public var autoPlayNextEpisode: Bool
    public var preferSimplifiedChineseSubtitle: Bool
    public var externalSubtitleDirectories: [String]
    public var rememberLastDirectory: Bool

    public enum ScrubMode: String, Codable, Sendable, CaseIterable {
        case fine, standard, turbo
        public var displayName: String {
            switch self {
            case .fine: return "精细 4x→60x"
            case .standard: return "标准 6x→120x"
            case .turbo: return "极速 10x→240x"
            }
        }
        public var initialRate: Double {
            switch self {
            case .fine: return 4
            case .standard: return 6
            case .turbo: return 10
            }
        }
        public var growth: Double {
            switch self {
            case .fine: return 2.15
            case .standard: return 2.25
            case .turbo: return 2.40
            }
        }
        public var ceiling: Double {
            switch self {
            case .fine: return 60
            case .standard: return 120
            case .turbo: return 240
            }
        }
    }

    public init(
        decodePreference: DecodePreference = .automatic,
        enginePreference: EnginePreference = .automatic,
        scalingPreference: ScalingPreference = .aspectFit,
        playbackRate: Double = 1.0,
        scrubMode: ScrubMode = .standard,
        cacheMegabytes: Int = 96,
        autoPlayNextEpisode: Bool = true,
        preferSimplifiedChineseSubtitle: Bool = true,
        externalSubtitleDirectories: [String] = ["Subs", "Subtitles", "Subtitle", "字幕"],
        rememberLastDirectory: Bool = true
    ) {
        self.decodePreference = decodePreference
        self.enginePreference = enginePreference
        self.scalingPreference = scalingPreference
        self.playbackRate = playbackRate
        self.scrubMode = scrubMode
        self.cacheMegabytes = cacheMegabytes
        self.autoPlayNextEpisode = autoPlayNextEpisode
        self.preferSimplifiedChineseSubtitle = preferSimplifiedChineseSubtitle
        self.externalSubtitleDirectories = externalSubtitleDirectories
        self.rememberLastDirectory = rememberLastDirectory
    }

    /// 缓存硬上限：文档要求 <= 192 MB，默认 96 MB。
    public var clampedCacheBytes: Int {
        min(192, max(16, cacheMegabytes)) * 1024 * 1024
    }
}
