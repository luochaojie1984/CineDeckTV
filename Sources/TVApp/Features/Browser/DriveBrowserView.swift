import SwiftUI
import NetworkVFS

/// 共享盘文件浏览：全宽 4 列大卡片网格 / 大字号宽列表一键切换，底部聚焦摘要条。
public struct DriveBrowserView: View {
    @EnvironmentObject private var env: AppEnvironment

    public let source: MediaSourceConfig

    @State private var entries: [VFSEntry] = []
    @State private var currentPath = ""
    @State private var isGrid = true
    @State private var videosOnly = false
    @State private var sortMode: SortMode = .name
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var focusedEntry: VFSEntry?
    @FocusState private var focusedID: VFSEntry.ID?

    public enum SortMode: String, CaseIterable {
        case name = "名称"
        case modified = "时间"
        case size = "大小"
    }

    public init(source: MediaSourceConfig) {
        self.source = source
    }

    private var visibleEntries: [VFSEntry] {
        var list = entries
        if videosOnly { list = list.filter { $0.isVideo || $0.isDirectory } }
        switch sortMode {
        case .name:
            list.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .modified:
            list.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .size:
            list.sort { $0.size > $1.size }
        }
        return list
    }

    public var body: some View {
        ZStack {
            TVTokens.backgroundGradient.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                toolbar
                content
                if let focusedEntry {
                    summaryBar(for: focusedEntry)
                }
            }
            .padding(.horizontal, TVTokens.Spacing.browserHorizontal)
            .padding(.top, 18)
        }
        .task(id: currentPath) { await reload() }
        .onChange(of: focusedID) { _, newValue in
            focusedEntry = visibleEntries.first { $0.id == newValue }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            if !currentPath.isEmpty {
                Button { goUp() } label: { Label("返回", systemImage: "chevron.left") }
                    .tvAdaptiveGlassButtonStyle()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(currentPath.isEmpty ? source.name : currentPath)
                    .font(TVTokens.Typography.directoryTitle)
                    .lineLimit(1)
                Text("\(visibleEntries.count) 个项目 · \(source.kind.displayName) \(source.host)")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            AdaptiveGlassContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button(sortMode.rawValue) { cycleSort() }
                        .lineLimit(1)
                        .tvAdaptiveGlassButtonStyle()
                    Button(isGrid ? "网格" : "列表") { isGrid.toggle() }
                        .lineLimit(1)
                        .tvAdaptiveGlassButtonStyle()
                    Button(videosOnly ? "仅视频" : "全部") { videosOnly.toggle() }
                        .lineLimit(1)
                        .tvAdaptiveGlassButtonStyle(prominent: videosOnly)
                }
            }
        }
        .frame(height: TVTokens.Size.toolbarHeight)
        .focusSection()
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText {
            errorPanel(errorText)
        } else if isGrid {
            grid
        } else {
            list
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420, maximum: 460), spacing: TVTokens.Spacing.gridSpacing)],
                      spacing: TVTokens.Spacing.gridSpacing) {
                ForEach(visibleEntries) { entry in
                    Button { open(entry) } label: { gridCard(entry) }
                        .buttonStyle(TVCardButtonStyle())
                        .focused($focusedID, equals: entry.id)
                }
            }
            .padding(.bottom, 12)
        }
        .focusSection()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(visibleEntries) { entry in
                    Button { open(entry) } label: { listRow(entry) }
                        .buttonStyle(TVCardButtonStyle())
                        .focused($focusedID, equals: entry.id)
                }
            }
            .padding(.bottom, 12)
        }
        .focusSection()
    }

    private func gridCard(_ entry: VFSEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                iconBlock(entry, size: TVTokens.Size.gridIcon)
                Spacer()
                VideoBadgeRow(entry.badges)
            }
            Spacer(minLength: 0)
            Text(entry.name)
                .font(TVTokens.Typography.gridPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 10) {
                Text(entry.isDirectory ? "文件夹" : formatSize(entry.size))
                Text(dateText(entry.modifiedAt))
            }
            .font(TVTokens.Typography.tertiary)
            .foregroundStyle(TVTokens.Color.secondaryText)
            if let progress = resumeProgress(entry) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(height: 6)
            }
        }
        .padding(TVTokens.Spacing.cardInner)
        .frame(height: TVTokens.Size.gridCardHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: TVTokens.Radius.card).fill(TVTokens.Color.cardSurface))
    }

    private func listRow(_ entry: VFSEntry) -> some View {
        HStack(spacing: 18) {
            iconBlock(entry, size: TVTokens.Size.listIcon)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(TVTokens.Typography.listPrimary)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    Text(entry.isDirectory ? "文件夹" : formatSize(entry.size))
                    Text(dateText(entry.modifiedAt))
                }
                .font(TVTokens.Typography.secondary)
                .foregroundStyle(TVTokens.Color.secondaryText)
            }
            Spacer()
            VideoBadgeRow(entry.badges)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: TVTokens.Radius.card).fill(TVTokens.Color.cardSurface))
    }

    private func iconBlock(_ entry: VFSEntry, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: TVTokens.Radius.gridIconBlock, style: .continuous)
            .fill(iconTint(entry).opacity(0.28))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: entry.isDirectory ? "folder.fill" : (entry.isVideo ? "film.fill" : "doc.fill"))
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(iconTint(entry))
            )
    }

    private func iconTint(_ entry: VFSEntry) -> Color {
        if entry.isDirectory { return TVTokens.Color.folderTint }
        if entry.isVideo { return TVTokens.Color.videoTint }
        if entry.isSubtitle { return TVTokens.Color.subtitleTint }
        return TVTokens.Color.backTint
    }

    private func summaryBar(for entry: VFSEntry) -> some View {
        HStack(spacing: 16) {
            Text(entry.path)
                .font(TVTokens.Typography.tertiary)
                .lineLimit(1)
            Spacer()
            Text(entry.modifiedAt.map { Self.dateFormatter.string(from: $0) } ?? "")
                .font(TVTokens.Typography.tertiary)
        }
        .foregroundStyle(TVTokens.Color.secondaryText)
        .padding(.horizontal, 18)
        .frame(height: TVTokens.Size.summaryBarHeight)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: true)
    }

    private func errorPanel(_ text: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)
            Text(text)
                .font(TVTokens.Typography.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await reload() } }
                .tvAdaptiveGlassButtonStyle(prominent: true)
        }
        .padding(40)
        .tvGlassSurface()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ entry: VFSEntry) {
        if entry.isDirectory {
            currentPath = entry.path
        }
    }

    private func goUp() {
        guard let index = currentPath.lastIndex(of: "/") else {
            currentPath = ""
            return
        }
        currentPath = String(currentPath[..<index])
    }

    private func cycleSort() {
        let all = SortMode.allCases
        let index = all.firstIndex(of: sortMode) ?? 0
        sortMode = all[(index + 1) % all.count]
    }

    private func reload() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let provider = try await env.provider(for: source)
            entries = try await provider.list(path: currentPath)
        } catch {
            entries = []
            errorText = error.localizedDescription
        }
    }

    private func resumeProgress(_ entry: VFSEntry) -> Double? {
        guard entry.isVideo else { return nil }
        guard let position = env.resumePosition(source: source, path: entry.path), position > 0 else { return nil }
        return min(1, position / 7200)
    }

    private func formatSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
