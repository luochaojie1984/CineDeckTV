import Foundation
import AVKit
import UIKit
import CoreMedia

/// 驱动 tvOS `AVDisplayManager`：按片源真实帧率/动态范围匹配电视刷新率（23.976/24/50/60 Hz），退出播放后还原默认。
@MainActor
public final class DisplayModeCoordinator {
    public static let shared = DisplayModeCoordinator()

    /// Retain an explicit Objective-C class reference in AVKit.framework so ld_prime never strips AVKit linkage.
    private static let retainedAVKitClass: AnyClass = AVDisplayManager.self
    private var lastAppliedRate: Float = 0
    private var lastAppliedFormatDesc: CMFormatDescription?
    private var lastAppliedFallbackKey: String?

    private init() {}

    private func resolveManager() -> AVDisplayManager? {
        _ = Self.retainedAVKitClass
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            guard let window = scene.windows.first,
                  window.responds(to: Selector(("avDisplayManager"))) else { continue }
            return window.avDisplayManager
        }
        return nil
    }

    public func apply(refreshRate: Float, formatDescription: CMFormatDescription? = nil, width: Int32 = 3840, height: Int32 = 2160, isHEVC: Bool = true) {
        guard let manager = resolveManager() else { return }
        let rate: Float = (refreshRate.isFinite && refreshRate > 1) ? refreshRate : 60
        if let formatDescription {
            if abs(rate - lastAppliedRate) < 0.05,
               let prev = lastAppliedFormatDesc,
               CMFormatDescriptionEqual(prev, otherFormatDescription: formatDescription) {
                return
            }
            lastAppliedRate = rate
            lastAppliedFormatDesc = formatDescription
            lastAppliedFallbackKey = nil
            manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: formatDescription)
            return
        }
        guard width > 0, height > 0 else { return }
        let key = "\(Int((rate * 100).rounded()))-\(width)x\(height)-\(isHEVC)"
        if key == lastAppliedFallbackKey {
            return
        }
        lastAppliedRate = rate
        lastAppliedFormatDesc = nil
        lastAppliedFallbackKey = key
        // FSPlayer 路径下构造有效视频格式描述以触发 Match Frame Rate（不强改 SDR/HDR，以免误切）
        var desc: CMVideoFormatDescription?
        let codec: CMVideoCodecType = isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: max(320, width),
            height: max(240, height),
            extensions: nil,
            formatDescriptionOut: &desc
        )
        if let desc {
            manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: desc)
        }
    }

    public func reset() {
        lastAppliedRate = 0
        lastAppliedFormatDesc = nil
        lastAppliedFallbackKey = nil
        resolveManager()?.preferredDisplayCriteria = nil
    }
}
