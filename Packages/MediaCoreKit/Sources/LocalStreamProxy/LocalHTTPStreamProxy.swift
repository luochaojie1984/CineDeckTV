import Foundation
import NetworkVFS
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 本地 127.0.0.1 流式 HTTP/1.1 Range 代理：把 VFS 缓存包装成播放器可直接吃的短 ASCII URL。
/// 关键约束：
/// 1. start() 同步完成 socket/bind/listen 并填充 port，彻底消除异步竞态导致的"本地代理未就绪"。
/// 2. 支持 HEAD、GET、Range (206 / 416) 与分片流式写回（常规 256 KB / 快进 64 KB + SO_SNDBUF=65536），绝不一次性分配数 GB 内存。
/// 3. 仅在 scrubMode == true 时取消旧未完成快进请求；正常并发 Range 互不干扰。
public actor LocalHTTPStreamProxy {
    public struct Route: Sendable, Hashable {
        public let token: String
        public let path: String
        public var urlPath: String { "/s/\(path)" }
    }

    public enum ProxyError: Error, LocalizedError, Sendable {
        case socketCreationFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .socketCreationFailed(let err): return "创建本地监听套接字失败 (errno \(err))"
            case .bindFailed(let err): return "绑定 127.0.0.1 端口失败 (errno \(err))"
            case .listenFailed(let err): return "启动本地监听失败 (errno \(err))"
            }
        }
    }

    private let cache: ReadAheadStreamCache
    private var server: POSIXLoopbackServer?
    private var routes: [String: Route] = [:]
    private var activeScrubTasks: [UUID: Task<Void, Never>] = [:]
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
        try ensureRunning(forceRestart: false, preferredPort: preferredPort)
    }

    /// 确保本地回环监听处于可用状态；若 tvOS 后台挂起回收了 socket，自动重建监听端口并保留已注册路由。
    public func ensureRunning(forceRestart: Bool = false, preferredPort: UInt16 = 0) throws {
        if !forceRestart, let server, server.isAlive() {
            self.port = server.port
            return
        }
        server?.stop()
        server = nil
        port = nil

        let srv = try POSIXLoopbackServer(preferredPort: preferredPort) { [weak self] fd in
            guard let self else {
                POSIXLoopbackServer.closeFD(fd)
                return
            }
            Task { await self.handleAcceptedClient(fd) }
        }
        self.server = srv
        self.port = srv.port
    }

    public func stop() {
        for task in activeScrubTasks.values { task.cancel() }
        activeScrubTasks.removeAll()
        server?.stop()
        server = nil
        port = nil
        routes.removeAll()
    }

    public func setScrubMode(_ enabled: Bool) {
        scrubMode = enabled
        if !enabled {
            activeScrubTasks.removeAll()
        }
    }

    public func localURL(for route: Route) -> URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(route.urlPath)")
    }

    /// 解析 HTTP Range 请求头，兼容 closed (`bytes=100-199`), open (`bytes=900-`), suffix (`bytes=-100`)。
    public nonisolated static func parseRange(_ value: String, total: Int64) -> (Int64, Int64)? {
        guard total > 0, value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6).split(separator: ",", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
        let pair = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        if pair[0].isEmpty, let suffix = Int64(pair[1]), suffix > 0 {
            return (max(0, total - suffix), total - 1)
        }
        guard let start = Int64(pair[0]), start >= 0 else { return nil }
        let end = pair[1].isEmpty ? (total - 1) : min(Int64(pair[1]) ?? (total - 1), total - 1)
        guard start <= end, start < total else { return nil }
        return (start, end)
    }

    private func handleAcceptedClient(_ fd: Int32) async {
        // 读取 HTTP 请求头（短超时防阻塞）
        guard let requestData = await Task.detached(priority: .userInitiated, operation: {
            Self.readHTTPHeader(fd: fd)
        }).value else {
            POSIXLoopbackServer.closeFD(fd)
            return
        }

        let head = String(decoding: requestData, as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            await Self.sendSimpleStatus(fd: fd, code: 400, reason: "Bad Request")
            POSIXLoopbackServer.closeFD(fd)
            return
        }

        let method = String(parts[0]).uppercased()
        var target = String(parts[1])
        if let qIdx = target.firstIndex(of: "?") {
            target = String(target[..<qIdx])
        }

        guard let route = routes[target] else {
            await Self.sendSimpleStatus(fd: fd, code: 404, reason: "Not Found")
            POSIXLoopbackServer.closeFD(fd)
            return
        }

        guard method == "GET" || method == "HEAD" else {
            await Self.sendSimpleStatus(fd: fd, code: 405, reason: "Method Not Allowed")
            POSIXLoopbackServer.closeFD(fd)
            return
        }

        let rangeHeader = lines
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }

        if scrubMode && method == "GET" {
            for existing in activeScrubTasks.values { existing.cancel() }
            activeScrubTasks.removeAll()
        }

        let taskID = UUID()
        let isScrub = scrubMode
        let cacheRef = cache
        let mime = Self.mimeType(forPath: route.path)

        let task = Task(priority: .userInitiated) {
            defer { POSIXLoopbackServer.closeFD(fd) }
            do {
                let total = try await cacheRef.fetchContentSize()
                if let rangeHeader {
                    guard let parsed = Self.parseRange(rangeHeader, total: total) else {
                        Self.sendHeader(
                            fd: fd,
                            statusLine: "HTTP/1.1 416 Range Not Satisfiable",
                            headers: [
                                "Content-Range": "bytes */\(total)",
                                "Content-Length": "0",
                                "Connection": "close"
                            ]
                        )
                        return
                    }
                    let start = parsed.0
                    let end = parsed.1
                    let responseLen = end - start + 1
                    Self.sendHeader(
                        fd: fd,
                        statusLine: "HTTP/1.1 206 Partial Content",
                        headers: [
                            "Content-Type": mime,
                            "Accept-Ranges": "bytes",
                            "Content-Range": "bytes \(start)-\(end)/\(total)",
                            "Content-Length": "\(responseLen)",
                            "Connection": "close"
                        ]
                    )
                    if method == "HEAD" { return }
                    try await Self.streamRange(
                        fd: fd,
                        cache: cacheRef,
                        start: start,
                        end: end,
                        sliceSize: isScrub ? 64 * 1024 : 256 * 1024,
                        lowWaterBuffer: isScrub
                    )
                } else {
                    Self.sendHeader(
                        fd: fd,
                        statusLine: "HTTP/1.1 200 OK",
                        headers: [
                            "Content-Type": mime,
                            "Accept-Ranges": "bytes",
                            "Content-Length": "\(total)",
                            "Connection": "close"
                        ]
                    )
                    if method == "HEAD" || total <= 0 { return }
                    try await Self.streamRange(
                        fd: fd,
                        cache: cacheRef,
                        start: 0,
                        end: total - 1,
                        sliceSize: isScrub ? 64 * 1024 : 256 * 1024,
                        lowWaterBuffer: isScrub
                    )
                }
            } catch {
                if !Task.isCancelled {
                    Self.sendSimpleStatusSync(fd: fd, code: 500, reason: "Internal Server Error")
                }
            }
        }

        if isScrub && method == "GET" {
            activeScrubTasks[taskID] = task
        }
        await task.value
        if isScrub && method == "GET" {
            activeScrubTasks.removeValue(forKey: taskID)
        }
    }

    private nonisolated static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "ts", "m2ts": return "video/mp2t"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "flv": return "video/x-flv"
        default: return "application/octet-stream"
        }
    }

    private nonisolated static func readHTTPHeader(fd: Int32) -> Data? {
        #if os(Linux)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        #else
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        #endif
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        while buffer.count < 32 * 1024 {
            let n = chunk.withUnsafeMutableBytes { ptr -> Int in
                #if canImport(Darwin)
                return Darwin.recv(fd, ptr.baseAddress, ptr.count, 0)
                #else
                return Glibc.recv(fd, ptr.baseAddress, ptr.count, 0)
                #endif
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if let range = buffer.range(of: separator) {
                return Data(buffer[..<range.upperBound])
            }
        }
        return nil
    }

    private nonisolated static func streamRange(
        fd: Int32,
        cache: ReadAheadStreamCache,
        start: Int64,
        end: Int64,
        sliceSize: Int,
        lowWaterBuffer: Bool
    ) async throws {
        if lowWaterBuffer {
            var sndBuf: Int32 = 65536
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
        }
        var cursor = start
        while cursor <= end {
            if Task.isCancelled { return }
            let want = Int(min(Int64(sliceSize), end - cursor + 1))
            let data = try await cache.read(offset: cursor, length: want)
            if data.isEmpty { break }
            if Task.isCancelled { return }
            let ok = sendAll(fd: fd, data: data)
            if !ok { break }
            cursor += Int64(data.count)
        }
    }

    private nonisolated static func sendHeader(fd: Int32, statusLine: String, headers: [String: String]) {
        var text = statusLine + "\r\n"
        for (k, v) in headers {
            text += "\(k): \(v)\r\n"
        }
        text += "\r\n"
        _ = sendAll(fd: fd, data: Data(text.utf8))
    }

    private nonisolated static func sendSimpleStatus(fd: Int32, code: Int, reason: String) async {
        sendSimpleStatusSync(fd: fd, code: code, reason: reason)
    }

    private nonisolated static func sendSimpleStatusSync(fd: Int32, code: Int, reason: String) {
        let text = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = sendAll(fd: fd, data: Data(text.utf8))
    }

    private nonisolated static func sendAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                if Task.isCancelled { return false }
                let remaining = data.count - sent
                let ptr = base.advanced(by: sent)
                #if canImport(Darwin)
                let written = Darwin.send(fd, ptr, remaining, 0)
                #else
                let written = Glibc.send(fd, ptr, remaining, Int32(MSG_NOSIGNAL))
                #endif
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                sent += written
            }
            return true
        }
    }
}

