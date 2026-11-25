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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(kind == .subtitles ? "字幕与样式" : "音轨与解码控制",
                      systemImage: kind == .subtitles ? "captions.bubble.fill" : "waveform.and.magnifyingglass")
                    .font(TVTokens.Typography.sectionTitle)
                Spacer()
                Button("完成", action: onClose)
                    .tvAdaptiveGlassButtonStyle(prominent: true)
            }

            Divider().overlay(Color.white.opacity(0.18))

            ScrollView {
                if kind == .subtitles {
                    subtitlesBody
                } else {
                    audioAndDecodeBody
                }
            }
        }
        .padding(28)
        .frame(width: TVTokens.Size.drawerWidth)
        .frame(maxHeight: 920)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: false)
    }

    @ViewBuilder
    private var subtitlesBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onDisableSubtitle) {
                HStack {
                    Image(systemName: activeExternalPath == nil && activeEmbeddedSubID == nil ? "checkmark.circle.fill" : "circle")
                    Text("关闭所有字幕")
                    Spacer()
                }
                .font(TVTokens.Typography.button)
                .padding(14)
            }
            .buttonStyle(TVListRowButtonStyle())

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
                    .buttonStyle(TVListRowButtonStyle())
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
                    .buttonStyle(TVListRowButtonStyle())
                }
            }

            Divider().overlay(Color.white.opacity(0.15))
            Text("实时字幕外观与时间偏移")
                .font(TVTokens.Typography.secondary)
                .foregroundStyle(TVTokens.Color.secondaryText)

            HStack(spacing: 12) {
                Text("同步偏移：\(String(format: "%+.1fs", style.offsetSeconds))")
                    .font(TVTokens.Typography.secondary)
                Spacer()
                Button("-0.5s") { style.offsetSeconds -= 0.5 }.tvAdaptiveGlassButtonStyle()
                Button("归零") { style.offsetSeconds = 0 }.tvAdaptiveGlassButtonStyle()
                Button("+0.5s") { style.offsetSeconds += 0.5 }.tvAdaptiveGlassButtonStyle()
            }

            HStack(spacing: 10) {
                Text("字号")
                    .font(TVTokens.Typography.secondary)
                Spacer()
                ForEach([28.0, 34.0, 42.0, 50.0], id: \.self) { size in
                    Button("\(Int(size))pt") { style.fontSize = size }
                        .tvAdaptiveGlassButtonStyle(prominent: abs(style.fontSize - size) < 1)
                }
            }

            HStack(spacing: 10) {
                Text("配色")
                    .font(TVTokens.Typography.secondary)
                Spacer()
                Button("纯白") { style.foregroundHex = "#FFFFFF" }
                    .tvAdaptiveGlassButtonStyle(prominent: style.foregroundHex == "#FFFFFF")
                Button("暖黄") { style.foregroundHex = "#FFD859" }
                    .tvAdaptiveGlassButtonStyle(prominent: style.foregroundHex == "#FFD859")
                Button("冰蓝") { style.foregroundHex = "#7AD7FF" }
                    .tvAdaptiveGlassButtonStyle(prominent: style.foregroundHex == "#7AD7FF")
            }

            HStack(spacing: 10) {
                Text("底距")
                    .font(TVTokens.Typography.secondary)
                Spacer()
                Button("贴底") { style.bottomInset = 32 }
                    .tvAdaptiveGlassButtonStyle(prominent: style.bottomInset <= 40)
                Button("标准") { style.bottomInset = 56 }
                    .tvAdaptiveGlassButtonStyle(prominent: style.bottomInset > 40 && style.bottomInset <= 80)
                Button("抬高") { style.bottomInset = 96 }
                    .tvAdaptiveGlassButtonStyle(prominent: style.bottomInset > 80)
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
                    .buttonStyle(TVListRowButtonStyle())
                }
            }

            Divider().overlay(Color.white.opacity(0.15))
            Text("VideoToolbox 解码与双引擎热切")
                .font(TVTokens.Typography.secondary)
                .foregroundStyle(TVTokens.Color.secondaryText)

            HStack(spacing: 12) {
                Button(coordinator.isHardwareDecode ? "✅ 硬件解码 (VideoToolbox)" : "硬件解码") {
                    onToggleHardwareDecode(true)
                }
                .tvAdaptiveGlassButtonStyle(prominent: coordinator.isHardwareDecode)

                Button(!coordinator.isHardwareDecode ? "✅ FFmpeg 软件解码" : "软件解码") {
                    onToggleHardwareDecode(false)
                }
                .tvAdaptiveGlassButtonStyle(prominent: !coordinator.isHardwareDecode)
            }

            HStack(spacing: 12) {
                Button("FSPlayer 主核") { onSwitchEngine(.fsplayer) }
                    .tvAdaptiveGlassButtonStyle(prominent: coordinator.activeEngine == .fsplayer)
                Button("AVPlayer 杜比") { onSwitchEngine(.avplayer) }
                    .tvAdaptiveGlassButtonStyle(prominent: coordinator.activeEngine == .avplayer)
            }

            Divider().overlay(Color.white.opacity(0.15))
            Text("倍速与画面裁切")
                .font(TVTokens.Typography.secondary)
                .foregroundStyle(TVTokens.Color.secondaryText)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                ForEach([0.5, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { rate in
                    Button("\(String(format: "%.2g", rate))x") {
                        onChangeRate(rate)
                    }
                    .tvAdaptiveGlassButtonStyle()
                }
            }

            HStack(spacing: 10) {
                ForEach(ScalingMode.allCases, id: \.self) { mode in
                    Button(mode.displayName) {
                        onChangeScaling(mode)
                    }
                    .tvAdaptiveGlassButtonStyle()
                }
            }

            Toggle("显示左上角实时码率与技术统计条", isOn: $showTechStats)
                .font(TVTokens.Typography.secondary)
        }
    }
}

/// 清晰透明感（.clear）液态玻璃顶部实时技术参数浮岛。
public struct TechStatsHUDPill: View {
    public let stats: PlaybackTechStats

    public var body: some View {
        HStack(spacing: 16) {
            Label(stats.engineName, systemImage: "cpu")
            Text("·")
            Text(stats.isHardwareDecode ? "HW 硬解" : "SW 软解")
                .foregroundStyle(stats.isHardwareDecode ? TVTokens.Color.accent : .yellow)
            Text("·")
            Text("\(stats.videoCodec) \(stats.resolution)")
            Text("·")
            Text(String(format: "%.2f / %.2f fps", stats.fps, stats.outputFPS))
            Text("·")
            Text(String(format: "%.1f Mbps", stats.bitrateMbps))
            if stats.downloadSpeedMBps > 0.05 {
                Text("·")
                Text(String(format: "局域网 %.1f MB/s", stats.downloadSpeedMBps))
            }
            Text("·")
            Text("丢帧 \(stats.droppedFrames)")
        }
        .font(.system(size: 18, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.capsule, clear: true)
    }
}
