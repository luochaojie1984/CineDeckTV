import SwiftUI
import SubtitleKit
import AppPreferences

public enum ActivePlayerDrawer: String, Sendable, CaseIterable {
    case decodeAndEngine
    case subtitles
    case audio

    public var title: String {
        switch self {
        case .decodeAndEngine: return "解码与内核"
        case .subtitles: return "字幕与样式"
        case .audio: return "音轨与统计"
        }
    }

    public var icon: String {
        switch self {
        case .decodeAndEngine: return "cpu.fill"
        case .subtitles: return "captions.bubble.fill"
        case .audio: return "waveform"
        }
    }
}

/// 播放器贴底液态玻璃设置面板：
/// - 紧贴底部进度条上方弹出，严格约束在 1920×1080 视频画框内部，绝不超出视频边缘；
/// - 所有设置行均采用横向排布 + `.focusSection()`，支持 Siri Remote 左右键直接切换软硬解码、播放器内核、倍速、画幅、音轨及丰富字幕样式（字体/字号/位置/颜色/描边/底框/对齐/同步偏移）。
public struct PlayerBottomSettingsPanel: View {
    @Binding public var kind: ActivePlayerDrawer?
    @ObservedObject public var coordinator: PlaybackCoordinator
    public let externalSubtitles: [SubtitleCandidate]
    public let activeExternalPath: String?
    public let activeEmbeddedSubID: Int32?
    public let activeAudioTrackID: Int32?
    @Binding public var style: SubtitleStyleConfig
    @Binding public var showTechStats: Bool
    public var onSelectExternalSubtitle: (SubtitleCandidate) -> Void
    public var onSelectEmbeddedSubtitle: (Int32) -> Void
    public var onDisableSubtitle: () -> Void
    public var onSelectAudioTrack: (Int32) -> Void
    public var onSwitchEngine: (PlaybackCoordinator.EngineKind) -> Void
    public var onToggleHardwareDecode: (Bool) -> Void
    public var onChangeRate: (Double) -> Void
    public var onChangeScaling: (ScalingMode) -> Void
    public var onInteraction: () -> Void
    public var onClose: () -> Void

    private var activeTab: ActivePlayerDrawer {
        kind ?? .decodeAndEngine
    }

