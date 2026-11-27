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

/// 播放器贴底圆角液态玻璃设置面板：
/// - 加大加圆润的 10-foot 胶囊选项与字号，打开或切换分类时立即自动高亮首个可调节选项；
/// - 调整字幕时直接以设置栏上沿作为画面虚拟底边（默认距底 8px），实时看到真实字幕位置与字体/颜色变化；
/// - 每行使用横向 `.focusSection()` + `ScrollView(.horizontal)`，Siri Remote 左右/上下键顺畅调节全部参数且严格位于视频画框内。
public struct PlayerBottomSettingsPanel: View {
    private enum PanelFocusItem: Hashable {
        case tab(ActivePlayerDrawer)
        case decodeHardware
        case subtitleDisable
        case fontOption(SubtitleStyleConfig.FontFamily)
        case audioFirst
        case closeButton
    }

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

    @FocusState private var panelFocus: PanelFocusItem?

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

    private func defaultFocusTarget(for tab: ActivePlayerDrawer) -> PanelFocusItem {
        switch tab {
        case .decodeAndEngine: return .decodeHardware
        case .subtitles: return .fontOption(style.fontFamily)
        case .audio: return .audioFirst
        }
    }

    private func claimInitialFocus(for tab: ActivePlayerDrawer) {
        let target = defaultFocusTarget(for: tab)
        panelFocus = target
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 55_000_000)
            if kind == tab && panelFocus == nil {
                panelFocus = target
            }
            try? await Task.sleep(nanoseconds: 110_000_000)
            if kind == tab && panelFocus == nil {
                panelFocus = target
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerTabsRow
                .focusSection()

            Divider().overlay(Color.white.opacity(0.18))

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
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlassSurface(cornerRadius: 30, clear: false, tint: accent.opacity(0.08))
        .defaultFocus($panelFocus, defaultFocusTarget(for: activeTab))
        .onAppear {
            claimInitialFocus(for: activeTab)
        }
        .onChange(of: kind) { _, newKind in
            if let newKind {
                claimInitialFocus(for: newKind)
            }
        }
    }

    // MARK: - 顶部横向分类切换栏 + 状态指示

