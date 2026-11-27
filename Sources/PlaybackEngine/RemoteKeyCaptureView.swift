import Foundation
import SwiftUI
import UIKit

/// Siri Remote 底层专注捕获控制器（对齐 AuraTV 成熟架构）：
/// 1. 48pt 水平滑动死区 + 横向主轴过滤 + cancelsTouchesInView = false：彻底杜绝大拇指轻搭/微晃误触导致画面自动暂停！
/// 2. 在 pressesBegan / pressesEnded / pressesCancelled 全生命周期吞掉已处理按键（含 .playPause / .select / 方向键），
///    彻底消除按一下 Play/Pause 后松手瞬间再次冒泡给 SwiftUI `.onPlayPauseCommand` 引发的“自动恢复播放”双重触发！
/// 3. HUD / 设置面板弹出时设置 `isCaptureEnabled = false` 交还 SwiftUI Focus Engine，不破坏视图身份、不丢弃手势状态。
public struct RemoteKeyCaptureView: UIViewControllerRepresentable {
    public var isCaptureEnabled: Bool
    public var enableTouchpadScrub: Bool
    public var onShortPress: (_ forward: Bool) -> Void
    public var onLongPressBegan: (_ forward: Bool) -> Void
    public var onLongPressEnded: () -> Void
    public var onTouchpadPanBegan: () -> Void
    public var onTouchpadPanChanged: (_ deltaPoints: CGFloat, _ velocityPointsPerSec: CGFloat) -> Void
    public var onTouchpadPanEnded: () -> Void
    public var onMenu: (() -> Void)?
    public var onPlayPause: () -> Void
    public var onSelect: () -> Void
    public var onShowHUD: () -> Void

    public init(
        isCaptureEnabled: Bool,
        enableTouchpadScrub: Bool = true,
        onShortPress: @escaping (_ forward: Bool) -> Void,
        onLongPressBegan: @escaping (_ forward: Bool) -> Void,
        onLongPressEnded: @escaping () -> Void,
        onTouchpadPanBegan: @escaping () -> Void = {},
        onTouchpadPanChanged: @escaping (_ deltaPoints: CGFloat, _ velocityPointsPerSec: CGFloat) -> Void = { _, _ in },
        onTouchpadPanEnded: @escaping () -> Void = {},
        onMenu: (() -> Void)? = nil,
        onPlayPause: @escaping () -> Void,
        onSelect: @escaping () -> Void,
        onShowHUD: @escaping () -> Void
    ) {
        self.isCaptureEnabled = isCaptureEnabled
        self.enableTouchpadScrub = enableTouchpadScrub
        self.onShortPress = onShortPress
        self.onLongPressBegan = onLongPressBegan
        self.onLongPressEnded = onLongPressEnded
        self.onTouchpadPanBegan = onTouchpadPanBegan
        self.onTouchpadPanChanged = onTouchpadPanChanged
        self.onTouchpadPanEnded = onTouchpadPanEnded
        self.onMenu = onMenu
        self.onPlayPause = onPlayPause
        self.onSelect = onSelect
        self.onShowHUD = onShowHUD
    }

    public func makeUIViewController(context: Context) -> KeyCaptureViewController {
        let vc = KeyCaptureViewController()
        vc.coordinator = context.coordinator
        vc.setCaptureEnabled(isCaptureEnabled, touchpadEnabled: enableTouchpadScrub)
        return vc
    }

