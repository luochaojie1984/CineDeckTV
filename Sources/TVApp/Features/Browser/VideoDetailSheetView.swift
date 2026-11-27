import SwiftUI
import UIKit
import NetworkVFS
import MetadataKit
import AppPreferences

/// 共享盘刮削影片高清详情页（支持大图/海报、完整演员与标签、剧情简介、高清剧照以及同番号重复版本一键切换）。
public struct VideoDetailSheetView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    public let source: MediaSourceConfig
    @State private var selectedVideo: VFSEntry
    public let siblingVersions: [VFSEntry]
    @ObservedObject public var loader: DirectoryMetadataLoader
    public var onPlay: (VFSEntry) -> Void

    @State private var extraStills: [UIImage] = []
    @FocusState private var isPlayFocused: Bool

    public init(
        source: MediaSourceConfig,
        initialVideo: VFSEntry,
        siblingVersions: [VFSEntry],
        loader: DirectoryMetadataLoader,
        onPlay: @escaping (VFSEntry) -> Void
    ) {
        self.source = source
        self._selectedVideo = State(initialValue: initialVideo)
        self.siblingVersions = siblingVersions
        self.loader = loader
        self.onPlay = onPlay
    }

    private var metadata: MovieMetadata? {
        loader.metadataByPath[selectedVideo.path]
    }

    private var match: VideoSidecarMatch? {
        loader.matchesByPath[selectedVideo.path]
    }

    private var duplicateInfo: DuplicateVersionInfo? {
        loader.duplicateMap[selectedVideo.path]
    }

    private var posterImage: UIImage? {
        loader.posterOrFanart(for: selectedVideo.path)
    }

    private var backdropImage: UIImage? {
        loader.fanartsByPath[selectedVideo.path] ?? loader.postersByPath[selectedVideo.path]
    }

    public var body: some View {
        ZStack {
            backdropLayer

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    topHeroContent

                    if !extraStills.isEmpty {
                        stillsSection
                    }
                }
                .padding(.horizontal, 68)
                .padding(.vertical, 44)
            }
        }
        .onExitCommand { dismiss() }
        .task(id: selectedVideo.path) {
            isPlayFocused = true
            extraStills = await loader.loadExtraStills(
                dirPath: match?.extraFanartDirPath,
                source: source,
                env: env
            )
        }
    }

    private var backdropLayer: some View {
        ZStack {
            Color(red: 0.04, green: 0.06, blue: 0.12).ignoresSafeArea()
            if let bg = backdropImage {
                Image(uiImage: bg)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 26)
                    .opacity(0.36)
                    .ignoresSafeArea()
            }
            LinearGradient(
                colors: [
                    Color.black.opacity(0.76),
                    Color(red: 0.04, green: 0.06, blue: 0.12).opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var topHeroContent: some View {
        HStack(alignment: .top, spacing: 40) {
            // 左侧高清竖版/横版封面卡片
            ZStack {
                if let posterImage {
                    Image(uiImage: posterImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 316, height: 446)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 316, height: 446)
                        .overlay {
                            Image(systemName: "film.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.24), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 22, y: 12)

            // 右侧完整详细信息区
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    if let code = metadata?.code, !code.isEmpty {
                        detailPill(code, tint: TVTokens.Color.amber, solid: true)
                    }
                    if let dup = duplicateInfo, dup.total >= 2 {
                        detailPill("同番号版本 \(dup.index)/\(dup.total)", tint: TVTokens.Color.coral, solid: true)
                    }
                    if let tags = match?.versionTags {
                        ForEach(tags.prefix(5), id: \.self) { tag in
                            detailPill(tag, tint: TVTokens.Color.accent, solid: false)
                        }
                    }
                    if let subs = match?.subtitleCount, subs > 0 {
                        detailPill("外挂字幕 \(subs)", tint: TVTokens.Color.emerald, solid: false)
                    }
                }

                Text(metadata?.title ?? TVTitleFormatter.cleanDisplayTitle(selectedVideo.name))
                    .font(.system(size: 38, weight: .bold))
                    .lineLimit(3)

                if let orig = metadata?.originalTitle, orig != metadata?.title {
                    Text(orig)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(TVTokens.Color.secondaryText)
                        .lineLimit(2)
                }

                // 发行日期 / 时长 / 评分 / 片商 / 厂牌 / 系列
                HStack(spacing: 16) {
                    if let date = metadata?.releaseDate {
                        metaItem(icon: "calendar", text: date)
                    } else if let year = metadata?.year {
                        metaItem(icon: "calendar", text: String(year))
                    }
                    if let mins = metadata?.runtimeMinutes, mins > 0 {
                        metaItem(icon: "clock", text: "\(mins) 分钟")
                    }
                    if let rating = metadata?.rating, rating > 0 {
                        metaItem(icon: "star.fill", text: String(format: "%.1f", rating), tint: TVTokens.Color.amber)
                    }
                    if let studio = metadata?.studio {
                        metaItem(icon: "building.2", text: studio)
                    }
                    if let publisher = metadata?.publisher, publisher != metadata?.studio {
                        metaItem(icon: "tag.square", text: publisher)
                    }
                    if let series = metadata?.series {
                        metaItem(icon: "books.vertical", text: series)
                    }
                }
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(TVTokens.Color.secondaryText)

                // 演员列表
                if let actors = metadata?.actors, !actors.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("演员")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(TVTokens.Color.tertiaryText)
                        FlowTagWrap(items: actors, tint: TVTokens.Color.violet)
                    }
                }

                // 分类标签
                let allLabels = (metadata?.genres ?? []) + (metadata?.tags ?? []).filter { !(metadata?.genres ?? []).contains($0) }
                if !allLabels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("类型与标签")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(TVTokens.Color.tertiaryText)
                        FlowTagWrap(items: Array(allLabels.prefix(14)), tint: TVTokens.Color.accent)
                    }
                }

                if let plot = metadata?.plot, !plot.isEmpty {
                    Text(plot)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(5)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tvGlassSurface(cornerRadius: 16, clear: true)
                }

                // 真实文件识别信息（区分重复文件/非标准命名）
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(TVTokens.Color.accent)
                    Text(selectedVideo.name)
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: selectedVideo.size, countStyle: .file))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(TVTokens.Color.amber)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                // 同目录同番号重复版本切换器
                if siblingVersions.count >= 2 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前目录下发现 \(siblingVersions.count) 个同番号视频版本（点按切换）：")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(TVTokens.Color.coral)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(siblingVersions.enumerated()), id: \.element.id) { idx, sibling in
                                    let sibTags = loader.matchesByPath[sibling.path]?.versionTags.prefix(3).joined(separator: "·") ?? ""
                                    let sizeStr = ByteCountFormatter.string(fromByteCount: sibling.size, countStyle: .file)
                                    Button {
                                        selectedVideo = sibling
                                    } label: {
                                        Text("版本 \(idx + 1) · \(sizeStr)\(sibTags.isEmpty ? "" : " · \(sibTags)")")
                                            .font(.system(size: 17, weight: .semibold))
                                            .lineLimit(1)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                    }
                                    .buttonStyle(TVPlayerOptionButtonStyle(
                                        isSelected: sibling.path == selectedVideo.path,
                                        accentTint: TVTokens.Color.coral,
                                        cornerRadius: 999
                                    ))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .focusSection()
                }

                // 操作按钮栏
                AdaptiveGlassContainer(spacing: 16) {
                    HStack(spacing: 16) {
                        Button {
                            let target = selectedVideo
                            dismiss()
                            onPlay(target)
                        } label: {
                            Label("立即播放", systemImage: "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .padding(.horizontal, 34)
                                .padding(.vertical, 15)
                        }
                        .tvAdaptiveGlassButtonStyle(prominent: true)
                        .tint(TVTokens.Color.accent)
                        .focused($isPlayFocused)

                        Button {
                            dismiss()
                        } label: {
                            Label("返回目录", systemImage: "chevron.left")
                                .font(.system(size: 20, weight: .semibold))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 15)
                        }
                        .tvAdaptiveGlassButtonStyle()
                    }
                }
                .focusSection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stillsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("高清剧照（extrafanart）")
                .font(TVTokens.Typography.sectionTitle)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(extraStills.enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 300, height: 168)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(.white.opacity(0.20), lineWidth: 1)
                            )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func detailPill(_ text: String, tint: Color, solid: Bool) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(tint.opacity(solid ? 0.28 : 0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(solid ? 0.72 : 0.40), lineWidth: 1))
            .foregroundStyle(solid ? .white : tint)
    }

    private func metaItem(icon: String, text: String, tint: Color = TVTokens.Color.secondaryText) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
        }
    }
}

private struct FlowTagWrap: View {
    let items: [String]
    let tint: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(tint.opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(tint.opacity(0.38), lineWidth: 1))
                        .foregroundStyle(.white.opacity(0.94))
                }
            }
            .padding(.vertical, 2)
        }
    }
}
