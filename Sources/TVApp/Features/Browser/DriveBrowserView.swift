import SwiftUI
import NetworkVFS
import AppPreferences

/// 网盘风格共享浏览器：
/// - 采用原生 `NavigationStack(path:)` 逐级入栈，遥控器按返回自动退回上一级目录，根目录按返回回到「首页」；
/// - 顶部工具栏与内容区均配置 `.focusSection()`，上下左右方向键随时可在任意卡片与功能按钮间直达移动。
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
        .padding(.horizontal, 48)
        .padding(.vertical, 24)
        .task(id: "\(source?.id.uuidString ?? "none")::\(currentPath)") {
            await loadDirectory()
        }
    }

    private var toolbar: some View {
        AdaptiveGlassContainer(spacing: 14) {
            HStack(spacing: 14) {
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

                VStack(alignment: .leading, spacing: 4) {
                    Text(source?.name ?? "未连接片源")
                        .font(TVTokens.Typography.directoryTitle)
                        .lineLimit(1)
                    Text(currentPath.isEmpty ? "/" : currentPath)
                        .font(TVTokens.Typography.tertiary)
                        .foregroundStyle(TVTokens.Color.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

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
                    storedIsGrid.toggle()
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
            .frame(minHeight: TVTokens.Size.toolbarHeight)
        }
    }

    private func gridContent(source: MediaSourceConfig) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: TVTokens.Spacing.gridSpacing), count: 3),
            spacing: TVTokens.Spacing.gridSpacing
        ) {
            ForEach(entries) { entry in
                Button {
                    open(entry, source: source)
                } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: icon(for: entry))
                                .font(.system(size: 36, weight: .semibold))
                                .frame(width: TVTokens.Size.gridIcon, height: TVTokens.Size.gridIcon)
                                .background(iconTint(for: entry).opacity(0.24), in: RoundedRectangle(cornerRadius: TVTokens.Radius.gridIconBlock))
                                .foregroundStyle(iconTint(for: entry))
                            Spacer()
                            if entry.isVideo {
                                VideoBadgeRow(entry.badges)
                            }
                        }

                        Text(entry.name)
                            .font(TVTokens.Typography.gridPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: 4)

                        if entry.isDirectory {
                            Text("文件夹")
                                .font(TVTokens.Typography.tertiary)
                                .foregroundStyle(TVTokens.Color.secondaryText)
                        } else {
                            let record = historyRecord(for: entry, source: source)
                            if let record, record.duration > 0 {
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView(value: record.progress)
                                        .tint(TVTokens.Color.accent)
                                    Text("已看 \(Int(record.progress * 100))% · \(formatSize(entry.size))")
                                        .font(TVTokens.Typography.tertiary)
                                        .foregroundStyle(TVTokens.Color.secondaryText)
                                }
                            } else {
                                Text(formatSize(entry.size))
                                    .font(TVTokens.Typography.tertiary)
                                    .foregroundStyle(TVTokens.Color.secondaryText)
                            }
                        }
                    }
                    .padding(TVTokens.Spacing.cardInner)
                    .frame(height: TVTokens.Size.gridCardHeight)
                }
                .buttonStyle(TVCardButtonStyle())
            }
        }
        .padding(.vertical, 8)
    }

    private func listContent(source: MediaSourceConfig) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(entries) { entry in
                Button {
                    open(entry, source: source)
                } label: {
                    HStack(spacing: 18) {
                        Image(systemName: icon(for: entry))
                            .font(.system(size: 32, weight: .semibold))
                            .frame(width: TVTokens.Size.listIcon, height: TVTokens.Size.listIcon)
                            .background(iconTint(for: entry).opacity(0.24), in: RoundedRectangle(cornerRadius: TVTokens.Radius.iconBlock))
                            .foregroundStyle(iconTint(for: entry))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.name)
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
                                            .foregroundStyle(TVTokens.Color.accent)
                                    }
                                }
                                .font(TVTokens.Typography.secondary)
                                .foregroundStyle(TVTokens.Color.secondaryText)
                            }
                        }

                        Spacer()

                        if entry.isVideo {
                            VideoBadgeRow(entry.badges)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(TVTokens.Color.secondaryText)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .buttonStyle(TVListRowButtonStyle())
            }
        }
        .padding(.vertical, 6)
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

    private func icon(for entry: VFSEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isVideo { return "film.fill" }
        if entry.isSubtitle { return "captions.bubble.fill" }
        return "doc.fill"
    }

    private func iconTint(for entry: VFSEntry) -> Color {
        if entry.isDirectory { return TVTokens.Color.folderTint }
        if entry.isVideo { return TVTokens.Color.videoTint }
        if entry.isSubtitle { return TVTokens.Color.subtitleTint }
        return TVTokens.Color.secondaryText
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