    public func updateUIViewController(_ uiViewController: KeyCaptureViewController, context: Context) {
        context.coordinator.parent = self
        uiViewController.setCaptureEnabled(isCaptureEnabled, touchpadEnabled: enableTouchpadScrub)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    public final class Coordinator {
        var parent: RemoteKeyCaptureView
        init(parent: RemoteKeyCaptureView) {
            self.parent = parent
        }
    }

    public final class FocusableCaptureView: UIView {
        var captureActive: Bool = true
        public override var canBecomeFocused: Bool { captureActive }
        public override var canBecomeFirstResponder: Bool { captureActive }
    }

    @MainActor
    public final class KeyCaptureViewController: UIViewController {
        weak var coordinator: Coordinator?
        private let captureView = FocusableCaptureView()

        private var longPressWorkItem: DispatchWorkItem?
        private var pressedDirection: Bool?
        private var didTriggerLongPress: Bool = false
        private let longPressDelay: TimeInterval = 0.18

        private var panGesture: UIPanGestureRecognizer?
        private var isTouchpadScrubbing: Bool = false
        private var lastPanX: CGFloat = 0
        private let panActivationDeadzone: CGFloat = 48.0

        public override func loadView() {
            captureView.backgroundColor = .clear
            self.view = captureView
        }

        public override func viewDidLoad() {
            super.viewDidLoad()
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTouchpadPan(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            pan.cancelsTouchesInView = false
            captureView.addGestureRecognizer(pan)
            self.panGesture = pan
        }

        public override var preferredFocusEnvironments: [UIFocusEnvironment] {
            captureView.captureActive ? [captureView] : []
        }

        public override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            requestFocusIfEnabled()
        }

        func setCaptureEnabled(_ enabled: Bool, touchpadEnabled: Bool) {
            let changed = (captureView.captureActive != enabled)
            captureView.captureActive = enabled
            captureView.isUserInteractionEnabled = enabled
            panGesture?.isEnabled = enabled && touchpadEnabled

            if !enabled {
                resetPress()
                if isTouchpadScrubbing {
                    isTouchpadScrubbing = false
                    coordinator?.parent.onTouchpadPanEnded()
                }
            } else if changed {
                requestFocusIfEnabled()
            }
        }

        private func requestFocusIfEnabled() {
            guard captureView.captureActive else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.captureView.captureActive else { return }
                self.captureView.becomeFirstResponder()
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
        }

        @objc private func handleTouchpadPan(_ gesture: UIPanGestureRecognizer) {
            guard captureView.captureActive,
                  coordinator?.parent.enableTouchpadScrub == true,
                  pressedDirection == nil else {
                return
            }

            switch gesture.state {
            case .began:
                isTouchpadScrubbing = false
                lastPanX = 0

            case .changed:
                let translation = gesture.translation(in: captureView)
                let velocity = gesture.velocity(in: captureView)

                if !isTouchpadScrubbing {
                    // 48pt 横向死区 + 水平主方向判定，杜绝拇指轻放误触暂停
                    if abs(translation.x) >= panActivationDeadzone && abs(translation.x) > abs(translation.y) * 1.4 {
                        isTouchpadScrubbing = true
                        lastPanX = translation.x
                        coordinator?.parent.onTouchpadPanBegan()
                    }
                } else {
                    let dx = translation.x - lastPanX
                    lastPanX = translation.x
                    if abs(dx) > 0.25 {
                        coordinator?.parent.onTouchpadPanChanged(dx, velocity.x)
                    }
                }

            case .ended, .cancelled, .failed:
                if isTouchpadScrubbing {
                    isTouchpadScrubbing = false
                    coordinator?.parent.onTouchpadPanEnded()
                }

            default:
                break
            }
        }

        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard captureView.captureActive else {
                super.pressesBegan(presses, with: event)
                return
            }

            if isTouchpadScrubbing {
                isTouchpadScrubbing = false
                coordinator?.parent.onTouchpadPanEnded()
            }

            for press in presses {
                switch press.type {
                case .leftArrow, .rightArrow:
                    beginPress(forward: press.type == .rightArrow)
                case .upArrow, .downArrow:
                    coordinator?.parent.onShowHUD()
                case .select:
                    coordinator?.parent.onSelect()
                case .playPause:
                    coordinator?.parent.onPlayPause()
                case .menu:
                    if let onMenu = coordinator?.parent.onMenu {
                        onMenu()
                    } else {
                        super.pressesBegan([press], with: event)
                    }
                default:
                    super.pressesBegan([press], with: event)
                }
            }
        }

        public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handlePressRelease(presses: presses, event: event, isCancelled: false)
        }

        public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handlePressRelease(presses: presses, event: event, isCancelled: true)
        }

        private func handlePressRelease(presses: Set<UIPress>, event: UIPressesEvent?, isCancelled: Bool) {
            guard captureView.captureActive else {
                if isCancelled {
                    super.pressesCancelled(presses, with: event)
                } else {
                    super.pressesEnded(presses, with: event)
                }
                return
            }

            for press in presses {
                switch press.type {
                case .leftArrow, .rightArrow:
                    endPress()
                case .upArrow, .downArrow, .select, .playPause:
                    // 吞掉释放事件，防止 playPause 松手时二次冒泡到 SwiftUI onPlayPauseCommand
                    break
                case .menu:
                    if coordinator?.parent.onMenu == nil {
                        if isCancelled {
                            super.pressesCancelled([press], with: event)
                        } else {
                            super.pressesEnded([press], with: event)
                        }
                    }
                default:
                    if isCancelled {
                        super.pressesCancelled([press], with: event)
                    } else {
                        super.pressesEnded([press], with: event)
                    }
                }
            }
        }

        private func beginPress(forward: Bool) {
            pressedDirection = forward
            didTriggerLongPress = false
            longPressWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pressedDirection != nil else { return }
                self.didTriggerLongPress = true
                self.coordinator?.parent.onLongPressBegan(forward)
            }
            longPressWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
        }

        private func endPress() {
            longPressWorkItem?.cancel()
            longPressWorkItem = nil
            guard let forward = pressedDirection else { return }
            if didTriggerLongPress {
                coordinator?.parent.onLongPressEnded()
            } else {
                coordinator?.parent.onShortPress(forward)
            }
            resetPress()
        }

        private func resetPress() {
            longPressWorkItem?.cancel()
            longPressWorkItem = nil
            pressedDirection = nil
            didTriggerLongPress = false
        }
    }
}