    private var headerTabsRow: some View {
        HStack(spacing: 12) {
            ForEach(ActivePlayerDrawer.allCases, id: \.self) { tab in
                let selected = (activeTab == tab)
                Button {
                    onInteraction()
                    withAnimation(TVTokens.Motion.focus) {
                        kind = tab
                    }
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 21, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: selected, accentTint: tabAccent(tab), cornerRadius: 999))
                .focused($panelFocus, equals: .tab(tab))
            }

            Spacer(minLength: 12)

            Text(statusSummary)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(TVTokens.Color.secondaryText)
                .lineLimit(1)

            Button {
                onClose()
            } label: {
                Label("收起", systemImage: "chevron.down")
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
            }
            .buttonStyle(TVPlayerOptionButtonStyle(isSelected: false, accentTint: accent, cornerRadius: 999))
            .focused($panelFocus, equals: .closeButton)
        }
    }

    private var statusSummary: String {
        switch activeTab {
        case .decodeAndEngine:
            let dec = coordinator.isHardwareDecode ? "硬解 HW" : "软解 SW"
            return "当前：\(coordinator.activeEngine.displayName) · \(dec) · \(String(format: "%.2gx", coordinator.currentPlaybackRate))"
        case .subtitles:
            return "\(style.fontFamily.displayName) · \(Int(style.fontSize))pt · 距底 \(Int(style.bottomInset))px（上沿为底）"
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                rowLabel("解码内核")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        optionPill("硬件解码", selected: coordinator.isHardwareDecode, tint: TVTokens.Color.emerald) {
                            onInteraction()
                            onToggleHardwareDecode(true)
                        }
                        .focused($panelFocus, equals: .decodeHardware)

                        optionPill("软件解码", selected: !coordinator.isHardwareDecode, tint: TVTokens.Color.amber) {
                            onInteraction()
                            onToggleHardwareDecode(false)
                        }

                        rowDivider

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
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .focusSection()

            HStack(spacing: 12) {
                rowLabel("倍速比例")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
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
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .focusSection()
        }
    }

    // MARK: - 分类 2：字幕轨道 + 7 款真实中文字体 + 位置 + 大小 + 10 色 + 描边底框同步

    private var subtitlesRows: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Row 1: 字幕轨道选择
            HStack(spacing: 12) {
                rowLabel("字幕轨道")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        optionPill(
                            "关闭字幕",
                            selected: activeExternalPath == nil && activeEmbeddedSubID == nil,
                            tint: TVTokens.Color.coral
                        ) {
                            onInteraction()
                            onDisableSubtitle()
                        }
                        .focused($panelFocus, equals: .subtitleDisable)

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
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .focusSection()

            // Row 2: 7 款真实中文字体 + 位置（默认 8px，设置栏上沿即画面底边）+ 大小
            HStack(spacing: 12) {
                rowLabel("字体位置")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(SubtitleStyleConfig.FontFamily.allCases, id: \.self) { family in
                            Button {
                                onInteraction()
                                style.fontFamily = family
                            } label: {
                                Text(family.displayName)
                                    .font(SubtitleFontRegistry.shared.resolveSwiftUIFont(for: family, size: 21))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(TVPlayerOptionButtonStyle(isSelected: style.fontFamily == family, accentTint: TVTokens.Color.amber, cornerRadius: 999))
                            .focused($panelFocus, equals: .fontOption(family))
                        }

                        rowDivider

                        optionPill("下移", selected: false, tint: TVTokens.Color.emerald) {
                            onInteraction()
                            style.bottomInset = max(0, style.bottomInset - 4)
                        }
                        optionPill("距底 \(Int(style.bottomInset))px", selected: abs(style.bottomInset - 8) < 0.5, tint: TVTokens.Color.emerald) {
                            onInteraction()
                            style.bottomInset = 8
                        }
                        optionPill("上移", selected: false, tint: TVTokens.Color.emerald) {
                            onInteraction()
                            style.bottomInset = min(240, style.bottomInset + 4)
                        }

                        rowDivider

                        optionPill("A-", selected: false, tint: TVTokens.Color.accent) {
                            onInteraction()
                            style.fontSize = max(24, style.fontSize - 4)
                        }
                        Text("\(Int(style.fontSize))pt")
                            .font(.system(size: 19, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(minWidth: 56)
                        optionPill("A+", selected: false, tint: TVTokens.Color.accent) {
                            onInteraction()
                            style.fontSize = min(76, style.fontSize + 4)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .focusSection()

            // Row 3: 10 种字幕颜色
            HStack(spacing: 12) {
                rowLabel("字幕配色")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(SubtitleStyleConfig.colorPresets) { preset in
                            colorPill(preset.name, hex: preset.hex)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .focusSection()

            // Row 4: 描边 + 底框 + 对齐 + 时间同步偏移
            HStack(spacing: 12) {
                rowLabel("描边同步")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Self.outlinePresets) { preset in
                            optionPill(preset.label, selected: abs(style.outlineWidth - preset.value) < 0.6, tint: TVTokens.Color.accent) {
                                onInteraction()
                                style.outlineWidth = preset.value
                            }
                        }

                        rowDivider

                        ForEach(Self.backgroundPresets) { preset in
                            optionPill(preset.label, selected: abs(style.backgroundOpacity - preset.value) < 0.14, tint: TVTokens.Color.violet) {
                                onInteraction()
                                style.backgroundOpacity = preset.value
                            }
                        }

                        rowDivider

                        ForEach(SubtitleStyleConfig.HorizontalAlignment.allCases, id: \.self) { align in
                            optionPill(align.displayName, selected: style.alignment == align, tint: TVTokens.Color.accent) {
                                onInteraction()
                                style.alignment = align
                            }
                        }

                        rowDivider

                        optionPill("-0.5s", selected: false, tint: TVTokens.Color.amber) {
                            onInteraction()
                            style.offsetSeconds = max(-30, style.offsetSeconds - 0.5)
                        }
                        optionPill("-0.1s", selected: false, tint: TVTokens.Color.amber) {
                            onInteraction()
                            style.offsetSeconds = max(-30, style.offsetSeconds - 0.1)
                        }
                        optionPill(String(format: "归零 %+.1fs", style.offsetSeconds), selected: abs(style.offsetSeconds) < 0.05, tint: TVTokens.Color.emerald) {
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
                                style.forceCustomStyle ? "自定义层：开" : "libass",
                                selected: style.forceCustomStyle,
                                tint: TVTokens.Color.violet
                            ) {
                                onInteraction()
                                style.forceCustomStyle.toggle()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .focusSection()
        }
    }

    // MARK: - 分类 3：音轨与实时统计

    private var audioAndStatsRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                rowLabel("音轨选择")
                if coordinator.audioTracks.isEmpty {
                    optionPill("默认音轨", selected: true, tint: TVTokens.Color.violet) {
                        onInteraction()
                    }
                    .focused($panelFocus, equals: .audioFirst)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(coordinator.audioTracks.enumerated()), id: \.element.id) { idx, track in
                                let isActive = (activeAudioTrackID == track.id) || (activeAudioTrackID == nil && track.isSelected)
                                if idx == 0 {
                                    optionPill(track.displayName, selected: isActive, tint: TVTokens.Color.violet) {
                                        onInteraction()
                                        onSelectAudioTrack(track.id)
                                    }
                                    .focused($panelFocus, equals: .audioFirst)
                                } else {
                                    optionPill(track.displayName, selected: isActive, tint: TVTokens.Color.violet) {
                                        onInteraction()
                                        onSelectAudioTrack(track.id)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
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

    // MARK: - 大字号圆边胶囊控件

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(TVTokens.Color.secondaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 84, alignment: .leading)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.20))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 4)
    }

    private func optionPill(_ title: String, selected: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .buttonStyle(TVPlayerOptionButtonStyle(isSelected: selected, accentTint: tint, cornerRadius: 999))
    }

    private func colorPill(_ title: String, hex: String) -> some View {
        let selected = style.foregroundHex.caseInsensitiveCompare(hex) == .orderedSame
        let swatch = Color(panelHex: hex)
        return Button {
            onInteraction()
            style.foregroundHex = hex
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(swatch)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1))
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(TVPlayerOptionButtonStyle(isSelected: selected, accentTint: swatch, cornerRadius: 999))
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
        if raw.count <= 24 { return raw }
        return String(raw.prefix(13)) + "…" + String(raw.suffix(9))
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
        .font(.system(size: 16, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
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
