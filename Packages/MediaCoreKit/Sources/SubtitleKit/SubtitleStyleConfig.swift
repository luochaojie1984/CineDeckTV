import Foundation

/// 文本字幕样式配置：供 KSPlayer / AVPlayer 叠加层与 FSPlayer 字幕引擎实时联动（支持字体、字号、位置、配色、描边、底框、对齐与时间偏移）。
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
        case rounded
        case heavy
        case serif
        case monospaced

        public var displayName: String {
            switch self {
            case .system: return "影院黑体"
            case .rounded: return "柔和圆体"
            case .heavy: return "醒目粗黑"
            case .serif: return "经典宋体"
            case .monospaced: return "等宽清晰"
            }
        }
    }

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