    private var accent: Color {
        switch activeTab {
        case .decodeAndEngine: return TVTokens.Color.accent
        case .subtitles: return TVTokens.Color.amber
        case .audio: return TVTokens.Color.violet
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerTabsRow
                .focusSection()

            Divider().overlay(Color.white.opacity(0.16))

            Group {
                switch activeTab {
                case .decodeAndEngine:
                    decodeAndEngineRows
                case .subtitles:
                    subtitlesRows
                case .audio:
                    audioAndStatsRows
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlassSurface(cornerRadius: 22, clear: false, tint: accent.opacity(0.08))
    }

    // MARK: - 顶部横向分类切换栏（支持左右一键切换设置分类）

    private var headerTabsRow: some View {
        HStack(spacing: 10) {
            ForEach(ActivePlayerDrawer.allCases, id: \.self) { tab in
                let selected = (activeTab == tab)
                Button {
                    onInteraction()
                    withAnimation(TVTokens.Motion.focus) {
                        kind = tab
                    }
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: selected, accentTint: tabAccent(tab), cornerRadius: 12))
            }

            Spacer(minLength: 12)

            Text(statusSummary)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(TVTokens.Color.secondaryText)
                .lineLimit(1)

            Button {
                onClose()
            } label: {
                Label("收起", systemImage: "chevron.down")
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(TVPlayerOptionButtonStyle(isSelected: false, accentTint: accent, cornerRadius: 12))
        }
    }

    private var statusSummary: String {
        switch activeTab {
        case .decodeAndEngine:
            let dec = coordinator.isHardwareDecode ? "硬解 HW" : "软解 SW"
            return "当前：\(coordinator.activeEngine.displayName) · \(dec) · \(String(format: "%.2gx", coordinator.currentPlaybackRate))"
        case .subtitles:
            return "\(style.fontFamily.displayName) · \(Int(style.fontSize))pt · 底距 \(Int(style.bottomInset)) · 偏移 \(String(format: "%+.1fs", style.offsetSeconds))"
        case .audio:
            return "音轨 \(max(1, coordinator.audioTracks.count)) 条 · 统计 \(showTechStats ? "开" : "关")"
        }
    }

    private func tabAccent(_ tab: ActivePlayerDrawer) -> Color {
        switch tab {
        case .decodeAndEngine: return TVTokens.Color.accent
        case .subtitles: return TVTokens.Color.amber
        case .audio: return TVTokens.Color.violet
        }
    }

    // MARK: - 分类 1：解码方式 + 播放器内核 + 倍速 + 画面比例

    private var decodeAndEngineRows: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Row 1: 软/硬解码 + 播放器内核（全部横向排列，左右键无缝滑动）
            HStack(spacing: 12) {
                rowLabel("解码方式")
                optionPill("硬件解码", selected: coordinator.isHardwareDecode, tint: TVTokens.Color.emerald) {
                    onInteraction()
                    onToggleHardwareDecode(true)
                }
                optionPill("软件解码", selected: !coordinator.isHardwareDecode, tint: TVTokens.Color.amber) {
                    onInteraction()
                    onToggleHardwareDecode(false)
                }

                rowDivider

                rowLabel("播放内核")
                optionPill("自动 (KS优先)", selected: coordinator.currentPreference == .automatic, tint: TVTokens.Color.accent) {
                    onInteraction()
                    onSwitchEngine(.automatic)
                }
                optionPill("KSPlayer", selected: coordinator.activeEngine == .ksplayer && coordinator.currentPreference == .ksplayer, tint: TVTokens.Color.accent) {
                    onInteraction()
                    onSwitchEngine(.ksplayer)
                }
                optionPill("FSPlayer", selected: coordinator.activeEngine == .fsplayer && coordinator.currentPreference == .fsplayer, tint: TVTokens.Color.emerald) {
                    onInteraction()
                    onSwitchEngine(.fsplayer)
                }
                optionPill("AVPlayer", selected: coordinator.activeEngine == .avplayer && coordinator.currentPreference == .avplayer, tint: TVTokens.Color.violet) {
                    onInteraction()
                    onSwitchEngine(.avplayer)
                }
                Spacer(minLength: 0)
            }
            .focusSection()

            // Row 2: 播放倍速 + 画面比例
            HStack(spacing: 10) {
                rowLabel("播放倍速")
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { rate in
                    optionPill(
                        "\(String(format: "%.2g", rate))x",
                        selected: abs(coordinator.currentPlaybackRate - rate) < 0.03,
                        tint: TVTokens.Color.accent
                    ) {
                        onInteraction()
                        onChangeRate(rate)
                    }
                }

                rowDivider

                rowLabel("画面比例")
                ForEach(ScalingMode.allCases, id: \.self) { mode in
                    optionPill(
                        mode.displayName,
                        selected: coordinator.currentScalingMode == mode,
                        tint: TVTokens.Color.violet
                    ) {
                        onInteraction()
                        onChangeScaling(mode)
                    }
                }
                Spacer(minLength: 0)
            }
            .focusSection()
        }
    }

    // MARK: - 分类 2：字幕轨道 + 字体 + 字号 + 位置 + 颜色 + 描边 + 底框 + 对齐 + 偏移

    private var subtitlesRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: 字幕轨道选择（横向滚动）
            HStack(spacing: 10) {
                rowLabel("字幕轨道")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        optionPill(
                            "关闭字幕",
                            selected: activeExternalPath == nil && activeEmbeddedSubID == nil,
                            tint: TVTokens.Color.coral
                        ) {
                            onInteraction()
                            onDisableSubtitle()
                        }

                        ForEach(externalSubtitles, id: \.path) { sub in
                            optionPill(
                                "外挂 · \(shortSubName(sub.fileName))",
                                selected: activeExternalPath == sub.path,
                                tint: TVTokens.Color.amber
                            ) {
                                onInteraction()
                                onSelectExternalSubtitle(sub)
                            }
                        }

                        ForEach(coordinator.embeddedSubtitleTracks) { track in
                            optionPill(
                                "内嵌 · \(track.displayName)",
                                selected: activeEmbeddedSubID == track.id,
                                tint: TVTokens.Color.accent
                            ) {
                                onInteraction()
                                onSelectEmbeddedSubtitle(track.id)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .focusSection()

            // Row 2: 字体选择 + 字号调节 + 垂直位置调节
            HStack(spacing: 10) {
                rowLabel("字体")
                ForEach(SubtitleStyleConfig.FontFamily.allCases, id: \.self) { family in
                    optionPill(family.displayName, selected: style.fontFamily == family, tint: TVTokens.Color.amber) {
                        onInteraction()
                        style.fontFamily = family
                    }
                }

                rowDivider

                rowLabel("大小")
                optionPill("A-", selected: false, tint: TVTokens.Color.accent) {
                    onInteraction()
                    style.fontSize = max(24, style.fontSize - 4)
                }
                Text("\(Int(style.fontSize))pt")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 50)
                optionPill("A+", selected: false, tint: TVTokens.Color.accent) {
                    onInteraction()
                    style.fontSize = min(76, style.fontSize + 4)
                }

                rowDivider

                rowLabel("位置")
                optionPill("下移", selected: false, tint: TVTokens.Color.emerald) {
                    onInteraction()
                    style.bottomInset = max(12, style.bottomInset - 16)
                }
                Text("\(Int(style.bottomInset))")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 38)
                optionPill("上移", selected: false, tint: TVTokens.Color.emerald) {
                    onInteraction()
                    style.bottomInset = min(260, style.bottomInset + 16)
                }
                Spacer(minLength: 0)
            }
            .focusSection()

            // Row 3: 字幕颜色 + 描边粗细 + 背景底框透明度
            HStack(spacing: 10) {
                rowLabel("颜色")
                colorPill("纯白", hex: "#FFFFFF")
                colorPill("暖黄", hex: "#FFD859")
                colorPill("冰蓝", hex: "#7AD7FF")
                colorPill("翠绿", hex: "#5EEAD4")
                colorPill("柔灰", hex: "#D4D4D8")

                rowDivider

                rowLabel("描边")
                ForEach(Self.outlinePresets) { preset in
                    optionPill(preset.label, selected: abs(style.outlineWidth - preset.value) < 0.6, tint: TVTokens.Color.accent) {
                        onInteraction()
                        style.outlineWidth = preset.value
                    }
                }

                rowDivider

                rowLabel("底框")
                ForEach(Self.backgroundPresets) { preset in
                    optionPill(preset.label, selected: abs(style.backgroundOpacity - preset.value) < 0.14, tint: TVTokens.Color.violet) {
                        onInteraction()
                        style.backgroundOpacity = preset.value
                    }
                }
                Spacer(minLength: 0)
            }
            .focusSection()

            // Row 4: 对齐方式 + 时间轴同步偏移 + FSPlayer 强制自定义字体开关
            HStack(spacing: 10) {
                rowLabel("对齐")
                ForEach(SubtitleStyleConfig.HorizontalAlignment.allCases, id: \.self) { align in
                    optionPill(align.displayName, selected: style.alignment == align, tint: TVTokens.Color.accent) {
                        onInteraction()
                        style.alignment = align
                    }
                }

                rowDivider

                rowLabel("时间同步")
                optionPill("-0.5s", selected: false, tint: TVTokens.Color.amber) {
                    onInteraction()
                    style.offsetSeconds = max(-30, style.offsetSeconds - 0.5)
                }
                optionPill("-0.1s", selected: false, tint: TVTokens.Color.amber) {
                    onInteraction()
                    style.offsetSeconds = max(-30, style.offsetSeconds - 0.1)
                }
                optionPill(String(format: "归零 (%+.1fs)", style.offsetSeconds), selected: abs(style.offsetSeconds) < 0.05, tint: TVTokens.Color.emerald) {
                    onInteraction()
                    style.offsetSeconds = 0
                }
                optionPill("+0.1s", selected: false, tint: TVTokens.Color.amber) {
                    onInteraction()
                    style.offsetSeconds = min(30, style.offsetSeconds + 0.1)
                }
                optionPill("+0.5s", selected: false, tint: TVTokens.Color.amber) {
                    onInteraction()
                    style.offsetSeconds = min(30, style.offsetSeconds + 0.5)
                }

                if coordinator.activeEngine == .fsplayer {
                    rowDivider
                    optionPill(
                        style.forceCustomStyle ? "自定义字体渲染：开" : "原生 libass 渲染",
                        selected: style.forceCustomStyle,
                        tint: TVTokens.Color.violet
                    ) {
                        onInteraction()
                        style.forceCustomStyle.toggle()
                    }
                }
                Spacer(minLength: 0)
            }
            .focusSection()
        }
    }

