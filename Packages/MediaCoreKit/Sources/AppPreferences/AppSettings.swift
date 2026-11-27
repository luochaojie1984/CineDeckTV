import Foundation
import SubtitleKit

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
        case automatic, ksplayer, fsplayer, avplayer
        public var displayName: String {
            switch self {
            case .automatic: return "自动（KSPlayer 优先）"
            case .ksplayer: return "KSPlayer"
            case .fsplayer: return "FSPlayer"
            case .avplayer: return "AVPlayer"
            }
        }
    }

    public enum ScalingPreference: String, Codable, Sendable, CaseIterable {
        case aspectFit, aspectFill, fill
        public var displayName: String {
            switch self {
            case .aspectFit: return "等比适配"
            case .aspectFill: return "等比裁切"
            case .fill: return "铺满拉伸"
            }
        }
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

    public enum ShortPressSeekBehavior: String, CaseIterable, Codable, Sendable {
        case fixedStepJump
        case multiStageShuttle

        public var displayName: String {
            switch self {
            case .fixedStepJump: return "定长跳秒"
            case .multiStageShuttle: return "多级倍速穿梭"
            }
        }
    }

    public enum LongPressSeekMode: String, CaseIterable, Codable, Sendable {
        case mxLiveKeyframeScrub
        case continuousFastPlay

        public var displayName: String {
            switch self {
            case .mxLiveKeyframeScrub: return "实时出画快进"
            case .continuousFastPlay: return "连续倍速播放"
            }
        }
    }

    public enum ScrubBarColorPreset: String, CaseIterable, Codable, Sendable {
        case skyBlue = "#38BDF8"
        case appleBlue = "#0A84FF"
        case emerald = "#34D399"
        case amberGold = "#FBBF24"
        case coralRed = "#FB7185"
        case pureWhite = "#FFFFFF"

        public var displayName: String {
            switch self {
            case .skyBlue: return "极光蓝"
            case .appleBlue: return "苹果蓝"
            case .emerald: return "翠绿"
            case .amberGold: return "琥珀金"
            case .coralRed: return "珊瑚红"
            case .pureWhite: return "纯白"
            }
        }
    }

    public var shortSeekSeconds: Double
    public var shortPressSeekBehavior: ShortPressSeekBehavior
    public var longPressSeekMode: LongPressSeekMode
    public var enableTouchpadScrub: Bool
    public var enableResumePlayback: Bool
    public var scrubBarColorHex: String
    /// 默认关闭；开启后仅在进入共享盘视频目录时展示 `.nfo` 与封面刮削详情，首页保持纯净。
    public var enableMetadataDisplay: Bool

    public static let currentSubtitleDefaultsVersion = 2

    public var subtitleStyle: SubtitleStyleConfig
    public var subtitleDefaultsVersion: Int
    public var lastVisitedPaths: [String: String]

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
        rememberLastDirectory: Bool = true,
        shortSeekSeconds: Double = 10,
        shortPressSeekBehavior: ShortPressSeekBehavior = .fixedStepJump,
        longPressSeekMode: LongPressSeekMode = .mxLiveKeyframeScrub,
        enableTouchpadScrub: Bool = true,
        enableResumePlayback: Bool = true,
        scrubBarColorHex: String = ScrubBarColorPreset.skyBlue.rawValue,
        enableMetadataDisplay: Bool = false,
        subtitleStyle: SubtitleStyleConfig = SubtitleStyleConfig(),
        subtitleDefaultsVersion: Int = AppSettings.currentSubtitleDefaultsVersion,
        lastVisitedPaths: [String: String] = [:]
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
        self.shortSeekSeconds = shortSeekSeconds
        self.shortPressSeekBehavior = shortPressSeekBehavior
        self.longPressSeekMode = longPressSeekMode
        self.enableTouchpadScrub = enableTouchpadScrub
        self.enableResumePlayback = enableResumePlayback
        self.scrubBarColorHex = scrubBarColorHex
        self.enableMetadataDisplay = enableMetadataDisplay
        self.subtitleStyle = subtitleStyle
        self.subtitleDefaultsVersion = subtitleDefaultsVersion
        self.lastVisitedPaths = lastVisitedPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decodePreference = try c.decodeIfPresent(DecodePreference.self, forKey: .decodePreference) ?? .automatic
        enginePreference = try c.decodeIfPresent(EnginePreference.self, forKey: .enginePreference) ?? .automatic
        scalingPreference = try c.decodeIfPresent(ScalingPreference.self, forKey: .scalingPreference) ?? .aspectFit
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1.0
        scrubMode = try c.decodeIfPresent(ScrubMode.self, forKey: .scrubMode) ?? .standard
        cacheMegabytes = try c.decodeIfPresent(Int.self, forKey: .cacheMegabytes) ?? 96
        autoPlayNextEpisode = try c.decodeIfPresent(Bool.self, forKey: .autoPlayNextEpisode) ?? true
        preferSimplifiedChineseSubtitle = try c.decodeIfPresent(Bool.self, forKey: .preferSimplifiedChineseSubtitle) ?? true
        externalSubtitleDirectories = try c.decodeIfPresent([String].self, forKey: .externalSubtitleDirectories) ?? ["Subs", "Subtitles", "Subtitle", "字幕"]
        rememberLastDirectory = try c.decodeIfPresent(Bool.self, forKey: .rememberLastDirectory) ?? true
        shortSeekSeconds = try c.decodeIfPresent(Double.self, forKey: .shortSeekSeconds) ?? 10
        shortPressSeekBehavior = try c.decodeIfPresent(ShortPressSeekBehavior.self, forKey: .shortPressSeekBehavior) ?? .fixedStepJump
        longPressSeekMode = try c.decodeIfPresent(LongPressSeekMode.self, forKey: .longPressSeekMode) ?? .mxLiveKeyframeScrub
        enableTouchpadScrub = try c.decodeIfPresent(Bool.self, forKey: .enableTouchpadScrub) ?? true
        enableResumePlayback = try c.decodeIfPresent(Bool.self, forKey: .enableResumePlayback) ?? true
        scrubBarColorHex = try c.decodeIfPresent(String.self, forKey: .scrubBarColorHex) ?? ScrubBarColorPreset.skyBlue.rawValue
        enableMetadataDisplay = try c.decodeIfPresent(Bool.self, forKey: .enableMetadataDisplay) ?? false
        let savedSubtitleVersion = try c.decodeIfPresent(Int.self, forKey: .subtitleDefaultsVersion) ?? 1
        var decodedSubtitleStyle = try c.decodeIfPresent(SubtitleStyleConfig.self, forKey: .subtitleStyle) ?? SubtitleStyleConfig()
        if savedSubtitleVersion < Self.currentSubtitleDefaultsVersion {
            decodedSubtitleStyle.fontFamily = .kaiti
            decodedSubtitleStyle.fontSize = 66
            decodedSubtitleStyle.bottomInset = 8
        }
        subtitleStyle = decodedSubtitleStyle
        subtitleDefaultsVersion = Self.currentSubtitleDefaultsVersion
        lastVisitedPaths = try c.decodeIfPresent([String: String].self, forKey: .lastVisitedPaths) ?? [:]
    }

    /// 缓存硬上限：<= 192 MB，默认 96 MB。
    public var clampedCacheBytes: Int {
        min(192, max(16, cacheMegabytes)) * 1024 * 1024
    }
}
