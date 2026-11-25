import Foundation
import SwiftUI
import NetworkVFS
import AppPreferences
import SubtitleKit

/// 全局依赖容器：设置、源、历史、provider 缓存与播放历史。
@MainActor
public final class AppEnvironment: ObservableObject {
    @Published public private(set) var settings: AppSettings
    @Published public private(set) var sources: [MediaSourceConfig]
    @Published public private(set) var history: [PlaybackRecord]
    @Published public var lastError: String?

    private let settingsStore = AppSettingsStore()
    private let sourceStore = MediaSourceStore()
    private let historyStore = PlaybackHistoryStore()
    private var providers: [UUID: any VFSProvider] = [:]

    public init() {
        settings = AppSettingsStore().load()
        sources = MediaSourceStore().load()
        history = PlaybackHistoryStore().load()
    }

    public func update(settings newValue: AppSettings) {
        settings = newValue
        do { try settingsStore.save(newValue) } catch { lastError = error.localizedDescription }
    }

    public func upsert(source: MediaSourceConfig, password: String?) {
        do {
            try sourceStore.upsert(source)
            sources = sourceStore.load()
            providers[source.id] = nil
            if let password, !password.isEmpty {
                try KeychainCredentialStore.save(password: password, accountID: source.id.uuidString)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func remove(source: MediaSourceConfig) {
        try? sourceStore.remove(id: source.id)
        sources = sourceStore.load()
        providers[source.id] = nil
        KeychainCredentialStore.delete(accountID: source.id.uuidString)
    }

    /// 取得（必要时建立）某个源的 provider。
    public func provider(for source: MediaSourceConfig) async throws -> any VFSProvider {
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

    public func recordHistory(source: MediaSourceConfig, path: String, title: String, position: Double, duration: Double) {
        let record = PlaybackRecord(sourceID: source.id, path: path, title: title, position: position, duration: duration)
        try? historyStore.record(record)
        history = historyStore.load()
    }

    public func resumePosition(source: MediaSourceConfig, path: String) -> Double? {
        historyStore.position(sourceID: source.id, path: path)
    }
}
