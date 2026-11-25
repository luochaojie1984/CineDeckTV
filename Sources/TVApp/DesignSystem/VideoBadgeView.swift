import SwiftUI

/// 规格徽章（4K / HDR10 / HEVC / 10bit / Atmos ...），单行不换行。
public struct VideoBadgeView: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .heavy))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(badgeTint.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(badgeTint.opacity(0.65), lineWidth: 1))
            .foregroundStyle(badgeTint)
    }

    private var badgeTint: Color {
        switch text {
        case "4K", "HDR10", "HDR10+", "DV": return Color(red: 1.0, green: 0.72, blue: 0.28)
        case "HEVC", "AV1", "H.264": return Color(red: 0.55, green: 0.80, blue: 1.0)
        case "Atmos", "TrueHD", "DTS": return Color(red: 0.72, green: 0.62, blue: 1.0)
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
        HStack(spacing: 8) {
            ForEach(Array(badges.prefix(3).enumerated()), id: \.offset) { _, badge in
                VideoBadgeView(badge)
            }
        }
    }
}
