import Testing
import Foundation
@testable import SubtitleKit

@Suite("SubtitleParser")
struct SubtitleParserTests {
    @Test("SRT 解析出正确时间段与文本")
    func parsesSRT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        <i>第一行</i>

        2
        00:01:02,250 --> 00:01:04,000
        第二行
        """
        let cues = SubtitleParser.parse(text: srt, fileExtension: "srt")
        #expect(cues.count == 2)
        #expect(cues[0].start == 1.0)
        #expect(cues[0].end == 3.5)
        #expect(cues[0].text == "第一行")
        #expect(abs(cues[1].start - 62.25) < 0.001)
    }

    @Test("ASS Events 解析并剥离样式覆盖")
    func parsesASS() {
        let ass = """
        [Script Info]
        Title: test

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:05.00,0:00:07.00,Default,,0,0,0,,{\\i1}特效字幕{\\i0}\\N第二行
        """
        let cues = SubtitleParser.parse(text: ass, fileExtension: "ass")
        #expect(cues.count == 1)
        #expect(cues[0].start == 5.0)
        #expect(cues[0].text.contains("特效字幕"))
        #expect(cues[0].text.contains("\\N") == false)
    }

    @Test("VTT 时间戳与 SRT 通用")
    func parsesVTT() {
        let vtt = """
        WEBVTT

        00:00:10.000 --> 00:00:12.000
        Hello
        """
        let cues = SubtitleParser.parse(text: vtt, fileExtension: "vtt")
        #expect(cues.count == 1)
        #expect(cues[0].start == 10.0)
        #expect(cues[0].text == "Hello")
    }
}
