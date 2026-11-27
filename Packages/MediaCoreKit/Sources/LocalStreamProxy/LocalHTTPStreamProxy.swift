import Foundation
import NetworkVFS
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 本地 127.0.0.1 高吞吐流式 HTTP/1.1 Range 代理：把 VFS 缓存包装成播放器可直接吃的短 ASCII URL。
/// 关键优化（对齐 AuraTV 零阻塞同步锁设计）：
/// 1. 使用轻量 NSLock 替代 Swift actor，彻底消除每个 Range 请求 / 任务注销的 actor 跳数与排队开销。
/// 2. start() / ensureRunning() 同步完成 socket/bind/listen 并填充 port。
/// 3. 常规播放 256 KB 低延迟切片 + 512 KB SO_SNDBUF + TCP_NODELAY，快进模式 64 KB 切片 + 取消陈旧快进请求。
public final class LocalHTTPStreamProxy: @unchecked Sendable {
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
    private let lock = NSLock()
    private var server: POSIXLoopbackServer?
    private var routes: [String: Route] = [:]
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeScrubTasks: [UUID: Task<Void, Never>] = [:]
    private var scrubMode = false
    private var _port: UInt16?

    public var port: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return _port
    }

    public init(cache: ReadAheadStreamCache) {
        self.cache = cache
    }

    deinit {
        stop()
    }

    /// 注册文件路由，返回短 ASCII 播放地址（保留扩展名，与真实中文/日文长文件名彻底隔离）。
    public func register(fileExtension: String) -> Route {
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let ext = fileExtension.isEmpty ? "bin" : fileExtension.lowercased()
        let route = Route(token: token, path: "\(token).\(ext)")
        lock.lock()
        routes[route.urlPath] = route
        lock.unlock()
        return route
    }

    public func start(preferredPort: UInt16 = 0) throws {
        try ensureRunning(forceRestart: false, preferredPort: preferredPort)
    }

    /// 确保本地回环监听处于可用状态；若 tvOS 后台挂起回收了 socket，自动重建监听端口并保留已注册路由。
    public func ensureRunning(forceRestart: Bool = false, preferredPort: UInt16 = 0) throws {
        lock.lock()
        let currentServer = server
        let alive = !forceRestart && (currentServer?.isAlive() == true)
        if alive, let currentServer {
            _port = currentServer.port
            lock.unlock()
            return
        }
        server = nil
        _port = nil
        lock.unlock()

        currentServer?.stop()

        let srv = try POSIXLoopbackServer(preferredPort: preferredPort) { [weak self] fd in
            guard let self else {
                POSIXLoopbackServer.closeFD(fd)
                return
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    POSIXLoopbackServer.closeFD(fd)
                    return
                }
                await self.serveDetachedClient(fd)
            }
        }

        lock.lock()
        server = srv
        _port = srv.port
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let tasks = Array(activeTasks.values)
        let scrubTasks = Array(activeScrubTasks.values)
        activeTasks.removeAll()
        activeScrubTasks.removeAll()
        let oldServer = server
        server = nil
        _port = nil
        routes.removeAll()
        scrubMode = false
        lock.unlock()

        for task in tasks { task.cancel() }
        for task in scrubTasks { task.cancel() }
        oldServer?.stop()
    }

    public func setScrubMode(_ enabled: Bool) {
        var tasksToCancel: [Task<Void, Never>] = []
        lock.lock()
        scrubMode = enabled
        if !enabled {
            tasksToCancel = Array(activeScrubTasks.values)
            activeScrubTasks.removeAll()
        }
        lock.unlock()

        for task in tasksToCancel { task.cancel() }
    }

    public func localURL(for route: Route) -> URL? {
        guard let currentPort = port else { return nil }
        return URL(string: "http://127.0.0.1:\(currentPort)\(route.urlPath)")
    }

    /// 解析 HTTP Range 请求头，兼容 closed (`bytes=100-199`), open (`bytes=900-`), suffix (`bytes=-100`)。
    public static func parseRange(_ value: String, total: Int64) -> (Int64, Int64)? {
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

    private func lookupRouteAndPrepare(target: String, method: String) -> (route: Route, isScrub: Bool, cache: ReadAheadStreamCache)? {
        var staleScrubTasks: [Task<Void, Never>] = []
        lock.lock()
        guard let route = routes[target] else {
            lock.unlock()
            return nil
        }
        let isScrub = scrubMode
        if isScrub && method == "GET" {
            staleScrubTasks = Array(activeScrubTasks.values)
            activeScrubTasks.removeAll()
        }
        let cacheRef = cache
        lock.unlock()

        for existing in staleScrubTasks { existing.cancel() }
        return (route, isScrub, cacheRef)
    }

    private func registerTask(_ task: Task<Void, Never>, id: UUID, isScrubGet: Bool) {
        lock.lock()
        activeTasks[id] = task
        if isScrubGet {
            activeScrubTasks[id] = task
        }
        lock.unlock()
    }

    private func unregisterTask(id: UUID) {
        lock.lock()
        activeTasks.removeValue(forKey: id)
        activeScrubTasks.removeValue(forKey: id)
        lock.unlock()
    }

    private func serveDetachedClient(_ fd: Int32) async {
        guard let requestData = Self.readHTTPHeader(fd: fd) else {
            POSIXLoopbackServer.closeFD(fd)
            return
        }

        let head = String(decoding: requestData, as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            Self.sendSimpleStatusSync(fd: fd, code: 400, reason: "Bad Request")
            POSIXLoopbackServer.closeFD(fd)
            return
        }

        let method = String(parts[0]).uppercased()
        var target = String(parts[1])
        if let qIdx = target.firstIndex(of: "?") {
            target = String(target[..<qIdx])
        }

        guard method == "GET" || method == "HEAD" else {
            Self.sendSimpleStatusSync(fd: fd, code: 405, reason: "Method Not Allowed")
            POSIXLoopbackServer.closeFD(fd)
            return
        }

        guard let resolved = lookupRouteAndPrepare(target: target, method: method) else {
            Self.sendSimpleStatusSync(fd: fd, code: 404, reason: "Not Found")
            POSIXLoopbackServer.closeFD(fd)
            return
        }

        let rangeHeader = lines
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }

        let taskID = UUID()
        let isScrub = resolved.isScrub
        let cacheRef = resolved.cache
        let mime = Self.mimeType(forPath: resolved.route.path)

        let streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                POSIXLoopbackServer.closeFD(fd)
                self?.unregisterTask(id: taskID)
            }
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

        registerTask(streamTask, id: taskID, isScrubGet: isScrub && method == "GET")
    }

    private static func mimeType(forPath path: String) -> String {
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

    private static func readHTTPHeader(fd: Int32) -> Data? {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
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

    private static func streamRange(
        fd: Int32,
        cache: ReadAheadStreamCache,
        start: Int64,
        end: Int64,
        sliceSize: Int,
        lowWaterBuffer: Bool
    ) async throws {
        var sndBuf: Int32 = lowWaterBuffer ? 65536 : (512 * 1024)
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
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

    private static func sendHeader(fd: Int32, statusLine: String, headers: [String: String]) {
        var text = statusLine + "\r\n"
        for (k, v) in headers {
            text += "\(k): \(v)\r\n"
        }
        text += "\r\n"
        _ = sendAll(fd: fd, data: Data(text.utf8))
    }

    private static func sendSimpleStatusSync(fd: Int32, code: Int, reason: String) {
        let text = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = sendAll(fd: fd, data: Data(text.utf8))
    }

    private static func sendAll(fd: Int32, data: Data) -> Bool {
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
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                return Darwin.getsockname(fd, $0, &addrLen)
                #else
                return Glibc.getsockname(fd, $0, &addrLen)
                #endif
            }
        }
        guard nameRes == 0 else {
            let err = errno
            Self.closeFD(fd)
            throw LocalHTTPStreamProxy.ProxyError.bindFailed(err)
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        acceptQueue.async { [weak self] in
            self?.acceptLoop(onAccept: onAccept)
        }
    }

    deinit {
        stop()
    }

    func isAlive() -> Bool {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        if isStopped { return false }
        var errVal: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        let rc = getsockopt(listenFD, SOL_SOCKET, SO_ERROR, &errVal, &len)
        return rc == 0 && errVal == 0
    }

    func stop() {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        stateLock.unlock()
        #if canImport(Darwin)
        _ = Darwin.shutdown(listenFD, SHUT_RDWR)
        #else
        _ = Glibc.shutdown(listenFD, Int32(SHUT_RDWR))
        #endif
        Self.closeFD(listenFD)
    }

    private func acceptLoop(onAccept: @escaping @Sendable (Int32) -> Void) {
        while true {
            stateLock.lock()
            let shouldStop = stopped
            stateLock.unlock()
            if shouldStop { break }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    #if canImport(Darwin)
                    return Darwin.accept(listenFD, $0, &clientLen)
                    #else
                    return Glibc.accept(listenFD, $0, &clientLen)
                    #endif
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            #if canImport(Darwin)
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var noDelay: Int32 = 1
            setsockopt(clientFD, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            onAccept(clientFD)
        }
    }

    static func closeFD(_ fd: Int32) {
        guard fd >= 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }
}
