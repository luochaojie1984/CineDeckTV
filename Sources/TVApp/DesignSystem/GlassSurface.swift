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
    /// 常规液态玻璃面板（抽屉、弹窗、HUD 浮岛、分组卡片），附带左上高光镜面边线。
    @ViewBuilder
    func tvGlassSurface(cornerRadius: CGFloat = 24, clear: Bool = false, tint: Color? = nil) -> some View {
        if #available(tvOS 26.0, *) {
            let rim = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(clear ? 0.34 : 0.28),
                            Color.white.opacity(0.08),
                            (tint ?? TVTokens.Color.accent).opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.1
                )
            if clear {
                self
                    .glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
                    .overlay(rim)
                    .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 10)
            } else if let tint {
                self
                    .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
                    .overlay(rim)
                    .shadow(color: Color.black.opacity(0.34), radius: 22, x: 0, y: 12)
            } else {
                self
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    .overlay(rim)
                    .shadow(color: Color.black.opacity(0.34), radius: 22, x: 0, y: 12)
            }
        } else {
            self
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.16))
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.07), (tint ?? TVTokens.Color.accent).opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.1
                        )
                )
                .shadow(color: Color.black.opacity(0.34), radius: 20, x: 0, y: 10)
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
                .overlay(Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 1))
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
