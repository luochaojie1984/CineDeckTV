import SwiftUI
import UIKit

/// 10-foot 聚焦卡片样式：读取 `@Environment(\.isFocused)`，配完整 `contentShape` 确保 tvOS Focus Engine 精准命中每一张卡片。
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
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isFocused ? Color.white.opacity(0.16) : fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isFocused
                                ? LinearGradient(
                                    colors: [Color.white.opacity(0.98), TVTokens.Color.accent.opacity(0.9)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: isFocused ? 3.5 : 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(
                    color: isFocused ? TVTokens.Color.accent.opacity(0.35) : Color.black.opacity(0.35),
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
                .contentShape(RoundedRectangle(cornerRadius: TVTokens.Radius.card, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: TVTokens.Radius.card, style: .continuous)
                        .fill(isFocused ? Color.white.opacity(0.16) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TVTokens.Radius.card, style: .continuous)
                        .strokeBorder(
                            isFocused ? TVTokens.Color.accent.opacity(0.95) : Color.white.opacity(0.10),
                            lineWidth: isFocused ? 3 : 1
                        )
                )
                .shadow(color: isFocused ? TVTokens.Color.accent.opacity(0.28) : .clear, radius: 14, y: 6)
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
