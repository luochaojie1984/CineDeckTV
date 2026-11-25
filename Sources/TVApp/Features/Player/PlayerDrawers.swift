import SwiftUI
import SubtitleKit
import AppPreferences

public enum ActivePlayerDrawer: String, Sendable {
    case subtitles
    case audioAndDecode
}

/// 播放器侧边液态玻璃抽屉：字幕管理（外挂 + 内挂 + 实时样式）与 音轨/硬解/倍率/画幅切换。
public struct PlayerSideDrawer: View {
    public let kind: ActivePlayerDrawer
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
    public var onClose: () -> Void

    public var body: some View {
        let accent = kind == .subtitles ? TVTokens.Color.accent : TVTokens.Color.violet
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: kind == .subtitles ? "captions.bubble.fill" : "waveform.and.magnifyingglass")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(accent.opacity(0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(accent)

                Text(kind == .subtitles ? "字幕与样式" : "音轨与解码控制")
                    .font(TVTokens.Typography.sectionTitle)
                    .lineLimit(1)
                Spacer()
                Button("完成", action: onClose)
                    .tvAdaptiveGlassButtonStyle(prominent: true)
            }
            .focusSection()

            Divider().overlay(Color.white.opacity(0.18))

            ScrollView {
                if kind == .subtitles {
                    subtitlesBody
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .focusSection()
                } else {
                    audioAndDecodeBody
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .focusSection()
                }
            }
            .focusSection()
        }
        .padding(28)
        .frame(width: TVTokens.Size.drawerWidth)
        .frame(maxHeight: 980)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: false, tint: accent.opacity(0.08))
    }

    @ViewBuilder
    private var subtitlesBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onDisableSubtitle) {
                HStack {
                    Image(systemName: activeExternalPath == nil && activeEmbeddedSubID == nil ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(activeExternalPath == nil && activeEmbeddedSubID == nil ? TVTokens.Color.accent : TVTokens.Color.secondaryText)
                    Text("关闭所有字幕")
                    Spacer()
                }
                .font(TVTokens.Typography.button)
                .padding(14)
            }
            .buttonStyle(TVListRowButtonStyle(accentTint: TVTokens.Color.accent))

            if !externalSubtitles.isEmpty {
                Text("外挂字幕（自动转码 UTF-8 / libass）")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
                ForEach(externalSubtitles, id: \.path) { sub in
                    Button {
                        onSelectExternalSubtitle(sub)
                    } label: {
                        HStack {
                            Image(systemName: activeExternalPath == sub.path ? "checkmark.circle.fill" : "captions.bubble")
                                .foregroundStyle(TVTokens.Color.accent)
                            Text(sub.fileName)
                                .font(TVTokens.Typography.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(14)
                    }
                    .buttonStyle(TVListRowButtonStyle(accentTint: TVTokens.Color.accent))
                }
            }

            if !coordinator.embeddedSubtitleTracks.isEmpty {
                Text("内嵌字幕流")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
                ForEach(coordinator.embeddedSubtitleTracks) { track in
                    Button {
                        onSelectEmbeddedSubtitle(track.id)
                    } label: {
                        HStack {
                            Image(systemName: activeEmbeddedSubID == track.id ? "checkmark.circle.fill" : "text.bubble")
                                .foregroundStyle(TVTokens.Color.accent)
                            Text(track.displayName)
                                .font(TVTokens.Typography.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(14)
                    }
                    .buttonStyle(TVListRowButtonStyle(accentTint: TVTokens.Color.accent))
                }
            }

            Divider().overlay(Color.white.opacity(0.15))

            VStack(alignment: .leading, spacing: 10) {
                Text("同步偏移：\(String(format: "%+.1fs", style.offsetSeconds))")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    drawerPill("-0.5s") { style.offsetSeconds -= 0.5 }
                    drawerPill("归零", prominent: abs(style.offsetSeconds) < 0.05) { style.offsetSeconds = 0 }
                    drawerPill("+0.5s") { style.offsetSeconds += 0.5 }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("字号大小")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach([28.0, 34.0, 42.0, 50.0], id: \.self) { size in
                        drawerPill("\(Int(size))pt", prominent: abs(style.fontSize - size) < 1) {
                            style.fontSize = size
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("字幕配色与底距")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    drawerPill("纯白", prominent: style.foregroundHex == "#FFFFFF") { style.foregroundHex = "#FFFFFF" }
                    drawerPill("暖黄", prominent: style.foregroundHex == "#FFD859", tint: TVTokens.Color.amber) { style.foregroundHex = "#FFD859" }
                    drawerPill("冰蓝", prominent: style.foregroundHex == "#7AD7FF", tint: TVTokens.Color.accent) { style.foregroundHex = "#7AD7FF" }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    drawerPill("贴底", prominent: style.bottomInset <= 40) { style.bottomInset = 32 }
                    drawerPill("标准", prominent: style.bottomInset > 40 && style.bottomInset <= 80) { style.bottomInset = 56 }
                    drawerPill("抬高", prominent: style.bottomInset > 80) { style.bottomInset = 96 }
                }
            }
        }
    }

    @ViewBuilder
    private var audioAndDecodeBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("音轨选择")
                .font(TVTokens.Typography.secondary)
                .foregroundStyle(TVTokens.Color.secondaryText)

            if coordinator.audioTracks.isEmpty {
                Text("使用默认音轨")
                    .font(TVTokens.Typography.tertiary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
            } else {
                ForEach(coordinator.audioTracks) { track in
                    Button {
                        onSelectAudioTrack(track.id)
                    } label: {
                        HStack {
                            Image(systemName: activeAudioTrackID == track.id ? "checkmark.circle.fill" : "speaker.wave.2")
                                .foregroundStyle(TVTokens.Color.accent)
                            Text(track.displayName)
                                .font(TVTokens.Typography.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(14)
                    }
                    .buttonStyle(TVListRowButtonStyle(accentTint: TVTokens.Color.violet))
                }
            }

            Divider().overlay(Color.white.opacity(0.15))

            VStack(alignment: .leading, spacing: 10) {
                Text("VideoToolbox 解码与双引擎热切")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    drawerPill("硬件解码", prominent: coordinator.isHardwareDecode, tint: TVTokens.Color.emerald) { onToggleHardwareDecode(true) }
                    drawerPill("软件解码", prominent: !coordinator.isHardwareDecode, tint: TVTokens.Color.amber) { onToggleHardwareDecode(false) }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    drawerPill("FSPlayer 主核", prominent: coordinator.activeEngine == .fsplayer) { onSwitchEngine(.fsplayer) }
                    drawerPill("AVPlayer 杜比", prominent: coordinator.activeEngine == .avplayer, tint: TVTokens.Color.violet) { onSwitchEngine(.avplayer) }
                }
            }

            Divider().overlay(Color.white.opacity(0.15))

            VStack(alignment: .leading, spacing: 10) {
                Text("播放倍速与画面比例")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach([0.5, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { rate in
                        drawerPill("\(String(format: "%.2g", rate))x") { onChangeRate(rate) }
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(ScalingMode.allCases, id: \.self) { mode in
                        drawerPill(mode.displayName) { onChangeScaling(mode) }
                    }
                }
            }

            Toggle("显示左上角实时码率与技术统计条", isOn: $showTechStats)
                .font(TVTokens.Typography.secondary)
        }
    }

    private func drawerPill(_ title: String, prominent: Bool = false, tint: Color = TVTokens.Color.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if prominent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                }
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .tvAdaptiveGlassButtonStyle(prominent: prominent)
        .tint(prominent ? tint : (nil as Color?))
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
