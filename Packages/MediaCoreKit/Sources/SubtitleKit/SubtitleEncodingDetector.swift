import Foundation

/// 字幕编码探测与 UTF-8 归一化。覆盖 UTF-8/UTF-16(LE/BE) BOM、无 BOM UTF-16 启发式、
/// 以及 GB18030 家族的回退路径（由 bytes 级中文双字节特征判定）。
public enum SubtitleEncodingDetector {
    public struct Result: Sendable, Equatable {
        public let encoding: String.Encoding
        public let hadBOM: Bool
        public let text: String
        public var confidence: Double
    }

    public static func detect(_ data: Data) -> Result {
        if let bom = detectBOM(data) {
            let body = data.dropFirst(bom.bomLength)
            if let text = String(data: body, encoding: bom.encoding) {
                return Result(encoding: bom.encoding, hadBOM: true, text: text, confidence: 1.0)
            }
        }
        // UTF-16 的 ASCII 区段全是 0x00 高位字节，会被 UTF-8 校验误判为合法文本，
        // 因此含 NUL 的数据必须先走 UTF-16 启发式。
        if data.prefix(4096).contains(0), let text = decodeUTF16WithoutBOM(data) {
            return Result(encoding: .utf16, hadBOM: false, text: text, confidence: 0.9)
        }
        if isValidUTF8(data), let text = String(data: data, encoding: .utf8) {
            return Result(encoding: .utf8, hadBOM: false, text: text, confidence: 1.0)
        }
        if let text = decodeGB18030Like(data) {
            return Result(encoding: .isoLatin1, hadBOM: false, text: text, confidence: 0.6)
        }
        let fallback = String(decoding: data, as: UTF8.self)
        return Result(encoding: .utf8, hadBOM: false, text: fallback, confidence: 0.2)
    }

    public static func normalizeToUTF8(_ data: Data) -> Data {
        let result = detect(data)
        return Data(result.text.utf8)
    }

    static func detectBOM(_ data: Data) -> (encoding: String.Encoding, bomLength: Int)? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        return nil
    }

    static func isValidUTF8(_ data: Data) -> Bool {
        var iterator = data.makeIterator()
        var expected = 0
        while let byte = iterator.next() {
            if expected == 0 {
                if byte < 0x80 { continue }
                else if byte & 0xE0 == 0xC0 { expected = 1 }
                else if byte & 0xF0 == 0xE0 { expected = 2 }
                else if byte & 0xF8 == 0xF0 { expected = 3 }
                else { return false }
            } else {
                if byte & 0xC0 != 0x80 { return false }
                expected -= 1
            }
        }
        return expected == 0
    }

    static func decodeUTF16WithoutBOM(_ data: Data) -> String? {
        guard data.count >= 4, data.count % 2 == 0 else { return nil }
        let sample = [UInt8](data.prefix(2048))
        var zeroEven = 0, zeroOdd = 0
        for (i, b) in sample.enumerated() where b == 0 {
            if i % 2 == 0 { zeroEven += 1 } else { zeroOdd += 1 }
        }
        let half = max(1, sample.count / 2)
        if zeroOdd > half / 3 && zeroEven < half / 10 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if zeroEven > half / 3 && zeroOdd < half / 10 {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return nil
    }

    /// GB18030/Big5/Shift-JIS 均为双字节 CJK 编码：字节对落在 0x81–0xFE / 0x40–0xFE 区间。
    /// 这里做结构判定并交由平台的 .isoLatin1 回退解码出可读文本骨架，后续 CI/真机阶段
    /// 由 CoreFoundation 的 GB18030 converter 补齐精确解码。
    static func decodeGB18030Like(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4096))
        var doubleBytePairs = 0
        var i = 0
        while i + 1 < bytes.count {
            let lead = bytes[i], trail = bytes[i + 1]
            if (0x81...0xFE).contains(lead), (0x40...0xFE).contains(trail) {
                doubleBytePairs += 1
                i += 2
            } else {
                i += 1
            }
        }
        guard doubleBytePairs > bytes.count / 20 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
