import Foundation

/// 设置持久化：写入 Caches/<bundle>/settings.json，并同步镜像到 UserDefaults，
/// 规避 tvOS 真机 .documentDirectory 只读问题（设计规划 6.1 #1）。
public final class AppSettingsStore: @unchecked Sendable {
    private let folderName: String
    private let defaultsKey: String
    private let lock = NSLock()

    public init(folderName: String = "CineDeckTV", defaultsKey: String = "cinedeck.settings.v1") {
        self.folderName = folderName
        self.defaultsKey = defaultsKey
    }

    public var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    public func load() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: fileURL),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            persistMigratedIfNeeded(rawData: data, migrated: settings)
            return settings
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            persistMigratedIfNeeded(rawData: data, migrated: settings)
            return settings
        }
        return AppSettings()
    }

    public func save(_ settings: AppSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try JSONEncoder().encode(settings)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func persistMigratedIfNeeded(rawData: Data, migrated: AppSettings) {
        let obj = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
        let savedVersion = obj?["subtitleDefaultsVersion"] as? Int
        guard savedVersion != migrated.subtitleDefaultsVersion else { return }
        if let updatedData = try? JSONEncoder().encode(migrated) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? updatedData.write(to: fileURL, options: .atomic)
            UserDefaults.standard.set(updatedData, forKey: defaultsKey)
        }
    }
}
