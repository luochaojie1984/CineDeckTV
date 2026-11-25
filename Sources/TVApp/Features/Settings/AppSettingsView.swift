import SwiftUI
import AppPreferences

/// 偏好设置工坊：双栏 Apple TV 4K 液态玻璃控制台（左栏分类导航 + 右栏分组卡片与实时快进胶囊预览，零截断零溢出）。
public struct AppSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedCategory: SettingsCategory = .playback

    public init() {}

    public enum SettingsCategory: String, CaseIterable, Identifiable {
        case playback
        case scrubbing
        case appearance
        case storage

        public var id: String { rawValue }

        var title: String {
            switch self {
            case .playback: return "播放与解码"
            case .scrubbing: return "快进与遥控"
            case .appearance: return "胶囊与视效"
            case .storage: return "缓存与片库"
            }
        }

        var subtitle: String {
            switch self {
            case .playback: return "双引擎、硬解与变速曲线"
            case .scrubbing: return "短按、长按与 Siri 触控"
            case .appearance: return "悬浮胶囊高亮与画面比例"
            case .storage: return "192 MB 上限与续播策略"
            }
        }

        var icon: String {
            switch self {
            case .playback: return "cpu.fill"
            case .scrubbing: return "forward.fill"
            case .appearance: return "sparkles"
            case .storage: return "externaldrive.fill"
            }
        }

        var tint: Color {
            switch self {
            case .playback: return TVTokens.Color.accent
            case .scrubbing: return TVTokens.Color.amber
            case .appearance: return TVTokens.Color.violet
            case .storage: return TVTokens.Color.emerald
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("偏好设置")
                        .font(TVTokens.Typography.pageTitle)
                    Text("专为 Apple TV 4K 调优的解码性能、闭环同步快进与 tvOS 液态玻璃视效")
                        .font(TVTokens.Typography.secondary)
                        .foregroundStyle(TVTokens.Color.secondaryText)
                }
                Spacer()
                HStack(spacing: 10) {
                    Circle().fill(TVTokens.Color.emerald).frame(width: 8, height: 8)
                    Text("CineDeckTV 0.3.0 · Dual Engine")
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TVTokens.Color.secondaryText)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .tvGlassSurface(cornerRadius: TVTokens.Radius.capsule, clear: true)
            }
            .focusSection()

            HStack(alignment: .top, spacing: 32) {
                sidebar
                    .frame(width: 400)
                    .focusSection()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        categoryDetailContent
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(TVTokens.Motion.panel, value: selectedCategory)
                .focusSection()
            }
        }
        .padding(.horizontal, TVTokens.Spacing.pageHorizontal)
        .padding(.top, 24)
        .padding(.bottom, 32)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(SettingsCategory.allCases) { category in
                let isActive = selectedCategory == category
                Button {
                    withAnimation(TVTokens.Motion.panel) {
                        selectedCategory = category
                    }
                } label: {
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isActive ? category.tint : Color.clear)
                            .frame(width: 5, height: 42)

                        Image(systemName: category.icon)
                            .font(.system(size: 24, weight: .semibold))
                            .frame(width: 52, height: 52)
                            .background(category.tint.opacity(isActive ? 0.32 : 0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(isActive ? .white : category.tint)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(category.title)
                                .font(.system(size: 25, weight: .bold))
                            Text(category.subtitle)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(TVTokens.Color.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(TVListRowButtonStyle(accentTint: category.tint))
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 8) {
                Label("实时胶囊高亮：\(currentColorPresetName)", systemImage: "paintpalette.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(cdHex: env.settings.scrubBarColorHex))
                Text("快进挡位：\(env.settings.scrubMode.displayName)")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TVTokens.Color.secondaryText)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tvGlassSurface(cornerRadius: TVTokens.Radius.card, clear: true)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var categoryDetailContent: some View {
        switch selectedCategory {
        case .playback:
            settingCard(title: "播放内核", subtitle: "FSPlayer (FFmpeg 7 + Metal) 主攻 MKV/HDR/外挂字幕，AVPlayer 负责杜比视界") {
                gridChoices(
                    items: AppSettings.EnginePreference.allCases.map { ($0, $0.displayName) },
                    columns: 3,
                    selected: env.settings.enginePreference,
                    tint: TVTokens.Color.accent
                ) { value in
                    env.update(settings: mutated { $0.enginePreference = value })
                }
            }

            settingCard(title: "视频解码方式", subtitle: "推荐使用自动，4K HEVC/H.264 优先走 VideoToolbox 硬解零拷贝") {
                gridChoices(
                    items: AppSettings.DecodePreference.allCases.map { ($0, $0.displayName) },
                    columns: 3,
                    selected: env.settings.decodePreference,
                    tint: TVTokens.Color.emerald
                ) { value in
                    env.update(settings: mutated { $0.decodePreference = value })
                }
            }

            settingCard(title: "快进变速曲线（实时画面同步）", subtitle: "长按方向键时的非线性倍速曲线，UI 倍速始终与真实解码帧率闭环锁步") {
                gridChoices(
                    items: AppSettings.ScrubMode.allCases.map { ($0, $0.displayName) },
                    columns: 3,
                    selected: env.settings.scrubMode,
                    tint: TVTokens.Color.amber
                ) { value in
                    env.update(settings: mutated { $0.scrubMode = value })
                }
            }

            liveCapsulePreviewCard

        case .scrubbing:
            settingCard(title: "短按左右键行为", subtitle: "点按方向键直接定长跳秒，或切换至类似机顶盒的多级倍速穿梭") {
                gridChoices(
                    items: AppSettings.ShortPressSeekBehavior.allCases.map { ($0, $0.displayName) },
                    columns: 2,
                    selected: env.settings.shortPressSeekBehavior,
                    tint: TVTokens.Color.amber
                ) { value in
                    env.update(settings: mutated { $0.shortPressSeekBehavior = value })
                }
            }

            settingCard(title: "短按单次跳秒步长", subtitle: "连点可无缝累加，适合跳过片头或精彩回放") {
                gridChoices(
                    items: [(5.0, "5 秒"), (10.0, "10 秒"), (15.0, "15 秒"), (30.0, "30 秒"), (60.0, "60 秒")],
                    columns: 3,
                    selected: env.settings.shortSeekSeconds,
                    tint: TVTokens.Color.accent
                ) { value in
                    env.update(settings: mutated { $0.shortSeekSeconds = value })
                }
            }

            settingCard(title: "长按快进模式与触控板", subtitle: "支持关键帧实时出画或 3x 连续变速播放") {
                VStack(alignment: .leading, spacing: 14) {
                    gridChoices(
                        items: AppSettings.LongPressSeekMode.allCases.map { ($0, $0.displayName) },
                        columns: 2,
                        selected: env.settings.longPressSeekMode,
                        tint: TVTokens.Color.violet
                    ) { value in
                        env.update(settings: mutated { $0.longPressSeekMode = value })
                    }
                    gridChoices(
                        items: [(true, "触控板划屏快进：开启"), (false, "触控板划屏快进：关闭")],
                        columns: 2,
                        selected: env.settings.enableTouchpadScrub,
                        tint: TVTokens.Color.emerald
                    ) { value in
                        env.update(settings: mutated { $0.enableTouchpadScrub = value })
                    }
                }
            }

        case .appearance:
            settingCard(title: "快进悬浮胶囊高亮色", subtitle: "实时渲染于播放器底部居中的 tvOS Liquid Glass 玻璃胶囊进度条") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                    ForEach(AppSettings.ScrubBarColorPreset.allCases, id: \.self) { preset in
                        let selected = env.settings.scrubBarColorHex.caseInsensitiveCompare(preset.rawValue) == .orderedSame
                        let chipColor = Color(cdHex: preset.rawValue)
                        Button {
                            env.update(settings: mutated { $0.scrubBarColorHex = preset.rawValue })
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(chipColor)
                                    .frame(width: 14, height: 14)
                                    .shadow(color: chipColor.opacity(0.75), radius: 5)
                                Text(preset.displayName)
                                    .font(.system(size: 20, weight: .semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                        }
                        .tvAdaptiveGlassButtonStyle(prominent: selected)
                        .tint(selected ? chipColor : (nil as Color?))
                    }
                }
            }

            liveCapsulePreviewCard

            settingCard(title: "默认画面比例", subtitle: "保持电影原始宽高比，或裁切填充整张电视屏幕") {
                gridChoices(
                    items: AppSettings.ScalingPreference.allCases.map { ($0, $0.displayName) },
                    columns: 3,
                    selected: env.settings.scalingPreference,
                    tint: TVTokens.Color.accent
                ) { value in
                    env.update(settings: mutated { $0.scalingPreference = value })
                }
            }

        case .storage:
            settingCard(title: "内存预读缓存上限", subtitle: "严格遵循 Apple TV Jetsam <= 192 MB 安全保护，头尾 moov 永久钉住") {
                gridChoices(
                    items: [48, 96, 144, 192].map { ($0, "\($0) MB") },
                    columns: 4,
                    selected: env.settings.cacheMegabytes,
                    tint: TVTokens.Color.emerald
                ) { value in
                    env.update(settings: mutated { $0.cacheMegabytes = value })
                }
            }

            settingCard(title: "连续观影与智能记忆", subtitle: "剧集连播、历史断点续播与简体中文字幕优先匹配") {
                VStack(alignment: .leading, spacing: 14) {
                    gridChoices(
                        items: [(true, "自动连播下一集：开"), (false, "自动连播下一集：关")],
                        columns: 2,
                        selected: env.settings.autoPlayNextEpisode,
                        tint: TVTokens.Color.accent
                    ) { value in
                        env.update(settings: mutated { $0.autoPlayNextEpisode = value })
                    }
                    gridChoices(
                        items: [(true, "记忆断点续播：开"), (false, "记忆断点续播：关")],
                        columns: 2,
                        selected: env.settings.enableResumePlayback,
                        tint: TVTokens.Color.amber
                    ) { value in
                        env.update(settings: mutated { $0.enableResumePlayback = value })
                    }
                    gridChoices(
                        items: [(true, "优先匹配简中字幕：开"), (false, "优先匹配简中字幕：关")],
                        columns: 2,
                        selected: env.settings.preferSimplifiedChineseSubtitle,
                        tint: TVTokens.Color.violet
                    ) { value in
                        env.update(settings: mutated { $0.preferSimplifiedChineseSubtitle = value })
                    }
                }
            }
        }
    }

    private var liveCapsulePreviewCard: some View {
        let barColor = Color(cdHex: env.settings.scrubBarColorHex)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("居中悬浮液态玻璃胶囊 · 实时预览", systemImage: "rectangle.and.hand.point.up.left.filled")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Text(currentColorPresetName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(barColor)
            }

            HStack {
                Spacer()
                HStack(spacing: 16) {
                    Text(">>> 16x")
                        .font(.system(size: 24, weight: .heavy, design: .monospaced))
                        .foregroundStyle(barColor)
                    Text("+02:18")
                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TVTokens.Color.secondaryText)
                    Text("01:08:40")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22)).frame(width: 340, height: 7)
                        Capsule()
                            .fill(LinearGradient(colors: [barColor, barColor.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 170, height: 7)
                            .shadow(color: barColor.opacity(0.65), radius: 6)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white)
                            .frame(width: 3, height: 12)
                            .offset(x: 169)
                    }
                    Text("02:49:00")
                        .font(.system(size: 19, weight: .medium, design: .monospaced))
                        .foregroundStyle(TVTokens.Color.secondaryText)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 15)
                .tvGlassSurface(cornerRadius: TVTokens.Radius.capsule, clear: false)
                Spacer()
            }
        }
        .padding(26)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: false, tint: barColor.opacity(0.06))
        .focusSection()
    }

    private func settingCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TVTokens.Color.secondaryText)
            }
            content()
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: false)
        .focusSection()
    }

    private func gridChoices<T: Hashable>(
        items: [(T, String)],
        columns: Int,
        selected: T,
        tint: Color,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        AdaptiveGlassContainer(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { entry in
                    let isSelected = entry.element.0 == selected
                    Button {
                        onSelect(entry.element.0)
                    } label: {
                        HStack(spacing: 8) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(entry.element.1)
                                .font(.system(size: 20, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.86)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                    }
                    .tvAdaptiveGlassButtonStyle(prominent: isSelected)
                    .tint(isSelected ? tint : (nil as Color?))
                }
            }
        }
    }

    private var currentColorPresetName: String {
        AppSettings.ScrubBarColorPreset.allCases
            .first(where: { $0.rawValue.caseInsensitiveCompare(env.settings.scrubBarColorHex) == .orderedSame })?
            .displayName ?? "极光蓝"
    }

    private func mutated(_ transform: (inout AppSettings) -> Void) -> AppSettings {
        var copy = env.settings
        transform(&copy)
        return copy
    }
}

private extension Color {
    init(cdHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\n"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else {
            self = TVTokens.Color.accent
            return
        }
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
