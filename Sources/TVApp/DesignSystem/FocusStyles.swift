import SwiftUI
import UIKit

/// 10-foot 液态玻璃聚焦卡片样式：严格内描边与零越界焦点渲染（不向外膨胀越过边框）。
public struct TVCardButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var fillColor: Color
    public var focusedScale: CGFloat
    public var accentTint: Color

    public init(
        cornerRadius: CGFloat = TVTokens.Radius.card,
        fillColor: Color = TVTokens.Color.cardSurface,
        focusedScale: CGFloat = 1.0,
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
                                        Color.white.opacity(0.98),
                                        accentTint.opacity(0.95),
                                        TVTokens.Color.violet.opacity(0.78)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.22),
                                        Color.white.opacity(0.06),
                                        accentTint.opacity(0.14)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: isFocused ? 3.2 : 1.0
                        )
                )
                .clipShape(shape)
                .shadow(
                    color: isFocused ? accentTint.opacity(0.22) : Color.black.opacity(0.24),
                    radius: isFocused ? 6 : 4,
                    x: 0,
                    y: isFocused ? 3 : 2
                )
                .scaleEffect(configuration.isPressed ? 0.988 : min(1.0, focusedScale))
                .animation(TVTokens.Motion.focus, value: isFocused)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
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
                                        isFocused ? Color.white.opacity(0.16) : fillColor,
                                        accentTint.opacity(isFocused ? 0.22 : 0.04)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .glassEffect(
                        .regular.tint(accentTint.opacity(isFocused ? 0.24 : 0.04)),
                        in: .rect(cornerRadius: cornerRadius)
                    )
                    .overlay(
                        LinearGradient(
                            colors: [Color.white.opacity(isFocused ? 0.20 : 0.05), .clear],
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
                            shape.fill(isFocused ? accentTint.opacity(0.22) : fillColor)
                        }
                    )
            }
        }
    }
}

/// 10-foot 液态玻璃横条树状列表行聚焦样式：严格锁定在边框内部（scale=1.0、无 interactive 溢出光晕、内描边 + 左侧高亮条）。
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
                .overlay(alignment: .leading) {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white, accentTint],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 5)
                            .padding(.vertical, 12)
                            .padding(.leading, 7)
                    }
                }
                .overlay(
                    shape
                        .strokeBorder(
                            isFocused
                                ? LinearGradient(
                                    colors: [Color.white.opacity(0.96), accentTint.opacity(0.95)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: isFocused ? 3.0 : 1.0
                        )
                )
                .clipShape(shape)
                .shadow(color: isFocused ? accentTint.opacity(0.18) : Color.black.opacity(0.16), radius: isFocused ? 5 : 2, y: isFocused ? 2 : 1)
                .scaleEffect(configuration.isPressed ? 0.994 : 1.0)
                .animation(TVTokens.Motion.focus, value: isFocused)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
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
                    .background(
                        shape.fill(
                            isFocused
                                ? LinearGradient(
                                    colors: [Color.white.opacity(0.16), accentTint.opacity(0.24)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.05), Color.white.opacity(0.025)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                        )
                    )
                    .glassEffect(
                        .regular.tint(accentTint.opacity(isFocused ? 0.22 : 0.03)),
                        in: .rect(cornerRadius: TVTokens.Radius.card)
                    )
            } else {
                configuration.label
                    .contentShape(shape)
                    .background(
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            shape.fill(isFocused ? accentTint.opacity(0.22) : Color.white.opacity(0.045))
                        }
                    )
            }
        }
    }
}

/// 播放器底部浮岛 / 底部设置面板专用紧凑胶囊按钮样式：零焦点外溢、左右遥控焦点清晰可见、严格贴合视频内边界。
public struct TVPlayerOptionButtonStyle: ButtonStyle {
    public var isSelected: Bool
    public var accentTint: Color
    public var cornerRadius: CGFloat

    public init(
        isSelected: Bool = false,
        accentTint: Color = TVTokens.Color.accent,
        cornerRadius: CGFloat = 14
    ) {
        self.isSelected = isSelected
        self.accentTint = accentTint
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        PlayerOptionInner(
            configuration: configuration,
            isSelected: isSelected,
            accentTint: accentTint,
            cornerRadius: cornerRadius
        )
    }

    private struct PlayerOptionInner: View {
        let configuration: Configuration
        let isSelected: Bool
        let accentTint: Color
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .foregroundStyle(isFocused ? Color.black : (isSelected ? Color.white : Color.white.opacity(0.88)))
                .background(
                    shape.fill(
                        isFocused
                            ? Color.white
                            : (isSelected ? accentTint.opacity(0.44) : Color.white.opacity(0.11))
                    )
                )
                .overlay(
                    shape.strokeBorder(
                        isFocused
                            ? accentTint
                            : (isSelected ? accentTint.opacity(0.90) : Color.white.opacity(0.18)),
                        lineWidth: isFocused ? 3.5 : (isSelected ? 1.8 : 1.0)
                    )
                )
                .clipShape(shape)
                .shadow(
                    color: isFocused ? Color.white.opacity(0.48) : Color.clear,
                    radius: isFocused ? 7 : 0,
                    x: 0,
                    y: isFocused ? 2 : 0
                )
                .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isFocused)
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
