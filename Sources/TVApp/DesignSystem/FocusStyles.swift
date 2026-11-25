import SwiftUI

/// 内容卡片焦点样式：微抬高光描边 + 环境投影，保持轻量（网格内几十上百张卡不能上玻璃材质）。
public struct TVCardButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(TVTokens.Motion.focus, value: configuration.isPressed)
    }
}

public struct TVFocusableCard<Content: View>: View {
    @FocusState private var focused: Bool
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        content()
            .padding(TVTokens.Spacing.cardInner)
            .background(
                RoundedRectangle(cornerRadius: TVTokens.Radius.card, style: .continuous)
                    .fill(TVTokens.Color.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TVTokens.Radius.card, style: .continuous)
                    .strokeBorder(focused ? Color.white.opacity(0.85) : Color.white.opacity(0.08),
                                  lineWidth: focused ? 2 : 1)
            )
            .shadow(color: .black.opacity(focused ? 0.55 : 0.2), radius: focused ? 22 : 8, y: focused ? 12 : 4)
            .scaleEffect(focused ? 1.04 : 1.0)
            .animation(TVTokens.Motion.focus, value: focused)
            .focusable()
            .focused($focused)
    }
}
