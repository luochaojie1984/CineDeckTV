import Foundation
import NetworkVFS

/// 单个视频与同目录 `.nfo` / 高清封面图 / 剧照目录 / 字幕计数 / 版本特征指纹的 1 对 1 严格匹配结果。
public struct VideoSidecarMatch: Sendable, Equatable {
    public let video: VFSEntry
    public let nfoEntry: VFSEntry?
    public let posterEntry: VFSEntry?
    public let fanartEntry: VFSEntry?
    public let extraFanartDirPath: String?
    public let subtitleCount: Int
    public let versionTags: [String]

    public var hasMetadataOrArtwork: Bool {
        nfoEntry != nil || posterEntry != nil || fanartEntry != nil
    }

    public init(
        video: VFSEntry,
        nfoEntry: VFSEntry?,
        posterEntry: VFSEntry?,
        fanartEntry: VFSEntry?,
        extraFanartDirPath: String?,
        subtitleCount: Int,
        versionTags: [String]
    ) {
        self.video = video
        self.nfoEntry = nfoEntry
        self.posterEntry = posterEntry
        self.fanartEntry = fanartEntry
        self.extraFanartDirPath = extraFanartDirPath
        self.subtitleCount = subtitleCount
        self.versionTags = versionTags
    }
}

/// 同目录下存在相同番号多份文件时的清晰区分标注（保留所有真实文件，不覆盖不误删）。
public struct DuplicateVersionInfo: Sendable, Equatable {
    public let normalizedCode: String
    public let index: Int
    public let total: Int

    public init(normalizedCode: String, index: Int, total: Int) {
        self.normalizedCode = normalizedCode
        self.index = index
        self.total = total
    }
}

/// 严格侧车文件匹配器：
/// - 优先按视频完整主文件名（`<videoBase>.nfo` / `-poster.jpg` / `-fanart.jpg`）精准 1 对 1 绑定；
/// - 仅当目录只包含单部影片（或同片 CD1/CD2 分段）时才允许回退 `movie.nfo` / `poster.jpg` / `fanart.jpg` / `extrafanart`，彻底防止同目录多影片或重复影片串图。
public enum SidecarMatcher {
    private static let imageExtensions: [String] = ["jpg", "jpeg", "png", "webp"]

    public static func match(entries: [VFSEntry]) -> [String: VideoSidecarMatch] {
        let videos = entries.filter(\.isVideo)
        guard !videos.isEmpty else { return [:] }

        let directories = entries.filter(\.isDirectory)
        let files = entries.filter { !$0.isDirectory }
        var byLowerName: [String: VFSEntry] = [:]
        var nfoFiles: [VFSEntry] = []
        var subtitleFiles: [VFSEntry] = []

        for file in files {
            let lower = file.name.lowercased()
            if byLowerName[lower] == nil {
                byLowerName[lower] = file
            }
            if file.fileExtension == "nfo" {
                nfoFiles.append(file)
            } else if file.isSubtitle {
                subtitleFiles.append(file)
            }
        }

        let isSingleMovieDir = detectSingleMovieDirectory(videos: videos)
        let extraFanartDir = isSingleMovieDir
            ? directories.first(where: { $0.name.caseInsensitiveCompare("extrafanart") == .orderedSame })?.path
            : nil

        var results: [String: VideoSidecarMatch] = [:]
        for video in videos {
            let base = fileStem(video.name)
            let partStripped = stripMultiPartSuffix(base)
            let baseCandidates = partStripped.caseInsensitiveCompare(base) == .orderedSame ? [base] : [base, partStripped]

            var matchedNFO: VFSEntry?
            for candidate in baseCandidates {
                if let exact = byLowerName["\(candidate.lowercased()).nfo"] {
                    matchedNFO = exact
                    break
                }
            }
            if matchedNFO == nil && isSingleMovieDir {
                matchedNFO = byLowerName["movie.nfo"] ?? (nfoFiles.count == 1 ? nfoFiles.first : nil)
            }

            var matchedPoster: VFSEntry?
            for candidate in baseCandidates {
                let lc = candidate.lowercased()
                if let hit = firstImage(namedCandidates: ["\(lc)-poster", "\(lc)-thumb", lc], lookup: byLowerName) {
                    matchedPoster = hit
                    break
                }
            }
            if matchedPoster == nil && isSingleMovieDir {
                matchedPoster = firstImage(namedCandidates: ["poster", "thumb", "folder"], lookup: byLowerName)
            }

            var matchedFanart: VFSEntry?
            for candidate in baseCandidates {
                let lc = candidate.lowercased()
                if let hit = firstImage(namedCandidates: ["\(lc)-fanart", "\(lc)-backdrop"], lookup: byLowerName) {
                    matchedFanart = hit
                    break
                }
            }
            if matchedFanart == nil && isSingleMovieDir {
                matchedFanart = firstImage(namedCandidates: ["fanart", "backdrop"], lookup: byLowerName)
            }

            let lcBase = base.lowercased()
            let lcPart = partStripped.lowercased()
            let subCount: Int
            if isSingleMovieDir {
                subCount = subtitleFiles.count
            } else {
                subCount = subtitleFiles.filter { sub in
                    let subLower = sub.name.lowercased()
                    return subLower.hasPrefix(lcBase) || (lcPart != lcBase && subLower.hasPrefix(lcPart))
                }.count
            }

            results[video.path] = VideoSidecarMatch(
                video: video,
                nfoEntry: matchedNFO,
                posterEntry: matchedPoster,
                fanartEntry: matchedFanart,
                extraFanartDirPath: extraFanartDir,
                subtitleCount: subCount,
                versionTags: extractVersionTags(fileName: video.name)
            )
        }
        return results
    }

