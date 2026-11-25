import Foundation

/// 一条字幕（时间为秒）。
public struct SubtitleCue: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// SRT / WebVTT / ASS 文本字幕解析（FSPlayer 走 libass，AVPlayer 兜底时用本解析器叠加）。
public enum SubtitleParser {
    public static func parse(text: String, fileExtension: String) -> [SubtitleCue] {
        switch fileExtension.lowercased() {
        case "ass", "ssa": return parseASS(text)
        case "vtt": return parseSRTLike(text, vtt: true)
        default: return parseSRTLike(text, vtt: false)
        }
    }

    static func parseSRTLike(_ text: String, vtt: Bool) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeLineIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1]) else { continue }
            let body = lines[(timeLineIndex + 1)...].joined(separator: "\n")
            let cleaned = stripTags(body)
            if !cleaned.isEmpty {
                cues.append(SubtitleCue(start: start, end: end, text: cleaned))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var inEvents = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents, line.lowercased().hasPrefix("dialogue:") else { continue }
            let payload = line.dropFirst("dialogue:".count)
            let fields = payload.components(separatedBy: ",")
            guard fields.count >= 10,
                  let start = parseASSTime(fields[1]),
                  let end = parseASSTime(fields[2]) else { continue }
            let text = fields[9...].joined(separator: ",")
            let cleaned = stripASSOverrides(text).replacingOccurrences(of: "\\N", with: "\n")
            if !cleaned.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: cleaned)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func parseTimestamp(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let segments = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard segments.count >= 2 else { return nil }
        var seconds: Double = 0
        for segment in segments {
            guard let number = Double(segment) else { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    static func parseASSTime(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func stripTags(_ text: String) -> String {
        var result = text
        for pattern in ["<[^>]+>", "\\{[^}]*\\}"] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripASSOverrides(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\{[^}]*\\}") else { return text }
        let result = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
