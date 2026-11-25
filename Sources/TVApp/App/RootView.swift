import SwiftUI
import FSPlayer

struct RootView: View {
    private enum Tab: Hashable { case home, browser, history, settings }

    var body: some View {
        TabView {
            PlaceholderPanel(title: "首页", subtitle: "继续观看 · 服务器棚 · 附近设备")
                .tabItem { Label("首页", systemImage: "play.house.fill") }
                .tag(Tab.home)
            PlaceholderPanel(title: "共享盘", subtitle: "全宽 4 列卡片网格 / 宽列表")
                .tabItem { Label("共享盘", systemImage: "externaldrive.connected.to.line.below.fill") }
                .tag(Tab.browser)
            PlaceholderPanel(title: "观看历史", subtitle: "断点续播")
                .tabItem { Label("观看历史", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            PlaceholderPanel(title: "设置", subtitle: "解码 · 快进 · 缓存 · 字幕")
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
    }
}

private struct PlaceholderPanel: View {
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.027, green: 0.039, blue: 0.071),
                                    Color(red: 0.055, green: 0.082, blue: 0.145)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Text(title)
                    .font(.system(size: 42, weight: .heavy))
                Text(subtitle)
                    .font(.system(size: 22, weight: .medium))
                    .opacity(0.72)
                Text(engineBadge)
                    .font(.system(size: 20, weight: .semibold))
                    .opacity(0.5)
            }
        }
    }

    private var engineBadge: String {
        "FSPlayer \(FSPlayerVersionProvider.version) · 骨架构建"
    }
}

enum FSPlayerVersionProvider {
    static var version: String {
        FSPlayer.playerVersion()
    }
}
