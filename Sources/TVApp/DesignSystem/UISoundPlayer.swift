import Foundation
import AudioToolbox

/// tvOS 没有震动反馈，焦点移动与操作反馈用极短系统音效替代。
public enum UISoundPlayer {
    public static func focusMove() {
        AudioServicesPlaySystemSound(0x450)
    }

    public static func select() {
        AudioServicesPlaySystemSound(0x451)
    }

    public static func error() {
        AudioServicesPlaySystemSound(0x457)
    }
}
