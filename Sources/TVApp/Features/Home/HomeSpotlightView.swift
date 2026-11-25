import SwiftUI
import NetworkVFS

/// 首页：继续观看 Hero + 服务器大卡网格 + 附近局域网设备。
public struct HomeSpotlightView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var bonjour = BonjourDiscoveryService()
    public var onOpenSource: (MediaSourceConfig) -> Void

    public init(onOpenSource: @escaping (MediaSourceConfig) -> Void) {
        self.onOpenSource = onOpenSource
    }

    public var body: some View {
        ZStack {
            TVTokens.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: TVTokens.Spacing.sectionVertical) {
                    hero
                    serverSection
                    nearbySection
                }
                .padding(.horizontal, TVTokens.Spacing.pageHorizontal)
                .padding(.vertical, 28)
            }
        }
        .task { bonjour.start() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(env.history.first?.title ?? "连接你的局域网媒体库")
                .font(TVTokens.Typography.heroTitle)
                .lineLimit(2)
            Text(env.history.first.map { "上次看到 \(Int($0.position / 60)) 分钟 · 剩余 \(Int($0.remaining / 60)) 分钟" } ?? "SMB / WebDAV 直连，FSPlayer 内核，支持 10-bit HEVC 与特效字幕")
                .font(TVTokens.Typography.secondary)
                .foregroundStyle(TVTokens.Color.secondaryText)
            AdaptiveGlassContainer(spacing: 14) {
                HStack(spacing: 14) {
                    Button("添加 SMB / WebDAV 服务器") { onOpenSource(env.sources.first ?? MediaSourceConfig(
                        name: "新服务器", kind: .smb, host: "", username: "", sharePath: ""
                    )) }
                    .tvAdaptiveGlassButtonStyle(prominent: true)
                }
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: TVTokens.Size.heroHeight, alignment: .leading)
        .tvGlassSurface(cornerRadius: 28)
        .focusSection()
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("我的服务器").font(TVTokens.Typography.sectionTitle)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 460), spacing: 24)], spacing: 24) {
                ForEach(env.sources) { source in
                    Button { onOpenSource(source) } label: {
                        HStack(spacing: 18) {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(TVTokens.Color.folderTint.opacity(0.28))
                                .frame(width: 76, height: 76)
                                .overlay(Image(systemName: "externaldrive.fill").font(.system(size: 34, weight: .bold)).foregroundStyle(TVTokens.Color.folderTint))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(source.name).font(.system(size: 30, weight: .bold)).lineLimit(1)
                                Text("\(source.kind.displayName) · \(source.host):\(source.port)").font(TVTokens.Typography.secondary).foregroundStyle(TVTokens.Color.secondaryText).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(18)
                        .frame(height: 152)
                        .background(RoundedRectangle(cornerRadius: TVTokens.Radius.card).fill(TVTokens.Color.cardSurface))
                    }
                    .buttonStyle(TVCardButtonStyle())
                }
            }
        }
        .focusSection()
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("附近局域网设备").font(TVTokens.Typography.sectionTitle)
            if bonjour.hosts.isEmpty {
                Text("未发现 Bonjour 广播的 SMB / WebDAV 主机")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(bonjour.hosts) { host in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(host.name).font(.system(size: 26, weight: .bold)).lineLimit(1)
                                Text(host.kind).font(TVTokens.Typography.tertiary).foregroundStyle(TVTokens.Color.secondaryText)
                            }
                            .padding(18)
                            .frame(width: 320, height: 120, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: TVTokens.Radius.card).fill(TVTokens.Color.cardSurface))
                        }
                    }
                }
            }
        }
        .focusSection()
    }
}
