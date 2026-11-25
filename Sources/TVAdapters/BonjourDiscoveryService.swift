import Foundation
import Network

/// 局域网 Bonjour 发现：_smb._tcp / _webdav._tcp / _webdavs._tcp。
/// Info.plist 里的 NSBonjourServices 必须与这里保持一致，否则 tvOS 不返回结果。
@MainActor
public final class BonjourDiscoveryService: ObservableObject {
    public struct DiscoveredHost: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let kind: String
        public var displayName: String { name }
    }

    @Published public private(set) var hosts: [DiscoveredHost] = []
    @Published public private(set) var isBrowsing = false

    private var browsers: [NWBrowser] = []
    private let queue = DispatchQueue(label: "cinedeck.bonjour")

    public init() {}

    public func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        for service in ["_smb._tcp", "_webdav._tcp", "_webdavs._tcp"] {
            let parameters = NWParameters.tcp
            let browser = NWBrowser(for: .bonjour(type: service, domain: nil), using: parameters)
            browser.stateUpdateHandler = { _ in }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let mapped: [DiscoveredHost] = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredHost(id: "\(service)/\(name)", name: name, kind: service)
                }
                Task { @MainActor in
                    guard let self else { return }
                    let merged = Dictionary(
                        (self.hosts + mapped).map { ($0.id, $0) },
                        uniquingKeysWith: { _, new in new }
                    )
                    self.hosts = merged.values.sorted { $0.name < $1.name }
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        isBrowsing = false
    }
}
