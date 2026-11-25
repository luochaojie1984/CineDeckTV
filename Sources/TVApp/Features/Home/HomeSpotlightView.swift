import SwiftUI
import NetworkVFS
import AppPreferences

/// 首页聚光灯（tvOS 26/27 Cinema Liquid Glass Hero + 海报式继续观看 + 共享源网格 + Bonjour 局域网即时发现）。
public struct HomeSpotlightView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var bonjour = BonjourDiscoveryService()

    public var onOpenSource: (MediaSourceConfig) -> Void
    public var onOpenSourcesManager: () -> Void
    public var onResumeRecord: (PlaybackRecord) -> Void
    public var onSelectBonjour: (_ host: String, _ kind: MediaSourceKind) -> Void

    public init(
        onOpenSource: @escaping (MediaSourceConfig) -> Void,
        onOpenSourcesManager: @escaping () -> Void = {},
        onResumeRecord: @escaping (PlaybackRecord) -> Void = { _ in },
        onSelectBonjour: @escaping (String, MediaSourceKind) -> Void = { _, _ in }
    ) {
        self.onOpenSource = onOpenSource
        self.onOpenSourcesManager = onOpenSourcesManager
        self.onResumeRecord = onResumeRecord
        self.onSelectBonjour = onSelectBonjour
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVTokens.Spacing.sectionVertical) {
                heroBanner
                    .focusSection()

                if !env.history.isEmpty {
                    recentSection
                        .focusSection()
                }

                sourcesSection
                    .focusSection()

                bonjourSection
                    .focusSection()
            }
            .padding(.horizontal, TVTokens.Spacing.pageHorizontal)
            .padding(.top, 26)
            .padding(.bottom, 52)
        }
        .onAppear { bonjour.start() }
        .onDisappear { bonjour.stop() }
    }

    private var heroBanner: some View {
        let hero = env.history.first
        let heroTitle = hero?.title ?? "CineDeckTV 家庭影院"
        let theme = TVMediaTheme.palette(forTitle: heroTitle)
        let badges = hero.map { VFSEntry(path: $0.path, name: $0.title, isDirectory: false, size: 0, modifiedAt: nil).badges } ?? ["4K", "HDR10", "HEVC", "Atmos"]

        return ZStack {
            // 所有环境光斑严格在面板圆角内裁切，彻底杜绝光晕溢出边框
            ZStack {
                LinearGradient(
                    colors: [
                        theme.primary.opacity(0.24),
                        theme.secondary.opacity(0.18),
                        Color(red: 0.05, green: 0.08, blue: 0.16)
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
                RadialGradient(
                    colors: [theme.primary.opacity(0.34), .clear],
                    center: UnitPoint(x: 0.85, y: 0.18),
                    startRadius: 10,
                    endRadius: 520
                )
                RadialGradient(
                    colors: [theme.secondary.opacity(0.28), .clear],
                    center: UnitPoint(x: 0.15, y: 0.90),
                    startRadius: 10,
                    endRadius: 460
                )
            }

            HStack(spacing: 36) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(hero != nil ? TVTokens.Color.amber : TVTokens.Color.accent)
                                .frame(width: 9, height: 9)
                                .shadow(color: (hero != nil ? TVTokens.Color.amber : TVTokens.Color.accent).opacity(0.8), radius: 5)
                            Text(hero != nil ? "继续上次观看" : "双引擎直连影院")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))

                        VideoBadgeRow(badges, maxCount: 4)
                    }

                    if let hero {
                        Text(TVTitleFormatter.cleanDisplayTitle(hero.title))
                            .font(TVTokens.Typography.heroTitle)
                            .lineLimit(2)

                        HStack(spacing: 14) {
                            Text("已播 \(Int(hero.progress * 100))%")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primary)
                            Text("·")
                                .foregroundStyle(TVTokens.Color.tertiaryText)
                            Text("\(formatClock(hero.position)) / \(formatClock(hero.duration))")
                            Text("·")
                                .foregroundStyle(TVTokens.Color.tertiaryText)
                            Text("剩余约 \(Int(max(1, hero.remaining / 60))) 分钟")
                        }
                        .font(TVTokens.Typography.secondary)
                        .foregroundStyle(TVTokens.Color.secondaryText)

                        TVProgressBar(
                            progress: hero.progress,
                            tint: theme.primary,
                            secondaryTint: theme.secondary,
                            height: 8
                        )
                        .frame(maxWidth: 620)
                        .padding(.vertical, 4)

                        AdaptiveGlassContainer(spacing: 16) {
                            HStack(spacing: 16) {
                                Button {
                                    onResumeRecord(hero)
                                } label: {
                                    Label("继续播放", systemImage: "play.fill")
                                        .font(TVTokens.Typography.button)
                                        .padding(.horizontal, 28)
                                        .padding(.vertical, 14)
                                }
                                .tvAdaptiveGlassButtonStyle(prominent: true)

                                if let src = env.sources.first(where: { $0.id == hero.sourceID }) ?? env.sources.first {
                                    Button {
                                        onOpenSource(src)
                                    } label: {
                                        Label("打开共享目录", systemImage: "folder.fill")
                                            .font(TVTokens.Typography.button)
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 14)
                                    }
                                    .tvAdaptiveGlassButtonStyle()
                                }
                            }
                        }
                    } else {
                        Text("CineDeckTV")
                            .font(TVTokens.Typography.heroTitle)
                        Text("FSPlayer (FFmpeg 7 + Metal + libass) 搭配 AVPlayer 杜比双引擎，即刻直连局域网 SMB / WebDAV 4K 原盘")
                            .font(TVTokens.Typography.secondary)
                            .foregroundStyle(TVTokens.Color.secondaryText)
                            .frame(maxWidth: 780, alignment: .leading)

                        AdaptiveGlassContainer(spacing: 16) {
                            HStack(spacing: 16) {
                                Button {
                                    if let first = env.sources.first {
                                        onOpenSource(first)
                                    } else {
                                        onOpenSourcesManager()
                                    }
                                } label: {
                                    Label(env.sources.isEmpty ? "添加 SMB / WebDAV 服务器" : "浏览共享片库", systemImage: env.sources.isEmpty ? "plus.circle.fill" : "folder.fill")
                                        .font(TVTokens.Typography.button)
                                        .padding(.horizontal, 28)
                                        .padding(.vertical, 14)
                                }
                                .tvAdaptiveGlassButtonStyle(prominent: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                heroArtworkPlaque(theme: theme, hero: hero)
            }
            .padding(36)
        }
        .frame(height: TVTokens.Size.heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: TVTokens.Radius.panel, style: .continuous))
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: false, tint: theme.primary.opacity(0.08))
    }

    private func heroArtworkPlaque(theme: TVMediaPalette, hero: PlaybackRecord?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            LinearGradient(
                colors: [theme.primary.opacity(0.38), theme.secondary.opacity(0.30), Color.black.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.white.opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 260
            )
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(theme.tag)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.32), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    Spacer()
                    Image(systemName: "4k.tv.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                Spacer()

                HStack {
                    Spacer()
                    Image(systemName: theme.symbol)
                        .font(.system(size: 76, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(colors: [.white, theme.primary.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                        )
                        .shadow(color: theme.primary.opacity(0.65), radius: 18, y: 6)
                    Spacer()
                }

                Spacer()

                HStack(spacing: 10) {
                    plaqueChip("FSPlayer + Metal")
                    plaqueChip("闭环同步快进")
                    Spacer()
                    if let hero {
                        Text("\(Int(hero.progress * 100))%")
                            .font(.system(size: 18, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(22)
        }
        .frame(width: 460, height: 326)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.2
            )
        )
        .shadow(color: theme.primary.opacity(0.28), radius: 20, y: 10)
    }

    private func plaqueChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.white.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.20), lineWidth: 0.8))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("继续观看", subtitle: "从上次停下的精准时刻无缝续播", icon: "play.rectangle.fill", tint: TVTokens.Color.amber)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TVTokens.Spacing.gridSpacing) {
                    ForEach(env.history.prefix(10)) { record in
                        let entry = VFSEntry(path: record.path, name: record.title, isDirectory: false, size: 0, modifiedAt: nil)
                        let theme = TVMediaTheme.palette(forTitle: record.title)
                        Button {
                            onResumeRecord(record)
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                ZStack(alignment: .topLeading) {
                                    LinearGradient(
                                        colors: [theme.primary.opacity(0.34), theme.secondary.opacity(0.22), Color.black.opacity(0.18)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            VideoBadgeRow(entry.badges, maxCount: 3)
                                            Spacer()
                                            Image(systemName: "play.circle.fill")
                                                .font(.system(size: 32))
                                                .foregroundStyle(.white.opacity(0.92))
                                                .shadow(color: theme.primary.opacity(0.6), radius: 8)
                                        }
                                        Spacer()
                                        HStack {
                                            Text("已播 \(Int(record.progress * 100))%")
                                                .font(.system(size: 15, weight: .bold))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 4)
                                                .background(Color.black.opacity(0.35), in: Capsule())
                                            Spacer()
                                            Text("剩 \(Int(max(1, record.remaining / 60))) 分钟")
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.85))
                                        }
                                    }
                                    .padding(16)
                                }
                                .frame(height: 112)

                                VStack(alignment: .leading, spacing: 10) {
                                    Text(TVTitleFormatter.cleanDisplayTitle(record.title))
                                        .font(TVTokens.Typography.gridPrimary)
                                        .lineLimit(2)
                                    Spacer(minLength: 2)
                                    TVProgressBar(
                                        progress: record.progress,
                                        tint: theme.primary,
                                        secondaryTint: theme.secondary,
                                        height: 6
                                    )
                                    Text("\(formatClock(record.position)) / \(formatClock(record.duration))")
                                        .font(TVTokens.Typography.tertiary)
                                        .foregroundStyle(TVTokens.Color.secondaryText)
                                }
                                .padding(18)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            }
                            .frame(width: 432, height: 242, alignment: .leading)
                        }
                        .buttonStyle(TVCardButtonStyle(accentTint: theme.primary))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("局域网片源", subtitle: "SMB2/3 常驻预读句柄与 WebDAV 高速流媒体", icon: "externaldrive.connected.to.line.below.fill", tint: TVTokens.Color.accent)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TVTokens.Spacing.gridSpacing), count: 3), spacing: TVTokens.Spacing.gridSpacing) {
                ForEach(env.sources) { source in
                    let tint = source.kind == .smb ? TVTokens.Color.accent : TVTokens.Color.violet
                    Button {
                        onOpenSource(source)
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: source.kind == .smb ? "externaldrive.fill.badge.wifi" : "globe")
                                .font(.system(size: 30, weight: .semibold))
                                .frame(width: 66, height: 66)
                                .background(
                                    LinearGradient(colors: [tint.opacity(0.42), tint.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: TVTokens.Radius.iconBlock, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: TVTokens.Radius.iconBlock, style: .continuous)
                                        .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                                )
                                .foregroundStyle(.white)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(source.name)
                                        .font(TVTokens.Typography.gridPrimary)
                                        .lineLimit(1)
                                    Circle()
                                        .fill(TVTokens.Color.emerald)
                                        .frame(width: 8, height: 8)
                                }
                                Text("\(source.kind.displayName) · \(source.host):\(source.port)")
                                    .font(TVTokens.Typography.secondary)
                                    .foregroundStyle(TVTokens.Color.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(TVTokens.Spacing.cardInner)
                    }
                    .buttonStyle(TVCardButtonStyle(accentTint: tint))
                }

                Button {
                    onOpenSourcesManager()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .frame(width: 66, height: 66)
                            .background(TVTokens.Color.emerald.opacity(0.22), in: RoundedRectangle(cornerRadius: TVTokens.Radius.iconBlock, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: TVTokens.Radius.iconBlock, style: .continuous)
                                    .strokeBorder(TVTokens.Color.emerald.opacity(0.45), lineWidth: 1)
                            )
                            .foregroundStyle(TVTokens.Color.emerald)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("添加服务器")
                                .font(TVTokens.Typography.gridPrimary)
                            Text("配置 SMB / WebDAV 共享")
                                .font(TVTokens.Typography.secondary)
                                .foregroundStyle(TVTokens.Color.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(TVTokens.Spacing.cardInner)
                }
                .buttonStyle(TVCardButtonStyle(accentTint: TVTokens.Color.emerald))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    private var bonjourSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                sectionHeader("局域网自动发现（mDNS / Bonjour）", subtitle: "自动探测同一网段内的 NAS 与共享主机", icon: "bonjour", tint: TVTokens.Color.emerald)
                if bonjour.isBrowsing {
                    ProgressView().scaleEffect(0.85)
                }
            }

            if bonjour.hosts.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 24))
                        .foregroundStyle(TVTokens.Color.emerald)
                    Text(env.previewScenario != nil
                         ? "点按发现的局域网主机可一键预填连接参数：nas-studio.local (SMB)"
                         : "正在后台扫描局域网中的 SMB 与 WebDAV 设备…")
                        .font(TVTokens.Typography.secondary)
                        .foregroundStyle(TVTokens.Color.secondaryText)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .tvGlassSurface(cornerRadius: 18, clear: true)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TVTokens.Spacing.gridSpacing), count: 3), spacing: TVTokens.Spacing.gridSpacing) {
                    ForEach(bonjour.hosts) { item in
                        Button {
                            let targetHost = item.name.hasSuffix(".local") ? item.name : "\(item.name).local"
                            onSelectBonjour(targetHost, item.kind == "SMB" ? .smb : .webdav)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "bonjour")
                                    .font(.system(size: 28))
                                    .foregroundStyle(TVTokens.Color.emerald)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .font(TVTokens.Typography.gridPrimary)
                                        .lineLimit(1)
                                    Text("\(item.kind) · 点按一键预填连接")
                                        .font(TVTokens.Typography.tertiary)
                                        .foregroundStyle(TVTokens.Color.secondaryText)
                                }
                                Spacer()
                            }
                            .padding(TVTokens.Spacing.cardInner)
                        }
                        .buttonStyle(TVCardButtonStyle(accentTint: TVTokens.Color.emerald))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TVTokens.Typography.sectionTitle)
                Text(subtitle)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TVTokens.Color.tertiaryText)
            }
        }
    }

    private func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
