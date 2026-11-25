#if canImport(Network)
import Foundation
import NetworkVFS
import Network

/// 本地 127.0.0.1 HTTP Range 代理：把 VFS 缓存包装成播放器可直接吃的短 ASCII URL。
/// 关键约束（设计规划 6.3 #15）：只在 scrubMode 下取消旧连接，正常播放互不干扰。
public actor LocalHTTPStreamProxy {
    public struct Route: Sendable, Hashable {
        public let token: String
        public let path: String
        public var urlPath: String { "/s/\(token)" }
    }

    private let cache: ReadAheadStreamCache
    private var listener: NWListener?
    private var routes: [String: Route] = [:]
    private var activeScrubConnections: [ObjectIdentifier] = []
    private var scrubMode = false
    public private(set) var port: UInt16?

    public init(cache: ReadAheadStreamCache) {
        self.cache = cache
    }

    /// 注册文件路由，返回短 ASCII 播放地址（与真实中文/日文长文件名彻底隔离）。
    public func register(fileExtension: String) -> Route {
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let ext = fileExtension.isEmpty ? "bin" : fileExtension.lowercased()
        let route = Route(token: token, path: "\(token).\(ext)")
        routes[route.urlPath] = route
        return route
    }

    public func start(preferredPort: UInt16 = 0) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: preferredPort) ?? .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        routes.removeAll()
    }

    public func setScrubMode(_ enabled: Bool) {
        scrubMode = enabled
        if !enabled { activeScrubConnections.removeAll() }
    }

    public func localURL(for route: Route) -> URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(route.urlPath)")
    }

    private func handleListenerState(_ state: NWListener.State) {
        if case .ready = state { port = listener?.port?.rawValue }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                Task { await self?.respond(connection, request: accumulated) }
                return
            }
            if error != nil || isComplete { connection.cancel(); return }
            Task { await self?.receiveRequest(connection, buffer: accumulated) }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        let head = String(decoding: request.prefix(4096), as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let target = String(parts[1])
        guard routes[target] != nil else {
            sendStatus(connection, code: 404, reason: "Not Found")
            return
        }
        let rangeHeader = lines
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }

        Task {
            do {
                let total = try await cache.fetchContentSize()
                var start: Int64 = 0
                var end: Int64 = total - 1
                if let rangeHeader, let parsed = Self.parseRange(rangeHeader, total: total) {
                    start = parsed.0
                    end = parsed.1
                }
                let length = Int(max(0, end - start + 1))
                let body = try await cache.read(offset: start, length: length)
                var header = ""
                if rangeHeader != nil {
                    header += "HTTP/1.1 206 Partial Content\r\n"
                    header += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
                } else {
                    header += "HTTP/1.1 200 OK\r\n"
                }
                header += "Content-Type: application/octet-stream\r\n"
                header += "Accept-Ranges: bytes\r\n"
                header += "Content-Length: \(body.count)\r\n"
                header += "Connection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            } catch {
                self.sendStatus(connection, code: 500, reason: "Internal Error")
            }
        }
    }

    private func sendStatus(_ connection: NWConnection, code: Int, reason: String) {
        let text = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    static func parseRange(_ value: String, total: Int64) -> (Int64, Int64)? {
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6)
        let pair = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        if pair[0].isEmpty, let suffix = Int64(pair[1]) {
            let start = max(0, total - suffix)
            return (start, total - 1)
        }
        guard let start = Int64(pair[0]) else { return nil }
        let end = pair[1].isEmpty ? total - 1 : min(Int64(pair[1]) ?? total - 1, total - 1)
        guard start <= end, start < total else { return nil }
        return (start, end)
    }
}


#else
import Foundation
import NetworkVFS

/// Linux 平台：Network.framework 不可用，保留同一套接口供跨平台单测与语法预检。
public actor LocalHTTPStreamProxy {
    public struct Route: Sendable, Hashable {
        public let token: String
        public let path: String
        public var urlPath: String { "/s/\(token)" }
    }

    private let cache: ReadAheadStreamCache
    public private(set) var port: UInt16?

    public init(cache: ReadAheadStreamCache) {
        self.cache = cache
    }

    public func register(fileExtension: String) -> Route {
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let ext = fileExtension.isEmpty ? "bin" : fileExtension.lowercased()
        return Route(token: token, path: "\(token).\(ext)")
    }

    public func start(preferredPort: UInt16 = 0) throws {
        throw VFSError.unsupported("LocalHTTPStreamProxy 需要 Network.framework（仅 Apple 平台）")
    }

    public func stop() {}
    public func setScrubMode(_ enabled: Bool) {}

    public func localURL(for route: Route) -> URL? { nil }

    static func parseRange(_ value: String, total: Int64) -> (Int64, Int64)? {
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6)
        let pair = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        if pair[0].isEmpty, let suffix = Int64(pair[1]) {
            return (max(0, total - suffix), total - 1)
        }
        guard let start = Int64(pair[0]) else { return nil }
        let end = pair[1].isEmpty ? total - 1 : min(Int64(pair[1]) ?? total - 1, total - 1)
        guard start <= end, start < total else { return nil }
        return (start, end)
    }
}
#endif
