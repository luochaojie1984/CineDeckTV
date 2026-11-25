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
                        AdaptiveGlassContainer(spacing: 12) {
                            HStack(spacing: 14) {
                                ForEach([48, 96, 144, 192], id: \.self) { megabytes in
                                    let selected = env.settings.cacheMegabytes == megabytes
                                    Button {
                                        env.update(settings: mutated { $0.cacheMegabytes = megabytes })
                                    } label: {
                                        HStack(spacing: 8) {
                                            if selected { Image(systemName: "checkmark.circle.fill") }
                                            Text("\(megabytes) MB")
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                    }
                                    .tvAdaptiveGlassButtonStyle(prominent: selected)
                                    .tint(selected ? TVTokens.Color.accent : (nil as Color?))
                                }
                            }
                        }
                        Text("硬上限 192 MB（Jetsam 保护）")
                            .font(TVTokens.Typography.tertiary)
                            .foregroundStyle(TVTokens.Color.secondaryText)
                    }
                    section("自动连播下一集") {
                        AdaptiveGlassContainer(spacing: 12) {
                            HStack(spacing: 14) {
                                Button {
                                    env.update(settings: mutated { $0.autoPlayNextEpisode = true })
                                } label: {
                                    HStack(spacing: 8) {
                                        if env.settings.autoPlayNextEpisode { Image(systemName: "checkmark.circle.fill") }
                                        Text("开")
                                    }
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                                }
                                .tvAdaptiveGlassButtonStyle(prominent: env.settings.autoPlayNextEpisode)
                                .tint(env.settings.autoPlayNextEpisode ? TVTokens.Color.accent : (nil as Color?))

                                Button {
                                    env.update(settings: mutated { $0.autoPlayNextEpisode = false })
                                } label: {
                                    HStack(spacing: 8) {
                                        if !env.settings.autoPlayNextEpisode { Image(systemName: "checkmark.circle.fill") }
                                        Text("关")
                                    }
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                                }
                                .tvAdaptiveGlassButtonStyle(prominent: !env.settings.autoPlayNextEpisode)
                                .tint(!env.settings.autoPlayNextEpisode ? TVTokens.Color.accent : (nil as Color?))
                            }
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 36)
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
                    let isSelected = entry.element.0 == selected
                    Button {
                        onSelect(entry.element.0)
                    } label: {
                        HStack(spacing: 8) {
                            if isSelected { Image(systemName: "checkmark.circle.fill") }
                            Text(entry.element.1)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .tvAdaptiveGlassButtonStyle(prominent: isSelected)
                    .tint(isSelected ? TVTokens.Color.accent : (nil as Color?))
                }
            }
        }
    }
}
