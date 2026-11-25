import SwiftUI

/// 10-foot 聚焦卡片样式：真正读取 `@Environment(\.isFocused)`，聚焦时微放大（1.045）、高光描边、环境投影并播放轻系统音。
public struct TVCardButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var fillColor: Color
    public var focusedScale: CGFloat

    public init(
        cornerRadius: CGFloat = TVTokens.Radius.card,
        fillColor: Color = TVTokens.Color.cardSurface,
        focusedScale: CGFloat = 1.045
    ) {
        self.cornerRadius = cornerRadius
        self.fillColor = fillColor
        self.focusedScale = focusedScale
    }

    public func makeBody(configuration: Configuration) -> some View {
        FocusCardInner(
            configuration: configuration,
            cornerRadius: cornerRadius,
            fillColor: fillColor,
            focusedScale: focusedScale
        )
    }

    private struct FocusCardInner: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let fillColor: Color
        let focusedScale: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isFocused ? Color.white.opacity(0.14) : fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isFocused
                                ? LinearGradient(
                                    colors: [Color.white.opacity(0.95), TVTokens.Color.accent.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: isFocused ? 3 : 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(
                    color: isFocused ? TVTokens.Color.accent.opacity(0.32) : Color.black.opacity(0.35),
                    radius: isFocused ? 22 : 8,
                    x: 0,
                    y: isFocused ? 12 : 4
                )
                .scaleEffect(configuration.isPressed ? 0.985 : (isFocused ? focusedScale : 1.0))
                .animation(TVTokens.Motion.focus, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onChange(of: isFocused) { _, nowFocused in
                    if nowFocused { UISoundPlayer.focusMove() }
                }
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { UISoundPlayer.select() }
                }
        }
    }
}

/// 10-foot 列表行聚焦样式。
public struct TVListRowButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        FocusRowInner(configuration: configuration)
    }

    private struct FocusRowInner: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: TVTokens.Radius.card, style: .continuous)
                        .fill(isFocused ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TVTokens.Radius.card, style: .continuous)
                        .strokeBorder(
                            isFocused ? TVTokens.Color.accent.opacity(0.9) : Color.white.opacity(0.10),
                            lineWidth: isFocused ? 2.5 : 1
                        )
                )
                .shadow(color: isFocused ? TVTokens.Color.accent.opacity(0.25) : .clear, radius: 14, y: 6)
                .scaleEffect(configuration.isPressed ? 0.99 : (isFocused ? 1.02 : 1.0))
                .animation(TVTokens.Motion.focus, value: isFocused)
                .onChange(of: isFocused) { _, nowFocused in
                    if nowFocused { UISoundPlayer.focusMove() }
                }
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { UISoundPlayer.select() }
                }
        }
    }
}
