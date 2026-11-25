import SwiftUI

/// 10-foot 设计令牌（基准 1920x1080）：多层次影院配色、液态玻璃极光环境光效与媒体主题映射。
public enum TVTokens {
    public enum Spacing {
        public static let pageHorizontal: CGFloat = 56
        public static let browserHorizontal: CGFloat = 56
        public static let sectionVertical: CGFloat = 34
        public static let gridSpacing: CGFloat = 24
        public static let cardInner: CGFloat = 20
    }

    public enum Radius {
        public static let card: CGFloat = 22
        public static let iconBlock: CGFloat = 16
        public static let gridIconBlock: CGFloat = 18
        public static let capsule: CGFloat = 30
        public static let panel: CGFloat = 28
    }

    public enum Typography {
        public static let pageTitle = Font.system(size: 44, weight: .heavy, design: .rounded)
        public static let sectionTitle = Font.system(size: 32, weight: .bold, design: .rounded)
        public static let directoryTitle = Font.system(size: 34, weight: .bold, design: .rounded)
        public static let listPrimary = Font.system(size: 28, weight: .semibold)
        public static let gridPrimary = Font.system(size: 25, weight: .bold)
        public static let secondary = Font.system(size: 21, weight: .medium)
        public static let tertiary = Font.system(size: 18, weight: .medium)
        public static let button = Font.system(size: 22, weight: .semibold)
        public static let heroTitle = Font.system(size: 42, weight: .heavy, design: .rounded)
    }

    public enum Size {
        public static let capsuleHeight: CGFloat = 56
        public static let toolbarHeight: CGFloat = 88
        public static let listIcon: CGFloat = 62
        public static let gridIcon: CGFloat = 68
        public static let gridCardHeight: CGFloat = 250
        public static let heroHeight: CGFloat = 410
        public static let drawerWidth: CGFloat = 640
        public static let summaryBarHeight: CGFloat = 48
    }

    public enum Color {
        public static let backgroundTop = SwiftUI.Color(red: 0.022, green: 0.036, blue: 0.086)
        public static let backgroundMid = SwiftUI.Color(red: 0.044, green: 0.068, blue: 0.148)
        public static let backgroundBottom = SwiftUI.Color(red: 0.028, green: 0.042, blue: 0.098)

        public static let accent = SwiftUI.Color(red: 0.24, green: 0.76, blue: 0.99)
        public static let amber = SwiftUI.Color(red: 0.98, green: 0.71, blue: 0.26)
        public static let violet = SwiftUI.Color(red: 0.65, green: 0.49, blue: 0.99)
        public static let emerald = SwiftUI.Color(red: 0.20, green: 0.85, blue: 0.72)
        public static let coral = SwiftUI.Color(red: 0.98, green: 0.45, blue: 0.56)
        public static let indigo = SwiftUI.Color(red: 0.42, green: 0.49, blue: 0.99)

        public static let folderTint = SwiftUI.Color(red: 0.20, green: 0.72, blue: 0.96)
        public static let videoTint = SwiftUI.Color(red: 0.48, green: 0.52, blue: 0.99)
        public static let subtitleTint = SwiftUI.Color(red: 0.22, green: 0.85, blue: 0.74)
        public static let backTint = SwiftUI.Color.white.opacity(0.28)
        public static let cardSurface = SwiftUI.Color.white.opacity(0.075)
        public static let secondaryText = SwiftUI.Color.white.opacity(0.78)
        public static let tertiaryText = SwiftUI.Color.white.opacity(0.56)
    }

    public enum Motion {
        public static let focus = Animation.spring(response: 0.30, dampingFraction: 0.74)
        public static let panel = Animation.spring(response: 0.36, dampingFraction: 0.80)
        public static let ambient = Animation.easeInOut(duration: 0.85)
    }

    public static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Color.backgroundTop, Color.backgroundMid, Color.backgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

public enum CinemaAmbientPalette: Sendable, Equatable {
    case home
    case browser
    case history
    case sources
    case settings
}

/// 影院级多色极光背景：为 tvOS 26/27 `.glassEffect` 提供可折射的柔和环境光斑，并严格裁切在边界内避免溢出。
public struct CinemaAmbientBackdrop: View {
    public let palette: CinemaAmbientPalette

    public init(palette: CinemaAmbientPalette = .home) {
        self.palette = palette
    }

