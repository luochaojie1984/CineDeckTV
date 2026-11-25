import Foundation
import NetworkVFS

/// 服务器列表持久化（Caches + UserDefaults 双写；密码不进 JSON）。
public final class MediaSourceStore: @unchecked Sendable {
    private let folderName: String
    private let defaultsKey: String
    private let lock = NSLock()

    public init(folderName: String = "CineDeckTV", defaultsKey: String = "cinedeck.sources.v1") {
        self.folderName = folderName
        self.defaultsKey = defaultsKey
    }

    private var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("sources.json") }

    public func load() -> [MediaSourceConfig] {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: fileURL),
           let sources = try? JSONDecoder().decode([MediaSourceConfig].self, from: data) {
            return sources
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let sources = try? JSONDecoder().decode([MediaSourceConfig].self, from: data) {
            return sources
        }
        return []
    }

    public func save(_ sources: [MediaSourceConfig]) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(sources)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    public func upsert(_ source: MediaSourceConfig) throws {
        var sources = load()
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        try save(sources)
    }

    public func remove(id: UUID) throws {
        try save(load().filter { $0.id != id })
    }
}
