import Foundation
import NetworkVFS
import AppPreferences
import PlaybackKit

/// CI 多界面截图预览参数（仅加载纯净虚构演示数据，绝不包含任何个人 NAS IP / 凭据 / 私有文件名）。
public enum PreviewScenario: String, Sendable {
    case home = "home"
    case browserGrid = "browser-grid"
    case browserList = "browser-list"
    case sources = "sources"
    case playerHUD = "player-hud"
    case settings = "settings"

    public static func fromLaunchEnvironment() -> PreviewScenario? {
        for arg in CommandLine.arguments {
            if let value = arg.split(separator: "=", maxSplits: 1).last,
               arg.hasPrefix("--preview-screen="),
               let scenario = PreviewScenario(rawValue: String(value)) {
                return scenario
            }
        }
        if let raw = ProcessInfo.processInfo.environment["CINEDECK_PREVIEW_SCREEN"],
           let scenario = PreviewScenario(rawValue: raw) {
            return scenario
        }
        return nil
    }
}

/// CI 实时播放冒烟测试配置（仅读取本地沙盒测试视频）。
public struct SmokeTestPlaybackConfig: Sendable {
    public let videoFilePath: String
    public let statusFilePath: String?

    public static func fromLaunchEnvironment() -> SmokeTestPlaybackConfig? {
        var videoPath: String?
        var statusPath: String?
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--smoke-test-playback="),
               let val = arg.split(separator: "=", maxSplits: 1).last,
               !val.isEmpty {
                videoPath = String(val)
            } else if arg.hasPrefix("--smoke-test-status="),
                      let val = arg.split(separator: "=", maxSplits: 1).last,
                      !val.isEmpty {
                statusPath = String(val)
            }
        }
        if videoPath == nil,
           let envVideo = ProcessInfo.processInfo.environment["CINEDECK_SMOKE_TEST_VIDEO"],
           !envVideo.isEmpty {
            videoPath = envVideo
        }
        if statusPath == nil,
           let envStatus = ProcessInfo.processInfo.environment["CINEDECK_SMOKE_TEST_STATUS"],
           !envStatus.isEmpty {
            statusPath = envStatus
        }
        guard let videoPath else { return nil }
        return SmokeTestPlaybackConfig(videoFilePath: videoPath, statusFilePath: statusPath)
    }
}

/// 全局依赖容器：配置、服务器源、Keychain 密码、播放历史与预览演示数据。
@MainActor
public final class AppEnvironment: ObservableObject {
    public static let appDidReturnToForegroundNotification = Notification.Name("local.personal.cinedecktv.didReturnToForeground")

    @Published public private(set) var settings: AppSettings
    @Published public private(set) var sources: [MediaSourceConfig]
    @Published public private(set) var history: [PlaybackRecord]
    @Published public var lastError: String?

    public let previewScenario: PreviewScenario?
    public let smokeTestPlayback: SmokeTestPlaybackConfig?

    private let settingsStore = AppSettingsStore()
    private let sourceStore = MediaSourceStore()
    private let historyStore = PlaybackHistoryStore()
    private var providers: [UUID: any VFSProvider] = [:]

    public init(
        previewScenario: PreviewScenario? = PreviewScenario.fromLaunchEnvironment(),
        smokeTestPlayback: SmokeTestPlaybackConfig? = SmokeTestPlaybackConfig.fromLaunchEnvironment()
    ) {
        self.previewScenario = previewScenario
        self.smokeTestPlayback = smokeTestPlayback
        if previewScenario != nil || smokeTestPlayback != nil {
            self.settings = AppSettings()
            let demoSources = Self.makePreviewSources()
            self.sources = demoSources
            self.history = Self.makePreviewHistory(sources: demoSources)
        } else {
            self.settings = settingsStore.load()
            self.sources = sourceStore.load()
            self.history = historyStore.load()
        }
    }

    public func update(settings newValue: AppSettings) {
        settings = newValue
        guard previewScenario == nil else { return }
        try? settingsStore.save(newValue)
    }

