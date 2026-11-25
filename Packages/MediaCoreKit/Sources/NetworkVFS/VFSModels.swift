import Foundation

/// 局域网影音源中的一项（文件夹 / 视频 / 字幕 / 其他文件）。
public struct VFSEntry: Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date?

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, size: Int64, modifiedAt: Date?) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }

    public var fileExtension: String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }

    /// 视频容器白名单：覆盖设计规划里要求的 MKV/MP4/MOV/TS/AVI 及常见衍生。
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "ts", "m2ts", "mts", "avi", "wmv", "flv", "webm", "iso", "rmvb", "mpg", "mpeg"
    ]

    public static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sup", "sub"]

    public var isVideo: Bool { !isDirectory && Self.videoExtensions.contains(fileExtension) }
    public var isSubtitle: Bool { !isDirectory && Self.subtitleExtensions.contains(fileExtension) }

    /// 视频规格徽章识别（4K / 1080p / DV / HDR10 / HEVC / AV1 / 10bit / Atmos / TrueHD / DTS）。
    /// 仅基于文件名推断，避免为列表滚动触发额外网络探测。
    public var badges: [String] {
        guard isVideo else { return [] }
        let upper = name.uppercased()
        var result: [String] = []
        if upper.contains("2160") || upper.contains("4K") { result.append("4K") }
        else if upper.contains("1080") { result.append("1080p") }
        else if upper.contains("720") { result.append("720p") }
        if upper.contains("DOVI") || upper.contains("DOLBY VISION") || upper.contains(" DV ") { result.append("DV") }
        if upper.contains("HDR10+") { result.append("HDR10+") } else if upper.contains("HDR") { result.append("HDR10") }
        if upper.contains("H265") || upper.contains("H.265") || upper.contains("HEVC") || upper.contains("X265") { result.append("HEVC") }
        if upper.contains("H264") || upper.contains("H.264") || upper.contains("X264") { result.append("H.264") }
        if upper.contains("AV1") { result.append("AV1") }
        if upper.contains("10BIT") || upper.contains("10-BIT") || upper.contains("10 BIT") { result.append("10bit") }
        if upper.contains("ATMOS") { result.append("Atmos") }
        if upper.contains("TRUEHD") { result.append("TrueHD") }
        if upper.contains("DTS") { result.append("DTS") }
        return result
    }
}

public enum VFSError: Error, Sendable, LocalizedError {
    case notConnected
    case notFound(String)
    case permissionDenied(String)
    case authenticationFailed(String)
    case unsupported(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "尚未连接到服务器"
        case .notFound(let p): return "路径不存在：\(p)"
        case .permissionDenied(let p): return "没有权限访问：\(p)"
        case .authenticationFailed(let p): return "认证失败：\(p)"
        case .unsupported(let p): return "暂不支持：\(p)"
        case .transport(let p): return "网络传输错误：\(p)"
        }
    }
}

/// 支持的源类型。
public enum MediaSourceKind: String, Codable, Sendable, CaseIterable {
    case smb
    case webdav

    public var displayName: String { self == .smb ? "SMB" : "WebDAV" }
    public var defaultPort: Int { self == .smb ? 445 : 80 }
}

/// 服务器连接参数（不存密码，密码走 Keychain）。
public struct MediaSourceConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: MediaSourceKind
    public var host: String
    public var port: Int
    public var username: String
    public var sharePath: String
    public var useTLS: Bool
    public var enableAnonymous: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: MediaSourceKind,
        host: String,
        port: Int? = nil,
        username: String,
        sharePath: String,
        useTLS: Bool = false,
        enableAnonymous: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.username = username
        self.sharePath = sharePath
        self.useTLS = useTLS
        self.enableAnonymous = enableAnonymous
    }

    public var baseURL: URL? {
        switch kind {
        case .smb:
            var comps = URLComponents()
            comps.scheme = "smb"
            comps.host = host
            comps.port = port
            comps.path = sharePath.hasPrefix("/") ? sharePath : "/" + sharePath
            return comps.url
        case .webdav:
            var comps = URLComponents()
            comps.scheme = useTLS ? "https" : "http"
            comps.host = host
            comps.port = port
            comps.path = sharePath.hasPrefix("/") ? sharePath : "/" + sharePath
            return comps.url
        }
    }
}
