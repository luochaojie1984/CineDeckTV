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

    @Test("字幕样式支持字体/底框/位置/对齐且兼容旧版 JSON")
    func subtitleStyleBackwardCompatibility() throws {
        var style = SubtitleStyleConfig()
        style.fontFamily = .rounded
        style.fontSize = 46
        style.bottomInset = 88
        style.backgroundOpacity = 0.68
        style.alignment = .leading
        style.forceCustomStyle = true

        let encoded = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(SubtitleStyleConfig.self, from: encoded)
        #expect(decoded == style)

        let legacy = Data("{\"fontSize\": 42, \"foregroundHex\": \"#FFD859\"}".utf8)
        let legacyDecoded = try JSONDecoder().decode(SubtitleStyleConfig.self, from: legacy)
        #expect(legacyDecoded.fontSize == 42)
        #expect(legacyDecoded.foregroundHex == "#FFD859")
        #expect(legacyDecoded.fontFamily == .system)
        #expect(legacyDecoded.backgroundOpacity == 0.32)
    }

    @Test("7 款中文字体（含楷体/宋体/仿宋/圆体/电影艺术黑）与 10 种配色及旧版 rawValue 兼容")
    func chineseFontsAndLegacyMapping() throws {
        #expect(SubtitleStyleConfig.FontFamily.allCases.count == 7)
        #expect(SubtitleStyleConfig.FontFamily.allCases.contains(.kaiti))
        #expect(SubtitleStyleConfig.FontFamily.allCases.contains(.songti))
        #expect(SubtitleStyleConfig.FontFamily.allCases.contains(.fangsong))
        #expect(SubtitleStyleConfig.FontFamily.allCases.contains(.rounded))
        #expect(SubtitleStyleConfig.FontFamily.allCases.contains(.smiley))
        #expect(SubtitleStyleConfig.colorPresets.count == 10)

        let legacySerif = Data("{\"fontFamily\": \"serif\", \"fontSize\": 44}".utf8)
        let decodedSerif = try JSONDecoder().decode(SubtitleStyleConfig.self, from: legacySerif)
        #expect(decodedSerif.fontFamily == .songti)
        #expect(decodedSerif.fontSize == 44)

        let legacyMono = Data("{\"fontFamily\": \"monospaced\"}".utf8)
        let decodedMono = try JSONDecoder().decode(SubtitleStyleConfig.self, from: legacyMono)
        #expect(decodedMono.fontFamily == .system)
    }
}