    public var body: some View {
        ZStack {
            TVTokens.backgroundGradient

            RadialGradient(
                colors: [primaryOrb.opacity(0.28), primaryOrb.opacity(0.07), .clear],
                center: UnitPoint(x: 0.16, y: 0.14),
                startRadius: 20,
                endRadius: 680
            )

            RadialGradient(
                colors: [secondaryOrb.opacity(0.24), secondaryOrb.opacity(0.06), .clear],
                center: UnitPoint(x: 0.86, y: 0.24),
                startRadius: 20,
                endRadius: 720
            )

            RadialGradient(
                colors: [tertiaryOrb.opacity(0.20), .clear],
                center: UnitPoint(x: 0.52, y: 0.92),
                startRadius: 30,
                endRadius: 640
            )
        }
        .animation(TVTokens.Motion.ambient, value: palette)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var primaryOrb: Color {
        switch palette {
        case .home: return TVTokens.Color.amber
        case .browser: return TVTokens.Color.folderTint
        case .history: return TVTokens.Color.violet
        case .sources: return TVTokens.Color.emerald
        case .settings: return TVTokens.Color.indigo
        }
    }

    private var secondaryOrb: Color {
        switch palette {
        case .home: return TVTokens.Color.accent
        case .browser: return TVTokens.Color.indigo
        case .history: return TVTokens.Color.amber
        case .sources: return TVTokens.Color.accent
        case .settings: return TVTokens.Color.accent
        }
    }

    private var tertiaryOrb: Color {
        switch palette {
        case .home: return TVTokens.Color.violet
        case .browser: return TVTokens.Color.emerald
        case .history: return TVTokens.Color.accent
        case .sources: return TVTokens.Color.violet
        case .settings: return TVTokens.Color.emerald
        }
    }
}

public struct TVMediaPalette: Sendable {
    public let primary: Color
    public let secondary: Color
    public let symbol: String
    public let tag: String

    public init(primary: Color, secondary: Color, symbol: String, tag: String) {
        self.primary = primary
        self.secondary = secondary
        self.symbol = symbol
        self.tag = tag
    }
}

/// 根据片名与介质类型映射富层次配色（Dolby Vision / HDR 金琥珀、4K HEVC 深海蓝、Atmos 紫罗兰、目录青绿）。
public enum TVMediaTheme {
    public static func palette(forTitle title: String, isDirectory: Bool = false, isSubtitle: Bool = false) -> TVMediaPalette {
        if isDirectory {
            return TVMediaPalette(
                primary: TVTokens.Color.folderTint,
                secondary: TVTokens.Color.indigo,
                symbol: "folder.fill",
                tag: "共享目录"
            )
        }
        if isSubtitle {
            return TVMediaPalette(
                primary: TVTokens.Color.emerald,
                secondary: TVTokens.Color.accent,
                symbol: "captions.bubble.fill",
                tag: "外挂字幕"
            )
        }
        let upper = title.uppercased()
        if upper.contains("DV") || upper.contains("DOLBY") || upper.contains("VISION") {
            return TVMediaPalette(
                primary: TVTokens.Color.amber,
                secondary: TVTokens.Color.coral,
                symbol: "sparkles.tv.fill",
                tag: "Dolby Vision"
            )
        }
        if upper.contains("HDR10") || upper.contains("HDR") {
            return TVMediaPalette(
                primary: TVTokens.Color.amber,
                secondary: TVTokens.Color.violet,
                symbol: "sun.max.fill",
                tag: "4K HDR"
            )
        }
        if upper.contains("ATMOS") || upper.contains("TRUEHD") {
            return TVMediaPalette(
                primary: TVTokens.Color.violet,
                secondary: TVTokens.Color.accent,
                symbol: "waveform.circle.fill",
                tag: "沉浸全景声"
            )
        }
        if upper.contains("2160") || upper.contains("4K") || upper.contains("HEVC") {
            return TVMediaPalette(
                primary: TVTokens.Color.accent,
                secondary: TVTokens.Color.indigo,
                symbol: "film.stack.fill",
                tag: "4K UHD"
            )
        }
        return TVMediaPalette(
            primary: TVTokens.Color.indigo,
            secondary: TVTokens.Color.emerald,
            symbol: "film.fill",
            tag: "HD 影库"
        )
    }
}

public enum TVTitleFormatter {
    private static let mediaExts: Set<String> = ["mkv", "mp4", "mov", "m4v", "ts", "m2ts", "avi", "webm", "flv"]

    public static func cleanDisplayTitle(_ raw: String) -> String {
        let ext = (raw as NSString).pathExtension.lowercased()
        guard mediaExts.contains(ext) else { return raw }
        let stripped = (raw as NSString).deletingPathExtension
        return stripped.isEmpty ? raw : stripped
    }
}

/// 发光渐变胶囊进度条：替代生硬系统 ProgressView。
public struct TVProgressBar: View {
    public let progress: Double
    public let tint: Color
    public let secondaryTint: Color
    public let height: CGFloat

    public init(
        progress: Double,
        tint: Color = TVTokens.Color.accent,
        secondaryTint: Color = TVTokens.Color.violet,
        height: CGFloat = 7
    ) {
        self.progress = progress
        self.tint = tint
        self.secondaryTint = secondaryTint
        self.height = height
    }

    public var body: some View {
        let clamped = min(max(progress.isFinite ? progress : 0, 0), 1)
        GeometryReader { geo in
            let w = max(height, geo.size.width * clamped)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                if clamped > 0.005 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint, secondaryTint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: min(geo.size.width, w))
                        .shadow(color: tint.opacity(0.55), radius: 6, x: 0, y: 0)
                }
            }
        }
        .frame(height: height)
    }
}
