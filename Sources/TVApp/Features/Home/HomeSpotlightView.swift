import SwiftUI
import NetworkVFS
import AppPreferences

/// 首页聚光灯（tvOS 26/27 Liquid Glass Hero + 继续观看 + 共享源网格 + Bonjour 局域网即时发现）。
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
            .padding(.horizontal, 48)
            .padding(.vertical, 28)
        }
        .onAppear { bonjour.start() }
        .onDisappear { bonjour.stop() }
    }

    private var heroBanner: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: TVTokens.Radius.panel, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.14, green: 0.25, blue: 0.45),
                            Color(red: 0.08, green: 0.11, blue: 0.24),
                            Color(red: 0.04, green: 0.05, blue: 0.12)
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
                .overlay(
                    Circle()
                        .fill(TVTokens.Color.accent.opacity(0.22))
                        .frame(width: 480, height: 480)
                        .blur(radius: 90)
                        .offset(x: 240, y: -120),
                    alignment: .topTrailing
                )

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    if let hero = env.history.first {
                        VideoBadgeRow(
                            VFSEntry(path: hero.path, name: hero.title, isDirectory: false, size: 0, modifiedAt: nil).badges
                        )
                        Text(hero.title)
                            .font(TVTokens.Typography.heroTitle)
                            .lineLimit(2)
                        HStack(spacing: 16) {
                            Text("已播 \(formatClock(hero.position)) / \(formatClock(hero.duration))")
                            Text("•")
                            Text("剩余约 \(Int(max(1, hero.remaining / 60))) 分钟")
                        }
                        .font(TVTokens.Typography.secondary)
                        .foregroundStyle(TVTokens.Color.secondaryText)

                        ProgressView(value: hero.progress)
                            .tint(TVTokens.Color.accent)
                            .frame(maxWidth: 520)

                        AdaptiveGlassContainer(spacing: 18) {
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
                            .frame(maxWidth: 860, alignment: .leading)

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
                Spacer()
            }
            .padding(44)
        }
        .frame(height: TVTokens.Size.heroHeight)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: false)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("继续观看")
                .font(TVTokens.Typography.sectionTitle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TVTokens.Spacing.gridSpacing) {
                    ForEach(env.history.prefix(10)) { record in
                        Button {
                            onResumeRecord(record)
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                VideoBadgeRow(
                                    VFSEntry(path: record.path, name: record.title, isDirectory: false, size: 0, modifiedAt: nil).badges
                                )
                                Text(record.title)
                                    .font(TVTokens.Typography.gridPrimary)
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                ProgressView(value: record.progress)
                                    .tint(TVTokens.Color.accent)
                                HStack {
                                    Text(formatClock(record.position))
                                    Spacer()
                                    Text("剩 \(Int(max(1, record.remaining / 60))) 分钟")
                                }
                                .font(TVTokens.Typography.tertiary)
                                .foregroundStyle(TVTokens.Color.secondaryText)
                            }
                            .padding(TVTokens.Spacing.cardInner)
                            .frame(width: 400, height: 220, alignment: .leading)
                        }
                        .buttonStyle(TVCardButtonStyle())
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("局域网片源")
                .font(TVTokens.Typography.sectionTitle)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TVTokens.Spacing.gridSpacing), count: 3), spacing: TVTokens.Spacing.gridSpacing) {
                ForEach(env.sources) { source in
                    Button {
                        onOpenSource(source)
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: source.kind == .smb ? "externaldrive.fill.badge.wifi" : "globe")
                                .font(.system(size: 36, weight: .semibold))
                                .frame(width: 68, height: 68)
                                .background(TVTokens.Color.folderTint.opacity(0.24), in: RoundedRectangle(cornerRadius: TVTokens.Radius.iconBlock))
                                .foregroundStyle(TVTokens.Color.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(source.name)
                                    .font(TVTokens.Typography.gridPrimary)
                                    .lineLimit(1)
                                Text("\(source.kind.displayName) · \(source.host):\(source.port)")
                                    .font(TVTokens.Typography.secondary)
                                    .foregroundStyle(TVTokens.Color.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(TVTokens.Spacing.cardInner)
                    }
                    .buttonStyle(TVCardButtonStyle())
                }

                Button {
                    onOpenSourcesManager()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .frame(width: 68, height: 68)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: TVTokens.Radius.iconBlock))
                            .foregroundStyle(.white)
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
                .buttonStyle(TVCardButtonStyle())
            }
        }
    }

    private var bonjourSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("局域网自动发现（mDNS / Bonjour）")
                    .font(TVTokens.Typography.sectionTitle)
                if bonjour.isBrowsing {
                    ProgressView().scaleEffect(0.85)
                }
            }

            if bonjour.hosts.isEmpty {
                Text(env.previewScenario != nil
                     ? "点击即可快速预填局域网主机：nas-studio.local (SMB)"
                     : "正在后台扫描局域网中的 SMB 与 WebDAV 设备…")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
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
                                    .foregroundStyle(TVTokens.Color.accent)
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
                        .buttonStyle(TVCardButtonStyle())
                    }
                }
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
