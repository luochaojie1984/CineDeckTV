#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking
#else
import Foundation
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// WebDAV 实现：PROPFIND 列目录、Range 随机读、301/302 直链缓存。
public actor WebDAVProvider: VFSProvider {
    public nonisolated var kind: MediaSourceKind { .webdav }

    private let config: MediaSourceConfig
    private let password: String?
    private let session: URLSession
    /// 302 直链缓存：原始路径 -> 重定向后的真实 URL，避免每次请求都走一跳。
    private var redirectCache: [String: URL] = [:]

    public init(config: MediaSourceConfig, password: String?) {
        self.config = config
        self.password = password
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: cfg)
    }

    public func connect() async throws {
        guard let url = config.baseURL else {
            throw VFSError.transport("WebDAV 地址无效：\(config.host)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        applyAuth(&request)
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw VFSError.transport("无 HTTP 响应")
            }
            switch http.statusCode {
            case 200, 207, 301, 302, 405: return
            case 401: throw VFSError.authenticationFailed(config.host)
            case 404: throw VFSError.notFound(config.sharePath)
            default: throw VFSError.transport("HTTP \(http.statusCode)")
            }
        } catch let error as VFSError {
            throw error
        } catch {
            throw VFSError.transport(error.localizedDescription)
        }
    }

    public func disconnect() async {
        session.invalidateAndCancel()
        redirectCache.removeAll()
    }

    public func list(path: String) async throws -> [VFSEntry] {
        guard let url = url(for: path) else { throw VFSError.notFound(path) }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VFSError.transport("无 HTTP 响应") }
        switch http.statusCode {
        case 207, 200: break
        case 401: throw VFSError.authenticationFailed(path)
        case 404: throw VFSError.notFound(path)
        default: throw VFSError.transport("PROPFIND HTTP \(http.statusCode)")
        }
        let parser = WebDAVMultiStatusParser()
        let entries = parser.parse(data)
        let base = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return entries
            .filter { entry in
                let trimmed = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return trimmed != base && !trimmed.isEmpty
            }
            .map { entry in
                let relative = entry.hrefPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let name = (relative as NSString).lastPathComponent
                let full = relative.isEmpty ? name : relative
                return VFSEntry(
                    path: full,
                    name: name.removingPercentEncoding ?? name,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    modifiedAt: entry.modifiedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public func readHead(path: String, length: Int) async throws -> Data {
        try await read(path: path, offset: 0, length: length)
    }

    public func readTail(path: String, length: Int) async throws -> Data {
        let total = try await size(path: path)
        let start = max(0, total - Int64(length))
        return try await read(path: path, offset: start, length: Int(total - start))
    }

    public func read(path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        guard var url = url(for: path) else { throw VFSError.notFound(path) }
        if let cached = redirectCache[path] { url = cached }
        var attempt = 0
        while attempt < 2 {
            attempt += 1
            var request = URLRequest(url: url)
            let end = offset + Int64(length) - 1
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            applyAuth(&request)
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw VFSError.transport("无 HTTP 响应") }
                switch http.statusCode {
                case 206, 200: return data
                case 301, 302, 307, 308:
                    // 直链跳转：缓存真实地址后重试一次。
                    if let location = http.value(forHTTPHeaderField: "Location"),
                       let real = URL(string: location, relativeTo: url)?.absoluteURL {
                        redirectCache[path] = real
                        url = real
                        continue
                    }
                    throw VFSError.transport("重定向缺少 Location")
                case 401: throw VFSError.authenticationFailed(path)
                case 404: throw VFSError.notFound(path)
                case 416: return Data()
                default: throw VFSError.transport("Range HTTP \(http.statusCode)")
                }
            } catch let error as VFSError {
                throw error
            } catch {
                throw VFSError.transport(error.localizedDescription)
            }
        }
        throw VFSError.transport("重定向循环")
    }

    public func size(path: String) async throws -> Int64 {
        guard let url = url(for: path) else { throw VFSError.notFound(path) }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        applyAuth(&request)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VFSError.transport("无 HTTP 响应") }
        if http.statusCode == 401 { throw VFSError.authenticationFailed(path) }
        if let value = http.value(forHTTPHeaderField: "Content-Length"), let size = Int64(value) {
            return size
        }
        throw VFSError.transport("服务器未返回 Content-Length")
    }

    public func makeChunkSource(path: String) async throws -> any StreamChunkSource {
        WebDAVChunkSource(provider: self, path: path)
    }

    private func url(for path: String) -> URL? {
        guard var comps = URLComponents(url: config.baseURL ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false) else {
            return config.baseURL
        }
        let base = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joined = [base, relative].filter { !$0.isEmpty }.joined(separator: "/")
        comps.path = "/" + joined
        if joined.isEmpty { comps.path = "/" }
        comps.percentEncodedPath = comps.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? comps.path
        return comps.url
    }

    private func applyAuth(_ request: inout URLRequest) {
        if let password, !config.username.isEmpty, let data = "\(config.username):\(password)".data(using: .utf8) {
            request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
    }

    func readRaw(path: String, offset: Int64, length: Int) async throws -> Data {
        try await read(path: path, offset: offset, length: length)
    }

    func totalSize(path: String) async throws -> Int64 {
        try await size(path: path)
    }
}

private struct WebDAVChunkSource: StreamChunkSource {
    let provider: WebDAVProvider
    let path: String

    func contentLength() async throws -> Int64 {
        try await provider.totalSize(path: path)
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        try await provider.readRaw(path: path, offset: offset, length: length)
    }
}

/// Depth:1 multistatus 解析。
final class WebDAVMultiStatusParser: NSObject {
    struct Entry {
        var hrefPath: String = ""
        var path: String = ""
        var isDirectory = false
        var size: Int64 = 0
        var modifiedAt: Date?
    }

    private var entries: [Entry] = []
    private var current: Entry?
    private var currentElement = ""
    private var buffer = ""

    func parse(_ data: Data) -> [Entry] {
        entries = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    /// HTTP-date 解析（每次新建，避免静态非 Sendable 实例）。
    static func parseHTTPDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.timeZone = TimeZone(identifier: "GMT")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return rfc.date(from: value)
    }
}

extension WebDAVMultiStatusParser: XMLParserDelegate {
    private func localName(_ element: String) -> String {
        (element.split(separator: ":").last.map(String.init) ?? element).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = localName(elementName)
        buffer = ""
        if currentElement == "response" { current = Entry() }
        if currentElement == "collection", var entry = current {
            entry.isDirectory = true
            current = entry
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href":
            current?.hrefPath = value
            current?.path = value
        case "getcontentlength":
            current?.size = Int64(value) ?? 0
        case "getlastmodified":
            current?.modifiedAt = Self.parseHTTPDate(value)
        case "response":
            if let entry = current, !entry.hrefPath.isEmpty { entries.append(entry) }
            current = nil
        default:
            break
        }
        buffer = ""
    }
}
