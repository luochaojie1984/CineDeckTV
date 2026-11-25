import SwiftUI
import NetworkVFS

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selection: Int = 0
    @State private var activeSource: MediaSourceConfig?
    @State private var playingEntry: (source: MediaSourceConfig, entry: VFSEntry)?

    var body: some View {
        TabView(selection: $selection) {
            HomeSpotlightView(onOpenSource: { source in
                activeSource = source
                selection = 1
            })
            .tabItem { Label("首页", systemImage: "play.house.fill") }
            .tag(0)

            Group {
                if let activeSource {
                    DriveBrowserView(source: activeSource, onPlay: { entry in
                        playingEntry = (activeSource, entry)
                    })
                } else {
                    DriveBrowserView(source: env.sources.first ?? MediaSourceConfig(
                        name: "未添加服务器", kind: .smb, host: "—", username: "", sharePath: ""
                    ), onPlay: { entry in
                        if let source = env.sources.first { playingEntry = (source, entry) }
                    })
                }
            }
            .tabItem { Label("共享盘", systemImage: "externaldrive.connected.to.line.below.fill") }
            .tag(1)

            SourceManagerView(onSelect: { source in
                activeSource = source
                selection = 1
            })
            .tabItem { Label("服务器", systemImage: "server.rack") }
            .tag(2)

            AppSettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .fullScreenCover(item: Binding(
            get: { playingEntry.map { PlaybackTarget(source: $0.source, entry: $0.entry) } },
            set: { if $0 == nil { playingEntry = nil } }
        )) { target in
            PlayerScreenView(source: target.source, entry: target.entry)
                .environmentObject(env)
        }
    }
}

struct PlaybackTarget: Identifiable {
    let source: MediaSourceConfig
    let entry: VFSEntry
    var id: String { "\(source.id)/\(entry.path)" }
}
