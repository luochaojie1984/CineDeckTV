import Testing
import Foundation
@testable import AppPreferences
@testable import NetworkVFS

@Suite("Stores")
struct StoresTests {
    @Test("源列表往返保存")
    func sourceRoundTrip() throws {
        let store = MediaSourceStore(folderName: "CineDeckTVTests-\(UUID().uuidString)", defaultsKey: "test.sources.\(UUID().uuidString)")
        let config = MediaSourceConfig(name: "NAS", kind: .smb, host: "192.168.1.10", username: "user", sharePath: "/Movies")
        try store.save([config])
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.host == "192.168.1.10")
        #expect(loaded.first?.kind == .smb)
    }

    @Test("历史记录去重并按时间倒序")
    func historyDeduplicates() throws {
        let store = PlaybackHistoryStore(folderName: "CineDeckTVTests-\(UUID().uuidString)", defaultsKey: "test.history.\(UUID().uuidString)")
        try store.removeAll()
        let source = UUID()
        let first = PlaybackRecord(sourceID: source, path: "/a.mkv", title: "A", position: 30, duration: 3000)
        var second = first
        second.position = 120
        try store.record(first)
        try store.record(second)
        let records = store.load()
        #expect(records.count == 1)
        #expect(records.first?.position == 120)
        #expect(records.first?.progress ?? 0 == 0.04)
    }

    @Test("备份导出可恢复")
    func backupRoundTrip() throws {
        let settings = AppSettings()
        let source = MediaSourceConfig(name: "S", kind: .webdav, host: "h", username: "u", sharePath: "/dav")
        let history = [PlaybackRecord(sourceID: source.id, path: "/x.mkv", title: "X", position: 1, duration: 2)]
        let data = try WebDAVBackupService.export(settings: settings, sources: [source], history: history)
        let bundle = try WebDAVBackupService.restore(data)
        #expect(bundle.settings == settings)
        #expect(bundle.sources.first?.host == "h")
        #expect(bundle.history.count == 1)
    }
}
