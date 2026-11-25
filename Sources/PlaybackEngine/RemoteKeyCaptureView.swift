import Foundation
import UIKit

/// Siri Remote 底层捕获：区分短按（跳秒）、长按（连续加速）、触控板左右划动、Menu、上键呼出面板与播放暂停。
/// HUD 或抽屉弹出时必须把 isCaptureEnabled 置 false 并关闭 allowsHitTesting，绝不抢 SwiftUI 控件焦点。
@MainActor
public final class RemoteKeyCaptureView: UIView {
    public var isCaptureEnabled = true { didSet { if !isCaptureEnabled { resetPress() } } }

    public var onShortPress: ((_ forward: Bool) -> Void)?
    public var onLongPressBegan: ((_ forward: Bool) -> Void)?
    public var onLongPressEnded: (() -> Void)?
    public var onTouchpadPanBegan: (() -> Void)?
    public var onTouchpadPanChanged: ((_ deltaSeconds: Double) -> Void)?
    public var onTouchpadPanEnded: (() -> Void)?
    public var onMenu: (() -> Void)?
    public var onPlayPause: (() -> Void)?
    public var onSelect: (() -> Void)?
    public var onShowHUD: (() -> Void)?

    public var longPressDelay: TimeInterval = 0.18

    private var pressedDirection: Bool?
    private var didTriggerLongPress = false
    private var longPressWorkItem: DispatchWorkItem?
    private var panAccumulatedDelta: Double = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTouchpadPan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        addGestureRecognizer(pan)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var canBecomeFocused: Bool { true }

    @objc private func handleTouchpadPan(_ recognizer: UIPanGestureRecognizer) {
        guard isCaptureEnabled else { return }
        let translationX = recognizer.translation(in: self).x
        switch recognizer.state {
        case .began:
            panAccumulatedDelta = 0
            onTouchpadPanBegan?()
        case .changed:
            // 将触控板横向位移平滑映射为进度秒数（~120pt ≈ 30s）
            let deltaSec = Double(translationX) * 0.25
            panAccumulatedDelta = deltaSec
            onTouchpadPanChanged?(deltaSec)
        case .ended, .cancelled, .failed:
            panAccumulatedDelta = 0
            onTouchpadPanEnded?()
        default:
            break
        }
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isCaptureEnabled else {
            super.pressesBegan(presses, with: event)
            return
        }
        for press in presses {
            switch press.type {
            case .leftArrow, .rightArrow:
                beginPress(forward: press.type == .rightArrow)
            case .upArrow, .downArrow:
                onShowHUD?()
            case .select:
                onSelect?()
            case .playPause:
                onPlayPause?()
            case .menu:
                onMenu?()
            default:
                break
            }
        }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isCaptureEnabled else {
            super.pressesEnded(presses, with: event)
            return
        }
        for press in presses where press.type == .leftArrow || press.type == .rightArrow {
            endPress()
        }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endPress()
        super.pressesCancelled(presses, with: event)
    }

    private func beginPress(forward: Bool) {
        pressedDirection = forward
        didTriggerLongPress = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pressedDirection != nil else { return }
            self.didTriggerLongPress = true
            self.onLongPressBegan?(forward)
        }
        longPressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
    }

    private func endPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        guard let forward = pressedDirection else { return }
        if didTriggerLongPress {
            onLongPressEnded?()
        } else {
            onShortPress?(forward)
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
