import SwiftUI
import UIKit

/// 10-foot 液态玻璃聚焦卡片样式：tvOS 26+ 原生 `.glassEffect(.regular.tint().interactive())` + 镜面光泽边框 + 柔和弹性悬停。
public struct TVCardButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var fillColor: Color
    public var focusedScale: CGFloat
    public var accentTint: Color

    public init(
        cornerRadius: CGFloat = TVTokens.Radius.card,
        fillColor: Color = TVTokens.Color.cardSurface,
        focusedScale: CGFloat = 1.032,
        accentTint: Color = TVTokens.Color.accent
    ) {
        self.cornerRadius = cornerRadius
        self.fillColor = fillColor
        self.focusedScale = focusedScale
        self.accentTint = accentTint
    }

    public func makeBody(configuration: Configuration) -> some View {
        FocusCardInner(
            configuration: configuration,
            cornerRadius: cornerRadius,
            fillColor: fillColor,
            focusedScale: focusedScale,
            accentTint: accentTint
        )
    }

    private struct FocusCardInner: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let fillColor: Color
        let focusedScale: CGFloat
        let accentTint: Color
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            cardSurface(shape: shape)
                .overlay(
                    shape
                        .strokeBorder(
                            isFocused
                                ? LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.96),
                                        accentTint.opacity(0.92),
                                        TVTokens.Color.violet.opacity(0.75)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.24),
                                        Color.white.opacity(0.06),
                                        accentTint.opacity(0.14)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: isFocused ? 2.8 : 1.0
                        )
                )
                .clipShape(shape)
                .shadow(
                    color: isFocused ? accentTint.opacity(0.36) : Color.black.opacity(0.32),
                    radius: isFocused ? 18 : 10,
                    x: 0,
                    y: isFocused ? 10 : 5
                )
                .scaleEffect(configuration.isPressed ? 0.985 : (isFocused ? focusedScale : 1.0))
                .offset(y: isFocused ? -3 : 0)
                .animation(TVTokens.Motion.focus, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onChange(of: isFocused) { _, nowFocused in
                    if nowFocused { UISoundPlayer.focusMove() }
                }
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { UISoundPlayer.select() }
                }
        }

        @ViewBuilder
        private func cardSurface(shape: RoundedRectangle) -> some View {
            if #available(tvOS 26.0, *) {
                configuration.label
                    .contentShape(shape)
                    .background(
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        isFocused ? Color.white.opacity(0.12) : fillColor,
                                        accentTint.opacity(isFocused ? 0.14 : 0.04)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .glassEffect(
                        .regular.tint(accentTint.opacity(isFocused ? 0.22 : 0.05)).interactive(),
                        in: .rect(cornerRadius: cornerRadius)
                    )
                    .overlay(
                        LinearGradient(
                            colors: [Color.white.opacity(isFocused ? 0.18 : 0.05), .clear],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                        .allowsHitTesting(false)
                    )
            } else {
                configuration.label
                    .contentShape(shape)
                    .background(
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            shape.fill(isFocused ? accentTint.opacity(0.18) : fillColor)
                        }
                    )
            }
        }
    }
}

/// 10-foot 液态玻璃列表行聚焦样式。
public struct TVListRowButtonStyle: ButtonStyle {
    public var accentTint: Color

    public init(accentTint: Color = TVTokens.Color.accent) {
        self.accentTint = accentTint
    }

    public func makeBody(configuration: Configuration) -> some View {
        FocusRowInner(configuration: configuration, accentTint: accentTint)
    }

