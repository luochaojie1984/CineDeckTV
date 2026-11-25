import Foundation
import AVFoundation
import CoreMedia

/// 帧率与动态范围匹配：tvOS 用 AVPlayerItem.preferredDisplayCriteria（AVDisplayCriteria）。
/// FSPlayer 路径下拿不到 CMFormatDescription 时跳过，不影响播放。
public enum DisplayModeCoordinator {
    public static func criteria(for track: AVAssetTrack) async -> AVDisplayCriteria? {
        guard let formatDescription = track.formatDescriptions.first as? CMFormatDescription else { return nil }
        var refreshRate: Float = 0
        if let frameDuration = try? await track.load(.minFrameDuration), frameDuration.isValid, frameDuration.seconds > 0 {
            refreshRate = Float((1.0 / frameDuration.seconds).rounded())
        }
        guard refreshRate > 0 else { return nil }
        return AVDisplayCriteria(refreshRate: refreshRate, formatDescription: formatDescription)
    }

    public static func apply(to item: AVPlayerItem, track: AVAssetTrack) async {
        guard let criteria = await criteria(for: track) else { return }
        await MainActor.run {
            item.preferredDisplayCriteria = criteria
        }
    }
}
