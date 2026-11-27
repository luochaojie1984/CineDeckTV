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
        #expect(legacyDecoded.fontFamily == .kaiti)
        #expect(legacyDecoded.backgroundOpacity == 0.32)
        #expect(legacyDecoded.bottomInset == 8)
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

    @Test("字幕默认为经典楷体 66 号、距底 8px 且缺失字段兼容解码为新默认值")
    func defaultKaiti66And8px() throws {
        let style = SubtitleStyleConfig()
        #expect(style.fontFamily == .kaiti)
        #expect(style.fontSize == 66)
        #expect(style.bottomInset == 8)

        let empty = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(SubtitleStyleConfig.self, from: empty)
        #expect(decoded.fontFamily == .kaiti)
        #expect(decoded.fontSize == 66)
        #expect(decoded.bottomInset == 8)
    }

    @Test("内置字体 PostScript、libass 家族名与风格回退链完整准确")
    func fontMetadataAndFallbackChain() {
        #expect(SubtitleStyleConfig.FontFamily.kaiti.postScriptName == "LXGWWenKaiLite-Medium")
        #expect(SubtitleStyleConfig.FontFamily.kaiti.libassFamilyName == "LXGW WenKai Lite")
        #expect(SubtitleStyleConfig.FontFamily.songti.postScriptName == "LXGWNeoZhiSongPlus")
        #expect(SubtitleStyleConfig.FontFamily.songti.libassFamilyName == "LXGW Neo ZhiSong Plus")
        #expect(SubtitleStyleConfig.FontFamily.fangsong.postScriptName == "ZhuqueFangsong-Regular")
        #expect(SubtitleStyleConfig.FontFamily.fangsong.libassFamilyName == "Zhuque Fangsong (technical preview)")
        #expect(SubtitleStyleConfig.FontFamily.rounded.postScriptName == "LXGWMarkerGothic-Regular")
        #expect(SubtitleStyleConfig.FontFamily.rounded.libassFamilyName == "LXGW Marker Gothic")
        #expect(SubtitleStyleConfig.FontFamily.smiley.postScriptName == "LXGWFasmartGothic")
        #expect(SubtitleStyleConfig.FontFamily.smiley.libassFamilyName == "LXGW Fasmart Gothic")

        for family in SubtitleStyleConfig.FontFamily.allCases where family.bundledFileName != nil {
            #expect(!family.fallbackOrder.isEmpty)
            #expect(family.fallbackOrder.allSatisfy { $0.bundledFileName != nil && $0 != family })
        }
        #expect(SubtitleStyleConfig.FontFamily.system.fallbackOrder.isEmpty)
        #expect(SubtitleStyleConfig.FontFamily.heavy.fallbackOrder.isEmpty)
    }
}

