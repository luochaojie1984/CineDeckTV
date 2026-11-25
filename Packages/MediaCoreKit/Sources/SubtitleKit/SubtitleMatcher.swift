import Foundation

/// 外挂字幕与视频的智能匹配：按剧集号 + 语言标签打分。
public struct SubtitleCandidate: Sendable, Hashable {
    public let fileName: String
    public let path: String

    public init(fileName: String, path: String) {
        self.fileName = fileName
        self.path = path
    }
}

public enum SubtitleMatcher {
    public static let languageTags: [String: [String]] = [
        "zh-Hans": ["chs", "sc", "zh-cn", "简体", "简中", "中文"],
        "zh-Hant": ["cht", "tc", "zh-tw", "繁体", "繁中"],
        "ja": ["jpn", "jp", "ja", "日文", "日语"],
        "en": ["eng", "en", "英文", "英语"],
    ]

    /// 提取剧集号：E01 / EP01 / 第01集 / [01] / - 01 -。
    public static func episodeNumber(in name: String) -> Int? {
        let patterns = [
            "(?i)(?:^|[^a-z])e(\\d{1,4})(?:[^0-9]|$)",
            "(?i)ep(?:isode)?[ ._-]?(\\d{1,4})",
            "第(\\d{1,4})[集话話]",
            "\\[(\\d{1,4})\\]",
            "(?:^|[ ._-])(\\d{1,3})(?:[ ._-]|$)"
        ]
        let upper = name
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: upper, range: NSRange(upper.startIndex..., in: upper)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: upper),
               let value = Int(upper[range]) {
                return value
            }
        }
        return nil
    }

    public static func language(of fileName: String) -> String? {
        let lower = fileName.lowercased()
        for (code, tags) in languageTags where tags.contains(where: { lower.contains($0) }) {
            return code
        }
        return nil
    }

    /// 返回按匹配度降序排列的字幕候选。
    public static func rank(videoName: String, candidates: [SubtitleCandidate]) -> [SubtitleCandidate] {
        let videoEpisode = episodeNumber(in: videoName)
        let videoBase = URL(fileURLWithPath: videoName).deletingPathExtension().lastPathComponent
        return candidates
            .map { candidate -> (SubtitleCandidate, Int) in
                var score = 0
                let candidateBase = URL(fileURLWithPath: candidate.fileName).deletingPathExtension().lastPathComponent
                if candidateBase.hasPrefix(videoBase) { score += 100 }
                if let videoEpisode, episodeNumber(in: candidate.fileName) == videoEpisode { score += 50 }
                if language(of: candidate.fileName) == "zh-Hans" { score += 20 }
                if language(of: candidate.fileName) != nil { score += 5 }
                return (candidate, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
