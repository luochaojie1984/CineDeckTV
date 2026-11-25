import Foundation
import NetworkVFS

/// 设置与历史的一键备份/恢复（JSON 单文件，可放回 WebDAV 目录）。
public struct BackupBundle: Codable, Sendable {
    public var version: Int
    public var exportedAt: Date
    public var settings: AppSettings
    public var sources: [MediaSourceConfig]
    public var history: [PlaybackRecord]

    public init(version: Int = 1, exportedAt: Date = Date(), settings: AppSettings, sources: [MediaSourceConfig], history: [PlaybackRecord]) {
        self.version = version
        self.exportedAt = exportedAt
        self.settings = settings
        self.sources = sources
        self.history = history
    }
}

public enum WebDAVBackupService {
    public static func export(settings: AppSettings, sources: [MediaSourceConfig], history: [PlaybackRecord]) throws -> Data {
        let bundle = BackupBundle(settings: settings, sources: sources, history: history)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    public static func restore(_ data: Data) throws -> BackupBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupBundle.self, from: data)
    }
}
