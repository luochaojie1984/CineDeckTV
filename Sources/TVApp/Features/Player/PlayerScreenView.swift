import SwiftUI
import UIKit
import QuartzCore
import NetworkVFS
import LocalStreamProxy
import PlaybackKit
import SubtitleKit
import AppPreferences

/// 全屏影视播放器视图：Metal 双引擎渲染、单飞不积压 MX 手感快进、外挂字幕 UTF-8 转码、Liquid Glass 浮岛 HUD + 侧边抽屉与自动连播。
public struct PlayerScreenView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    public let source: MediaSourceConfig
    public let entry: VFSEntry
    public let initialResumePosition: Double
    public let previewOpenHUD: Bool

    @StateObject private var coordinator = PlaybackCoordinator()
    @StateObject private var scrub = MXScrubController()
    @State private var proxy: LocalHTTPStreamProxy?
    @State private var streamCache: ReadAheadStreamCache?
    @State private var externalSubtitles: [SubtitleCandidate] = []
    @State private var activeExternalSubPath: String?
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

    @State private var subtitleStyle = SubtitleStyleConfig()
    @Namespace private var drawerNamespace

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

    public var body: some View {
        ZStack {
            if previewOpenHUD {
                previewCinemaBackdrop
            } else {
                PlaybackContainerView(coordinator: coordinator, revision: coordinator.layerRevision)
                    .ignoresSafeArea()
            }

            if coordinator.activeEngine == .avplayer && !overlayCues.isEmpty {
                SubtitleOverlayView(cues: overlayCues, currentTime: coordinator.currentTime, style: subtitleStyle)
            }

            if previewOpenHUD {
                SubtitleOverlayView(
                    cues: [SubtitleCue(start: 0, end: 99999, text: "不要温顺地走进那个良夜 —— 外挂 ASS / GB18030 自动转码就绪")],
                    currentTime: 100,
                    style: subtitleStyle
                )
            }

            RemoteCaptureRepresentable(
                isCaptureEnabled: !showHUD && activeDrawer == nil && nextEpisodeCountdown == nil && !previewOpenHUD && errorMessage == nil,
                enableTouchpadScrub: env.settings.enableTouchpadScrub,
                onShortPress: { forward in handleShortPress(forward: forward) },
                onLongPressBegan: { forward in startScrub(forward: forward) },
                onLongPressEnded: { endScrub() },
                onTouchpadPanBegan: { beginTouchpadScrub() },
                onTouchpadPanChanged: { delta in scrub.updateTouchpadPan(deltaFromOrigin: delta) },
                onTouchpadPanEnded: { endTouchpadScrub() },
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
                        toggleHUD()
                    }
                },
                onShowHUD: {
                    if scrub.isScrubbing {
                        commitActiveScrub()
                    }
                    bumpHUD()
                }
            )
            .allowsHitTesting(!showHUD && activeDrawer == nil && nextEpisodeCountdown == nil && !previewOpenHUD && errorMessage == nil)

            if coordinator.isBuffering && !scrub.isScrubbing && !previewOpenHUD {
                VStack(spacing: 14) {
                    ProgressView().scaleEffect(1.4)
                    Text("缓冲高码率媒体流…")
                        .font(TVTokens.Typography.secondary)
                }
                .padding(28)
                .tvGlassSurface(cornerRadius: 24)
            }

            if showTechStats || previewOpenHUD {
                VStack {
                    HStack {
                        TechStatsHUDPill(stats: previewOpenHUD ? Self.previewTechStats : coordinator.techStats)
                        Spacer()
                    }
                    .padding(.leading, 48)
                    .padding(.trailing, activeDrawer != nil ? 730 : 48)
                    .padding(.top, 36)
                    Spacer()
                }
            }

            if showResumeBanner && initialResumePosition > 5 {
                resumePill
            }

            if !showHUD && !previewOpenHUD && (scrub.isShowingBar || isFastPlaying) {
                compactBottomScrubBar
                    .allowsHitTesting(false)
            }

            if showHUD || previewOpenHUD {
                floatingTransportHUD
            }

            if let drawer = activeDrawer {
                HStack {
                    Spacer()
                    AdaptiveGlassContainer(spacing: 16) {
                        PlayerSideDrawer(
                            kind: drawer,
                            coordinator: coordinator,
                            externalSubtitles: previewOpenHUD ? Self.previewExternalSubs : externalSubtitles,
                            activeExternalPath: activeExternalSubPath,
                            activeEmbeddedSubID: activeEmbeddedSubID,
                            activeAudioTrackID: activeAudioTrackID,
                            style: $subtitleStyle,
                            showTechStats: $showTechStats,
                            onSelectExternalSubtitle: { candidate in
                                Task { await activateExternalSubtitle(candidate) }
                            },
                            onSelectEmbeddedSubtitle: { id in
                                activeExternalSubPath = nil
                                overlayCues = []
                                activeEmbeddedSubID = id
                                coordinator.selectSubtitleTrack(id)
                            },
                            onDisableSubtitle: {
                                activeExternalSubPath = nil
                                activeEmbeddedSubID = nil
                                overlayCues = []
                                coordinator.disableEmbeddedSubtitle()
                            },
                            onSelectAudioTrack: { id in
                                activeAudioTrackID = id
                                coordinator.selectAudioTrack(id)
                            },
                            onSwitchEngine: { targetEngine in
                                let resume = max(0, coordinator.currentTime)
                                coordinator.load(
                                    url: lastLoadedURL ?? "",
                                    startAt: resume,
                                    options: currentEngineOptions,
                                    preference: targetEngine
                                )
                            },
                            onToggleHardwareDecode: { hw in
                                _ = coordinator.switchDecoder(hardware: hw)
                            },
                            onChangeRate: { rate in
                                coordinator.setPlaybackRate(rate)
                            },
                            onChangeScaling: { scaling in
                                coordinator.setScalingMode(scaling)
                            },
                            onClose: {
                                withAnimation(TVTokens.Motion.focus) { activeDrawer = nil }
                                bumpHUD()
                            }
                        )
                        .tvGlassMorphID("drawer-\(drawer.rawValue)", in: drawerNamespace)
                    }
                }
                .padding(.trailing, 40)
                .padding(.vertical, 36)
            }

            if let countdown = nextEpisodeCountdown, let next = nextEpisodeEntry {
                autoNextOverlay(next: next, countdown: countdown)
            }

            if let errorMessage {
                errorOverlay(errorMessage)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: subtitleStyle) { _, newStyle in
            coordinator.applySubtitleStyle(newStyle)
            var copy = env.settings
            copy.subtitleStyle = newStyle
            env.update(settings: copy)
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
        .task {
            subtitleStyle = env.settings.subtitleStyle
            if previewOpenHUD {
                showHUD = true
                showTechStats = true
                activeDrawer = .subtitles
                return
            }
            UIApplication.shared.isIdleTimerDisabled = true
            await startPlayback(for: entry, startAt: initialResumePosition)
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
            scrub.cancelAll()
            teardownTasks()
            saveCurrentProgress()
            coordinator.shutdown()
            Task { await proxy?.stop() }
        }
    }

    @State private var lastLoadedURL: String?

    private var currentEngineOptions: EngineLoadOptions {
        EngineLoadOptions(
            hardwareDecode: env.settings.decodePreference != .software,
            playbackRate: env.settings.playbackRate,
            scaling: mapScaling(env.settings.scalingPreference),
            cacheBytes: env.settings.clampedCacheBytes
        )
    }

    // MARK: - 启动与字幕加载

    private func recoverAfterForeground() async {
        guard !isRecoveringForeground, !didDismiss else { return }
        isRecoveringForeground = true
        defer { isRecoveringForeground = false }

        if isFastPlaying {
            isFastPlaying = false
            coordinator.setMuted(false)
            coordinator.setPlaybackRate(env.settings.playbackRate)
        }
        scrub.cancelAll()
        teardownTasks()
        coordinator.shutdown()
        if let oldProxy = proxy {
            proxy = nil
            await oldProxy.stop()
        }
        streamCache = nil
        await env.resetProvider(for: source.id)

        let resumeAt = resumePositionAfterBackground > 0
            ? resumePositionAfterBackground
            : (coordinator.currentTime > 0 ? coordinator.currentTime : initialResumePosition)
        await startPlayback(for: activeEntry, startAt: resumeAt)
    }

    private func startPlayback(for item: VFSEntry, startAt: Double) async {
        currentEntry = item
        errorMessage = nil
        let effectiveStartAt = env.settings.enableResumePlayback ? startAt : 0

        if let oldProxy = proxy {
            proxy = nil
            await oldProxy.stop()
        }

        do {
            var openedProvider: (any VFSProvider)?
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
                        if let moov = try? await provider.locateMoov(path: item.path), moov.offset > totalSize / 2 {
                            moovOffset = moov.offset
                            moovLength = moov.length
                        }
                    }
                    try await cache.prepare(totalSize: totalSize, moovOffset: moovOffset, moovLength: moovLength)

                    let proxy = LocalHTTPStreamProxy(cache: cache)
                    try await proxy.ensureRunning(forceRestart: attempt > 1, preferredPort: 0)
                    let route = await proxy.register(fileExtension: ext)
                    guard let url = await proxy.localURL(for: route) else {
                        throw PlayerEngineError.loadFailed("本地代理端口未就绪")
                    }
                    self.proxy = proxy
                    self.lastLoadedURL = url.absoluteString

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
                        await failedProxy.stop()
                    }
                    if attempt == 2 {
                        throw error
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }

            guard let provider = openedProvider, !didDismiss else { return }

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
                errorMessage = error.localizedDescription
            }
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
            activeEmbeddedSubID = nil
            overlayCues = SubtitleParser.parse(text: decoded.text, fileExtension: ext)
            _ = coordinator.loadExternalSubtitle(localFileURL: localURL)
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

    // MARK: - 遥控器短按（跳秒 / 多级倍速穿梭）& 闭环同步快进

    private func enterScrubStateIfNeeded() {
        guard !scrub.isScrubbing else { return }
        wasPlayingBeforeScrub = coordinator.isPlaying
        coordinator.pause()
        coordinator.setMuted(true)
        Task {
            await proxy?.setScrubMode(true)
            await streamCache?.setScrubMode(true)
        }
    }

    private func exitScrubStateAndSeek(to finalTarget: TimeInterval, accurate: Bool) {
        Task {
            await streamCache?.setScrubMode(false)
            await proxy?.setScrubMode(false)
        }
        coordinator.seek(to: finalTarget, accurate: accurate)
        coordinator.setMuted(false)
        if wasPlayingBeforeScrub {
            coordinator.play()
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
                onPreviewFrame: { [coordinator] target in
                    await coordinator.seekToKeyframePreview(at: target)
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
                onPreviewFrame: { [coordinator] target in
                    await coordinator.seekToKeyframePreview(at: target)
                },
                onCommit: { finalTarget in
                    exitScrubStateAndSeek(to: finalTarget, accurate: true)
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
            onPreviewFrame: { [coordinator] target in
                await coordinator.seekToKeyframePreview(at: target)
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
            exitScrubStateAndSeek(to: finalTarget, accurate: false)
        }
    }

    private func beginTouchpadScrub() {
        let dur = max(1, coordinator.duration > 0 ? coordinator.duration : 7200)
        enterScrubStateIfNeeded()
        scrub.beginTouchpadPan(
            currentTime: coordinator.currentTime,
            duration: dur,
            onPreviewFrame: { [coordinator] target in
                await coordinator.seekToKeyframePreview(at: target)
            }
        )
    }

    private func endTouchpadScrub() {
        scrub.commitTouchpadPan { finalTarget in
            exitScrubStateAndSeek(to: finalTarget, accurate: true)
        }
    }

    private func commitActiveScrub() {
        scrub.commit(keepBarBriefly: false) { finalTarget in
            exitScrubStateAndSeek(to: finalTarget, accurate: false)
        }
    }

    // MARK: - HUD 与定时刷新

    private func togglePlayPause() {
        if coordinator.isPlaying { coordinator.pause() } else { coordinator.play() }
    }

    private func toggleHUD() {
        withAnimation(TVTokens.Motion.focus) {
            showHUD.toggle()
            if !showHUD { activeDrawer = nil }
        }
        if showHUD { scheduleHUDAutoHide() }
    }

    private func bumpHUD() {
        withAnimation(TVTokens.Motion.focus) { showHUD = true }
        scheduleHUDAutoHide()
    }

    private func scheduleHUDAutoHide() {
        hudAutoHideTask?.cancel()
        guard activeDrawer == nil, !previewOpenHUD else { return }
        hudAutoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled && activeDrawer == nil {
                withAnimation(TVTokens.Motion.focus) { showHUD = false }
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
        } else if nextEpisodeCountdown != nil {
            nextEpisodeTimerTask?.cancel()
            nextEpisodeCountdown = nil
        } else if showHUD {
            withAnimation(TVTokens.Motion.focus) { showHUD = false }
        } else {
            dismissPlayer()
        }
    }

    private func dismissPlayer() {
        didDismiss = true
        scrub.cancelAll()
        teardownTasks()
        saveCurrentProgress()
        coordinator.shutdown()
        Task { await proxy?.stop() }
        dismiss()
    }

    // MARK: - 视觉组件

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

    /// tvOS Liquid Glass 居中悬浮胶囊（带玻璃背景卡片）+ AuraTV 闭环同步倍速与偏移量
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
                        .font(.system(size: 26, weight: .heavy, design: .monospaced))
                        .foregroundStyle(barColor)
                }
                Text(deltaText)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TVTokens.Color.secondaryText)

                Text(formatTime(displayTime))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))

                GeometryReader { proxy in
                    let fillWidth = max(0, proxy.size.width * ratio)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                        Capsule()
                            .fill(barColor)
                            .frame(width: fillWidth)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 3, height: 11)
                            .offset(x: max(0, min(proxy.size.width - 3, fillWidth - 1.5)))
                    }
                }
                .frame(width: 440, height: 7)

                Text(formatTime(coordinator.duration))
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundStyle(TVTokens.Color.secondaryText)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .tvGlassSurface(cornerRadius: TVTokens.Radius.capsule, clear: false)
            .padding(.bottom, 54)
        }
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
            .padding(.trailing, 48)
            .padding(.top, 36)
            Spacer()
        }
    }

    private var floatingTransportHUD: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activeEntry.name)
                            .font(TVTokens.Typography.directoryTitle)
                            .lineLimit(1)
                        VideoBadgeRow(activeEntry.badges)
                    }
                    Spacer()
                    Text(previewOpenHUD ? "01:08:40 / 02:49:00" : "\(formatTime(coordinator.currentTime)) / \(formatTime(coordinator.duration))")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundStyle(TVTokens.Color.secondaryText)
                }

                ProgressView(
                    value: previewOpenHUD ? 4120 : coordinator.currentTime,
                    total: previewOpenHUD ? 10140 : max(1, coordinator.duration)
                )
                .tint(TVTokens.Color.accent)

                AdaptiveGlassContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            togglePlayPause()
                        } label: {
                            Label(coordinator.isPlaying && !previewOpenHUD ? "暂停" : "播放", systemImage: coordinator.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .tvAdaptiveGlassButtonStyle(prominent: true)

                        Button {
                            withAnimation(TVTokens.Motion.focus) {
                                activeDrawer = activeDrawer == .subtitles ? nil : .subtitles
                            }
                        } label: {
                            Label("字幕", systemImage: "captions.bubble")
                                .font(.system(size: 20, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .tvAdaptiveGlassButtonStyle(prominent: activeDrawer == .subtitles)
                        .tvGlassMorphID("drawer-subtitles", in: drawerNamespace)

                        Button {
                            withAnimation(TVTokens.Motion.focus) {
                                activeDrawer = activeDrawer == .audioAndDecode ? nil : .audioAndDecode
                            }
                        } label: {
                            Label("音轨", systemImage: "waveform")
                                .font(.system(size: 20, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .tvAdaptiveGlassButtonStyle(prominent: activeDrawer == .audioAndDecode)
                        .tvGlassMorphID("drawer-audioAndDecode", in: drawerNamespace)

                        Button {
                            showTechStats.toggle()
                        } label: {
                            Label("统计", systemImage: "chart.bar.xaxis")
                                .font(.system(size: 20, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .tvAdaptiveGlassButtonStyle(prominent: showTechStats)

                        Spacer(minLength: 8)

                        Button {
                            dismissPlayer()
                        } label: {
                            Label("退出", systemImage: "xmark")
                                .font(.system(size: 20, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .tvAdaptiveGlassButtonStyle()
                    }
                    .focusSection()
                }
            }
            .padding(28)
            .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: false)
            .padding(.leading, 48)
            .padding(.trailing, activeDrawer != nil ? 730 : 48)
            .padding(.bottom, 34)
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
                    AdaptiveGlassContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            Button("立即播放") {
                                nextEpisodeTimerTask?.cancel()
                                nextEpisodeCountdown = nil
                                Task { await startPlayback(for: next, startAt: 0) }
                            }
                            .tvAdaptiveGlassButtonStyle(prominent: true)
                            Button("取消") {
                                nextEpisodeTimerTask?.cancel()
                                nextEpisodeCountdown = nil
                            }
                            .tvAdaptiveGlassButtonStyle()
                        }
                    }
                }
                .padding(28)
                .frame(width: 560)
                .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
                .padding(48)
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
            AdaptiveGlassContainer(spacing: 20) {
                HStack(spacing: 20) {
                    Button("重试播放") {
                        Task { await recoverAfterForeground() }
                    }
                    .tvAdaptiveGlassButtonStyle(prominent: true)

                    Button("返回", action: dismissPlayer)
                        .tvAdaptiveGlassButtonStyle()
                }
                .focusSection()
            }
        }
        .padding(40)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
    }

    // MARK: - 映射与样例数据

    private func mapPreference(_ p: AppSettings.EnginePreference) -> PlaybackCoordinator.EngineKind {
        switch p {
        case .automatic: return .automatic
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
        s.engineName = "FSPlayer (FFmpeg 7)"
        s.isHardwareDecode = true
        s.videoCodec = "HEVC 10bit HDR10"
        s.audioCodec = "TrueHD Atmos 7.1"
        s.resolution = "3840×2160"
        s.fps = 23.976
        s.outputFPS = 23.98
        s.bitrateMbps = 68.4
        s.downloadSpeedMBps = 84.2
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

private final class PlaybackSurfaceUIView: UIView {
    var mountedRevision: Int = -1
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
        case .fsplayer, .automatic: coordinator.fsEngine.mount(into: uiView)
        case .avplayer: coordinator.avEngine.mount(into: uiView)
        }
    }
}

private struct RemoteCaptureRepresentable: UIViewRepresentable {
    let isCaptureEnabled: Bool
    let enableTouchpadScrub: Bool
    let onShortPress: (Bool) -> Void
    let onLongPressBegan: (Bool) -> Void
    let onLongPressEnded: () -> Void
    let onTouchpadPanBegan: () -> Void
    let onTouchpadPanChanged: (Double) -> Void
    let onTouchpadPanEnded: () -> Void
    let onMenu: (() -> Void)?
    let onPlayPause: () -> Void
    let onSelect: () -> Void
    let onShowHUD: () -> Void

    func makeUIView(context: Context) -> RemoteKeyCaptureView {
        let view = RemoteKeyCaptureView()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: RemoteKeyCaptureView, context: Context) {
        uiView.isCaptureEnabled = isCaptureEnabled
        configure(uiView)
    }

    private func configure(_ view: RemoteKeyCaptureView) {
        view.enableTouchpadScrub = enableTouchpadScrub
        view.onShortPress = onShortPress
        view.onLongPressBegan = onLongPressBegan
        view.onLongPressEnded = onLongPressEnded
        view.onTouchpadPanBegan = onTouchpadPanBegan
        view.onTouchpadPanChanged = onTouchpadPanChanged
        view.onTouchpadPanEnded = onTouchpadPanEnded
        view.onMenu = onMenu
        view.onPlayPause = onPlayPause
        view.onSelect = onSelect
        view.onShowHUD = onShowHUD
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
