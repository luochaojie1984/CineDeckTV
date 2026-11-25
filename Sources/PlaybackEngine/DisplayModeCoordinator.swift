import Foundation
import AVFoundation
import CoreMedia

/// 帧率匹配：计算视频轨刷新率，供 tvOS 的显示匹配（AVDisplayManager）消费。
/// 注：tvOS SDK 的 AVPlayerItem 没有 preferredDisplayCriteria 属性，
/// 该能力由 AVDisplayManager 提供（需 windowScene），因此这里只做纯计算，不引用不存在的 API。
public enum DisplayModeCoordinator {
    public static func refreshRate(for track: AVAssetTrack) async -> Float {
        guard let frameDuration = try? await track.load(.minFrameDuration),
              frameDuration.isValid,
              frameDuration.seconds > 0 else { return 0 }
        return Float((1.0 / frameDuration.seconds).rounded())
    }

    /// 24 / 25 / 30 / 50 / 60 的最近档位（用于给用户显示"已匹配 24Hz"）。
    public static func nominalRate(_ raw: Float) -> Float {
        let candidates: [Float] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
        return candidates.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? raw
    }
}
