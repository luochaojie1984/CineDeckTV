import SwiftUI
import NetworkVFS
import AppPreferences

/// SMB / WebDAV 共享浏览器：
/// - 默认采用「纯净横条列表排列」，齐整利落无冗余树干线；
/// - 严格过滤字幕文件（.srt/.ass/.ssa/.vtt/.sub/.sup）及所有不可播放的非视频格式，仅展示共享文件夹与可播放视频；
/// - 焦点严格约束在条目边框内，绝不越界裁切。
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

    /// 默认横条列表排列（使用新 key 确保升级安装立即生效）。
    @AppStorage("cinedeck.browser.viewStyleV2") private var storedIsGrid = false
    @State private var entries: [VFSEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// 严格仅展示「文件夹」与「可播放视频」，自动隐藏字幕文件与不支持播放的杂项文件。
    private var visibleEntries: [VFSEntry] {
        entries.filter { $0.isDirectory || $0.isVideo }
    }

    private var directoryCount: Int {
        visibleEntries.filter(\.isDirectory).count
    }

    private var videoCount: Int {
        visibleEntries.filter(\.isVideo).count
    }

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
        VStack(alignment: .leading, spacing: 18) {
            toolbar
                .focusSection()

            if let source {
                if let errorMessage {
                    errorCard(errorMessage, source: source)
                        .focusSection()
                } else if isLoading && entries.isEmpty {
                    ProgressView("正在读取共享目录…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleEntries.isEmpty {
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
        .padding(.top, 20)
        .padding(.bottom, 24)
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
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: false, accentTint: TVTokens.Color.accent, cornerRadius: 16))
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
                        if !visibleEntries.isEmpty {
                            Text("\(directoryCount) 目录 · \(videoCount) 视频")
                                .font(.system(size: 16, weight: .bold))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.10), in: Capsule())
                                .foregroundStyle(TVTokens.Color.secondaryText)
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(TVTokens.Color.accent)
                        Text(source?.sharePath.isEmpty == false ? source!.sharePath : "/")
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(TVTokens.Color.accent)
                        if pathSegments.isEmpty {
                            Text("· 共享目录")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(TVTokens.Color.secondaryText)
                        } else {
                            ForEach(Array(pathSegments.enumerated()), id: \.offset) { _, seg in
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(TVTokens.Color.tertiaryText)
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
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: false, accentTint: TVTokens.Color.accent, cornerRadius: 16))

                Button {
                    Task { await loadDirectory() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(TVTokens.Typography.button)
                        .lineLimit(1)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: false, accentTint: TVTokens.Color.accent, cornerRadius: 16))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: false)
    }

    /// 纯净横条列表视图：全宽胶囊横条 + 严格边框内聚焦效果，无左侧树干竖线与分支横线。
    private func listContent(source: MediaSourceConfig) -> some View {
        let items = visibleEntries

        return LazyVStack(alignment: .leading, spacing: 12) {
            // 当前目录标头行
            HStack(spacing: 12) {
                Image(systemName: isAtRoot ? "externaldrive.connected.to.line.below.fill" : "folder.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(isAtRoot ? TVTokens.Color.accent : TVTokens.Color.folderTint)
                Text(isAtRoot ? "\(source.name)（共享根目录）" : (pathSegments.last ?? currentPath))
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("仅显示文件夹与可播放视频")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(TVTokens.Color.accent.opacity(0.16), in: Capsule())
                    .foregroundStyle(TVTokens.Color.accent)
                Spacer()
            }
            .padding(.leading, 6)
            .padding(.bottom, 2)

            ForEach(items) { entry in
                let theme = TVMediaTheme.palette(forTitle: entry.name, isDirectory: entry.isDirectory, isSubtitle: false)

                Button {
                        open(entry, source: source)
                    } label: {
                        HStack(spacing: 18) {
                            Image(systemName: theme.symbol)
                                .font(.system(size: 26, weight: .semibold))
                                .frame(width: 56, height: 56)
                                .background(
                                    LinearGradient(
                                        colors: [theme.primary.opacity(0.42), theme.secondary.opacity(0.18)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(theme.primary.opacity(0.48), lineWidth: 1)
                                )
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.isDirectory ? entry.name : TVTitleFormatter.cleanDisplayTitle(entry.name))
                                    .font(TVTokens.Typography.listPrimary)
                                    .lineLimit(1)

                                if entry.isDirectory {
                                    HStack(spacing: 8) {
                                        Text("共享文件夹")
                                            .foregroundStyle(theme.primary)
                                        Text("·")
                                        Text("按确定进入下级目录")
                                    }
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(TVTokens.Color.secondaryText)
                                } else {
                                    HStack(spacing: 12) {
                                        Text(entry.fileExtension.uppercased())
                                            .font(.system(size: 14, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(theme.primary.opacity(0.22), in: Capsule())
                                            .foregroundStyle(theme.primary)
                                        Text(formatSize(entry.size))
                                        if let record = historyRecord(for: entry, source: source), record.duration > 0 {
                                            Text("·")
                                            Text("已播 \(Int(record.progress * 100))%")
                                                .fontWeight(.bold)
                                                .foregroundStyle(theme.primary)
                                            TVProgressBar(progress: record.progress, tint: theme.primary, secondaryTint: theme.secondary, height: 5)
                                                .frame(width: 96)
                                        }
                                    }
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(TVTokens.Color.secondaryText)
                                }
                            }

                            Spacer(minLength: 16)

                            if entry.isVideo {
                                VideoBadgeRow(entry.badges, maxCount: 4)
                            } else {
                                Text("目录")
                                    .font(.system(size: 15, weight: .bold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(theme.primary.opacity(0.18), in: Capsule())
                                    .foregroundStyle(theme.primary)
                            }

                            Image(systemName: entry.isDirectory ? "chevron.right" : "play.circle.fill")
                                .font(.system(size: entry.isDirectory ? 20 : 26, weight: .bold))
                                .foregroundStyle(entry.isDirectory ? TVTokens.Color.secondaryText : theme.primary)
                        }
                        .padding(.leading, 22)
                        .padding(.trailing, 22)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                .buttonStyle(TVListRowButtonStyle(accentTint: theme.primary))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    private func gridContent(source: MediaSourceConfig) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: TVTokens.Spacing.gridSpacing), count: 3),
            spacing: TVTokens.Spacing.gridSpacing
        ) {
            ForEach(visibleEntries) { entry in
                let theme = TVMediaTheme.palette(forTitle: entry.name, isDirectory: entry.isDirectory, isSubtitle: false)
                Button {
                    open(entry, source: source)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
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
                                    Text("共享文件夹")
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
                                        Text(theme.tag)
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
                .buttonStyle(TVCardButtonStyle(focusedScale: 1.0, accentTint: theme.primary))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var emptyFolderCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 52))
                .foregroundStyle(TVTokens.Color.secondaryText)
            Text("当前目录没有可播放的视频或文件夹")
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