    private struct FocusRowInner: View {
        let configuration: Configuration
        let accentTint: Color
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: TVTokens.Radius.card, style: .continuous)
            rowSurface(shape: shape)
                .overlay(
                    shape
                        .strokeBorder(
                            isFocused
                                ? LinearGradient(
                                    colors: [Color.white.opacity(0.92), accentTint.opacity(0.95)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: isFocused ? 2.5 : 1.0
                        )
                )
                .clipShape(shape)
                .shadow(color: isFocused ? accentTint.opacity(0.28) : Color.black.opacity(0.22), radius: isFocused ? 14 : 6, y: isFocused ? 8 : 3)
                .scaleEffect(configuration.isPressed ? 0.99 : (isFocused ? 1.015 : 1.0))
                .animation(TVTokens.Motion.focus, value: isFocused)
                .onChange(of: isFocused) { _, nowFocused in
                    if nowFocused { UISoundPlayer.focusMove() }
                }
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { UISoundPlayer.select() }
                }
        }

        @ViewBuilder
        private func rowSurface(shape: RoundedRectangle) -> some View {
            if #available(tvOS 26.0, *) {
                configuration.label
                    .contentShape(shape)
                    .background(shape.fill(isFocused ? accentTint.opacity(0.12) : Color.white.opacity(0.045)))
                    .glassEffect(
                        .regular.tint(accentTint.opacity(isFocused ? 0.20 : 0.04)).interactive(),
                        in: .rect(cornerRadius: TVTokens.Radius.card)
                    )
            } else {
                configuration.label
                    .contentShape(shape)
                    .background(
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            shape.fill(isFocused ? accentTint.opacity(0.16) : Color.white.opacity(0.05))
                        }
                    )
            }
        }
    }
}

/// UIKit 响应链层硬件 Menu/Back 拦截器：
/// 当 `isEnabled == true` 时把 `UIPress.PressType.menu` 绑定到宿主 `UIViewController.view`，
/// 确保无论当前焦点停在哪个子视图或工具栏，按 Siri Remote 返回键都会触发应用内逐级返回，绝不误退回 Apple TV 桌面。
/// 当 `isEnabled == false`（如首页根视图、或已打开系统 `.sheet` / `NavigationStack` 子页），放行系统原生返回逻辑。
public struct TVMenuBackOverlay: UIViewRepresentable {
    public let isEnabled: Bool
    public let onMenu: () -> Void

    public init(isEnabled: Bool, onMenu: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.onMenu = onMenu
    }

    public func makeUIView(context: Context) -> MenuInterceptorView {
        let v = MenuInterceptorView()
        v.onMenu = onMenu
        v.isInterceptorEnabled = isEnabled
        return v
    }

    public func updateUIView(_ uiView: MenuInterceptorView, context: Context) {
        uiView.onMenu = onMenu
        uiView.isInterceptorEnabled = isEnabled
    }

    @MainActor
    public final class MenuInterceptorView: UIView {
        public var onMenu: (() -> Void)?
        public var isInterceptorEnabled = false {
            didSet { recognizer?.isEnabled = isInterceptorEnabled }
        }

        private weak var attachedHostView: UIView?
        private var recognizer: UITapGestureRecognizer?

        public override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                installIfNeeded()
            } else {
                removeIfNeeded()
            }
        }

        private func installIfNeeded() {
            guard recognizer == nil else {
                recognizer?.isEnabled = isInterceptorEnabled
                return
            }
            var resp: UIResponder? = self
            var hostVC: UIViewController?
            while let next = resp?.next {
                if let vc = next as? UIViewController {
                    hostVC = vc
                    break
                }
                resp = next
            }
            guard let hostView = hostVC?.view ?? window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleMenuPress))
            tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            tap.cancelsTouchesInView = true
            tap.isEnabled = isInterceptorEnabled
            hostView.addGestureRecognizer(tap)
            self.attachedHostView = hostView
            self.recognizer = tap
        }

        private func removeIfNeeded() {
            if let tap = recognizer, let host = attachedHostView {
                host.removeGestureRecognizer(tap)
            }
            recognizer = nil
            attachedHostView = nil
        }

        @objc private func handleMenuPress() {
            UISoundPlayer.select()
            onMenu?()
        }
    }
}
