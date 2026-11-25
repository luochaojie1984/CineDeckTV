import Foundation
import NetworkVFS

public struct PlaybackRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(sourceID.uuidString)/\(path)" }
    public let sourceID: UUID
    public let path: String
    public var title: String
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    public init(sourceID: UUID, path: String, title: String, position: Double, duration: Double, updatedAt: Date = Date()) {
        self.sourceID = sourceID
        self.path = path
        self.title = title
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    public var remaining: Double { max(0, duration - position) }
}

/// 观看历史与断点：最多 200 条，按更新时间倒序。
public final class PlaybackHistoryStore: @unchecked Sendable {
    private let folderName: String
    private let defaultsKey: String
    private let maxRecords = 200
    private let lock = NSLock()

    public init(folderName: String = "CineDeckTV", defaultsKey: String = "cinedeck.history.v1") {
        self.folderName = folderName
        self.defaultsKey = defaultsKey
    }

    private var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("history.json") }

    public func load() -> [PlaybackRecord] {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: fileURL),
           let records = try? JSONDecoder().decode([PlaybackRecord].self, from: data) {
            return records
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let records = try? JSONDecoder().decode([PlaybackRecord].self, from: data) {
            return records
        }
        return []
    }

    public func record(_ entry: PlaybackRecord) throws {
        var records = load().filter { $0.id != entry.id }
        records.insert(entry, at: 0)
        if records.count > maxRecords { records = Array(records.prefix(maxRecords)) }
        try persist(records)
    }

    public func position(sourceID: UUID, path: String) -> Double? {
        load().first { $0.sourceID == sourceID && $0.path == path }?.position
    }

    public func removeAll() throws {
        try persist([])
    }

    private func persist(_ records: [PlaybackRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
