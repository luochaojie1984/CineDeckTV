import Foundation

/// 纯 Swift `<movie>` XML 解析器（无 FoundationXML 依赖，Linux 与 tvOS 行为 100% 一致）。
public enum NFOParser {
    public static func parse(data: Data) -> MovieMetadata? {
        guard !data.isEmpty, let xml = decodeXMLString(data) else { return nil }
        return parse(xml: xml)
    }

    public static func parse(xml rawXML: String) -> MovieMetadata? {
        let strippedComments = removeXMLComments(in: rawXML)
        guard let movieBody = extractFirstElementBody(named: "movie", in: strippedComments) else {
            return nil
        }

        let numTag = firstTagText("num", in: movieBody)
        let uniqueIds = extractAllElements(named: "uniqueid", in: movieBody)
        let preferredUniqueID = uniqueIds.first(where: { !$0.isEmpty })
        let code = nonEmpty(numTag ?? preferredUniqueID)?.uppercased()

        let rawTitle = firstTagText("title", in: movieBody)
        let originalTitle = nonEmpty(firstTagText("originaltitle", in: movieBody))
        let resolvedTitle = nonEmpty(rawTitle) ?? originalTitle ?? code
        guard let title = resolvedTitle, !title.isEmpty else {
            return nil
        }

        let plot = nonEmpty(firstTagText("plot", in: movieBody))
            ?? nonEmpty(firstTagText("outline", in: movieBody))

        let releaseDate = nonEmpty(firstTagText("premiered", in: movieBody))
            ?? nonEmpty(firstTagText("releasedate", in: movieBody))
            ?? nonEmpty(firstTagText("release", in: movieBody))

        var year = nonEmpty(firstTagText("year", in: movieBody)).flatMap { Int($0) }
        if year == nil, let releaseDate, releaseDate.count >= 4 {
            year = Int(releaseDate.prefix(4))
        }

        let runtimeMinutes = nonEmpty(firstTagText("runtime", in: movieBody)).flatMap { raw -> Int? in
            let digits = raw.prefix(while: { $0.isNumber })
            return digits.isEmpty ? nil : Int(digits)
        }

        var rating = nonEmpty(firstTagText("rating", in: movieBody)).flatMap { Double($0) }
        if rating == nil, let ratingsBlock = extractFirstElementBody(named: "ratings", in: movieBody) {
            rating = nonEmpty(firstTagText("value", in: ratingsBlock)).flatMap { Double($0) }
        }

        let studio = nonEmpty(firstTagText("studio", in: movieBody))
        let publisher = nonEmpty(firstTagText("publisher", in: movieBody))
        let director = nonEmpty(firstTagText("director", in: movieBody))

        var series: String?
        if let setBody = extractFirstElementBody(named: "set", in: movieBody) {
            series = nonEmpty(firstTagText("name", in: setBody)) ?? nonEmpty(cleanText(setBody))
        }

        let actorBlocks = extractAllElements(named: "actor", in: movieBody)
        var actors: [String] = []
        for block in actorBlocks {
            if let actorName = nonEmpty(firstTagText("name", in: block)) ?? nonEmpty(cleanText(block)),
               !actors.contains(actorName) {
                actors.append(actorName)
            }
        }

        var genres: [String] = []
        for raw in extractAllElements(named: "genre", in: movieBody) {
            if let g = nonEmpty(cleanText(raw)), !genres.contains(g) {
                genres.append(g)
            }
        }

        var tags: [String] = []
        for raw in extractAllElements(named: "tag", in: movieBody) {
            if let t = nonEmpty(cleanText(raw)), !tags.contains(t) {
                tags.append(t)
            }
        }

        return MovieMetadata(
            code: code,
            title: title,
            originalTitle: originalTitle,
            plot: plot,
            releaseDate: releaseDate,
            year: year,
            runtimeMinutes: runtimeMinutes,
            rating: rating,
            studio: studio,
            publisher: publisher,
            director: director,
            series: series,
            actors: actors,
            genres: genres,
            tags: tags
        )
    }

    // MARK: - 文本与 XML 辅助

