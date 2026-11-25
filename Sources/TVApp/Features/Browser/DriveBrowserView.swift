import SwiftUI
import NetworkVFS
import AppPreferences

/// 网盘风格共享浏览器：
/// - 采用原生 `NavigationStack(path:)` 逐级入栈，遥控器按返回自动退回上一级目录，根目录按返回回到「首页」；
/// - 海报级多色氛围网格卡片 + 浮动液态玻璃顶栏，彻底消除角标拥挤与边框裁切。
public struct DriveBrowserView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Binding public var selectedSource: MediaSourceConfig?
    @Binding public var navPath: [String]
    public var onPlay: (MediaSourceConfig, VFSEntry) -> Void
    public var onOpenSourcesManager: () -> Void
    public var onBackToHome: () -> Void

    @State private var didRestoreInitialPath = false

    public init(
        selectedSource: Binding<MediaSourceConfig?>,
        navPath: Binding<[String]> = .constant([]),
        onPlay: @escaping (MediaSourceConfig, VFSEntry) -> Void,
        onOpenSourcesManager: @escaping () -> Void = {},
        onBackToHome: @escaping () -> Void = {}
    ) {
        self._selectedSource = selectedSource
        self._navPath = navPath
        self.onPlay = onPlay
        self.onOpenSourcesManager = onOpenSourcesManager
        self.onBackToHome = onBackToHome
    }

    private var activeSource: MediaSourceConfig? {
        selectedSource ?? env.sources.first
    }

    public var body: some View {
        NavigationStack(path: $navPath) {
            DriveDirectoryPage(
                source: activeSource,
                currentPath: "/",
                navPath: $navPath,
                selectedSource: $selectedSource,
                onPlay: onPlay,
                onOpenSourcesManager: onOpenSourcesManager
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { targetPath in
                DriveDirectoryPage(
                    source: activeSource,
                    currentPath: targetPath,
                    navPath: $navPath,
                    selectedSource: $selectedSource,
                    onPlay: onPlay,
                    onOpenSourcesManager: onOpenSourcesManager
                )
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .onAppear {
            if !didRestoreInitialPath, let src = activeSource {
                didRestoreInitialPath = true
                restorePath(for: src.id)
            }
        }
        .onChange(of: selectedSource?.id) { _, newID in
            if let newID {
                restorePath(for: newID)
            } else {
                navPath = []
            }
        }
        .onChange(of: navPath) { _, newStack in
            if let src = activeSource {
                env.saveLastVisitedPath(newStack.last ?? "/", for: src.id)
            }
        }
    }

    private func restorePath(for sourceID: UUID) {
        guard env.previewScenario == nil,
              let saved = env.lastVisitedPath(for: sourceID),
              saved != "/" else {
            navPath = []
            return
        }
        let segments = saved.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var stack: [String] = []
        var prefix = ""
        for seg in segments {
            prefix += "/\(seg)"
            stack.append(prefix)
        }
        navPath = stack
    }
}

private struct DriveDirectoryPage: View {
    @EnvironmentObject private var env: AppEnvironment

    let source: MediaSourceConfig?
    let currentPath: String
    @Binding var navPath: [String]
    @Binding var selectedSource: MediaSourceConfig?
    let onPlay: (MediaSourceConfig, VFSEntry) -> Void
    let onOpenSourcesManager: () -> Void

    @AppStorage("cinedeck.browser.isGrid") private var storedIsGrid = true
    @State private var entries: [VFSEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var effectiveIsGrid: Bool {
        if env.previewScenario == .browserGrid { return true }
        if env.previewScenario == .browserList { return false }
        return storedIsGrid
    }

    private var isAtRoot: Bool {
        currentPath == "/" || currentPath.isEmpty
    }

    private var pathSegments: [String] {
        currentPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            toolbar
                .focusSection()

            if let source {
                if let errorMessage {
                    errorCard(errorMessage, source: source)
                        .focusSection()
                } else if isLoading && entries.isEmpty {
                    ProgressView("正在读取共享目录…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    emptyFolderCard
                        .focusSection()
                } else {
                    ScrollView {
                        if effectiveIsGrid {
                            gridContent(source: source)
                                .focusSection()
                        } else {
                            listContent(source: source)
                                .focusSection()
                        }
                    }
                    .focusSection()
                }
            } else {
                noSourceCard
                    .focusSection()
            }
        }
        .padding(.horizontal, TVTokens.Spacing.browserHorizontal)
        .padding(.top, 22)
        .padding(.bottom, 28)
        .task(id: "\(source?.id.uuidString ?? "none")::\(currentPath)") {
            await loadDirectory()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            if !isAtRoot {
                Button {
                    if !navPath.isEmpty { navPath.removeLast() }
                } label: {
                    Label("返回上级", systemImage: "chevron.left")
                        .font(TVTokens.Typography.button)
                        .lineLimit(1)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                .tvAdaptiveGlassButtonStyle()
            }

            HStack(spacing: 16) {
                Image(systemName: (source?.kind ?? .smb) == .smb ? "externaldrive.fill.badge.wifi" : "globe")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .background(TVTokens.Color.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(TVTokens.Color.accent)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(source?.name ?? "未连接片源")
                            .font(TVTokens.Typography.directoryTitle)
                            .lineLimit(1)
                        if !entries.isEmpty {
                            Text("\(entries.count) 项")
                                .font(.system(size: 16, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(.white.opacity(0.10), in: Capsule())
                                .foregroundStyle(TVTokens.Color.secondaryText)
                        }
                    }

                    HStack(spacing: 6) {
                        Text("/")
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(TVTokens.Color.accent)
                        if pathSegments.isEmpty {
                            Text("共享根目录")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(TVTokens.Color.secondaryText)
                        } else {
                            ForEach(Array(pathSegments.enumerated()), id: \.offset) { idx, seg in
                                if idx > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(TVTokens.Color.tertiaryText)
                                }
                                Text(seg)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(TVTokens.Color.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            Spacer()

            AdaptiveGlassContainer(spacing: 12) {
                HStack(spacing: 12) {
                    if env.sources.count > 1, let current = source {
                        Menu {
                            ForEach(env.sources) { src in
                                Button {
                                    selectedSource = src
                                } label: {
                                    Label(src.name, systemImage: src.id == current.id ? "checkmark" : (src.kind == .smb ? "externaldrive.fill" : "globe"))
                                }
                            }
                        } label: {
                            Label("切换服务器", systemImage: "arrow.left.arrow.right")
                                .font(TVTokens.Typography.button)
                                .lineLimit(1)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                        }
                        .tvAdaptiveGlassButtonStyle()
                    }

                    Button {
                        withAnimation(TVTokens.Motion.panel) {
                            storedIsGrid.toggle()
                        }
                    } label: {
                        Label(effectiveIsGrid ? "列表视图" : "网格视图", systemImage: effectiveIsGrid ? "list.bullet" : "square.grid.2x2")
                            .font(TVTokens.Typography.button)
                            .lineLimit(1)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                    }
                    .tvAdaptiveGlassButtonStyle()

                    Button {
                        Task { await loadDirectory() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(TVTokens.Typography.button)
                            .lineLimit(1)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                    }
                    .tvAdaptiveGlassButtonStyle()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: false)
    }

    private func gridContent(source: MediaSourceConfig) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: TVTokens.Spacing.gridSpacing), count: 3),
            spacing: TVTokens.Spacing.gridSpacing
        ) {
            ForEach(entries) { entry in
                let theme = TVMediaTheme.palette(forTitle: entry.name, isDirectory: entry.isDirectory, isSubtitle: entry.isSubtitle)
                Button {
                    open(entry, source: source)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        // 顶部彩色氛围海报头：杜绝徽章与图标相互挤压
                        ZStack(alignment: .topLeading) {
                            LinearGradient(
                                colors: [theme.primary.opacity(0.32), theme.secondary.opacity(0.20), Color.black.opacity(0.14)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: theme.symbol)
                                    .font(.system(size: 30, weight: .semibold))
                                    .frame(width: 58, height: 58)
                                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                                            .strokeBorder(.white.opacity(0.24), lineWidth: 1)
                                    )
                                    .foregroundStyle(.white)

                                Spacer(minLength: 8)

                                if entry.isVideo {
                                    VideoBadgeRow(entry.badges, maxCount: 3)
                                } else {
                                    Text(theme.tag)
                                        .font(.system(size: 15, weight: .bold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(.white.opacity(0.14), in: Capsule())
                                        .foregroundStyle(.white.opacity(0.92))
                                }
                            }
                            .padding(16)
                        }
                        .frame(height: 94)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.isDirectory ? entry.name : TVTitleFormatter.cleanDisplayTitle(entry.name))
                                .font(TVTokens.Typography.gridPrimary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Spacer(minLength: 2)

                            if entry.isDirectory {
                                HStack {
                                    Text("目录")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 16, weight: .bold))
                                }
                                .font(TVTokens.Typography.tertiary)
                                .foregroundStyle(TVTokens.Color.secondaryText)
                            } else {
                                let record = historyRecord(for: entry, source: source)
                                if let record, record.duration > 0 {
                                    VStack(alignment: .leading, spacing: 6) {
                                        TVProgressBar(progress: record.progress, tint: theme.primary, secondaryTint: theme.secondary, height: 6)
                                        Text("已播 \(Int(record.progress * 100))% · \(formatSize(entry.size))")
                                            .font(TVTokens.Typography.tertiary)
                                            .foregroundStyle(TVTokens.Color.secondaryText)
                                    }
                                } else {
                                    HStack {
                                        Text(entry.isVideo ? theme.tag : "字幕文件")
                                            .foregroundStyle(theme.primary)
                                        Spacer()
                                        Text(formatSize(entry.size))
                                    }
                                    .font(TVTokens.Typography.tertiary)
                                    .foregroundStyle(TVTokens.Color.secondaryText)
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                    .frame(height: TVTokens.Size.gridCardHeight)
                }
                .buttonStyle(TVCardButtonStyle(accentTint: theme.primary))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
    }

    private func listContent(source: MediaSourceConfig) -> some View {
        LazyVStack(spacing: 14) {
            ForEach(entries) { entry in
                let theme = TVMediaTheme.palette(forTitle: entry.name, isDirectory: entry.isDirectory, isSubtitle: entry.isSubtitle)
                Button {
                    open(entry, source: source)
                } label: {
                    HStack(spacing: 18) {
                        Image(systemName: theme.symbol)
                            .font(.system(size: 28, weight: .semibold))
                            .frame(width: TVTokens.Size.listIcon, height: TVTokens.Size.listIcon)
                            .background(
                                LinearGradient(colors: [theme.primary.opacity(0.40), theme.secondary.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: TVTokens.Radius.iconBlock, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: TVTokens.Radius.iconBlock, style: .continuous)
                                    .strokeBorder(theme.primary.opacity(0.45), lineWidth: 1)
                            )
                            .foregroundStyle(.white)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.isDirectory ? entry.name : TVTitleFormatter.cleanDisplayTitle(entry.name))
                                .font(TVTokens.Typography.listPrimary)
                                .lineLimit(1)

                            if entry.isDirectory {
                                Text("文件夹")
                                    .font(TVTokens.Typography.secondary)
                                    .foregroundStyle(TVTokens.Color.secondaryText)
                            } else {
                                HStack(spacing: 12) {
                                    Text(formatSize(entry.size))
                                    if let record = historyRecord(for: entry, source: source), record.duration > 0 {
                                        Text("·")
                                        Text("已播 \(Int(record.progress * 100))%")
                                            .fontWeight(.bold)
                                            .foregroundStyle(theme.primary)
                                    }
                                }
                                .font(TVTokens.Typography.secondary)
                                .foregroundStyle(TVTokens.Color.secondaryText)
                            }
                        }

                        Spacer(minLength: 16)

                        if entry.isVideo {
                            VideoBadgeRow(entry.badges, maxCount: 4)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(TVTokens.Color.secondaryText)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                }
                .buttonStyle(TVListRowButtonStyle(accentTint: theme.primary))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var emptyFolderCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 52))
                .foregroundStyle(TVTokens.Color.secondaryText)
            Text("当前目录为空")
                .font(TVTokens.Typography.sectionTitle)
            if !isAtRoot {
                Button("返回上级目录") {
                    if !navPath.isEmpty { navPath.removeLast() }
                }
                .tvAdaptiveGlassButtonStyle(prominent: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
    }

    private var noSourceCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(TVTokens.Color.accent)
            Text("尚未添加任何 SMB / WebDAV 服务器")
                .font(TVTokens.Typography.sectionTitle)
            Text("添加您的 NAS、路由器或网盘 WebDAV 后，即可直接流畅播放 4K HDR / HEVC 影片。")
                .font(TVTokens.Typography.secondary)
                .foregroundStyle(TVTokens.Color.secondaryText)
            Button("前往添加服务器", action: onOpenSourcesManager)
                .tvAdaptiveGlassButtonStyle(prominent: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
    }

    private func errorCard(_ message: String, source: MediaSourceConfig) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text("读取目录失败")
                .font(TVTokens.Typography.sectionTitle)
            Text(message)
                .font(TVTokens.Typography.secondary)
                .foregroundStyle(TVTokens.Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 780)
            AdaptiveGlassContainer(spacing: 16) {
                HStack(spacing: 16) {
                    Button("重试加载") {
                        Task {
                            await env.resetProvider(for: source.id)
                            await loadDirectory()
                        }
                    }
                    .tvAdaptiveGlassButtonStyle(prominent: true)
                    Button("修改服务器配置", action: onOpenSourcesManager)
                        .tvAdaptiveGlassButtonStyle()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
    }

    private func open(_ entry: VFSEntry, source: MediaSourceConfig) {
        if entry.isDirectory {
            navPath.append(entry.path)
        } else if entry.isVideo {
            onPlay(source, entry)
        }
    }

    private func loadDirectory() async {
        guard let source else {
            entries = []
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let provider = try await env.provider(for: source)
            entries = try await provider.list(path: currentPath)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func historyRecord(for entry: VFSEntry, source: MediaSourceConfig) -> PlaybackRecord? {
        env.history.first { $0.sourceID == source.id && $0.path == entry.path }
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
