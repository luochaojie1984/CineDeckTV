import Foundation
import Network
import AMSMB2
import NetworkVFS

/// SMB 2/3 适配器（AMSMB2 4.0.3：错误保留真实 NTSTATUS、FileHandle 走 smb2_pread_async、
/// shareEnum 具备 Swift 回退；文档 6.2 所列补丁已被上游吸收，无需本地 patch）。
public actor AMSMB2Provider: VFSProvider {
    public nonisolated var kind: MediaSourceKind { .smb }

    private let config: MediaSourceConfig
    private let password: String?
    private var manager: SMB2Manager?
    private var shareName: String

    public init(config: MediaSourceConfig, password: String?) {
        self.config = config
        self.password = password
        let trimmed = config.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        self.shareName = parts.first ?? ""
    }

    public func connect() async throws {
        try await Self.preflight(host: config.host, port: UInt16(config.port), timeout: 6)
        guard let url = URL(string: "smb://\(config.host):\(config.port)/") else {
            throw VFSError.transport("SMB 地址无效：\(config.host)")
        }
        let credential: URLCredential? = config.enableAnonymous
            ? nil
            : URLCredential(user: config.username, password: password ?? "", persistence: .none)
        guard let manager = SMB2Manager(url: url, domain: "", credential: credential) else {
            throw VFSError.transport("SMB2Manager 初始化失败")
        }
        do {
            if !shareName.isEmpty {
                try await manager.connectShare(name: shareName)
            }
            self.manager = manager
        } catch {
            throw Self.translate(error, path: config.sharePath)
        }
    }

    public func disconnect() async {
        if let manager {
            try? await manager.disconnectShare(gracefully: false)
        }
        manager = nil
    }

    public func list(path: String) async throws -> [VFSEntry] {
        let manager = try requireManager()
        do {
            let rows = try await manager.contentsOfDirectory(atPath: normalize(path))
            return rows.compactMap { attrs -> VFSEntry? in
                guard let name = attrs[.nameKey] as? String else { return nil }
                if name == "." || name == ".." { return nil }
                let isDirectory = (attrs[.isDirectoryKey] as? Bool) ?? false
                let size = (attrs[.fileSizeKey] as? Int64) ?? Int64((attrs[.fileSizeKey] as? Int) ?? 0)
                let modified = attrs[.contentModificationDateKey] as? Date
                let childPath = path.isEmpty ? name : "\(path)/\(name)"
                return VFSEntry(path: childPath, name: name, isDirectory: isDirectory, size: size, modifiedAt: modified)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    public func read(path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let manager = try requireManager()
        let start = UInt64(max(0, offset))
        let end = start &+ UInt64(length)
        do {
            return try await manager.contents(atPath: normalize(path), range: start..<end)
        } catch {
            throw Self.translate(error, path: path)
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
        let manager = try requireManager()
        do {
            let attrs = try await manager.attributesOfItem(atPath: normalize(path))
            if let size = attrs[.fileSizeKey] as? Int64 { return size }
            if let size = attrs[.fileSizeKey] as? Int { return Int64(size) }
            if let size = attrs[.fileSizeKey] as? NSNumber { return size.int64Value }
            throw VFSError.transport("无法读取文件大小")
        } catch let error as VFSError {
            throw error
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    public func makeChunkSource(path: String) async throws -> any StreamChunkSource {
        SMBChunkSource(provider: self, path: path)
    }

    /// 列出共享名（过滤 $ 结尾的系统管理共享）。
    public func listShares() async throws -> [String] {
        let manager = try requireManager()
        let shares = try await manager.listShares(enumerateHidden: false)
        return shares.map(\.name).filter { !$0.hasSuffix("$") }
    }

    // MARK: - 内部

    private func requireManager() throws -> SMB2Manager {
        guard let manager else { throw VFSError.notConnected }
        return manager
    }

    private func normalize(_ path: String) -> String {
        var p = path
        if !shareName.isEmpty, p.hasPrefix(shareName) {
            p = String(p.dropFirst(shareName.count))
        }
        p = p.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return p.isEmpty ? "." : p
    }

    /// TCP 445 预检：先建立 NWConnection 触发 tvOS 本地网络权限，再给明确错误。
    static func preflight(host: String, port: UInt16, timeout: TimeInterval) async throws {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 445, using: .tcp)
        let queue = DispatchQueue(label: "cinedeck.smb.preflight")
        defer { connection.cancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    var resumed = false
                    connection.stateUpdateHandler = { state in
                        guard !resumed else { return }
                        switch state {
                        case .ready:
                            resumed = true
                            continuation.resume()
                        case .failed(let error):
                            resumed = true
                            continuation.resume(throwing: VFSError.transport("TCP 预检失败：\(error.localizedDescription)"))
                        case .waiting(let error):
                            resumed = true
                            connection.cancel()
                            continuation.resume(throwing: VFSError.transport("无法连接 \(host):\(port)（\(error.localizedDescription)）"))
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw VFSError.transport("连接 \(host):\(port) 超时（\(Int(timeout))s）")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    static func translate(_ error: Error, path: String) -> VFSError {
        if let vfs = error as? VFSError { return vfs }
        let text = error.localizedDescription
        if let posix = error as? POSIXError {
            switch posix.code {
            case .EPERM: return .permissionDenied(path)
            case .EACCES: return .permissionDenied(path)
            case .ENOENT: return .notFound(path)
            case .ENOTCONN, .ECONNREFUSED, .EHOSTUNREACH, .ETIMEDOUT: return .transport(text)
            default: return .transport(text)
            }
        }
        if text.contains("STATUS_LOGON_FAILURE") { return .authenticationFailed(path) }
        if text.contains("STATUS_ACCESS_DENIED") { return .permissionDenied(path) }
        if text.contains("STATUS_BAD_NETWORK_NAME") { return .notFound(path) }
        if text.contains("STATUS_OBJECT_NAME_NOT_FOUND") { return .notFound(path) }
        return .transport(text)
    }
}

private struct SMBChunkSource: StreamChunkSource {
    let provider: AMSMB2Provider
    let path: String

    func contentLength() async throws -> Int64 {
        try await provider.size(path: path)
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        try await provider.read(path: path, offset: offset, length: length)
    }
}