/// 跨平台 POSIX 回环 TCP 监听封装：在 init 内同步完成 bind/listen 并取得非 nil 端口。
private final class POSIXLoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let stateLock = NSLock()
    private var stopped = false
    private let acceptQueue = DispatchQueue(label: "cinedeck.proxy.accept", qos: .userInitiated)

    init(preferredPort: UInt16, onAccept: @escaping @Sendable (Int32) -> Void) throws {
        #if canImport(Darwin)
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else {
            throw LocalHTTPStreamProxy.ProxyError.socketCreationFailed(errno)
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferredPort.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian // 127.0.0.1

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                return Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                return Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Self.closeFD(fd)
            throw LocalHTTPStreamProxy.ProxyError.bindFailed(err)
        }

        #if canImport(Darwin)
        let listenResult = Darwin.listen(fd, 64)
        #else
        let listenResult = Glibc.listen(fd, 64)
        #endif
        guard listenResult == 0 else {
            let err = errno
            Self.closeFD(fd)
            throw LocalHTTPStreamProxy.ProxyError.listenFailed(err)
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.listenFD = fd

        acceptQueue.async { [weak self] in
            while let self, !self.isStopped {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        #if canImport(Darwin)
                        return Darwin.accept(fd, $0, &clientLen)
                        #else
                        return Glibc.accept(fd, $0, &clientLen)
                        #endif
                    }
                }
                if clientFD < 0 {
                    let err = errno
                    if self.isStopped { break }
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        usleep(10_000)
                        continue
                    }
                    var shouldClose = false
                    self.stateLock.lock()
                    if !self.stopped {
                        self.stopped = true
                        shouldClose = true
                    }
                    self.stateLock.unlock()
                    if shouldClose {
                        Self.closeFD(fd)
                    }
                    break
                }
                #if canImport(Darwin)
                var yes: Int32 = 1
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                #endif
                onAccept(clientFD)
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    func isAlive() -> Bool {
        guard !isStopped, listenFD >= 0, port > 0 else { return false }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &len)
            }
        }
        guard nameRes == 0, UInt16(bigEndian: boundAddr.sin_port) == port else {
            return false
        }

        #if canImport(Darwin)
        let probeFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
        let probeFD = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard probeFD >= 0 else { return false }
        defer { Self.closeFD(probeFD) }

        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        setsockopt(probeFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let flags = fcntl(probeFD, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(probeFD, F_SETFL, flags | O_NONBLOCK)
        }

        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr.s_addr = UInt32(0x7F000001).bigEndian

        let connRes = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                return Darwin.connect(probeFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                return Glibc.connect(probeFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        if connRes == 0 {
            return true
        }
        guard errno == EINPROGRESS else {
            return false
        }

        var pfd = pollfd(fd: probeFD, events: Int16(POLLOUT), revents: 0)
        let pollRes = poll(&pfd, 1, 150)
        guard pollRes > 0 else {
            return false
        }

        var soErr: Int32 = 0
        var soErrLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(probeFD, SOL_SOCKET, SO_ERROR, &soErr, &soErrLen) == 0 else {
            return false
        }
        return soErr == 0
    }

    func stop() {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        stopped = true
        stateLock.unlock()
        #if canImport(Darwin)
        Darwin.shutdown(listenFD, SHUT_RDWR)
        #else
        Glibc.shutdown(listenFD, Int32(SHUT_RDWR))
        #endif
        Self.closeFD(listenFD)
    }

    static func closeFD(_ fd: Int32) {
        #if canImport(Darwin)
        Darwin.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }

    deinit {
        stop()
    }
}
