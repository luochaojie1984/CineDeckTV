import Foundation
import os
import Network
@preconcurrency import AMSMB2
import NetworkVFS

/// 生产级 SMB2/SMB3 提供者：
/// 1. 使用经过补丁的 AMSMB2（NTLMSSP domain=NULL 协商、真实 NTSTATUS 错误、SMB2RandomAccessFile 常驻预读句柄）。
/// 2. 支持 `DOMAIN\user` 与 `DOMAIN;user` 解析。
/// 3. 支持 3 种挂载路径：
///    - `sharePath == ""` 或 `"/"`：根目录自动调用 `listShares()` 枚举共享磁盘；进入 `/AV/...` 时动态切换共享与相对路径；
///    - `sharePath == "/AV"`：直连共享名 `AV`；
///    - `sharePath == "/AV/Movies"`：直连共享 `AV` 并将浏览根目录映射到 `/Movies`。
/// 4. TCP 预检在 `.waiting` 期间绝不提前失败，完整保留 tvOS 首次「本地网络」弹窗授权窗口。
public final class AMSMB2Provider: VFSProvider, @unchecked Sendable {
    public let kind: MediaSourceKind = .smb

    private struct ConnectionState {
        var manager: SMB2Manager?
        var connectedShare: String?
    }

    private let config: MediaSourceConfig
    private let password: String?
    private let stateLock = OSAllocatedUnfairLock<ConnectionState>(initialState: ConnectionState())

    public init(config: MediaSourceConfig, password: String?) {
        self.config = config
        self.password = password
    }

