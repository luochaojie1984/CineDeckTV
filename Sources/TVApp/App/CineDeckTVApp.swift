import SwiftUI
import Darwin

@main
struct CineDeckTVApp: App {
    @StateObject private var environment = AppEnvironment()

    init() {
        signal(SIGPIPE, SIG_IGN)
        SubtitleFontRegistry.shared.ensureRegistered()
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        wasInBackground = true
                    case .active:
                        if wasInBackground {
                            wasInBackground = false
                            Task { await environment.handleReturnToForeground() }
                        }
                    default:
                        break
                    }
                }
        }
    }
}
