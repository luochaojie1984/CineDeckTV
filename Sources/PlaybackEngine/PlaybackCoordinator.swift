import Foundation
import UIKit

/// 引擎路由：默认 FSPlayer 优先，加载失败（无 codec / 打开失败 / 解码致命错误）
/// 自动回退 AVPlayer；也支持用户在抽屉里手动锁定内核。
@MainActor
public final class PlaybackCoordinator: ObservableObject {
    public enum EngineKind: String, Sendable {
        case fsplayer, avplayer, automatic
        public var displayName: String {
            switch self {
            case .fsplayer: return "FSPlayer"
            case .avplayer: return "AVPlayer"
            case .automatic: return "自动"
            }
        }
    }

    @Published public private(set) var activeEngine: EngineKind = .automatic
    @Published public private(set) var lastError: String?
    @Published public private(set) var isPlaying = false

    public let fsEngine = FSPlayerEngineAdapter()
    public let avEngine = AVPlayerEngineAdapter()

    private var current: (any PlayerEngine)?
    private var currentURL: String?
    private var currentStartAt: TimeInterval = 0
    private var currentOptions = EngineLoadOptions()

    public init() {
        fsEngine.onFinish = { [weak self] in self?.handleFinish() }
        avEngine.onFinish = { [weak self] in self?.handleFinish() }
    }

    public var engine: (any PlayerEngine)? { current }
    public var currentTime: TimeInterval { current?.currentTime ?? 0 }
    public var duration: TimeInterval { current?.duration ?? 0 }

    /// 载入并起播；preference 决定是否允许回退。
    public func load(url: String, startAt: TimeInterval, options: EngineLoadOptions, preference: EngineKind = .automatic) {
        currentURL = url
        currentStartAt = startAt
        currentOptions = options
        lastError = nil

        switch preference {
        case .avplayer:
            startAV(url: url, startAt: startAt, options: options)
        case .fsplayer:
            startFS(url: url, startAt: startAt, options: options, allowFallback: false)
        case .automatic:
            startFS(url: url, startAt: startAt, options: options, allowFallback: true)
        }
    }

    public func play() {
        current?.play()
        isPlaying = true
    }

    public func pause() {
        current?.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval, accurate: Bool = false) {
        current?.seek(to: time, accurate: accurate)
    }

    public func shutdown() {
        current?.shutdown()
        current = nil
        isPlaying = false
    }

    /// 硬解/软解热切换（仅 FSPlayer 生效）。
    @discardableResult
    public func switchDecoder(hardware: Bool) -> Bool {
        fsEngine.switchDecoder(hardware: hardware)
    }

    private func startFS(url: String, startAt: TimeInterval, options: EngineLoadOptions, allowFallback: Bool) {
        do {
            try fsEngine.load(url: url, startAt: startAt, options: options)
            current = fsEngine
            activeEngine = .fsplayer
            isPlaying = true
        } catch {
            lastError = error.localizedDescription
            if allowFallback {
                startAV(url: url, startAt: startAt, options: options)
            }
        }
    }

    private func startAV(url: String, startAt: TimeInterval, options: EngineLoadOptions) {
        do {
            try avEngine.load(url: url, startAt: startAt, options: options)
            current = avEngine
            activeEngine = .avplayer
            isPlaying = true
        } catch {
            lastError = error.localizedDescription
            current = nil
            isPlaying = false
        }
    }

    private func handleFinish() {
        isPlaying = false
    }
}
