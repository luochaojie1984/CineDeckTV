import Foundation
import AVKit
import UIKit
import CoreMedia

/// 驱动 tvOS `AVDisplayManager`：按片源真实帧率/动态范围匹配电视刷新率（23.976/24/50/60 Hz），退出播放后还原默认。
@MainActor
public final class DisplayModeCoordinator {
    public static let shared = DisplayModeCoordinator()

    private init() {}

    private func resolveManager() -> AVDisplayManager? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let manager = scene.windows.first?.avDisplayManager {
                return manager
            }
        }
        return nil
    }

    public func apply(refreshRate: Float, formatDescription: CMFormatDescription? = nil, width: Int32 = 3840, height: Int32 = 2160, isHEVC: Bool = true) {
        guard let manager = resolveManager() else { return }
        let rate: Float = refreshRate > 1 ? refreshRate : 60
        if let formatDescription {
            manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: formatDescription)
            return
        }
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
        resolveManager()?.preferredDisplayCriteria = nil
    }
}
