import Testing
import Foundation
@testable import SubtitleKit

@Suite("SubtitleEncodingDetector GB18030")
struct GB18030DecodingTests {
    @Test("真实 GB18030/GBK 中文字幕字节精准解码且无乱码")
    func decodesRealGB18030Bytes() {
        // GBK/GB18030 bytes for "1\r\n00:00:01,000 --> 00:00:03,000\r\n你好，世界！中文字幕测试。\r\n"
        // 你=C4E3 好=BAC3 ，=A3AC 世=CAC0 界=BDE7 ！=A3A1 中=D6D0 文=CEC4 字=D7D6 幕=C4BB 测=B2E2 试=CAD4 。=A1A3
        let gbBytes: [UInt8] = Array("1\r\n00:00:01,000 --> 00:00:03,000\r\n".utf8)
            + [0xC4, 0xE3, 0xBA, 0xC3, 0xA3, 0xAC, 0xCA, 0xC0, 0xBD, 0xE7, 0xA3, 0xA1,
               0xD6, 0xD0, 0xCE, 0xC4, 0xD7, 0xD6, 0xC4, 0xBB, 0xB2, 0xE2, 0xCA, 0xD4, 0xA1, 0xA3]
            + Array("\r\n".utf8)
        let data = Data(gbBytes)
        let result = SubtitleEncodingDetector.detect(data)
        #expect(result.text.contains("你好，世界！中文字幕测试。"))
        #expect(result.encodingName == "GB18030")

        let utf8Data = SubtitleEncodingDetector.normalizeToUTF8(data)
        let roundTrip = String(data: utf8Data, encoding: .utf8) ?? ""
        #expect(roundTrip.contains("你好，世界！中文字幕测试。"))
    }
}
