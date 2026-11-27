import Foundation
import UIKit
import CoreGraphics
import SubtitleKit
@preconcurrency import FSPlayer

/// 主播放内核（FSPlayer 1.1.3 / FFmpeg 7.1 + VideoToolbox + Metal + libass）。
@MainActor
public final class FSPlayerEngineAdapter: PlayerEngine {
    public private(set) var layerRevision = 0
    public private(set) var isHardwareDecodeEnabled = true
    public private(set) var isBuffering = false
    public private(set) var isPrepared = false

    public var onStateChange: ((String) -> Void)?
    public var onTimeUpdate: ((_ position: TimeInterval, _ duration: TimeInterval) -> Void)?
    public var onTracksChanged: ((_ audio: [MediaTrackItem], _ subtitles: [MediaTrackItem]) -> Void)?
    public var onPrepared: (() -> Void)?
    public var onFirstFrameRendered: (() -> Void)?
    public var onFinish: (() -> Void)?
    public var onError: ((String) -> Void)?

    private var player: FSPlayer?
    private var renderView: (UIView & FSVideoRenderingProtocol)?
    private var observerTokens: [NSObjectProtocol] = []
    private var seekPreviewContinuation: CheckedContinuation<Void, Never>?
    private var seekPreviewTimeoutTask: Task<Void, Never>?
    private var pendingResumeSeekTime: TimeInterval?
    private var pendingSubtitleStyle: SubtitleStyleConfig?
    private var lastAppliedSubtitleDelay: Float = 0
    private var didReportTerminalFinish = false

    public init() {}

    public var isPlaying: Bool { player?.isPlaying() ?? false }
    public var currentTime: TimeInterval { max(0, player?.currentPlaybackTime ?? 0) }

    /// 注意：FSPlayer.m 第 982 行已把内部毫秒除以 1000 返回秒！绝对不能再除以 1000.0。
    public var duration: TimeInterval { max(0, player?.duration ?? 0) }

    public func load(url: String, startAt: TimeInterval, options: EngineLoadOptions) throws {
        shutdown()
        didReportTerminalFinish = false
        isPrepared = false
        isBuffering = true
        isHardwareDecodeEnabled = options.hardwareDecode

        let fsOptions = FSOptions.byDefault()
        fsOptions.automaticallySetupAudioSession = true
        fsOptions.currentPlaybackTimeNotificationInterval = 0.25
        fsOptions.setPlayerOptionIntValue(options.hardwareDecode ? 1 : 0, forKey: "videotoolbox_hwaccel")
        // 关键修复：tvOS 上必须保持 copy_hw_frame = 0（零拷贝 CVPixelBuffer）；设为 1 会触发 av_hwframe_map 失败并破坏视频帧！
        fsOptions.setPlayerOptionIntValue(0, forKey: "copy_hw_frame")
        fsOptions.setPlayerOptionIntValue(0, forKey: "sn")
        fsOptions.setPlayerOptionIntValue(1, forKey: "subtitle_mix")
        fsOptions.setPlayerOptionIntValue(60, forKey: "max-fps")
        fsOptions.setPlayerOptionIntValue(1, forKey: "packet-buffering")
        fsOptions.setPlayerOptionIntValue(1, forKey: "framedrop")
        fsOptions.setPlayerOptionIntValue(1, forKey: "start-on-prepared")
        fsOptions.setPlayerOptionIntValue(0, forKey: "enable-accurate-seek")
        fsOptions.setPlayerOptionIntValue(800, forKey: "accurate-seek-timeout")
        fsOptions.setPlayerOptionIntValue(Int64(max(16 * 1024 * 1024, min(64 * 1024 * 1024, options.cacheBytes / 2))), forKey: "max-buffer-size")
        fsOptions.setFormatOptionIntValue(2 * 1024 * 1024, forKey: "probesize")
        fsOptions.setFormatOptionIntValue(2_000_000, forKey: "analyzeduration")
        fsOptions.setFormatOptionIntValue(15_000_000, forKey: "timeout")
        fsOptions.setFormatOptionValue("fastseek", forKey: "fflags")
        fsOptions.setFormatOptionIntValue(1, forKey: "reconnect")
        // LocalHTTPStreamProxy 每条请求返回 Connection: close，禁止复用已关闭短连接
        fsOptions.setFormatOptionValue("0", forKey: "http_persistent")

        // Open cleanly from t=0 and seek right after prepared to avoid seek-at-start resume hangs.
        self.pendingResumeSeekTime = startAt > 0.5 ? startAt : nil

        let metalView = FSVideoRenderView.createMetalRenderView()
        metalView.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let fsPlayer = FSPlayer(content: url, options: fsOptions, videoRendering: metalView)
        fsPlayer.shouldAutoplay = true
        fsPlayer.playbackRate = Float(options.playbackRate)
        fsPlayer.scalingMode = mapScaling(options.scaling)
        fsPlayer.enableAccurateSeek(false)

        self.renderView = metalView
        self.player = fsPlayer
        installObservers(for: fsPlayer)
        layerRevision &+= 1
        fsPlayer.prepareToPlay()
        onStateChange?("缓冲中…")
    }

