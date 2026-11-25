import Testing
import Foundation
@testable import SubtitleKit

@Suite("SubtitleKit")
struct SubtitleKitTests {
    @Test("UTF-8 BOM 被识别并剥离")
    func detectsUTF8BOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: Array("1\n00:00:01,000 --> 00:00:02,000\n你好\n".utf8))
        let result = SubtitleEncodingDetector.detect(data)
        #expect(result.hadBOM)
        #expect(result.text.hasPrefix("1"))
    }

    @Test("无 BOM 的 UTF-16LE 可解码")
    func decodesUTF16LE() {
        let text = "1\n00:00:01,000 --> 00:00:02,000\n字幕测试\n"
        let data = text.data(using: .utf16LittleEndian)!
        let result = SubtitleEncodingDetector.detect(data)
        #expect(result.text.contains("字幕测试"))
    }

    @Test("剧集号提取覆盖常见命名")
    func extractsEpisode() {
        #expect(SubtitleMatcher.episodeNumber(in: "Show.S01E07.1080p.mkv") == 7)
        #expect(SubtitleMatcher.episodeNumber(in: "剧名 - 第12集 - 1080p.mkv") == 12)
        #expect(SubtitleMatcher.episodeNumber(in: "[Group] Title [03][BDRip].mkv") == 3)
    }

    @Test("字幕按剧集号与语言排序")
    func ranksCandidates() {
        let video = "Show.S01E07.1080p.mkv"
        let candidates = [
            SubtitleCandidate(fileName: "Show.S01E06.chs.srt", path: "/a"),
            SubtitleCandidate(fileName: "Show.S01E07.chs.ass", path: "/b"),
            SubtitleCandidate(fileName: "Other.S01E07.eng.srt", path: "/c")
        ]
        let ranked = SubtitleMatcher.rank(videoName: video, candidates: candidates)
        #expect(ranked.first?.path == "/b")
    }
}
