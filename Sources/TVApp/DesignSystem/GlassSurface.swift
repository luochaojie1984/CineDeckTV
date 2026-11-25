import SwiftUI

/// 兼容容器：tvOS 26+ 用原生 GlassEffectContainer（合成优化 + 流体融合），低版本透明透传。
public struct AdaptiveGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    public init(spacing: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        if #available(tvOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

public extension View {
    /// 常规玻璃面板（抽屉、弹窗、HUD 浮岛、摘要条）。
    @ViewBuilder
    func tvGlassSurface(cornerRadius: CGFloat = 24, clear: Bool = false) -> some View {
        if #available(tvOS 26.0, *) {
            if clear {
                self.glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )
        }
    }

    /// 交互式玻璃胶囊（调用前必须先加 padding / frame）。
    @ViewBuilder
    func tvInteractiveGlassCapsule(tint: Color? = nil) -> some View {
        if #available(tvOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
            } else {
                self.glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            self
                .background((tint?.opacity(0.32) ?? Color.white.opacity(0.14)), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        }
    }

    @ViewBuilder
    func tvAdaptiveGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(tvOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    @ViewBuilder
    func tvGlassMorphID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(tvOS 26.0, *) {
            self.glassEffectID(id, in: namespace).glassEffectTransition(.matchedGeometry)
        } else {
            self
        }
    }
}