    /// 识别同一目录内解析出相同番号的多个视频，生成 `1/N ... N/N` 版本序号标记（未刮削视频绝不误判为重复）。
    public static func duplicateMap(
        videos: [VFSEntry],
        metadataByPath: [String: MovieMetadata]
    ) -> [String: DuplicateVersionInfo] {
        var groups: [String: [VFSEntry]] = [:]
        for video in videos {
            guard let rawCode = metadataByPath[video.path]?.code?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased(),
                !rawCode.isEmpty else {
                continue
            }
            groups[rawCode, default: []].append(video)
        }

        var map: [String: DuplicateVersionInfo] = [:]
        for (code, group) in groups where group.count >= 2 {
            let sorted = group.sorted { lhs, rhs in
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            for (idx, item) in sorted.enumerated() {
                map[item.path] = DuplicateVersionInfo(
                    normalizedCode: code,
                    index: idx + 1,
                    total: sorted.count
                )
            }
        }
        return map
    }

    /// 从原始文件名提取区分多版本/重复文件的版本标签（分辨率、字幕/破解/流出标注、分段、容器）。
    public static func extractVersionTags(fileName: String) -> [String] {
        let stem = fileStem(fileName)
        let upper = stem.uppercased()
        let tokens = Set(upper.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var tags: [String] = []

        func appendUnique(_ tag: String) {
            if !tags.contains(tag) { tags.append(tag) }
        }

        if upper.contains("2160P") || upper.contains("4K") || tokens.contains("2160") {
            appendUnique("4K")
        } else if upper.contains("1080P") || upper.contains("FHD") || tokens.contains("1080") {
            appendUnique("1080P")
        } else if upper.contains("720P") || tokens.contains("720") {
            appendUnique("720P")
        }

        if upper.contains("DOVI") || upper.contains("DOLBY") || tokens.contains("DV") {
            appendUnique("DV")
        }
        if upper.contains("HDR10+") {
            appendUnique("HDR10+")
        } else if upper.contains("HDR") {
            appendUnique("HDR")
        }

        if stem.contains("中字") || stem.contains("中文") || stem.contains("简中") || stem.contains("繁中")
            || tokens.contains("C") || tokens.contains("CH") || tokens.contains("CHS") || tokens.contains("CHT")
            || tokens.contains("CN") || tokens.contains("UC") || upper.hasSuffix("-C") {
            appendUnique("中字")
        }

        if stem.contains("无码") || stem.contains("步兵") || tokens.contains("UC") || tokens.contains("U")
            || tokens.contains("UNCENSORED") || upper.hasSuffix("-U") {
            appendUnique("无码")
        }

        if stem.contains("破解") || tokens.contains("CRACK") {
            appendUnique("破解")
        }
        if stem.contains("流出") || tokens.contains("LEAK") || tokens.contains("LEAKED") {
            appendUnique("流出")
        }

        if let part = detectPartTag(upperStem: upper) {
            appendUnique(part)
        }

        let ext = (fileName as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !ext.isEmpty {
            appendUnique(ext)
        }
        return tags
    }

    // MARK: - 内部匹配辅助

    private static func detectSingleMovieDirectory(videos: [VFSEntry]) -> Bool {
        if videos.count <= 1 { return true }
        let normalizedStems = Set(videos.map { stripMultiPartSuffix(fileStem($0.name)).lowercased() })
        return normalizedStems.count == 1
    }

    private static func fileStem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private static func stripMultiPartSuffix(_ stem: String) -> String {
        let pattern = "(?:[-_.\\s]*(?:CD|PART|DISC)\\s*\\d+|[-_.]\\d{1,2})$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return stem
        }
        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        let stripped = regex.stringByReplacingMatches(in: stem, options: [], range: range, withTemplate: "")
        let trimmed = stripped.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        return trimmed.isEmpty ? stem : trimmed
    }

    private static func detectPartTag(upperStem: String) -> String? {
        let pattern = "(?:CD|PART|DISC)\\s*(\\d+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(upperStem.startIndex..<upperStem.endIndex, in: upperStem)
        guard let match = regex.firstMatch(in: upperStem, options: [], range: range),
              match.numberOfRanges >= 2,
              let r1 = Range(match.range(at: 1), in: upperStem) else {
            return nil
        }
        let prefix = upperStem[Range(match.range(at: 0), in: upperStem)!].contains("PART") ? "PART" : "CD"
        return "\(prefix)\(upperStem[r1])"
    }

    private static func firstImage(namedCandidates: [String], lookup: [String: VFSEntry]) -> VFSEntry? {
        for base in namedCandidates {
            for ext in imageExtensions {
                if let entry = lookup["\(base).\(ext)"] {
                    return entry
                }
            }
        }
        return nil
    }
}
