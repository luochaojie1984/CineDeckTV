import SwiftUI
import NetworkVFS
import AppPreferences

/// 首页聚光灯：顶部优先呈现局域网片源与自动发现，下方紧接历史播放记录。
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
            VStack(alignment: .leading, spacing: 28) {
                sourcesSection
                    .focusSection()

                bonjourSection
                    .focusSection()

                recentSection
                    .focusSection()
            }
            .padding(.horizontal, TVTokens.Spacing.pageHorizontal)
            .padding(.top, 22)
            .padding(.bottom, 52)
        }
        .onAppear { bonjour.start() }
        .onDisappear { bonjour.stop() }
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
                                HStack(spacing: 8) {
                                    Text(source.kind.displayName)
                                        .font(.system(size: 13, weight: .bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(tint.opacity(0.22), in: Capsule())
                                        .foregroundStyle(tint)
                                    Text("\(source.host):\(String(source.port))")
                                        .font(TVTokens.Typography.secondary)
                                        .foregroundStyle(TVTokens.Color.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(TVTokens.Color.tertiaryText)
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
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(TVTokens.Color.tertiaryText)
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

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("历史播放记录", subtitle: "从上次停下的精准时刻无缝续播", icon: "clock.arrow.circlepath", tint: TVTokens.Color.amber)

            if env.history.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 24))
                        .foregroundStyle(TVTokens.Color.amber)
                    Text("暂无历史播放记录 · 从上方局域网片源选择影片开始观影")
                        .font(TVTokens.Typography.secondary)
                        .foregroundStyle(TVTokens.Color.secondaryText)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .tvGlassSurface(cornerRadius: 18, clear: true)
            } else {
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