    public func play() { player?.play() }
    public func pause() { player?.pause() }

    public func seek(to time: TimeInterval, accurate: Bool) {
        guard let player else { return }
        player.enableAccurateSeek(accurate)
        let clamped = duration > 0 ? min(max(0, time), max(0, duration - 0.5)) : max(0, time)
        player.currentPlaybackTime = clamped
    }

    /// 单飞关键帧预览跳转：发送快速帧 seek 后等待首帧渲染通知（带 260ms 防卡死超时保护），返回真实渲染时刻。
    public func seekToKeyframePreview(at time: TimeInterval, timeoutMs: UInt64 = 260) async -> TimeInterval {
        guard let player else { return time }
        completeSeekPreview()
        player.enableAccurateSeek(false)
        let clamped = duration > 0 ? min(max(0, time), max(0, duration - 0.5)) : max(0, time)
        player.currentPlaybackTime = clamped

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.seekPreviewContinuation = continuation
            self.seekPreviewTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                self?.completeSeekPreview()
            }
        }
        let actual = player.currentPlaybackTime
        return (actual.isFinite && actual >= 0) ? actual : clamped
    }

    public func stepToNextFrame() {
        player?.stepToNextFrame()
    }

    public func setPlaybackRate(_ rate: Double) {
        player?.playbackRate = Float(min(4.0, max(0.25, rate)))
    }

    public func setScalingMode(_ scaling: ScalingMode) {
        player?.scalingMode = mapScaling(scaling)
    }

    public func setMuted(_ muted: Bool) {
        player?.playbackVolume = muted ? 0 : 1
    }

    @discardableResult
    public func switchDecoder(hardware: Bool) -> Bool {
        guard let player else { return false }
        let ok = player.switchVideoDecoder(hardware)
        if ok { isHardwareDecodeEnabled = hardware }
        return ok
    }

    public func selectStream(index: Int32) {
        player?.exchangeSelectedStream(index)
    }

    public func closeSubtitleStream() {
        player?.closeCurrentStream("timedtext")
    }

    @discardableResult
    public func loadExternalSubtitle(localFileURL: URL) -> Bool {
        player?.loadThenActiveSubtitle(localFileURL) ?? false
    }

    public func applySubtitleStyle(_ style: SubtitleStyleConfig) {
        pendingSubtitleStyle = style
        // 关键修复：ijkmp_set_subtitle_extra_delay 在 prepared 之前直接解引用 ffp->is->play_mutex 会立即 SIGSEGV！
        // 必须缓存并在 .FSPlayerIsPreparedToPlay 之后才写入 FSPlayer。
        guard let player, isPrepared else { return }
        var pref = fs_subtitle_default_preference()
        pref.ForceOverride = 1
        pref.Scale = Float(min(2.5, max(0.5, style.fontSize / 34.0)))
        pref.BottomMargin = Float(min(0.45, max(0.0, style.bottomInset / 1080.0)))
        pref.Outline = Float(min(6.0, max(0, style.outlineWidth)))
        pref.PrimaryColour = assColor(fromHex: style.foregroundHex, defaultColor: 0xFFFFFF00)
        pref.OutlineColour = assColor(fromHex: style.outlineHex, defaultColor: 0x00000000)
        Self.writeCString(style.fontFamily.libassFamilyName, into: &pref.FontName)
        if let fontsDir = SubtitleFontRegistry.shared.bundledFontsDirectoryPath {
            Self.writeCString(fontsDir, into: &pref.FontsDir)
        }
        player.subtitlePreference = pref
        let delay = Float(style.offsetSeconds)
        if abs(delay - lastAppliedSubtitleDelay) > 0.001 {
            player.currentSubtitleExtraDelay = delay
            lastAppliedSubtitleDelay = delay
        }
    }

    public func trackLists() -> (audio: [MediaTrackItem], subtitles: [MediaTrackItem]) {
        guard let player,
              let meta = player.monitor.mediaMeta as? [String: Any],
              let streams = meta["streams"] as? [[String: Any]] else {
            return ([], [])
        }
        var audioTracks: [MediaTrackItem] = []
        var subtitleTracks: [MediaTrackItem] = []

        for stream in streams {
            let type = (stream["type"] as? String) ?? ""
            let idx = (stream["stream_idx"] as? NSNumber)?.int32Value ?? -1
            guard idx >= 0 else { continue }
            let title = (stream["title"] as? String) ?? ""
            let lang = (stream["language"] as? String) ?? ""
            let codec = (stream["codec_name"] as? String) ?? ""
            let item = MediaTrackItem(id: idx, title: title, language: lang, codecName: codec)
            if type == "audio" {
                audioTracks.append(item)
            } else if type == "timedtext" {
                subtitleTracks.append(item)
            }
        }
        return (audioTracks, subtitleTracks)
    }

    public func captureTechStats() -> PlaybackTechStats {
        var stats = PlaybackTechStats()
        stats.engineName = "FSPlayer (FFmpeg 7)"
        stats.isHardwareDecode = isHardwareDecodeEnabled
        guard let player else { return stats }
        let mon = player.monitor
        stats.videoCodec = mon.vcodec ?? "—"
        stats.audioCodec = mon.acodec ?? "—"
        let natW = player.naturalSize.width.isFinite ? Int(player.naturalSize.width) : 0
        let natH = player.naturalSize.height.isFinite ? Int(player.naturalSize.height) : 0
        let w = mon.width > 0 ? Int(mon.width) : natW
        let h = mon.height > 0 ? Int(mon.height) : natH
        if w > 0 && h > 0 { stats.resolution = "\(w)×\(h)" }
        stats.fps = Double(mon.fps > 0 ? mon.fps : Float(player.fpsInMeta))
        stats.outputFPS = Double(player.fpsAtOutput)
        stats.bitrateMbps = Double(mon.bitrate) / 1_000_000.0
        stats.droppedFrames = player.dropFrameCount()
        stats.downloadSpeedMBps = Double(player.currentDownloadSpeed()) / (1024.0 * 1024.0)
        stats.bufferingProgress = player.bufferingProgress
        return stats
    }

    public func mount(into container: UIView) {
        guard let renderView else { return }
        if renderView.superview === container { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        renderView.frame = container.bounds
        renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(renderView)
    }

    public func shutdown() {
        completeSeekPreview()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        pendingResumeSeekTime = nil
        pendingSubtitleStyle = nil
        lastAppliedSubtitleDelay = 0
        player?.shutdownSync(false)
        player = nil
        renderView?.removeFromSuperview()
        renderView = nil
        isPrepared = false
        isBuffering = false
    }

    // MARK: - 内部监听

    private func installObservers(for fsPlayer: FSPlayer) {
        let nc = NotificationCenter.default

        observerTokens.append(nc.addObserver(forName: .FSPlayerIsPreparedToPlay, object: fsPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player, player === fsPlayer else { return }
                self.isPrepared = true
                self.isBuffering = false
                if let pendingStyle = self.pendingSubtitleStyle {
                    self.applySubtitleStyle(pendingStyle)
                }
                if let resumeAt = self.pendingResumeSeekTime {
                    self.pendingResumeSeekTime = nil
                    let dur = self.duration
                    let target = dur > 0 ? min(max(0, resumeAt), max(0, dur - 0.5)) : max(0, resumeAt)
                    player.enableAccurateSeek(false)
                    player.currentPlaybackTime = target
                }
                self.onTimeUpdate?(self.currentTime, self.duration)
                let lists = self.trackLists()
                self.onTracksChanged?(lists.audio, lists.subtitles)
                let mon = player.monitor
                let fps = mon.fps > 0 ? mon.fps : Float(player.fpsInMeta)
                let natW = player.naturalSize.width.isFinite ? Int32(player.naturalSize.width) : 0
                let natH = player.naturalSize.height.isFinite ? Int32(player.naturalSize.height) : 0
                let w = mon.width > 0 ? mon.width : natW
                let h = mon.height > 0 ? mon.height : natH
                let codecLower = (mon.vcodec ?? "").lowercased()
                if fps > 1, w > 0, h > 0 {
                    DisplayModeCoordinator.shared.apply(
                        refreshRate: fps,
                        formatDescription: nil,
                        width: w,
                        height: h,
                        isHEVC: codecLower.contains("hevc") || codecLower.contains("265")
                    )
                }
                self.onPrepared?()
                self.onStateChange?("正在播放")
            }
        })

        observerTokens.append(nc.addObserver(forName: .FSPlayerFirstVideoFrameRendered, object: fsPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === fsPlayer else { return }
                self.isBuffering = false
                self.onFirstFrameRendered?()
            }
        })

        observerTokens.append(nc.addObserver(forName: .FSPlayerCurrentPlaybackTimeDidChange, object: fsPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onTimeUpdate?(self.currentTime, self.duration)
            }
        })

        observerTokens.append(nc.addObserver(forName: .FSPlayerLoadStateDidChange, object: fsPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                let stalled = player.loadState.contains(.stalled)
                self.isBuffering = stalled
                self.onStateChange?(stalled ? "缓冲中…" : (player.isPlaying() ? "正在播放" : "已暂停"))
            }
        })

        observerTokens.append(nc.addObserver(forName: .FSPlayerPlaybackStateDidChange, object: fsPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.onStateChange?(player.isPlaying() ? "正在播放" : "已暂停")
            }
        })

        observerTokens.append(nc.addObserver(forName: .FSPlayerAfterSeekFirstVideoFrameDisplay, object: fsPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completeSeekPreview()
            }
        })

        observerTokens.append(nc.addObserver(forName: .FSPlayerDidSeekComplete, object: fsPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completeSeekPreview()
                self.onTimeUpdate?(self.currentTime, self.duration)
            }
        })

        observerTokens.append(nc.addObserver(forName: .FSPlayerSelectedStreamDidChange, object: fsPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let lists = self.trackLists()
                self.onTracksChanged?(lists.audio, lists.subtitles)
            }
        })

        observerTokens.append(nc.addObserver(forName: .FSPlayerNoCodecFound, object: fsPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.didReportTerminalFinish else { return }
                self.didReportTerminalFinish = true
                self.onError?("未找到可用的音视频解码器")
            }
        })

        observerTokens.append(nc.addObserver(forName: .FSPlayerVideoDecoderFatal, object: fsPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.didReportTerminalFinish else { return }
                self.didReportTerminalFinish = true
                self.onError?("视频硬件解码器发生致命错误")
            }
        })

        observerTokens.append(nc.addObserver(forName: .FSPlayerDidFinish, object: fsPlayer, queue: .main) { [weak self] note in
            let reasonRaw = (note.userInfo?[FSPlayerDidFinishReasonUserInfoKey] as? NSNumber)?.intValue
            Task { @MainActor [weak self] in
                guard let self, !self.didReportTerminalFinish else { return }
                self.didReportTerminalFinish = true
                let reason = reasonRaw.flatMap(FSFinishReason.init(rawValue:)) ?? .playbackEnded
                switch reason {
                case .playbackError:
                    self.onError?("FSPlayer 播放出错，请尝试切换内核或检查网络流")
                case .playbackEnded:
                    self.onFinish?()
                case .userExited:
                    break
                @unknown default:
                    self.onFinish?()
                }
            }
        })
    }

    private func completeSeekPreview() {
        seekPreviewTimeoutTask?.cancel()
        seekPreviewTimeoutTask = nil
        if let cont = seekPreviewContinuation {
            seekPreviewContinuation = nil
            cont.resume()
        }
    }

    private func mapScaling(_ scaling: ScalingMode) -> FSScalingMode {
        switch scaling {
        case .aspectFit: return .aspectFit
        case .aspectFill: return .aspectFill
        case .fill: return .fill
        }
    }

    private static func writeCString<T>(_ string: String, into tuple: inout T) {
        withUnsafeMutableBytes(of: &tuple) { raw in
            guard let base = raw.baseAddress, raw.count > 1 else { return }
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            let utf8 = Array(string.utf8.prefix(raw.count - 1))
            utf8.withUnsafeBytes { src in
                if let srcBase = src.baseAddress, !utf8.isEmpty {
                    base.copyMemory(from: srcBase, byteCount: utf8.count)
                }
            }
        }
    }

    private func assColor(fromHex hex: String, defaultColor: UInt32) -> UInt32 {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\n"))
        guard cleaned.count == 6, let rgb = UInt32(cleaned, radix: 16) else {
            return defaultColor
        }
        return (rgb << 8)
    }
}
