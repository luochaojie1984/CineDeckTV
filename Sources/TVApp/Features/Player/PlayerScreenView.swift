import SwiftUI
import UIKit
import QuartzCore
import AVFoundation
import NetworkVFS
import LocalStreamProxy
import PlaybackKit
import SubtitleKit
import AppPreferences

/// 全屏影视播放器视图：
/// - 三引擎协同（KSPlayer 5.6 主力 + FSPlayer + AVPlayer 完整保留，实时软硬解与内核热切）；
/// - 独立 `LiveKeyframeScrubEngine` + 零拷贝 `AVSampleBufferDisplayLayer` 预览帧呈现；
/// - 进度条与按遥控器确定弹出的设置面板均紧贴底边且严格位于视频画框内，支持 Siri Remote 左右/上下无缝调节全部设置项。
public struct PlayerScreenView: View {
    private enum HUDFocusItem: Hashable {
        case playPause
        case decodeAndEngine
        case subtitles
        case audio
        case stats
        case exit
    }

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    public let source: MediaSourceConfig
    public let entry: VFSEntry
    public let initialResumePosition: Double
    public let previewOpenHUD: Bool

    @StateObject private var coordinator = PlaybackCoordinator()
    @StateObject private var scrub = MXScrubController()
    @State private var scrubFramePresenter = ScrubFramePresenter()
    @State private var scrubEngine = LiveKeyframeScrubEngine()
    @State private var scrubPrepareTask: Task<Void, Never>?

    @State private var proxy: LocalHTTPStreamProxy?
    @State private var streamCache: ReadAheadStreamCache?
    @State private var externalSubtitles: [SubtitleCandidate] = []
    @State private var activeExternalSubPath: String?
    @State private var activeExternalLocalURL: URL?
    @State private var activeEmbeddedSubID: Int32?
    @State private var activeAudioTrackID: Int32?
    @State private var overlayCues: [SubtitleCue] = []

    @State private var showHUD = false
    @State private var activeDrawer: ActivePlayerDrawer?
    @State private var showTechStats = false
    @State private var showResumeBanner = false
    @State private var errorMessage: String?
    @State private var needsForegroundRecovery = false
    @State private var isRecoveringForeground = false
    @State private var resumePositionAfterBackground: Double = 0
    @State private var didDismiss = false
    @State private var wasPlayingBeforeScrub = true
    @State private var isFastPlaying = false
    @State private var fastPlayAnchorTime: Double = 0
    @State private var fastPlayStartWallTime: CFTimeInterval = 0
    @State private var fastPlayMeasuredRate: Double = 3.0
    @State private var hudAutoHideTask: Task<Void, Never>?
    @State private var statsPollTask: Task<Void, Never>?
    @State private var historySaveTask: Task<Void, Never>?

    @State private var nextEpisodeEntry: VFSEntry?
    @State private var nextEpisodeCountdown: Int?
    @State private var nextEpisodeTimerTask: Task<Void, Never>?
    @State private var currentEntry: VFSEntry?
    @State private var lastLoadedURL: String?

    @State private var subtitleStyle = SubtitleStyleConfig()
    @State private var bottomDockHeight: CGFloat = 0
    @State private var didScheduleScrubWarmup = false
    @State private var isCommittingScrub = false
    @State private var scrubEpoch: UInt64 = 0
    @State private var touchpadAccumulatedSeconds: Double = 0
    @State private var lastPlayPauseWallTime: CFTimeInterval = 0
    @FocusState private var hudFocus: HUDFocusItem?

    public init(
        source: MediaSourceConfig,
        entry: VFSEntry,
        initialResumePosition: Double = 0,
        previewOpenHUD: Bool = false
    ) {
        self.source = source
        self.entry = entry
        self.initialResumePosition = initialResumePosition
        self.previewOpenHUD = previewOpenHUD
    }

    private var activeEntry: VFSEntry { currentEntry ?? entry }

    /// 仅在纯观影态激活底层遥控器按键捕获；HUD / 底部设置面板弹出时完全移出视图树，杜绝焦点劫持！
    private var isRemoteCaptureActive: Bool {
        !showHUD && activeDrawer == nil && nextEpisodeCountdown == nil && !previewOpenHUD && errorMessage == nil
    }

    private var shouldRenderCustomSubtitleOverlay: Bool {
        guard !overlayCues.isEmpty else { return false }
        if coordinator.activeEngine != .fsplayer {
            return true
        }
        return subtitleStyle.forceCustomStyle
    }

    private var subtitleVirtualBottomFloor: CGFloat {
        guard showHUD || activeDrawer != nil || previewOpenHUD else { return 0 }
        if bottomDockHeight > 0 { return bottomDockHeight }
        return (activeDrawer != nil || previewOpenHUD) ? 518 : 172
    }

    private var shouldShowSubtitleOverlayLayer: Bool {
        if previewOpenHUD { return true }
        if activeDrawer == .subtitles { return true }
        return shouldRenderCustomSubtitleOverlay
    }