    private static func decodeXMLString(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
    }

    private static func removeXMLComments(in xml: String) -> String {
        var result = xml
        while let start = result.range(of: "<!--"),
              let end = result.range(of: "-->", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    private static func firstTagText(_ tag: String, in xml: String) -> String? {
        guard let body = extractFirstElementBody(named: tag, in: xml) else { return nil }
        return cleanText(body)
    }

    private static func extractFirstElementBody(named tag: String, in xml: String) -> String? {
        extractAllElements(named: tag, in: xml, limit: 1).first
    }

    private static func extractAllElements(named tag: String, in xml: String, limit: Int = Int.max) -> [String] {
        var results: [String] = []
        var searchStart = xml.startIndex
        let lowerTag = tag.lowercased()

        while results.count < limit, searchStart < xml.endIndex {
            guard let openStart = xml.range(of: "<\(lowerTag)", options: .caseInsensitive, range: searchStart..<xml.endIndex) else {
                break
            }
            let afterName = openStart.upperBound
            if afterName < xml.endIndex {
                let nextChar = xml[afterName]
                guard nextChar == ">" || nextChar == "/" || nextChar.isWhitespace else {
                    searchStart = afterName
                    continue
                }
            }
            guard let openClose = findTagCloseSkippingCDATAAndQuotes(from: afterName, in: xml) else {
                break
            }
            if openClose > afterName {
                let prevIndex = xml.index(before: openClose)
                if xml[prevIndex] == "/" {
                    results.append("")
                    searchStart = xml.index(after: openClose)
                    continue
                }
            }
            let contentStart = xml.index(after: openClose)
            guard let closeStart = findClosingTag(named: lowerTag, from: contentStart, in: xml),
                  let closeEnd = xml[closeStart...].firstIndex(of: ">") else {
                break
            }
            results.append(String(xml[contentStart..<closeStart]))
            searchStart = xml.index(after: closeEnd)
        }

        return results
    }

    private static func findTagCloseSkippingCDATAAndQuotes(from start: String.Index, in xml: String) -> String.Index? {
        var idx = start
        var quote: Character?
        while idx < xml.endIndex {
            let ch = xml[idx]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return idx
            }
            idx = xml.index(after: idx)
        }
        return nil
    }

    private static func findClosingTag(named lowerTag: String, from start: String.Index, in xml: String) -> String.Index? {
        var cursor = start
        let needle = "</\(lowerTag)"
        while cursor < xml.endIndex {
            if xml[cursor...].hasPrefix("<![CDATA[") {
                if let cdataEnd = xml.range(of: "]]>", range: cursor..<xml.endIndex) {
                    cursor = cdataEnd.upperBound
                    continue
                }
                return nil
            }
            if let closeRange = xml.range(of: needle, options: .caseInsensitive, range: cursor..<xml.endIndex) {
                let after = closeRange.upperBound
                if after < xml.endIndex, xml[after] == ">" || xml[after].isWhitespace {
                    return closeRange.lowerBound
                }
                cursor = after
                continue
            }
            return nil
        }
        return nil
    }

    private static func cleanText(_ raw: String) -> String {
        var working = raw
        if let first = working.range(of: "<![CDATA["),
           let last = working.range(of: "]]>", range: first.upperBound..<working.endIndex) {
            working = String(working[first.upperBound..<last.lowerBound])
        } else {
            // Strip any accidental nested inline tags if not pure text
            working = working.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        return unescapeEntities(working).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescapeEntities(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"),
               s.distance(from: i, to: semi) <= 12 {
                let entity = String(s[s.index(after: i)..<semi])
                if let replacement = decodeEntity(entity) {
                    out.append(contentsOf: replacement)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static func decodeEntity(_ entity: String) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                if let cp = UInt32(entity.dropFirst(2), radix: 16), let scalar = UnicodeScalar(cp) {
                    return String(scalar)
                }
            } else if entity.hasPrefix("#") {
                if let cp = UInt32(entity.dropFirst(), radix: 10), let scalar = UnicodeScalar(cp) {
                    return String(scalar)
                }
            }
            return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
