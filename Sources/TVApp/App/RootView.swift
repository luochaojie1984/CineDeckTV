import SwiftUI
import NetworkVFS
import AppPreferences

enum MainTab: Hashable {
    case home
    case browser
    case history
    case sources
    case settings
}

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedTab: MainTab = .home
    @State private var selectedSource: MediaSourceConfig?
    @State private var playingTarget: PlaybackTarget?
    @State private var pendingBonjourHost: String?
    @State private var pendingBonjourKind: MediaSourceKind = .smb
    @State private var didApplyPreviewScenario = false

    var body: some View {
        Group {
            if #available(tvOS 18.0, *) {
                mainTabView
                    .tabViewStyle(.sidebarAdaptable)
            } else {
                mainTabView
            }
        }
        .background(TVTokens.backgroundGradient.ignoresSafeArea())
        .fullScreenCover(item: $playingTarget) { target in
            PlayerScreenView(
                source: target.source,
                entry: target.entry,
                initialResumePosition: target.resumePosition,
                previewOpenHUD: env.previewScenario == .playerHUD
            )
            .environmentObject(env)
        }
        .onAppear {
            if selectedSource == nil {
                selectedSource = env.sources.first
            }
            applyPreviewScenarioIfNeeded()
        }
        .onChange(of: env.sources) { _, updated in
            if let current = selectedSource, !updated.contains(where: { $0.id == current.id }) {
                selectedSource = updated.first
            } else if selectedSource == nil {
                selectedSource = updated.first
            }
        }
    }

    @ViewBuilder
    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            HomeSpotlightView(
                onOpenSource: { source in
                    selectedSource = source
                    selectedTab = .browser
                },
                onOpenSourcesManager: {
                    selectedTab = .sources
                },
                onResumeRecord: { record in
                    resumePlayback(for: record)
                },
                onSelectBonjour: { host, kind in
                    pendingBonjourHost = host
                    pendingBonjourKind = kind
                    selectedTab = .sources
                }
            )
            .tabItem { Label("首页", systemImage: "sparkles.tv") }
            .tag(MainTab.home)

            DriveBrowserView(
                selectedSource: $selectedSource,
                onPlay: { source, entry in
                    playingTarget = PlaybackTarget(
                        source: source,
                        entry: entry,
                        resumePosition: env.resumePosition(source: source, path: entry.path) ?? 0
                    )
                },
                onOpenSourcesManager: {
                    selectedTab = .sources
                }
            )
            .tabItem { Label("共享盘", systemImage: "externaldrive.connected.to.line.below") }
            .tag(MainTab.browser)

            HistoryView(
                onResumeRecord: { record in
                    resumePlayback(for: record)
                },
                onOpenSource: { source in
                    selectedSource = source
                    selectedTab = .browser
                }
            )
            .tabItem { Label("观看历史", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") }
            .tag(MainTab.history)

            SourceManagerView(
                prefillHost: $pendingBonjourHost,
                prefillKind: $pendingBonjourKind,
                onOpenSource: { source in
                    selectedSource = source
                    selectedTab = .browser
                }
            )
            .tabItem { Label("服务器", systemImage: "server.rack") }
            .tag(MainTab.sources)

            AppSettingsView()
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
                .tag(MainTab.settings)
        }
    }

    private func resumePlayback(for record: PlaybackRecord) {
        guard let source = env.sources.first(where: { $0.id == record.sourceID }) else {
            selectedTab = .sources
            return
        }
        let name = (record.path as NSString).lastPathComponent
        let entry = VFSEntry(path: record.path, name: name.isEmpty ? record.title : name, isDirectory: false, size: 0, modifiedAt: record.updatedAt)
        playingTarget = PlaybackTarget(source: source, entry: entry, resumePosition: record.position)
    }

    private func applyPreviewScenarioIfNeeded() {
        guard !didApplyPreviewScenario, let scenario = env.previewScenario else { return }
        didApplyPreviewScenario = true
        switch scenario {
        case .home:
            selectedTab = .home
        case .browserGrid, .browserList:
            selectedSource = env.sources.first
            selectedTab = .browser
        case .sources:
            selectedTab = .sources
        case .settings:
            selectedTab = .settings
        case .playerHUD:
            selectedTab = .home
            if let source = env.sources.first, let hero = env.history.first {
                let entry = VFSEntry(path: hero.path, name: hero.title, isDirectory: false, size: 24_850_120_400, modifiedAt: Date())
                playingTarget = PlaybackTarget(source: source, entry: entry, resumePosition: hero.position)
            }
        }
    }
}

struct PlaybackTarget: Identifiable {
    let source: MediaSourceConfig
    let entry: VFSEntry
    let resumePosition: Double
    var id: String { "\(source.id.uuidString)/\(entry.path)" }
}