    // MARK: - 分类 3：音轨与实时统计

    private var audioAndStatsRows: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                rowLabel("音轨选择")
                if coordinator.audioTracks.isEmpty {
                    optionPill("默认音轨", selected: true, tint: TVTokens.Color.violet) {
                        onInteraction()
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(coordinator.audioTracks) { track in
                                let isActive = (activeAudioTrackID == track.id) || (activeAudioTrackID == nil && track.isSelected)
                                optionPill(track.displayName, selected: isActive, tint: TVTokens.Color.violet) {
                                    onInteraction()
                                    onSelectAudioTrack(track.id)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .focusSection()

            HStack(spacing: 12) {
                rowLabel("诊断显示")
                optionPill(showTechStats ? "左上角性能统计条：已开启" : "左上角性能统计条：已关闭", selected: showTechStats, tint: TVTokens.Color.emerald) {
                    onInteraction()
                    showTechStats.toggle()
                }
                Spacer(minLength: 0)
            }
            .focusSection()
        }
    }

    // MARK: - 紧凑辅助控件

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(TVTokens.Color.secondaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
    }

    private func optionPill(_ title: String, selected: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
        }
        .buttonStyle(TVPlayerOptionButtonStyle(isSelected: selected, accentTint: tint, cornerRadius: 11))
    }

    private func colorPill(_ title: String, hex: String) -> some View {
        let selected = style.foregroundHex.caseInsensitiveCompare(hex) == .orderedSame
        let swatch = Color(panelHex: hex)
        return Button {
            onInteraction()
            style.foregroundHex = hex
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(swatch)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(TVPlayerOptionButtonStyle(isSelected: selected, accentTint: swatch, cornerRadius: 11))
    }

    private struct NumericPreset: Identifiable {
        let id: String
        let value: Double
        let label: String
    }

    private static let outlinePresets: [NumericPreset] = [
        NumericPreset(id: "o0", value: 0.0, label: "无"),
        NumericPreset(id: "o1", value: 1.5, label: "细"),
        NumericPreset(id: "o2", value: 3.0, label: "中"),
        NumericPreset(id: "o3", value: 5.0, label: "粗")
    ]

    private static let backgroundPresets: [NumericPreset] = [
        NumericPreset(id: "b0", value: 0.0, label: "透明"),
        NumericPreset(id: "b1", value: 0.35, label: "轻暗"),
        NumericPreset(id: "b2", value: 0.68, label: "影院黑")
    ]

    private func shortSubName(_ raw: String) -> String {
        if raw.count <= 26 { return raw }
        return String(raw.prefix(14)) + "…" + String(raw.suffix(10))
    }
}

/// 清晰透明感（.clear）液态玻璃顶部实时技术参数浮岛：零截断完整展示音视频与局域网流吞吐指标。
public struct TechStatsHUDPill: View {
    public let stats: PlaybackTechStats

    public var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stats.isHardwareDecode ? TVTokens.Color.emerald : TVTokens.Color.amber)
                    .frame(width: 8, height: 8)
                Text(stats.engineName)
            }
            dot
            Text(stats.isHardwareDecode ? "HW 硬解" : "SW 软解")
                .foregroundStyle(stats.isHardwareDecode ? TVTokens.Color.accent : TVTokens.Color.amber)
            dot
            Text("\(stats.videoCodec) \(stats.resolution)")
            dot
            Text(String(format: "%.2f / %.2f fps", stats.fps, stats.outputFPS))
            dot
            Text(String(format: "%.1f Mbps", stats.bitrateMbps))
            if stats.downloadSpeedMBps > 0.05 {
                dot
                Text(String(format: "%.1f MB/s", stats.downloadSpeedMBps))
                    .foregroundStyle(TVTokens.Color.emerald)
            }
            dot
            Text("丢帧 \(stats.droppedFrames)")
        }
        .font(.system(size: 15, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.capsule, clear: true)
    }

    private var dot: some View {
        Text("·")
            .foregroundStyle(TVTokens.Color.tertiaryText)
    }
}

private extension Color {
    init(panelHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\n"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else {
            self = .white
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