    public var body: some View {
        ZStack {
            if previewOpenHUD {
                previewCinemaBackdrop
            } else {
                PlaybackContainerView(coordinator: coordinator, revision: coordinator.layerRevision)
                    .ignoresSafeArea()
                ScrubFrameDisplayView(presenter: scrubFramePresenter)
                    .ignoresSafeArea()
            }

            if previewOpenHUD {
                SubtitleOverlayView(
                    cues: [SubtitleCue(start: 0, end: 99999, text: "不要温顺地走进那个良夜 · 橋本環奈 桜沢優")],
                    currentTime: 100,
                    style: subtitleStyle,
                    virtualBottomFloor: subtitleVirtualBottomFloor
                )
            } else if shouldShowSubtitleOverlayLayer {
                SubtitleOverlayView(
                    cues: overlayCues,
                    currentTime: coordinator.currentTime,
                    style: subtitleStyle,
                    virtualBottomFloor: subtitleVirtualBottomFloor,
                    previewFallbackText: activeDrawer == .subtitles
                        ? "\(subtitleStyle.fontFamily.displayName) \(Int(subtitleStyle.fontSize))号 · 距底 \(Int(subtitleStyle.bottomInset))px（设置栏上沿即底边）"
                        : nil
                )
            }

            if !previewOpenHUD {
                RemoteKeyCaptureView(
                    isCaptureEnabled: isRemoteCaptureActive,
                    enableTouchpadScrub: env.settings.enableTouchpadScrub,
                    onShortPress: { forward in handleShortPress(forward: forward) },
                    onLongPressBegan: { forward in startScrub(forward: forward) },
                    onLongPressEnded: { endScrub() },
                    onTouchpadPanBegan: {
                        touchpadAccumulatedSeconds = 0
                        beginTouchpadScrub()
                    },
                    onTouchpadPanChanged: { dx, vel in
                        handleTouchpadPanChanged(deltaPoints: dx, velocityPointsPerSec: vel)
                    },
                    onTouchpadPanEnded: {
                        touchpadAccumulatedSeconds = 0
                        endTouchpadScrub()
                    },
                    onMenu: nil,
                    onPlayPause: {
                        if scrub.isScrubbing {
                            commitActiveScrub()
                        } else {
                            togglePlayPause()
                            bumpHUD()
                        }
                    },
                    onSelect: {
                        if scrub.isScrubbing {
                            commitActiveScrub()
                        } else {
                            openHUDFromSelect()
                        }
                    },
                    onShowHUD: {
                        if scrub.isScrubbing {
                            commitActiveScrub()
                        }
                        bumpHUD()
                    }
                )
                .ignoresSafeArea()
                .allowsHitTesting(isRemoteCaptureActive)
            }

            if coordinator.isBuffering && !scrub.isScrubbing && !previewOpenHUD {
                VStack(spacing: 14) {
                    ProgressView().scaleEffect(1.4)
                    Text("缓冲高码率媒体流…")
                        .font(TVTokens.Typography.secondary)
                }
                .padding(28)
                .tvGlassSurface(cornerRadius: 24)
                .allowsHitTesting(false)
            }

            if showTechStats || previewOpenHUD {
                VStack {
                    HStack {
                        TechStatsHUDPill(stats: previewOpenHUD ? Self.previewTechStats : coordinator.techStats)
                        Spacer()
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 26)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if let notice = coordinator.fallbackNotice, !previewOpenHUD {
                VStack {
                    HStack {
                        Spacer()
                        Label(notice, systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .tvGlassSurface(cornerRadius: TVTokens.Radius.capsule)
                    }
                    .padding(.trailing, 40)
                    .padding(.top, 28)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if showResumeBanner && initialResumePosition > 5 {
                resumePill
                    .allowsHitTesting(false)
            }

            // 快进/快退悬浮胶囊进度条：尽量贴近底边（bottom=14）
            if !showHUD && !previewOpenHUD && (scrub.isShowingBar || isFastPlaying) {
                compactBottomScrubBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            // 播放控制栏 + 贴底设置面板：贴紧 1080p 真实底边且实时测量占用高度作为字幕虚拟底边
            if showHUD || previewOpenHUD {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 12) {
                        if activeDrawer != nil {
                            PlayerBottomSettingsPanel(
                                kind: $activeDrawer,
                                coordinator: coordinator,
                                externalSubtitles: previewOpenHUD ? Self.previewExternalSubs : externalSubtitles,
                                activeExternalPath: previewOpenHUD ? Self.previewExternalSubs.first?.path : activeExternalSubPath,
                                activeEmbeddedSubID: activeEmbeddedSubID,
                                activeAudioTrackID: activeAudioTrackID,
                                style: $subtitleStyle,
                                showTechStats: $showTechStats,
                                onSelectExternalSubtitle: { candidate in
                                    Task { await activateExternalSubtitle(candidate) }
                                },
                                onSelectEmbeddedSubtitle: { id in
                                    activeExternalSubPath = nil
                                    activeExternalLocalURL = nil
                                    overlayCues = []
                                    activeEmbeddedSubID = id
                                    coordinator.selectSubtitleTrack(id)
                                },
                                onDisableSubtitle: {
                                    activeExternalSubPath = nil
                                    activeExternalLocalURL = nil
                                    activeEmbeddedSubID = nil
                                    overlayCues = []
                                    coordinator.disableEmbeddedSubtitle()
                                },
                                onSelectAudioTrack: { id in
                                    activeAudioTrackID = id
                                    coordinator.selectAudioTrack(id)
                                },
                                onSwitchEngine: { targetEngine in
                                    switchEngineLive(to: targetEngine)
                                },
                                onToggleHardwareDecode: { hw in
                                    toggleDecodeLive(hardware: hw)
                                },
                                onChangeRate: { rate in
                                    coordinator.setPlaybackRate(rate)
                                    var copy = env.settings
                                    copy.playbackRate = rate
                                    env.update(settings: copy)
                                },
                                onChangeScaling: { scaling in
                                    coordinator.setScalingMode(scaling)
                                    var copy = env.settings
                                    copy.scalingPreference = mapScalingBack(scaling)
                                    env.update(settings: copy)
                                },
                                onInteraction: {
                                    hudAutoHideTask?.cancel()
                                },
                                onClose: {
                                    withAnimation(TVTokens.Motion.focus) { activeDrawer = nil }
                                    claimHUDFocus(.decodeAndEngine)
                                    scheduleHUDAutoHide()
                                }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        floatingTransportHUD
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 18)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: BottomDockHeightPreferenceKey.self, value: geo.size.height)
                        }
                    )
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }

            if let countdown = nextEpisodeCountdown, let next = nextEpisodeEntry {
                autoNextOverlay(next: next, countdown: countdown)
            }

            if let errorMessage {
                errorOverlay(errorMessage)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onPreferenceChange(BottomDockHeightPreferenceKey.self) { measuredHeight in
            if abs(bottomDockHeight - measuredHeight) > 0.5 {
                bottomDockHeight = measuredHeight
            }
        }
        .onChange(of: subtitleStyle) { oldStyle, newStyle in
            coordinator.applySubtitleStyle(newStyle)
            if coordinator.activeEngine == .fsplayer && oldStyle.forceCustomStyle != newStyle.forceCustomStyle {
                if newStyle.forceCustomStyle {
                    coordinator.disableEmbeddedSubtitle()
                } else if let localURL = activeExternalLocalURL {
                    _ = coordinator.loadExternalSubtitle(localFileURL: localURL)
                    coordinator.applySubtitleStyle(newStyle)
                }
            }
            var copy = env.settings
            copy.subtitleStyle = newStyle
            env.update(settings: copy)
        }
        .onChange(of: hudFocus) { _, newFocus in
            if newFocus != nil && showHUD && activeDrawer == nil {
                scheduleHUDAutoHide()
            }
        }
        .background(
            TVMenuBackOverlay(isEnabled: !previewOpenHUD) {
                handlePlayerMenuBack()
            }
            .allowsHitTesting(false)
        )
        .onExitCommand {
            handlePlayerMenuBack()
        }
        .onPlayPauseCommand {
            guard !previewOpenHUD, !isRemoteCaptureActive else { return }
            if scrub.isScrubbing {
                commitActiveScrub()
            } else {
                togglePlayPause()
                if !showHUD {
                    bumpHUD()
                } else if activeDrawer == nil {
                    scheduleHUDAutoHide()
                }
            }
        }
        .task {
            subtitleStyle = env.settings.subtitleStyle
            if previewOpenHUD {
                subtitleStyle.fontFamily = .kaiti
                subtitleStyle.fontSize = 66
                subtitleStyle.foregroundHex = "#FFD859"
                subtitleStyle.bottomInset = 8
                showHUD = true
                showTechStats = true
                activeDrawer = .subtitles
                return
            }
            UIApplication.shared.isIdleTimerDisabled = true
            await startPlayback(for: entry, startAt: initialResumePosition)
        }
        .onChange(of: coordinator.isPlaying) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: scrub.isScrubbing) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: coordinator.currentTime) { _, newValue in
            if isFastPlaying {
                let wallElapsed = CACurrentMediaTime() - fastPlayStartWallTime
                if wallElapsed >= 0.35 {
                    let measured = (newValue - fastPlayAnchorTime) / wallElapsed
                    if measured.isFinite && measured > 0 {
                        fastPlayMeasuredRate = fastPlayMeasuredRate * 0.6 + min(8.0, measured) * 0.4
                    }
                }
            }
        }
        .onChange(of: coordinator.lastError) { _, newError in
            if let newError, !didDismiss {
                appendSmokeStatus("error:\(newError)")
                errorMessage = newError
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard !previewOpenHUD, !didDismiss else { return }
            switch newPhase {
            case .background:
                let pos = scrub.isScrubbing ? scrub.synchronizedDisplayTime : coordinator.currentTime
                if pos > 0 {
                    resumePositionAfterBackground = pos
                }
                if isFastPlaying {
                    isFastPlaying = false
                    coordinator.setMuted(false)
                    coordinator.setPlaybackRate(env.settings.playbackRate)
                }
                scrub.cancelAll()
                scrubFramePresenter.clear()
                coordinator.pause()
                saveCurrentProgress(positionOverride: resumePositionAfterBackground)
                needsForegroundRecovery = true
            case .active:
                if needsForegroundRecovery && !isRecoveringForeground {
                    needsForegroundRecovery = false
                    Task { await recoverAfterForeground() }
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppEnvironment.appDidReturnToForegroundNotification)) { _ in
            guard !previewOpenHUD, !didDismiss, needsForegroundRecovery, !isRecoveringForeground else { return }
            needsForegroundRecovery = false
            Task { await recoverAfterForeground() }
        }
        .onDisappear {
            didDismiss = true
            UIApplication.shared.isIdleTimerDisabled = false
            scrubPrepareTask?.cancel()
            scrubPrepareTask = nil
            scrub.cancelAll()
            scrubFramePresenter.clear()
            teardownTasks()
            saveCurrentProgress()
            coordinator.shutdown()
            let engineToClose = scrubEngine
            Task {
                await engineToClose.close()
            }
            proxy?.stop()
        }
    }

    private var currentEngineOptions: EngineLoadOptions {
        EngineLoadOptions(
            hardwareDecode: env.settings.decodePreference != .software,
            playbackRate: env.settings.playbackRate,
            scaling: mapScaling(env.settings.scalingPreference),
            cacheBytes: env.settings.clampedCacheBytes
        )
    }

    // MARK: - 启动、后台恢复与实时引擎/解码热切

    private func switchEngineLive(to targetEngine: PlaybackCoordinator.EngineKind) {
        guard let url = lastLoadedURL, !url.isEmpty else { return }
        let resume = max(0, coordinator.currentTime)
        var copy = env.settings
        copy.enginePreference = mapPreferenceBack(targetEngine)
        env.update(settings: copy)

        coordinator.load(
            url: url,
            fileName: activeEntry.name,
            startAt: resume,
            options: currentEngineOptions,
            preference: targetEngine
        )
        coordinator.applySubtitleStyle(subtitleStyle)
        if targetEngine == .fsplayer, !subtitleStyle.forceCustomStyle, let localURL = activeExternalLocalURL {
            _ = coordinator.loadExternalSubtitle(localFileURL: localURL)
        }
    }

    private func toggleDecodeLive(hardware: Bool) {
        var copy = env.settings
        copy.decodePreference = hardware ? .hardware : .software
        env.update(settings: copy)
        _ = coordinator.switchDecoder(hardware: hardware)
    }

    private func recoverAfterForeground() async {
        guard !isRecoveringForeground, !didDismiss else { return }
        isRecoveringForeground = true
        defer { isRecoveringForeground = false }

        if isFastPlaying {
            isFastPlaying = false
            coordinator.setMuted(false)
            coordinator.setPlaybackRate(env.settings.playbackRate)
        }
        scrubPrepareTask?.cancel()
        scrubPrepareTask = nil
        scrub.cancelAll()
        scrubFramePresenter.clear()
        teardownTasks()
        coordinator.shutdown()
        await scrubEngine.close()
        scrubEngine = LiveKeyframeScrubEngine()

        if let oldProxy = proxy {
            proxy = nil
            oldProxy.stop()
        }
        streamCache = nil
        await env.resetProvider(for: source.id)

        let resumeAt = resumePositionAfterBackground > 0
            ? resumePositionAfterBackground
            : (coordinator.currentTime > 0 ? coordinator.currentTime : initialResumePosition)
        await startPlayback(for: activeEntry, startAt: resumeAt)
    }

    private func appendSmokeStatus(_ event: String) {
        guard let statusPath = env.smokeTestPlayback?.statusFilePath else { return }
        let line = "\(String(format: "%.3f", CFAbsoluteTimeGetCurrent())) \(event)\n"
        let url = URL(fileURLWithPath: statusPath)
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        existing += line
        try? existing.write(to: url, atomically: true, encoding: .utf8)
    }

    private func startPlayback(for item: VFSEntry, startAt: Double) async {
        currentEntry = item
        errorMessage = nil
        didScheduleScrubWarmup = false
        appendSmokeStatus("start-playback")
        let effectiveStartAt = env.settings.enableResumePlayback ? startAt : 0

        scrubPrepareTask?.cancel()
        scrubPrepareTask = nil
        scrubFramePresenter.clear()
        await scrubEngine.close()
        scrubEngine = LiveKeyframeScrubEngine()

        if let oldProxy = proxy {
            proxy = nil
            oldProxy.stop()
        }

        do {
            var openedProvider: (any VFSProvider)?
            var openedURL: URL?
            for attempt in 1...2 {
                guard !didDismiss else { return }
                if attempt > 1 {
                    await env.resetProvider(for: source.id)
                }
                do {
                    let provider = try await env.provider(for: source)
                    let chunkSource = try await provider.makeChunkSource(path: item.path)
                    let cacheConfig = buildCacheConfig()
                    let cache = ReadAheadStreamCache(source: chunkSource, config: cacheConfig)
                    self.streamCache = cache

                    let ext = (item.name as NSString).pathExtension.lowercased()
                    let totalSize = try await chunkSource.contentLength()
                    var moovOffset: Int64?
                    var moovLength = 0
                    if ext == "mp4" || ext == "mov" || ext == "m4v" {
                        if let moov = try? await cache.locateMP4Moov(), moov.offset > totalSize / 2 {
                            moovOffset = moov.offset
                            moovLength = moov.length
                        }
                    }
                    try await cache.prepare(totalSize: totalSize, moovOffset: moovOffset, moovLength: moovLength)

                    let proxy = LocalHTTPStreamProxy(cache: cache)
                    try proxy.ensureRunning(forceRestart: attempt > 1, preferredPort: 0)
                    let route = proxy.register(fileExtension: ext)
                    guard let url = proxy.localURL(for: route) else {
                        throw PlayerEngineError.loadFailed("本地代理端口未就绪")
                    }
                    self.proxy = proxy
                    self.lastLoadedURL = url.absoluteString
                    openedURL = url
                    appendSmokeStatus("proxy-ready")

                    coordinator.onPreparedForSmokeTest = {
                        appendSmokeStatus("fs-prepared")
                    }
                    coordinator.onFirstFrameForSmokeTest = {
                        appendSmokeStatus("first-frame")
                        scheduleDelayedScrubWarmup(provider: provider, streamURL: url, itemPath: item.path)
                    }
                    coordinator.onPlaybackFinished = {
                        Task { @MainActor in await handlePlaybackEnded(currentItem: item) }
                    }
                    coordinator.load(
                        url: url.absoluteString,
                        fileName: item.name,
                        startAt: effectiveStartAt,
                        options: currentEngineOptions,
                        preference: mapPreference(env.settings.enginePreference)
                    )
                    coordinator.applySubtitleStyle(subtitleStyle)
                    openedProvider = provider
                    break
                } catch {
                    if let failedProxy = self.proxy {
                        self.proxy = nil
                        failedProxy.stop()
                    }
                    if attempt == 2 {
                        throw error
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }

            guard let provider = openedProvider, let streamURL = openedURL, !didDismiss else { return }

            // 兜底定时器：若个别内核未触发首帧回调（如 AVPlayer），6 秒后再低优先级预热快进引擎，避开起播 SMB 竞争
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                scheduleDelayedScrubWarmup(provider: provider, streamURL: streamURL, itemPath: item.path)
            }

            if effectiveStartAt > 10 {
                withAnimation { showResumeBanner = true }
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    withAnimation { showResumeBanner = false }
                }
            }

            startBackgroundPollers(item: item)
            await loadExternalSubtitles(provider: provider, videoEntry: item)
            await resolveNextEpisode(provider: provider, currentItem: item)
        } catch {
            if !didDismiss {
                appendSmokeStatus("error:\(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 首帧出画后再延迟 2.5s 预热独立硬件关键帧快进引擎，避免起播 T=0 时抢占 SMB 连接。
    private func scheduleDelayedScrubWarmup(provider: any VFSProvider, streamURL: URL, itemPath: String) {
        guard !didScheduleScrubWarmup, !didDismiss else { return }
        didScheduleScrubWarmup = true
        let localScrub = scrubEngine
        scrubPrepareTask?.cancel()
        scrubPrepareTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return }
            let directReader = try? await provider.openSynchronousScrubReader(path: itemPath)
            if Task.isCancelled { return }
            await localScrub.prepare(url: streamURL, directReader: directReader)
        }
    }

    private func loadExternalSubtitles(provider: any VFSProvider, videoEntry: VFSEntry) async {
        guard let paths = try? await provider.scanSubtitles(forVideoPath: videoEntry.path, directories: env.settings.externalSubtitleDirectories) else {
            return
        }
        let candidates = paths.map { SubtitleCandidate(fileName: ($0 as NSString).lastPathComponent, path: $0) }
        let ranked = SubtitleMatcher.rank(videoName: videoEntry.name, candidates: candidates)
        externalSubtitles = ranked
        if env.settings.preferSimplifiedChineseSubtitle, let best = ranked.first {
            await activateExternalSubtitle(best)
        }
    }

    private func activateExternalSubtitle(_ candidate: SubtitleCandidate) async {
        do {
            let provider = try await env.provider(for: source)
            let raw = try await provider.read(path: candidate.path, offset: 0, length: 8 * 1024 * 1024)
            let decoded = SubtitleEncodingDetector.detect(raw)
            let utf8Data = Data(decoded.text.utf8)

            let baseDir = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                           ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("CineDeckTV/Subtitles", isDirectory: true)
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            let ext = (candidate.fileName as NSString).pathExtension.lowercased()
            let safeName = "\(abs(candidate.path.hashValue)).\(ext.isEmpty ? "srt" : ext)"
            let localURL = baseDir.appendingPathComponent(safeName)
            try utf8Data.write(to: localURL, options: .atomic)

            activeExternalSubPath = candidate.path
            activeExternalLocalURL = localURL
            activeEmbeddedSubID = nil
            overlayCues = SubtitleParser.parse(text: decoded.text, fileExtension: ext)
            if coordinator.activeEngine == .fsplayer && !subtitleStyle.forceCustomStyle {
                _ = coordinator.loadExternalSubtitle(localFileURL: localURL)
            } else {
                coordinator.disableEmbeddedSubtitle()
            }
            coordinator.applySubtitleStyle(subtitleStyle)
        } catch {
            errorMessage = "加载外挂字幕失败：\(error.localizedDescription)"
        }
    }

    private func resolveNextEpisode(provider: any VFSProvider, currentItem: VFSEntry) async {
        let parent = (currentItem.path as NSString).deletingLastPathComponent
        guard let siblings = try? await provider.list(path: parent) else { return }
        let videos = siblings.filter { $0.isVideo }
        if let idx = videos.firstIndex(where: { $0.path == currentItem.path }), idx + 1 < videos.count {
            nextEpisodeEntry = videos[idx + 1]
        } else {
            nextEpisodeEntry = nil
        }
    }

    private func handlePlaybackEnded(currentItem: VFSEntry) async {
        saveCurrentProgress()
        guard env.settings.autoPlayNextEpisode, let next = nextEpisodeEntry else {
            dismissPlayer()
            return
        }
        nextEpisodeCountdown = 3
        nextEpisodeTimerTask?.cancel()
        nextEpisodeTimerTask = Task { @MainActor in
            for tick in stride(from: 2, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if tick == 0 {
                    nextEpisodeCountdown = nil
                    await startPlayback(for: next, startAt: 0)
                } else {
                    nextEpisodeCountdown = tick
                }
            }
        }
    }

    // MARK: - 遥控器短按 & 硬件关键帧闭环同步快进

    private func updateIdleTimer() {
        guard !previewOpenHUD else { return }
        UIApplication.shared.isIdleTimerDisabled = !didDismiss && (coordinator.isPlaying || scrub.isScrubbing || coordinator.isBuffering)
    }

    private func handleTouchpadPanChanged(deltaPoints: CGFloat, velocityPointsPerSec: CGFloat) {
        guard scrub.isScrubbing else { return }
        let absVel = abs(Double(velocityPointsPerSec))
        let secPerPoint: Double
        switch absVel {
        case ..<280: secPerPoint = 0.14
        case ..<800: secPerPoint = 0.48
        default:     secPerPoint = 1.25
        }
        let dur = coordinator.duration
        let durationScale: Double = (dur > 0 && dur < 300) ? max(0.25, dur / 300.0) : 1.0
        touchpadAccumulatedSeconds += Double(deltaPoints) * secPerPoint * durationScale
        scrub.updateTouchpadPan(deltaFromOrigin: touchpadAccumulatedSeconds)
    }

    private func enterScrubStateIfNeeded() {
        guard !scrub.isScrubbing else { return }
        if !isCommittingScrub {
            wasPlayingBeforeScrub = coordinator.isPlaying
        }
        isCommittingScrub = false
        scrubEpoch &+= 1
        scrubFramePresenter.beginScrubSession()
        scrubEngine.resetTracking()
        coordinator.pause()
        coordinator.setMuted(true)
        proxy?.setScrubMode(true)
        Task {
            await streamCache?.setScrubMode(true)
        }
    }

    private func previewScrubFrame(at target: TimeInterval) async -> TimeInterval {
        let epoch = scrubEpoch
        if scrubEngine.isReady {
            let outcome = await scrubEngine.decodePreviewFrame(
                at: target,
                requestedSpeed: max(1.0, scrub.requestedSpeed)
            )
            // 严防过期预览帧覆盖正在播放的主视频层（导致“声音动、画面卡在预览帧”）
            guard scrub.isScrubbing, !isCommittingScrub, scrubEpoch == epoch, !Task.isCancelled else {
                return target
            }
            switch outcome {
            case .frame(let preview):
                scrubFramePresenter.present(preview)
                return preview.actualTime
            case .unchanged(let actual):
                return actual
            case .unavailable:
                break
            }
        }
        guard scrub.isScrubbing, !isCommittingScrub, scrubEpoch == epoch, !Task.isCancelled else {
            return target
        }
        return await coordinator.seekToKeyframePreview(at: target)
    }

    private func exitScrubStateAndSeek(to finalTarget: TimeInterval, accurate: Bool) async {
        isCommittingScrub = true
        let epoch = scrubEpoch
        let shouldResume = wasPlayingBeforeScrub
        scrubFramePresenter.stopAcceptingFrames()
        await streamCache?.setScrubMode(false)
        proxy?.setScrubMode(false)
        await coordinator.seekAndWait(to: finalTarget, accurate: accurate, resumePlaying: shouldResume)
        coordinator.setMuted(false)
        try? await Task.sleep(nanoseconds: 90_000_000)
        if scrubEpoch == epoch && !scrub.isScrubbing {
            scrubFramePresenter.clear()
            isCommittingScrub = false
        }
    }

    private func handleShortPress(forward: Bool) {
        let dur = max(1, coordinator.duration > 0 ? coordinator.duration : 7200)
        enterScrubStateIfNeeded()
        if env.settings.shortPressSeekBehavior == .multiStageShuttle {
            let result = scrub.stepShuttle(
                direction: forward ? .forward : .backward,
                currentTime: coordinator.currentTime,
                duration: dur,
                onPreviewFrame: { target in
                    await previewScrubFrame(at: target)
                }
            )
            if case .exitedToNormalPlayback = result {
                commitActiveScrub()
            }
        } else {
            scrub.triggerShortStep(
                direction: forward ? .forward : .backward,
                stepSeconds: env.settings.shortSeekSeconds,
                currentTime: coordinator.currentTime,
                duration: dur,
                onPreviewFrame: { target in
                    await previewScrubFrame(at: target)
                },
                onCommit: { finalTarget in
                    await exitScrubStateAndSeek(to: finalTarget, accurate: true)
                }
            )
        }
    }

    private func startScrub(forward: Bool) {
        if env.settings.longPressSeekMode == .continuousFastPlay && forward && !scrub.isScrubbing {
            fastPlayAnchorTime = coordinator.currentTime
            fastPlayStartWallTime = CACurrentMediaTime()
            fastPlayMeasuredRate = 3.0
            isFastPlaying = true
            coordinator.setMuted(true)
            coordinator.setPlaybackRate(3.0)
            coordinator.play()
            return
        }

        let dur = max(1, coordinator.duration > 0 ? coordinator.duration : 7200)
        enterScrubStateIfNeeded()
        scrub.beginHold(
            direction: forward ? .forward : .backward,
            currentTime: coordinator.currentTime,
            duration: dur,
            profile: mapProfile(env.settings.scrubMode),
            onPreviewFrame: { target in
                await previewScrubFrame(at: target)
            }
        )
    }

    private func endScrub() {
        if isFastPlaying {
            isFastPlaying = false
            coordinator.setMuted(false)
            coordinator.setPlaybackRate(env.settings.playbackRate)
            return
        }
        scrub.commitHold { finalTarget in
            await exitScrubStateAndSeek(to: finalTarget, accurate: false)
        }
    }

    private func beginTouchpadScrub() {
        let dur = max(1, coordinator.duration > 0 ? coordinator.duration : 7200)
        enterScrubStateIfNeeded()
        scrub.beginTouchpadPan(
            currentTime: coordinator.currentTime,
            duration: dur,
            onPreviewFrame: { target in
                await previewScrubFrame(at: target)
            }
        )
    }

    private func endTouchpadScrub() {
        scrub.commitTouchpadPan { finalTarget in
            await exitScrubStateAndSeek(to: finalTarget, accurate: true)
        }
    }

    private func commitActiveScrub() {
        scrub.commit(keepBarBriefly: false) { finalTarget in
            await exitScrubStateAndSeek(to: finalTarget, accurate: false)
        }
    }

    // MARK: - HUD 与焦点控制

    private func togglePlayPause() {
        let now = CACurrentMediaTime()
        guard now - lastPlayPauseWallTime >= 0.25 else { return }
        lastPlayPauseWallTime = now
        if coordinator.isPlaying { coordinator.pause() } else { coordinator.play() }
    }

    /// 播放时按遥控器确定键：弹出贴底进度控制条，通过多次焦点确认保证首帧即清晰高亮当前按钮！
    private func openHUDFromSelect() {
        withAnimation(TVTokens.Motion.focus) {
            showHUD = true
        }
        claimHUDFocus(.decodeAndEngine)
        scheduleHUDAutoHide()
    }

    private func bumpHUD() {
        withAnimation(TVTokens.Motion.focus) { showHUD = true }
        if hudFocus == nil {
            claimHUDFocus(.playPause)
        }
        scheduleHUDAutoHide()
    }

    private func claimHUDFocus(_ target: HUDFocusItem) {
        hudFocus = target
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 55_000_000)
            if showHUD && activeDrawer == nil && hudFocus == nil {
                hudFocus = target
            }
            try? await Task.sleep(nanoseconds: 110_000_000)
            if showHUD && activeDrawer == nil && hudFocus == nil {
                hudFocus = target
            }
        }
    }

    private func scheduleHUDAutoHide() {
        hudAutoHideTask?.cancel()
        guard activeDrawer == nil, !previewOpenHUD else { return }
        hudAutoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled && activeDrawer == nil {
                withAnimation(TVTokens.Motion.focus) { showHUD = false }
                hudFocus = nil
            }
        }
    }

    private func startBackgroundPollers(item: VFSEntry) {
        statsPollTask?.cancel()
        statsPollTask = Task { @MainActor in
            while !Task.isCancelled {
                if showTechStats { coordinator.refreshTechStats() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        historySaveTask?.cancel()
        historySaveTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if env.settings.enableResumePlayback && coordinator.currentTime > 5 {
                    env.recordHistory(source: source, path: item.path, title: item.name, position: coordinator.currentTime, duration: coordinator.duration)
                }
            }
        }
    }

    private func saveCurrentProgress(positionOverride: Double? = nil) {
        let pos = positionOverride ?? coordinator.currentTime
        guard env.settings.enableResumePlayback, !previewOpenHUD, pos > 5 else { return }
        env.recordHistory(source: source, path: activeEntry.path, title: activeEntry.name, position: pos, duration: coordinator.duration)
    }

    private func teardownTasks() {
        hudAutoHideTask?.cancel()
        statsPollTask?.cancel()
        historySaveTask?.cancel()
        nextEpisodeTimerTask?.cancel()
    }

    private func handlePlayerMenuBack() {
        if scrub.isScrubbing {
            commitActiveScrub()
        } else if activeDrawer != nil {
            withAnimation(TVTokens.Motion.focus) { activeDrawer = nil }
            claimHUDFocus(.decodeAndEngine)
            scheduleHUDAutoHide()
        } else if nextEpisodeCountdown != nil {
            nextEpisodeTimerTask?.cancel()
            nextEpisodeCountdown = nil
        } else if showHUD {
            hudAutoHideTask?.cancel()
            withAnimation(TVTokens.Motion.focus) { showHUD = false }
            hudFocus = nil
        } else {
            dismissPlayer()
        }
    }

    private func dismissPlayer() {
        didDismiss = true
        scrubPrepareTask?.cancel()
        scrubPrepareTask = nil
        scrub.cancelAll()
        scrubFramePresenter.clear()
        teardownTasks()
        saveCurrentProgress()
        coordinator.shutdown()
        let engineToClose = scrubEngine
        Task {
            await engineToClose.close()
        }
        proxy?.stop()
        dismiss()
    }

    // MARK: - 贴底视觉组件

    private var previewCinemaBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.11, blue: 0.22),
                    Color(red: 0.16, green: 0.11, blue: 0.26),
                    Color(red: 0.03, green: 0.05, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(RadialGradient(colors: [Color.orange.opacity(0.45), Color.clear], center: .center, startRadius: 10, endRadius: 340))
                .frame(width: 680, height: 680)
                .offset(x: -220, y: -60)
            Circle()
                .fill(RadialGradient(colors: [TVTokens.Color.accent.opacity(0.32), Color.clear], center: .center, startRadius: 20, endRadius: 420))
                .frame(width: 820, height: 820)
                .offset(x: 240, y: 120)
        }
        .ignoresSafeArea()
    }

    /// tvOS Liquid Glass 居中悬浮快进胶囊：尽量贴近底边（bottom=14）
    private var compactBottomScrubBar: some View {
        let barColor = Color(cdHex: env.settings.scrubBarColorHex)
        let displayTime = isFastPlaying ? coordinator.currentTime : scrub.synchronizedDisplayTime
        let deltaSec = isFastPlaying ? (coordinator.currentTime - fastPlayAnchorTime) : scrub.synchronizedDeltaSeconds
        let total = max(1.0, coordinator.duration)
        let ratio = min(max(displayTime / total, 0), 1)
        let sign = deltaSec >= 0 ? "+" : "-"
        let deltaText = "\(sign)\(formatTime(abs(deltaSec)))"

        let speedBadge: String = {
            if isFastPlaying {
                let rounded = fastPlayMeasuredRate.rounded()
                let rateText = abs(fastPlayMeasuredRate - rounded) <= 0.18
                    ? "\(max(1, Int(rounded)))x"
                    : String(format: "%.1fx", max(0.5, fastPlayMeasuredRate))
                return ">>> \(rateText)"
            }
            return scrub.speedLabel
        }()

        return VStack {
            Spacer()
            HStack(spacing: 16) {
                if !speedBadge.isEmpty {
                    Text(speedBadge)
                        .font(.system(size: 24, weight: .heavy, design: .monospaced))
                        .foregroundStyle(barColor)
                }
                Text(deltaText)
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TVTokens.Color.secondaryText)

                Text(formatTime(displayTime))
                    .font(.system(size: 22, weight: .bold, design: .monospaced))

                GeometryReader { proxy in
                    let fillWidth = max(0, proxy.size.width * ratio)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                        Capsule()
                            .fill(LinearGradient(colors: [barColor, barColor.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: fillWidth)
                            .shadow(color: barColor.opacity(0.55), radius: 5)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 3, height: 11)
                            .offset(x: max(0, min(proxy.size.width - 3, fillWidth - 1.5)))
                    }
                }
                .frame(width: 440, height: 7)

                Text(formatTime(coordinator.duration))
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .foregroundStyle(TVTokens.Color.secondaryText)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .tvGlassSurface(cornerRadius: TVTokens.Radius.capsule, clear: false)
            .padding(.bottom, 18)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var resumePill: some View {
        VStack {
            HStack {
                Spacer()
                Label("已为您定位到上次观看进度 \(formatTime(initialResumePosition))", systemImage: "bookmark.fill")
                    .font(TVTokens.Typography.secondary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .tvGlassSurface(cornerRadius: TVTokens.Radius.capsule)
            }
            .padding(.trailing, 40)
            .padding(.top, 28)
            Spacer()
        }
    }

    /// 贴底圆润胶囊播放控制栏与进度条：大字号 10-foot 按钮与胶囊圆角，支持遥控器左右键顺畅切换所有按钮。
    private var floatingTransportHUD: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Text(TVTitleFormatter.cleanDisplayTitle(activeEntry.name))
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1)

                VideoBadgeRow(activeEntry.badges, maxCount: 4)

                Spacer(minLength: 12)

                Text(previewOpenHUD ? "01:08:40 / 02:49:00" : "\(formatTime(coordinator.currentTime)) / \(formatTime(coordinator.duration))")
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .foregroundStyle(TVTokens.Color.secondaryText)
            }

            TVProgressBar(
                progress: previewOpenHUD ? (4120.0 / 10140.0) : (coordinator.currentTime / max(1, coordinator.duration)),
                tint: Color(cdHex: env.settings.scrubBarColorHex),
                secondaryTint: TVTokens.Color.violet,
                height: 9
            )

            HStack(spacing: 12) {
                Button {
                    togglePlayPause()
                    scheduleHUDAutoHide()
                } label: {
                    Label(coordinator.isPlaying && !previewOpenHUD ? "暂停" : "播放", systemImage: coordinator.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: true, accentTint: TVTokens.Color.accent, cornerRadius: 999))
                .focused($hudFocus, equals: .playPause)

                Button {
                    hudAutoHideTask?.cancel()
                    let nextDrawer: ActivePlayerDrawer? = (activeDrawer == .decodeAndEngine ? nil : .decodeAndEngine)
                    withAnimation(TVTokens.Motion.focus) {
                        activeDrawer = nextDrawer
                    }
                    if nextDrawer != nil {
                        hudFocus = nil
                    } else {
                        claimHUDFocus(.decodeAndEngine)
                        scheduleHUDAutoHide()
                    }
                } label: {
                    Label("解码·内核", systemImage: "cpu.fill")
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: activeDrawer == .decodeAndEngine, accentTint: TVTokens.Color.accent, cornerRadius: 999))
                .focused($hudFocus, equals: .decodeAndEngine)

                Button {
                    hudAutoHideTask?.cancel()
                    let nextDrawer: ActivePlayerDrawer? = (activeDrawer == .subtitles ? nil : .subtitles)
                    withAnimation(TVTokens.Motion.focus) {
                        activeDrawer = nextDrawer
                    }
                    if nextDrawer != nil {
                        hudFocus = nil
                    } else {
                        claimHUDFocus(.subtitles)
                        scheduleHUDAutoHide()
                    }
                } label: {
                    Label("字幕设置", systemImage: "captions.bubble.fill")
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: activeDrawer == .subtitles, accentTint: TVTokens.Color.amber, cornerRadius: 999))
                .focused($hudFocus, equals: .subtitles)

                Button {
                    hudAutoHideTask?.cancel()
                    let nextDrawer: ActivePlayerDrawer? = (activeDrawer == .audio ? nil : .audio)
                    withAnimation(TVTokens.Motion.focus) {
                        activeDrawer = nextDrawer
                    }
                    if nextDrawer != nil {
                        hudFocus = nil
                    } else {
                        claimHUDFocus(.audio)
                        scheduleHUDAutoHide()
                    }
                } label: {
                    Label("音轨", systemImage: "waveform")
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: activeDrawer == .audio, accentTint: TVTokens.Color.violet, cornerRadius: 999))
                .focused($hudFocus, equals: .audio)

                Button {
                    showTechStats.toggle()
                    scheduleHUDAutoHide()
                } label: {
                    Label("统计", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: showTechStats, accentTint: TVTokens.Color.emerald, cornerRadius: 999))
                .focused($hudFocus, equals: .stats)

                Spacer(minLength: 10)

                Text("\(previewOpenHUD ? "KSPlayer 5.6 · HW" : "\(coordinator.activeEngine.displayName) · \(coordinator.isHardwareDecode ? "HW" : "SW")")")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(TVTokens.Color.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08), in: Capsule())

                Button {
                    dismissPlayer()
                } label: {
                    Label("退出", systemImage: "xmark")
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: false, accentTint: TVTokens.Color.coral, cornerRadius: 999))
                .focused($hudFocus, equals: .exit)
            }
            .focusSection()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlassSurface(cornerRadius: 30, clear: false)
        .defaultFocus($hudFocus, .decodeAndEngine)
        .onAppear {
            if !previewOpenHUD && activeDrawer == nil {
                claimHUDFocus(.decodeAndEngine)
            }
        }
    }

    private func autoNextOverlay(next: VFSEntry, countdown: Int) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(countdown) 秒后自动播放下一集")
                        .font(TVTokens.Typography.sectionTitle)
                        .foregroundStyle(TVTokens.Color.accent)
                    Text(next.name)
                        .font(TVTokens.Typography.secondary)
                        .lineLimit(2)
                    HStack(spacing: 12) {
                        Button("立即播放") {
                            nextEpisodeTimerTask?.cancel()
                            nextEpisodeCountdown = nil
                            Task { await startPlayback(for: next, startAt: 0) }
                        }
                        .buttonStyle(TVPlayerOptionButtonStyle(isSelected: true, accentTint: TVTokens.Color.accent, cornerRadius: 999))
                        Button("取消") {
                            nextEpisodeTimerTask?.cancel()
                            nextEpisodeCountdown = nil
                        }
                        .buttonStyle(TVPlayerOptionButtonStyle(isSelected: false, accentTint: TVTokens.Color.accent, cornerRadius: 999))
                    }
                    .focusSection()
                }
                .padding(24)
                .frame(width: 540)
                .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
                .padding(.trailing, 40)
                .padding(.bottom, 20)
            }
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.yellow)
            Text(message)
                .font(TVTokens.Typography.sectionTitle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
            HStack(spacing: 20) {
                Button {
                    Task { await recoverAfterForeground() }
                } label: {
                    Text("重试播放")
                        .font(.system(size: 20, weight: .bold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: true, accentTint: TVTokens.Color.accent, cornerRadius: 999))

                Button {
                    dismissPlayer()
                } label: {
                    Text("返回")
                        .font(.system(size: 20, weight: .bold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(TVPlayerOptionButtonStyle(isSelected: false, accentTint: TVTokens.Color.coral, cornerRadius: 999))
            }
            .focusSection()
        }
        .padding(36)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
    }

    // MARK: - 映射与样例数据

    private func mapPreference(_ p: AppSettings.EnginePreference) -> PlaybackCoordinator.EngineKind {
        switch p {
        case .automatic: return .automatic
        case .ksplayer: return .ksplayer
        case .fsplayer: return .fsplayer
        case .avplayer: return .avplayer
        }
    }

    private func mapPreferenceBack(_ k: PlaybackCoordinator.EngineKind) -> AppSettings.EnginePreference {
        switch k {
        case .automatic: return .automatic
        case .ksplayer: return .ksplayer
        case .fsplayer: return .fsplayer
        case .avplayer: return .avplayer
        }
    }

    private func mapScaling(_ s: AppSettings.ScalingPreference) -> ScalingMode {
        switch s {
        case .aspectFit: return .aspectFit
        case .aspectFill: return .aspectFill
        case .fill: return .fill
        }
    }

    private func mapScalingBack(_ s: ScalingMode) -> AppSettings.ScalingPreference {
        switch s {
        case .aspectFit: return .aspectFit
        case .aspectFill: return .aspectFill
        case .fill: return .fill
        }
    }

    private func mapProfile(_ mode: AppSettings.ScrubMode) -> ScrubProfile {
        switch mode {
        case .fine: return .fine
        case .standard: return .standard
        case .turbo: return .turbo
        }
    }

    private func buildCacheConfig() -> ReadAheadCacheConfig {
        var c = ReadAheadCacheConfig()
        c.maxCacheBytes = env.settings.clampedCacheBytes
        return c
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let sec = Int(t)
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private static var previewTechStats: PlaybackTechStats {
        var s = PlaybackTechStats()
        s.engineName = "KSPlayer 5.6 (Metal)"
        s.isHardwareDecode = true
        s.videoCodec = "HEVC 10bit HDR10"
        s.audioCodec = "TrueHD Atmos 7.1"
        s.resolution = "3840×2160"
        s.fps = 23.976
        s.outputFPS = 23.98
        s.bitrateMbps = 68.4
        s.downloadSpeedMBps = 96.8
        s.droppedFrames = 0
        return s
    }

    private static var previewExternalSubs: [SubtitleCandidate] {
        [
            SubtitleCandidate(fileName: "星际穿越.2014.简体中文+特效.ass", path: "/Subs/interstellar.chs.ass"),
            SubtitleCandidate(fileName: "星际穿越.2014.中英双语.srt", path: "/Subs/interstellar.bilingual.srt")
        ]
    }
}

private struct BottomDockHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private final class PlaybackSurfaceUIView: UIView {
    var mountedRevision: Int = -1

    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews where sub.translatesAutoresizingMaskIntoConstraints {
            sub.frame = bounds
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in layer.sublayers ?? [] where sublayer is AVPlayerLayer {
            sublayer.frame = bounds
        }
        CATransaction.commit()
    }
}

private struct PlaybackContainerView: UIViewRepresentable {
    let coordinator: PlaybackCoordinator
    let revision: Int

    func makeUIView(context: Context) -> PlaybackSurfaceUIView {
        let view = PlaybackSurfaceUIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlaybackSurfaceUIView, context: Context) {
        guard uiView.mountedRevision != revision else { return }
        uiView.mountedRevision = revision
        switch coordinator.activeEngine {
        case .ksplayer:
            coordinator.ksEngine.mount(into: uiView)
        case .fsplayer, .automatic:
            coordinator.fsEngine.mount(into: uiView)
        case .avplayer:
            coordinator.avEngine.mount(into: uiView)
        }
    }
}

private extension Color {
    init(cdHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\n"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else {
            self = TVTokens.Color.accent
            return
        }
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
