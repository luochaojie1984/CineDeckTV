import Foundation

/// 文本字幕样式配置：支持 7 款真实中文字体（内置 5 款开源中文 TTF：楷体/宋体/仿宋/圆体/电影艺术黑 + 系统黑体/粗黑）、10 种字幕配色、字号、底距位置、描边、底框、对齐与时间偏移。
public struct SubtitleStyleConfig: Codable, Sendable, Equatable {
    public enum HorizontalAlignment: String, Codable, Sendable, CaseIterable {
        case leading, center, trailing

        public var displayName: String {
            switch self {
            case .leading: return "左对齐"
            case .center: return "居中"
            case .trailing: return "右对齐"
            }
        }
    }

    public enum FontFamily: String, Codable, Sendable, CaseIterable {
        case system
        case heavy
        case kaiti
        case songti
        case fangsong
        case rounded
        case smiley

        public var displayName: String {
            switch self {
            case .system: return "影院黑体"
            case .heavy: return "醒目粗黑"
            case .kaiti: return "经典楷体"
            case .songti: return "书香宋体"
            case .fangsong: return "朱雀仿宋"
            case .rounded: return "柔和圆体"
            case .smiley: return "电影艺术黑"
            }
        }

        /// 打包在 `CineDeckTV.app/Fonts/` 中的真实中文字体文件名（系统内置黑体返回 nil）。
        public var bundledFileName: String? {
            switch self {
            case .system, .heavy: return nil
            case .kaiti: return "CineDeck-Kaiti.ttf"
            case .songti: return "CineDeck-Songti.ttf"
            case .fangsong: return "CineDeck-Fangsong.ttf"
            case .rounded: return "CineDeck-Yuanti.ttf"
            case .smiley: return "CineDeck-Smiley.ttf"
            }
        }

        /// CoreText / UIFont 精确 PostScript 名称。
        public var postScriptName: String {
            switch self {
            case .system: return "PingFangSC-Medium"
            case .heavy: return "PingFangSC-Semibold"
            case .kaiti: return "GBZenKai-Medium"
            case .songti: return "BousungEG-Light-GB"
            case .fangsong: return "ZhuqueFangsong-Regular"
            case .rounded: return "LXGWMarkerGothic-Regular"
            case .smiley: return "SmileySans-Oblique"
            }
        }

        /// 供 FSPlayer (libass) 使用的字体家族名。
        public var libassFamilyName: String {
            switch self {
            case .system, .heavy: return "PingFang SC"
            case .kaiti: return "AR PL KaitiM GB"
            case .songti: return "AR PL SungtiL GB"
            case .fangsong: return "Zhuque Fangsong (technical preview)"
            case .rounded: return "LXGW Marker Gothic"
            case .smiley: return "Smiley Sans"
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "serif": self = .songti
            case "monospaced": self = .system
            default:
                self = FontFamily(rawValue: raw) ?? .system
            }
        }
    }

    public struct ColorPreset: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let hex: String

        public init(name: String, hex: String) {
            self.id = hex
            self.name = name
            self.hex = hex
        }
    }

    /// 10 种客厅观影高对比字幕配色预设。
    public static let colorPresets: [ColorPreset] = [
        ColorPreset(name: "纯白", hex: "#FFFFFF"),
        ColorPreset(name: "暖黄", hex: "#FFD859"),
        ColorPreset(name: "琥珀金", hex: "#F59E0B"),
        ColorPreset(name: "冰蓝", hex: "#7AD7FF"),
        ColorPreset(name: "湖青", hex: "#22D3EE"),
        ColorPreset(name: "翠绿", hex: "#4ADE80"),
        ColorPreset(name: "薄荷", hex: "#5EEAD4"),
        ColorPreset(name: "樱花粉", hex: "#FDA4AF"),
        ColorPreset(name: "丁香紫", hex: "#C4B5FD"),
        ColorPreset(name: "柔和灰", hex: "#D4D4D8")
    ]

    public var fontFamily: FontFamily
    public var fontSize: Double
    public var foregroundHex: String
    public var outlineHex: String
    public var outlineWidth: Double
    public var backgroundOpacity: Double
    public var bottomInset: Double
    public var offsetSeconds: Double
    public var alignment: HorizontalAlignment
    public var forceCustomStyle: Bool

    public init(
        fontFamily: FontFamily = .system,
        fontSize: Double = 38,
        foregroundHex: String = "#FFFFFF",
        outlineHex: String = "#000000",
        outlineWidth: Double = 2.0,
        backgroundOpacity: Double = 0.32,
        bottomInset: Double = 56,
        offsetSeconds: Double = 0,
        alignment: HorizontalAlignment = .center,
        forceCustomStyle: Bool = false
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.foregroundHex = foregroundHex
        self.outlineHex = outlineHex
        self.outlineWidth = outlineWidth
        self.backgroundOpacity = backgroundOpacity
        self.bottomInset = bottomInset
        self.offsetSeconds = offsetSeconds
        self.alignment = alignment
        self.forceCustomStyle = forceCustomStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try c.decodeIfPresent(FontFamily.self, forKey: .fontFamily) ?? .system
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 38
        foregroundHex = try c.decodeIfPresent(String.self, forKey: .foregroundHex) ?? "#FFFFFF"
        outlineHex = try c.decodeIfPresent(String.self, forKey: .outlineHex) ?? "#000000"
        outlineWidth = try c.decodeIfPresent(Double.self, forKey: .outlineWidth) ?? 2.0
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.32
        bottomInset = try c.decodeIfPresent(Double.self, forKey: .bottomInset) ?? 56
        offsetSeconds = try c.decodeIfPresent(Double.self, forKey: .offsetSeconds) ?? 0
        alignment = try c.decodeIfPresent(HorizontalAlignment.self, forKey: .alignment) ?? .center
        forceCustomStyle = try c.decodeIfPresent(Bool.self, forKey: .forceCustomStyle) ?? false
    }
}
