import SwiftUI

/// 规格徽章（4K / HDR10 / DV / HEVC / 10bit / Atmos），10-foot 大屏高对比可识别字号。
public struct VideoBadgeView: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 19, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(badgeTint.opacity(0.24), in: Capsule())
            .overlay(Capsule().strokeBorder(badgeTint.opacity(0.72), lineWidth: 1.2))
            .foregroundStyle(badgeTint)
    }

    private var badgeTint: Color {
        switch text {
        case "4K", "HDR10", "HDR10+", "DV": return Color(red: 1.0, green: 0.74, blue: 0.28)
        case "HEVC", "AV1", "H.264": return Color(red: 0.50, green: 0.82, blue: 1.0)
        case "Atmos", "TrueHD", "DTS": return Color(red: 0.76, green: 0.64, blue: 1.0)
        default: return TVTokens.Color.secondaryText
        }
    }
}

public struct VideoBadgeRow: View {
    public let badges: [String]

    public init(_ badges: [String]) {
        self.badges = badges
    }

    public var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(badges.prefix(4).enumerated()), id: \.offset) { _, badge in
                VideoBadgeView(badge)
            }
        }
    }
}
