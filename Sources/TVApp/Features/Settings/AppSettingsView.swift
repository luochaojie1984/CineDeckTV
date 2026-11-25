import SwiftUI
import AppPreferences

public struct AppSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    public init() {}

    public var body: some View {
        ZStack {
            TVTokens.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text("设置").font(TVTokens.Typography.pageTitle)
                    section("播放内核") {
                        choiceRow(keys: AppSettings.EnginePreference.allCases.map { ($0, $0.displayName) },
                                  selected: env.settings.enginePreference) { value in
                            env.update(settings: mutated { $0.enginePreference = value })
                        }
                    }
                    section("解码方式") {
                        choiceRow(keys: AppSettings.DecodePreference.allCases.map { ($0, $0.displayName) },
                                  selected: env.settings.decodePreference) { value in
                            env.update(settings: mutated { $0.decodePreference = value })
                        }
                    }
                    section("快进手感") {
                        choiceRow(keys: AppSettings.ScrubMode.allCases.map { ($0, $0.displayName) },
                                  selected: env.settings.scrubMode) { value in
                            env.update(settings: mutated { $0.scrubMode = value })
                        }
                    }
                    section("缓存上限") {
                        HStack(spacing: 14) {
                            ForEach([48, 96, 144, 192], id: \.self) { megabytes in
                                Button("\(megabytes) MB") {
                                    env.update(settings: mutated { $0.cacheMegabytes = megabytes })
                                }
                                .tvAdaptiveGlassButtonStyle(prominent: env.settings.cacheMegabytes == megabytes)
                            }
                        }
                        Text("硬上限 192 MB（Jetsam 保护）")
                            .font(TVTokens.Typography.tertiary)
                            .foregroundStyle(TVTokens.Color.secondaryText)
                    }
                    section("自动连播下一集") {
                        HStack(spacing: 14) {
                            Button("开") { env.update(settings: mutated { $0.autoPlayNextEpisode = true }) }
                                .tvAdaptiveGlassButtonStyle(prominent: env.settings.autoPlayNextEpisode)
                            Button("关") { env.update(settings: mutated { $0.autoPlayNextEpisode = false }) }
                                .tvAdaptiveGlassButtonStyle(prominent: !env.settings.autoPlayNextEpisode)
                        }
                    }
                }
                .padding(40)
            }
        }
    }

    private func mutated(_ transform: (inout AppSettings) -> Void) -> AppSettings {
        var copy = env.settings
        transform(&copy)
        return copy
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(TVTokens.Typography.sectionTitle)
            content()
        }
        .focusSection()
    }

    @ViewBuilder
    private func choiceRow<T: Hashable>(keys: [(T, String)], selected: T, onSelect: @escaping (T) -> Void) -> some View {
        AdaptiveGlassContainer(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(Array(keys.enumerated()), id: \.offset) { entry in
                    Button(entry.element.1) { onSelect(entry.element.0) }
                        .tvAdaptiveGlassButtonStyle(prominent: entry.element.0 == selected)
                }
            }
        }
    }
}
