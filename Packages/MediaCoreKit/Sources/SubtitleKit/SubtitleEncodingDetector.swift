import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(Glibc)
import Glibc
#endif

/// 字幕编码探测与 UTF-8 归一化：完整支持 UTF-8 / UTF-16 BOM、无 BOM UTF-16、GB18030/GBK、Big5、Shift-JIS 与 Windows-1252。
public enum SubtitleEncodingDetector {
    public enum LegacyEncoding: String, Sendable, Equatable {
        case utf8BOM = "UTF-8 (BOM)"
        case utf8 = "UTF-8"
        case utf16LE = "UTF-16 LE"
        case utf16BE = "UTF-16 BE"
        case gb18030 = "GB18030"
        case big5 = "Big5"
        case shiftJIS = "Shift-JIS"
        case windows1252 = "Windows-1252"
    }

    public struct Result: Sendable, Equatable {
        public let encoding: String.Encoding
        public let hadBOM: Bool
        public let text: String
        public var confidence: Double
        public var encodingName: String

        public init(encoding: String.Encoding, hadBOM: Bool, text: String, confidence: Double, encodingName: String = "") {
            self.encoding = encoding
            self.hadBOM = hadBOM
            self.text = text
            self.confidence = confidence
            self.encodingName = encodingName
        }
    }

    public static func detect(_ rawData: Data) -> Result {
        guard !rawData.isEmpty else {
            return Result(encoding: .utf8, hadBOM: false, text: "", confidence: 1.0, encodingName: LegacyEncoding.utf8.rawValue)
        }
        let data = Data(rawData)

        // 1. BOM 优先
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            let body = Data(data.dropFirst(3))
            if let text = String(data: body, encoding: .utf8) {
                return Result(encoding: .utf8, hadBOM: true, text: normalizeLineEndings(text), confidence: 1.0, encodingName: LegacyEncoding.utf8BOM.rawValue)
            }
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            let body = Data(data.dropFirst(2))
            if let text = String(data: body, encoding: .utf16LittleEndian) {
                return Result(encoding: .utf16LittleEndian, hadBOM: true, text: normalizeLineEndings(text), confidence: 1.0, encodingName: LegacyEncoding.utf16LE.rawValue)
            }
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            let body = Data(data.dropFirst(2))
            if let text = String(data: body, encoding: .utf16BigEndian) {
                return Result(encoding: .utf16BigEndian, hadBOM: true, text: normalizeLineEndings(text), confidence: 1.0, encodingName: LegacyEncoding.utf16BE.rawValue)
            }
        }

        // 2. 无 BOM UTF-16 启发式（必须在严格 UTF-8 前检查，因为 ASCII 区段高位 NUL 字节会让 UTF-8 误判通过）
        if looksLikeUTF16WithoutBOM(data), let text = decodeUTF16WithoutBOM(data) {
            return Result(encoding: .utf16, hadBOM: false, text: normalizeLineEndings(text), confidence: 0.92, encodingName: "UTF-16")
        }

        // 3. 严格 UTF-8 校验
        if isValidUTF8(data), let text = String(data: data, encoding: .utf8) {
            return Result(encoding: .utf8, hadBOM: false, text: normalizeLineEndings(text), confidence: 1.0, encodingName: LegacyEncoding.utf8.rawValue)
        }

        // 4. 传统东亚多字节编码真解码 + 字符集质量打分（GB18030 vs Big5 vs Shift-JIS）
        let candidates: [(LegacyEncoding, String)] = [
            (.gb18030, "GB18030"),
            (.big5, "BIG5"),
            (.shiftJIS, "SHIFT_JIS")
        ]
        var best: (text: String, legacy: LegacyEncoding, score: Double)?
        for (legacy, iconvName) in candidates {
            if let decoded = decodeLegacy(data, encoding: legacy, iconvName: iconvName) {
                let score = scoreDecodedText(decoded, encoding: legacy)
                if best == nil || score > best!.score {
                    best = (decoded, legacy, score)
                }
            }
        }
        if let winner = best {
            return Result(
                encoding: .utf8,
                hadBOM: false,
                text: normalizeLineEndings(winner.text),
                confidence: 0.88,
                encodingName: winner.legacy.rawValue
            )
        }