    private var configuredBaseParts: [String] {
        Self.nfc(config.sharePath)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private var configuredShareName: String? {
        configuredBaseParts.first
    }

    private var configuredShareSubpath: String {
        let parts = configuredBaseParts
        guard parts.count > 1 else { return "" }
        return "/" + parts.dropFirst().joined(separator: "/")
    }

    private static func nfc(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    private func currentManager() throws -> SMB2Manager {
        guard let mgr = stateLock.withLock({ $0.manager }) else {
            throw VFSError.notConnected
        }
        return mgr
    }

    public func connect() async throws {
        let parsed = Self.parseHostAndPort(rawHost: config.host, configuredPort: config.port > 0 ? config.port : nil)
        guard !parsed.networkHost.isEmpty else {
            throw VFSError.transport("服务器主机地址不能为空")
        }

        let effectivePort = parsed.effectivePort ?? 445
        try await preflightTCP(host: parsed.networkHost, port: effectivePort)

        let urlString = effectivePort == 445 ? "smb://\(parsed.urlHost)" : "smb://\(parsed.urlHost):\(effectivePort)"
        guard let url = URL(string: urlString) else {
            throw VFSError.transport("SMB 地址无效：\(urlString)")
        }

        let (domain, username) = Self.parseDomainAndUser(config.username)
        let credential: URLCredential?
        if config.enableAnonymous || username.isEmpty {
            credential = nil
        } else {
            credential = URLCredential(user: username, password: password ?? "", persistence: .forSession)
        }

        guard let newManager = SMB2Manager(url: url, domain: domain, credential: credential) else {
            throw VFSError.transport("无法初始化 SMB2 管理器：\(urlString)")
        }
        stateLock.withLock {
            $0.manager = newManager
            $0.connectedShare = nil
        }

        if let share = configuredShareName {
            try await ensureShareConnected(share, using: newManager)
        }
    }

    public func disconnect() async {
        let manager = stateLock.withLock { state -> SMB2Manager? in
            let current = state.manager
            state.manager = nil
            state.connectedShare = nil
            return current
        }
        try? await manager?.disconnectShare()
    }

    public func list(path: String) async throws -> [VFSEntry] {
        let manager = try currentManager()

        guard let resolved = resolveShareAndRelativePath(path) else {
            // 根目录：调用补丁后的 listShares() 枚举共享文件夹（过滤 IPC$ / ADMIN$ / C$ 等隐藏管理共享）
            let shares: [(name: String, comment: String)]
            do {
                shares = try await manager.listShares(enumerateHidden: false)
            } catch {
                throw Self.classifySMBError(error, target: config.host)
            }
            return shares
                .filter { !$0.name.hasSuffix("$") }
                .map { share in
                    let clean = Self.nfc(share.name)
                    return VFSEntry(
                        path: "/\(clean)",
                        name: clean,
                        isDirectory: true,
                        size: 0,
                        modifiedAt: nil
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        try await ensureShareConnected(resolved.share, using: manager)

        let items: [[URLResourceKey: Any]]
        do {
            items = try await manager.contentsOfDirectory(atPath: resolved.relativePath)
        } catch {
            // 局域网休眠或 SMB 会话闲置超时后自动重连一次
            try await ensureShareConnected(resolved.share, using: manager, forceReconnect: true)
            do {
                items = try await manager.contentsOfDirectory(atPath: resolved.relativePath)
            } catch {
                throw Self.classifySMBError(error, target: path)
            }
        }

        let cleanDir = Self.nfc(path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return items.compactMap { item -> VFSEntry? in
            guard let name = item[.nameKey] as? String, name != ".", name != ".." else { return nil }
            let cleanName = Self.nfc(name)
            let isDir = (item[.isDirectoryKey] as? Bool) ?? false
            let size = (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
            let modDate = item[.contentModificationDateKey] as? Date
            let fullPath: String
            if cleanDir.isEmpty {
                fullPath = configuredShareName != nil ? "/\(cleanName)" : "/\(resolved.share)/\(cleanName)"
            } else {
                fullPath = "/\(cleanDir)/\(cleanName)"
            }
            return VFSEntry(
                path: fullPath,
                name: cleanName,
                isDirectory: isDir,
                size: size,
                modifiedAt: modDate
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func read(path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0, offset >= 0 else { return Data() }
        let manager = try currentManager()
        guard let resolved = resolveShareAndRelativePath(path) else {
            throw VFSError.notFound(path)
        }
        try await ensureShareConnected(resolved.share, using: manager)
        do {
            return try await manager.contents(atPath: resolved.relativePath, range: offset..<(offset + Int64(length)))
        } catch {
            try await ensureShareConnected(resolved.share, using: manager, forceReconnect: true)
            do {
                return try await manager.contents(atPath: resolved.relativePath, range: offset..<(offset + Int64(length)))
            } catch {
                throw Self.classifySMBError(error, target: path)
            }
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

    public func size(path: String) async throws -> Int64 {
        let manager = try currentManager()
        guard let resolved = resolveShareAndRelativePath(path) else {
            throw VFSError.notFound(path)
        }
        try await ensureShareConnected(resolved.share, using: manager)
        do {
            let attrs = try await manager.attributesOfItem(atPath: resolved.relativePath)
            return (attrs[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
        } catch {
            try await ensureShareConnected(resolved.share, using: manager, forceReconnect: true)
            do {
                let attrs = try await manager.attributesOfItem(atPath: resolved.relativePath)
                return (attrs[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
            } catch {
                throw Self.classifySMBError(error, target: path)
            }
        }
    }

    /// 打开专属的 SMB2RandomAccessFile 常驻预读句柄（独立 SMB2Client 会话，支持并发 smb2_pread_async 随机跳读）。
    public func makeChunkSource(path: String) async throws -> any StreamChunkSource {
        let manager = try currentManager()
        guard let resolved = resolveShareAndRelativePath(path) else {
            throw VFSError.notFound(path)
        }
        try await ensureShareConnected(resolved.share, using: manager)
        do {
            let raf = try await manager.openRandomAccessFile(shareName: resolved.share, atPath: resolved.relativePath)
            return SMBPersistentChunkSource(file: raf)
        } catch {
            try await ensureShareConnected(resolved.share, using: manager, forceReconnect: true)
            do {
                let raf = try await manager.openRandomAccessFile(shareName: resolved.share, atPath: resolved.relativePath)
                return SMBPersistentChunkSource(file: raf)
            } catch {
                throw Self.classifySMBError(error, target: path)
            }
        }
    }

    /// 打开独立常驻 SMB2 句柄供直连 FFmpeg AVIO 实时关键帧快进（零 HTTP 环回开销，不阻塞主播放流）。
    public func openSynchronousScrubReader(path: String) async throws -> (any SynchronousRandomAccessReader)? {
        let manager = try currentManager()
        guard let resolved = resolveShareAndRelativePath(path) else {
            throw VFSError.notFound(path)
        }
        try await ensureShareConnected(resolved.share, using: manager)
        do {
            let raf = try await manager.openRandomAccessFile(shareName: resolved.share, atPath: resolved.relativePath)
            return SMB2SynchronousReader(file: raf)
        } catch {
            try await ensureShareConnected(resolved.share, using: manager, forceReconnect: true)
            do {
                let raf = try await manager.openRandomAccessFile(shareName: resolved.share, atPath: resolved.relativePath)
                return SMB2SynchronousReader(file: raf)
            } catch {
                throw Self.classifySMBError(error, target: path)
            }
        }
    }

    /// 局域网 SMB2 读取吞吐测速（默认采样 20 MB，用于诊断 100M / 1000M 有线及 Wi-Fi 真实带宽）。
    public func benchmarkThroughput(at path: String, sampleBytes: Int64 = 20 * 1024 * 1024) async throws -> (bytesRead: Int64, seconds: Double, megabytesPerSec: Double) {
        let source = try await makeChunkSource(path: path)
        let total = try await source.contentLength()
        let target = min(total, max(1, sampleBytes))
        let start = CFAbsoluteTimeGetCurrent()
        var cursor: Int64 = 0
        let blockSize = 1024 * 1024
        while cursor < target {
            let want = Int(min(Int64(blockSize), target - cursor))
            let data = try await source.read(offset: cursor, length: want)
            if data.isEmpty { break }
            cursor += Int64(data.count)
        }
        let elapsed = max(0.01, CFAbsoluteTimeGetCurrent() - start)
        let mbps = Double(cursor) / (1024.0 * 1024.0) / elapsed
        return (cursor, elapsed, mbps)
    }

    // MARK: - 内部辅助

    private func ensureShareConnected(_ share: String, using manager: SMB2Manager, forceReconnect: Bool = false) async throws {
        let already = stateLock.withLock { $0.connectedShare == share }
        if already && !forceReconnect { return }
        do {
            try await manager.connectShare(name: share)
            stateLock.withLock { $0.connectedShare = share }
        } catch {
            throw Self.classifySMBError(error, target: share)
        }
    }

    private func resolveShareAndRelativePath(_ rawPath: String) -> (share: String, relativePath: String)? {
        let normalized = Self.nfc(rawPath)
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let fixedShare = configuredShareName {
            var relParts = parts
            if relParts.first == fixedShare {
                relParts.removeFirst()
            }
            let baseSub = configuredShareSubpath
            let rel: String
            if relParts.isEmpty {
                rel = baseSub.isEmpty ? "/" : baseSub
            } else {
                let joined = "/" + relParts.joined(separator: "/")
                rel = (!baseSub.isEmpty && !joined.hasPrefix(baseSub)) ? (baseSub + joined) : joined
            }
            return (fixedShare, rel)
        } else {
            guard let share = parts.first else { return nil }
            let rest = parts.dropFirst()
            let rel = rest.isEmpty ? "/" : ("/" + rest.joined(separator: "/"))
            return (share, rel)
        }
    }

    static func parseDomainAndUser(_ rawUser: String) -> (domain: String, username: String) {
        let trimmed = rawUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slashIdx = trimmed.firstIndex(of: "\\") {
            let d = String(trimmed[..<slashIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let u = String(trimmed[trimmed.index(after: slashIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (d, u)
        }
        if let semiIdx = trimmed.firstIndex(of: ";") {
            let d = String(trimmed[..<semiIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let u = String(trimmed[trimmed.index(after: semiIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (d, u)
        }
        return ("", trimmed)
    }

    static func parseHostAndPort(rawHost: String, configuredPort: Int?) -> (networkHost: String, urlHost: String, effectivePort: Int?) {
        var clean = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("smb://") {
            clean = String(clean.dropFirst("smb://".count))
        }
        while clean.hasSuffix("/") { clean.removeLast() }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)

        var networkHost = clean
        var urlHost = clean
        var inlinePort: Int?

        if clean.hasPrefix("["), let closeIdx = clean.firstIndex(of: "]") {
            let inside = String(clean[clean.index(after: clean.startIndex)..<closeIdx])
            let after = clean[clean.index(after: closeIdx)...]
            if after.hasPrefix(":"), let p = Int(after.dropFirst()), (1...65535).contains(p) {
                inlinePort = p
            }
            networkHost = inside
            urlHost = "[\(inside)]"
        } else {
            let colonCount = clean.filter { $0 == ":" }.count
            if colonCount == 1, let idx = clean.firstIndex(of: ":") {
                let hostPart = String(clean[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                let portPart = String(clean[clean.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !hostPart.isEmpty, let p = Int(portPart), (1...65535).contains(p) {
                    networkHost = hostPart
                    urlHost = hostPart
                    inlinePort = p
                }
            } else if colonCount >= 2 {
                networkHost = clean
                urlHost = "[\(clean)]"
            }
        }
        return (networkHost, urlHost, configuredPort ?? inlinePort)
    }

    private func preflightTCP(host: String, port: Int) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw VFSError.transport("端口号无效：\(port)")
        }
        let coordinator = TCPPreflightCoordinator(host: host, port: port, nwPort: nwPort)
        try await coordinator.run(timeoutSeconds: 6.0)
    }

    static func describeNWError(_ error: NWError, host: String, port: Int) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return "\(host):\(port) 拒绝连接，请确认 SMB 共享服务已开启。"
        case .posix(let code) where code == .ETIMEDOUT:
            return "连接 \(host):\(port) 超时，请检查 IP、网关或防火墙 445 端口。"
        case .dns(let dnsErr):
            return "无法解析主机 \(host)（DNS 错误 \(dnsErr)）。"
        default:
            return "无法连接 \(host):\(port)（\(error.localizedDescription)）。若首次启动，请在 Apple TV 弹框中允许「本地网络」访问。"
        }
    }

    private static func classifySMBError(_ error: Error, target: String?) -> VFSError {
        if let vfs = error as? VFSError { return vfs }
        let msg = error.localizedDescription
        let upper = msg.uppercased()
        let label = target ?? ""
        if upper.contains("STATUS_LOGON_FAILURE") || upper.contains("0XC000006D") || upper.contains("WRONG_PASSWORD") || upper.contains("EACCES") {
            return .authenticationFailed("SMB 账号或密码错误（\(label)），请检查用户名/密码或 DOMAIN\\用户名 格式。")
        }
        if upper.contains("STATUS_ACCESS_DENIED") || upper.contains("0XC0000022") {
            return .permissionDenied("SMB 权限不足（\(label)）：\(msg)")
        }
        if upper.contains("STATUS_BAD_NETWORK_NAME") || upper.contains("0XC00000CC") || upper.contains("OBJECT_NAME_NOT_FOUND") || upper.contains("ENOENT") {
            return .notFound("共享名或路径不存在（\(label)）：\(msg)")
        }
        return .transport(msg)
    }
}

private final class SMBPersistentChunkSource: StreamChunkSource, @unchecked Sendable {
    private let file: SMB2RandomAccessFile

    init(file: SMB2RandomAccessFile) {
        self.file = file
    }

    deinit {
        file.close()
    }

    func contentLength() async throws -> Int64 {
        file.totalSize
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        try await file.read(offset: offset, length: length)
    }
}

private final class TCPPreflightCoordinator: @unchecked Sendable {
    private struct State: Sendable {
        var finished = false
        var lastWaitingMessage: String?
        var timeoutTask: Task<Void, Never>?
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cinedeck.smb.preflight")
    private let host: String
    private let port: Int

    init(host: String, port: Int, nwPort: NWEndpoint.Port) {
        self.host = host
        self.port = port
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
    }

    private func finish(_ continuation: CheckedContinuation<Void, any Error>, result: Result<Void, any Error>) {
        let (shouldResume, taskToCancel) = lock.withLock { state -> (Bool, Task<Void, Never>?) in
            guard !state.finished else { return (false, nil) }
            state.finished = true
            let t = state.timeoutTask
            state.timeoutTask = nil
            return (true, t)
        }
        guard shouldResume else { return }
        taskToCancel?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }

    func run(timeoutSeconds: TimeInterval) async throws {
        let timeoutNanos = UInt64(max(0.5, timeoutSeconds) * 1_000_000_000)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                guard !Task.isCancelled else { return }
                let waitingMsg = self.lock.withLock { $0.lastWaitingMessage }
                let msg = waitingMsg ?? "连接 \(self.host):\(self.port) 超时，请检查 IP、端口及局域网权限。"
                self.finish(continuation, result: .failure(VFSError.transport(msg)))
            }
            self.lock.withLock { $0.timeoutTask = timeoutTask }

            self.connection.stateUpdateHandler = { nwState in
                switch nwState {
                case .ready:
                    self.finish(continuation, result: .success(()))
                case .waiting(let nwError):
                    // 关键修复：.waiting（包含等待用户在 tvOS 上点选「允许本地网络」）只记录信息，绝不提前中止！
                    let msg = AMSMB2Provider.describeNWError(nwError, host: self.host, port: self.port)
                    self.lock.withLock { state in
                        if !state.finished { state.lastWaitingMessage = msg }
                    }
                case .failed(let nwError):
                    let msg = AMSMB2Provider.describeNWError(nwError, host: self.host, port: self.port)
                    self.finish(continuation, result: .failure(VFSError.transport(msg)))
                case .cancelled:
                    self.finish(continuation, result: .failure(VFSError.transport("连接已取消")))
                default:
                    break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }
}

/// 常驻 SMB2 同步读取器：封装独立 `SMB2RandomAccessFile` 供 `LiveKeyframeScrubEngine` 直接喂给 FFmpeg AVIO。
private final class SMB2SynchronousReader: SynchronousRandomAccessReader, @unchecked Sendable {
    private let file: SMB2RandomAccessFile
    var totalSize: Int64 { file.totalSize }

    init(file: SMB2RandomAccessFile) {
        self.file = file
    }

    func readSync(offset: Int64, length: Int) throws -> Data {
        try file.readSync(offset: offset, length: length)
    }

    func closeSync() {
        file.close()
    }
}
