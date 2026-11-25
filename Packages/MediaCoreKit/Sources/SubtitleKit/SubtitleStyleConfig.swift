import Foundation

/// 文本字幕样式（AVPlayer 回退路径渲染，以及映射到 FSSubtitlePreference 的中间模型）。
public struct SubtitleStyleConfig: Codable, Sendable, Equatable {
    public enum HorizontalAlignment: String, Codable, Sendable, CaseIterable {
        case leading, center, trailing
    }

    public var fontSize: Double
    public var foregroundHex: String
    public var outlineHex: String
    public var outlineWidth: Double
    public var bottomInset: Double
    public var offsetSeconds: Double
    public var alignment: HorizontalAlignment

    public init(
        fontSize: Double = 34,
        foregroundHex: String = "#FFFFFF",
        outlineHex: String = "#000000",
        outlineWidth: Double = 2,
        bottomInset: Double = 56,
        offsetSeconds: Double = 0,
        alignment: HorizontalAlignment = .center
    ) {
        self.fontSize = fontSize
        self.foregroundHex = foregroundHex
        self.outlineHex = outlineHex
        self.outlineWidth = outlineWidth
        self.bottomInset = bottomInset
        self.offsetSeconds = offsetSeconds
        self.alignment = alignment
    }
}