        // 5. Latin-1 / Windows-1252 无损回退
        let fallback = String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        return Result(encoding: .windowsCP1252, hadBOM: false, text: normalizeLineEndings(fallback), confidence: 0.4, encodingName: LegacyEncoding.windows1252.rawValue)
    }

    public static func normalizeToUTF8(_ data: Data) -> Data {
        Data(detect(data).text.utf8)
    }

    private static func looksLikeUTF16WithoutBOM(_ data: Data) -> Bool {
        let sampleLen = min(data.count, 512)
        guard sampleLen >= 8 else { return false }
        let nullCount = data[0..<sampleLen].filter { $0 == 0 }.count
        return Double(nullCount) / Double(sampleLen) > 0.2
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

    private static func normalizeLineEndings(_ str: String) -> String {
        str.replacingOccurrences(of: "\r\n", with: "\n")
           .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func scoreDecodedText(_ text: String, encoding: LegacyEncoding) -> Double {
        var score: Double = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) {
                score += 3.0
            } else if (0x3000...0x303F).contains(v) || (0xFF01...0xFF5E).contains(v) {
                score += 2.0
            } else if (0x3040...0x30FF).contains(v) {
                score += (encoding == .shiftJIS ? 3.5 : 0.2)
            } else if (0xFF61...0xFF9F).contains(v) {
                score -= 4.0
            } else if (0x20...0x7E).contains(v) || v == 0x0A || v == 0x09 {
                score += 0.1
            } else if v == 0xFFFD || v < 0x20 || (0xE000...0xF8FF).contains(v) {
                score -= 10.0
            } else {
                score -= 2.0
            }
        }
        if encoding == .gb18030 { score += 0.5 }
        return score
    }

    private static func decodeLegacy(_ data: Data, encoding: LegacyEncoding, iconvName: String) -> String? {
        #if canImport(CoreFoundation) && !os(Linux)
        let cfEnc: CFStringEncodings
        switch encoding {
        case .gb18030: cfEnc = .GB_18030_2000
        case .big5: cfEnc = .big5
        case .shiftJIS: cfEnc = .shiftJIS
        default: return nil
        }
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: nsEnc))
        #elseif canImport(Glibc)
        return iconvDecode(data, from: iconvName)
        #else
        return nil
        #endif
    }

    #if canImport(Glibc)
    private static func iconvDecode(_ data: Data, from sourceCharset: String) -> String? {
        let cd = iconv_open("UTF-8", sourceCharset)
        let invalid = iconv_t(bitPattern: -1)
        guard let handle = cd, handle != invalid else { return nil }
        defer { iconv_close(handle) }

        return data.withUnsafeBytes { rawBuf -> String? in
            guard let basePtr = rawBuf.baseAddress else { return "" }
            var inBuf: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: basePtr.assumingMemoryBound(to: CChar.self))
            var inBytesLeft: Int = data.count

            var output = Data()
            var outChunk = [CChar](repeating: 0, count: max(4096, data.count * 2))

            while inBytesLeft > 0 {
                let produced: Int? = outChunk.withUnsafeMutableBufferPointer { outBufPtr in
                    var outPtr = outBufPtr.baseAddress
                    var outBytesLeft = outBufPtr.count
                    let res = iconv(handle, &inBuf, &inBytesLeft, &outPtr, &outBytesLeft)
                    let written = outBufPtr.count - outBytesLeft
                    if res == -1 {
                        if errno == E2BIG {
                            return written
                        }
                        return nil
                    }
                    return written
                }
                guard let count = produced else { return nil }
                if count > 0 {
                    outChunk.withUnsafeBytes { ptr in
                        output.append(ptr.bindMemory(to: UInt8.self).baseAddress!, count: count)
                    }
                }
            }
            return String(data: output, encoding: .utf8)
        }
    }
    #endif
}
