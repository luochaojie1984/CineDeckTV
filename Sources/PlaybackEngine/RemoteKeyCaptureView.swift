import Foundation
import UIKit

/// Siri Remote 底层捕获：区分短按（跳秒）、长按（连续加速）、Menu 与播放暂停。
/// HUD 或抽屉弹出时必须把 isCaptureEnabled 置 false，并把 allowsHitTesting 关掉，
/// 否则会把焦点从 SwiftUI 控件上抢走（设计规划 6.4 #19）。
@MainActor
public final class RemoteKeyCaptureView: UIView {
    public var isCaptureEnabled = true { didSet { if !isCaptureEnabled { resetPress() } } }

    public var onShortPress: ((_ forward: Bool) -> Void)?
    public var onLongPressBegan: ((_ forward: Bool) -> Void)?
    public var onLongPressEnded: (() -> Void)?
    public var onMenu: (() -> Void)?
    public var onPlayPause: (() -> Void)?
    public var onSelect: (() -> Void)?

    public var longPressDelay: TimeInterval = 0.18

    private var pressedDirection: Bool?
    private var pressStartedAt: CFTimeInterval = 0
    private var didTriggerLongPress = false
    private var longPressWorkItem: DispatchWorkItem?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var canBecomeFocused: Bool { true }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isCaptureEnabled else {
            super.pressesBegan(presses, with: event)
            return
        }
        for press in presses {
            switch press.type {
            case .leftArrow, .rightArrow:
                beginPress(forward: press.type == .rightArrow)
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
        pressStartedAt = CACurrentMediaTime()
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
