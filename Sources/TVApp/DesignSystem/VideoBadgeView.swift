import SwiftUI

/// 规格徽章（4K / HDR10 / DV / HEVC / 10bit / Atmos），带柔和渐变与玻璃边框。
public struct VideoBadgeView: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                LinearGradient(
                    colors: [badgeTint.opacity(0.32), badgeTint.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(badgeTint.opacity(0.72), lineWidth: 1))
            .foregroundStyle(Color.white.opacity(0.95))
    }

    private var badgeTint: Color {
        switch text {
        case "4K", "HDR10", "HDR10+", "DV": return TVTokens.Color.amber
        case "HEVC", "AV1", "H.264": return TVTokens.Color.accent
        case "Atmos", "TrueHD", "DTS": return TVTokens.Color.violet
        default: return Color.white.opacity(0.65)
        }
    }
}

public struct VideoBadgeRow: View {
    public let badges: [String]
    public let maxCount: Int

    public init(_ badges: [String], maxCount: Int = 4) {
        self.badges = badges
        self.maxCount = maxCount
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(badges.prefix(maxCount).enumerated()), id: \.offset) { _, badge in
                VideoBadgeView(badge)
            }
        }
    }
}
