import SwiftUI

/// 10-foot 设计令牌（基准 1920x1080）。所有页面只引用这里的数值，禁止散写魔法数字。
public enum TVTokens {
    public enum Spacing {
        public static let pageHorizontal: CGFloat = 40
        public static let browserHorizontal: CGFloat = 32
        public static let sectionVertical: CGFloat = 32
        public static let gridSpacing: CGFloat = 22
        public static let cardInner: CGFloat = 18
    }

    public enum Radius {
        public static let card: CGFloat = 18
        public static let iconBlock: CGFloat = 16
        public static let gridIconBlock: CGFloat = 18
        public static let capsule: CGFloat = 28
        public static let panel: CGFloat = 24
    }

    public enum Typography {
        public static let pageTitle = Font.system(size: 42, weight: .heavy)
        public static let sectionTitle = Font.system(size: 34, weight: .bold)
        public static let directoryTitle = Font.system(size: 36, weight: .bold)
        public static let listPrimary = Font.system(size: 32, weight: .semibold)
        public static let gridPrimary = Font.system(size: 28, weight: .bold)
        public static let secondary = Font.system(size: 22, weight: .medium)
        public static let tertiary = Font.system(size: 20, weight: .medium)
        public static let button = Font.system(size: 24, weight: .semibold)
        public static let heroTitle = Font.system(size: 44, weight: .heavy)
    }

    public enum Size {
        public static let capsuleHeight: CGFloat = 56
        public static let toolbarHeight: CGFloat = 84
        public static let listIcon: CGFloat = 68
        public static let gridIcon: CGFloat = 76
        public static let gridCardHeight: CGFloat = 220
        public static let heroHeight: CGFloat = 440
        public static let drawerWidth: CGFloat = 580
        public static let summaryBarHeight: CGFloat = 48
    }

    public enum Color {
        public static let backgroundTop = SwiftUI.Color(red: 0.027, green: 0.039, blue: 0.071)
        public static let backgroundBottom = SwiftUI.Color(red: 0.055, green: 0.082, blue: 0.145)
        public static let accent = SwiftUI.Color(red: 0.35, green: 0.78, blue: 0.98)
        public static let folderTint = SwiftUI.Color(red: 0.24, green: 0.62, blue: 0.94)
        public static let videoTint = SwiftUI.Color(red: 0.44, green: 0.46, blue: 0.95)
        public static let subtitleTint = SwiftUI.Color(red: 0.30, green: 0.80, blue: 0.72)
        public static let backTint = SwiftUI.Color.white.opacity(0.28)
        public static let cardSurface = SwiftUI.Color.white.opacity(0.06)
        public static let secondaryText = SwiftUI.Color.white.opacity(0.72)
    }

    public enum Motion {
        public static let focus = Animation.spring(response: 0.24, dampingFraction: 0.78)
    }

    public static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [Color.backgroundTop, Color.backgroundBottom], startPoint: .top, endPoint: .bottom)
    }
}