    public func upsert(source: MediaSourceConfig, password: String?) {
        var list = sources
        if let idx = list.firstIndex(where: { $0.id == source.id }) {
            list[idx] = source
        } else {
            list.append(source)
        }
        sources = list
        providers[source.id] = nil
        guard previewScenario == nil else { return }
        do {
            try sourceStore.save(list)
            if let password, !password.isEmpty {
                try KeychainCredentialStore.save(password: password, accountID: source.id.uuidString)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func remove(source: MediaSourceConfig) {
        sources.removeAll { $0.id == source.id }
        providers[source.id] = nil
        guard previewScenario == nil else { return }
        try? sourceStore.save(sources)
        KeychainCredentialStore.delete(accountID: source.id.uuidString)
    }

    public func hasSavedPassword(for sourceID: UUID) -> Bool {
        if previewScenario != nil { return true }
        return KeychainCredentialStore.password(accountID: sourceID.uuidString) != nil
    }

    public func provider(for source: MediaSourceConfig) async throws -> any VFSProvider {
        if let smoke = smokeTestPlayback {
            return LocalFileSmokeVFSProvider(filePath: smoke.videoFilePath)
        }
        if previewScenario != nil {
            return PreviewVFSProvider(source: source)
        }
        if let cached = providers[source.id] { return cached }
        let password = KeychainCredentialStore.password(accountID: source.id.uuidString)
        let provider: any VFSProvider
        switch source.kind {
        case .smb:
            provider = AMSMB2Provider(config: source, password: password)
        case .webdav:
            provider = WebDAVProvider(config: source, password: password)
        }
        try await provider.connect()
        providers[source.id] = provider
        return provider
    }

    public func resetProvider(for sourceID: UUID) async {
        if let existing = providers.removeValue(forKey: sourceID) {
            await existing.disconnect()
        }
    }

    public func resetAllProviders() async {
        let existing = providers
        providers.removeAll()
        for (_, provider) in existing {
            await provider.disconnect()
        }
    }

    public func handleReturnToForeground() async {
        await resetAllProviders()
        NotificationCenter.default.post(name: Self.appDidReturnToForegroundNotification, object: nil)
    }

    public func recordHistory(source: MediaSourceConfig, path: String, title: String, position: Double, duration: Double) {
        let record = PlaybackRecord(sourceID: source.id, path: path, title: title, position: position, duration: duration)
        var list = history.filter { $0.id != record.id }
        list.insert(record, at: 0)
        if list.count > 200 { list = Array(list.prefix(200)) }
        history = list
        guard previewScenario == nil else { return }
        try? historyStore.record(record)
    }

    public func resumePosition(source: MediaSourceConfig, path: String) -> Double? {
        history.first { $0.sourceID == source.id && $0.path == path }?.position
    }

    public func clearHistory() {
        history = []
        guard previewScenario == nil else { return }
        try? historyStore.removeAll()
    }

    public func lastVisitedPath(for sourceID: UUID) -> String? {
        guard settings.rememberLastDirectory else { return nil }
        return settings.lastVisitedPaths[sourceID.uuidString]
    }

    public func saveLastVisitedPath(_ path: String, for sourceID: UUID) {
        guard settings.rememberLastDirectory else { return }
        var copy = settings
        copy.lastVisitedPaths[sourceID.uuidString] = path
        update(settings: copy)
    }

    // MARK: - 虚构安全预览数据（严格无真实 NAS 信息）

    public static func makePreviewSources() -> [MediaSourceConfig] {
        let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        return [
            MediaSourceConfig(id: id1, name: "客厅 Synology NAS", kind: .smb, host: "nas.local", port: 445, username: "media", sharePath: "/Movies"),
            MediaSourceConfig(id: id2, name: "卧室 WebDAV 影库", kind: .webdav, host: "media-hub.local", port: 5005, username: "viewer", sharePath: "/dav/4K")
        ]
    }

    public static func makePreviewHistory(sources: [MediaSourceConfig]) -> [PlaybackRecord] {
        guard let primary = sources.first else { return [] }
        return [
            PlaybackRecord(
                sourceID: primary.id,
                path: "/Movies/星际穿越 (2014) 2160p HDR10 HEVC 10bit Atmos.mkv",
                title: "星际穿越 (2014) 2160p HDR10 HEVC 10bit Atmos.mkv",
                position: 4120,
                duration: 10140
            ),
            PlaybackRecord(
                sourceID: primary.id,
                path: "/Movies/沙丘2 (2024) 4K DV HEVC.mp4",
                title: "沙丘2 (2024) 4K DV HEVC.mp4",
                position: 1850,
                duration: 9960
            ),
            PlaybackRecord(
                sourceID: primary.id,
                path: "/Movies/地球脉动 S03E01.2160p.HEVC.mkv",
                title: "地球脉动 S03E01.2160p.HEVC.mkv",
                position: 920,
                duration: 3180
            )
        ]
    }
}

/// 预览截图专用只读虚拟文件系统（仅返回安全虚构目录/电影片单）。
private actor PreviewVFSProvider: VFSProvider {
    nonisolated let kind: MediaSourceKind
    private let source: MediaSourceConfig

    init(source: MediaSourceConfig) {
        self.kind = source.kind
        self.source = source
    }

    func connect() async throws {}
    func disconnect() async {}

    func list(path: String) async throws -> [VFSEntry] {
        [
            VFSEntry(path: "/4K科幻精选", name: "4K科幻精选", isDirectory: true, size: 0, modifiedAt: Date()),
            VFSEntry(path: "/自然纪录片合集", name: "自然纪录片合集", isDirectory: true, size: 0, modifiedAt: Date()),
            VFSEntry(path: "/动画电影原盘", name: "动画电影原盘", isDirectory: true, size: 0, modifiedAt: Date()),
            VFSEntry(path: "/星际穿越 (2014) 2160p HDR10 HEVC 10bit Atmos.mkv", name: "星际穿越 (2014) 2160p HDR10 HEVC 10bit Atmos.mkv", isDirectory: false, size: 24_850_120_400, modifiedAt: Date()),
            VFSEntry(path: "/沙丘2 (2024) 4K DV HEVC.mp4", name: "沙丘2 (2024) 4K DV HEVC.mp4", isDirectory: false, size: 18_420_000_000, modifiedAt: Date()),
            VFSEntry(path: "/奥本海默 (2023) 2160p HDR10+ HEVC TrueHD.mkv", name: "奥本海默 (2023) 2160p HDR10+ HEVC TrueHD.mkv", isDirectory: false, size: 28_100_000_000, modifiedAt: Date()),
            VFSEntry(path: "/地球脉动 S03E01.2160p.HEVC.mkv", name: "地球脉动 S03E01.2160p.HEVC.mkv", isDirectory: false, size: 6_340_000_000, modifiedAt: Date()),
            VFSEntry(path: "/星际穿越 (2014) 2160p HDR10 HEVC 10bit Atmos.chs.ass", name: "星际穿越 (2014) 2160p HDR10 HEVC 10bit Atmos.chs.ass", isDirectory: false, size: 128_400, modifiedAt: Date())
        ]
    }

    func readHead(path: String, length: Int) async throws -> Data { Data() }
    func readTail(path: String, length: Int) async throws -> Data { Data() }
    func read(path: String, offset: Int64, length: Int) async throws -> Data { Data() }
    func size(path: String) async throws -> Int64 { 24_850_120_400 }
    func makeChunkSource(path: String) async throws -> any StreamChunkSource { DataChunkSource(data: Data()) }
}

/// CI 实时播放冒烟测试用本地文件只读 VFSProvider（经完整 ReadAheadStreamCache -> LocalHTTPStreamProxy -> FSPlayer 管线）。
private actor LocalFileSmokeVFSProvider: VFSProvider {
    nonisolated let kind: MediaSourceKind = .smb
    private let filePath: String

    init(filePath: String) {
        self.filePath = filePath
    }

    func connect() async throws {}
    func disconnect() async {}
    func list(path: String) async throws -> [VFSEntry] { [] }

    func readHead(path: String, length: Int) async throws -> Data {
        try await read(path: path, offset: 0, length: length)
    }

    func readTail(path: String, length: Int) async throws -> Data {
        let total = try await size(path: path)
        let start = max(0, total - Int64(length))
        return try await read(path: path, offset: start, length: Int(total - start))
    }

    func read(path: String, offset: Int64, length: Int) async throws -> Data {
        let chunkSource = try await makeChunkSource(path: path)
        return try await chunkSource.read(offset: offset, length: length)
    }

    func size(path: String) async throws -> Int64 {
        let target = path.isEmpty ? filePath : path
        let attrs = try FileManager.default.attributesOfItem(atPath: target)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    func makeChunkSource(path: String) async throws -> any StreamChunkSource {
        let target = FileManager.default.fileExists(atPath: path) ? path : filePath
        return try LocalFileSmokeChunkSource(url: URL(fileURLWithPath: target))
    }
}

private actor LocalFileSmokeChunkSource: StreamChunkSource {
    private let fileURL: URL
    private let totalSize: Int64

    init(url: URL) throws {
        self.fileURL = url
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        self.totalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    func contentLength() async throws -> Int64 {
        totalSize
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0, offset < totalSize else { return Data() }
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(offset))
        let capped = Int(min(Int64(length), totalSize - offset))
        return try fh.read(upToCount: capped) ?? Data()
    }
}
