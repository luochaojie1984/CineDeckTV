import SwiftUI
import UIKit
import NetworkVFS
import LocalStreamProxy
import PlaybackKit
import SubtitleKit
import AppPreferences

/// 全屏影视播放器视图：Metal 双引擎渲染、单飞不积压 MX 手感快进、外挂字幕 UTF-8 转码、Liquid Glass 浮岛 HUD + 侧边抽屉与自动连播。
public struct PlayerScreenView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    public let source: MediaSourceConfig
    public let entry: VFSEntry
    public let initialResumePosition: Double
    public let previewOpenHUD: Bool

    @StateObject private var coordinator = PlaybackCoordinator()
    @State private var scrub = MXScrubController()
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
    @State private var scrubRateBadge: Double?
    @State private var previewTime: Double = 0
    @State private var isTouchpadScrubbing = false
    @State private var touchpadOriginTime: Double = 0
    @State private var errorMessage: String?

    @State private var shortPressDirection: Bool?
    @State private var shortPressCount = 0
    @State private var shortPressCommitTask: Task<Void, Never>?
    @State private var scrubWorkerTask: Task<Void, Never>?
    @State private var latestScrubTarget: Double?
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
                isCaptureEnabled: !showHUD && activeDrawer == nil && nextEpisodeCountdown == nil && !previewOpenHUD,
                onShortPress: { forward in handleShortPress(forward: forward) },
                onLongPressBegan: { forward in startScrub(forward: forward) },
                onLongPressEnded: { endScrub() },
                onTouchpadPanBegan: {
                    isTouchpadScrubbing = true
                    touchpadOriginTime = coordinator.currentTime
                    previewTime = touchpadOriginTime
                    Task {
                        await proxy?.setScrubMode(true)
                        await streamCache?.setScrubMode(true)
                    }
                },
                onTouchpadPanChanged: { delta in
                    let dur = max(1, coordinator.duration)
                    let clamped = min(dur, max(0, touchpadOriginTime + delta))
                    previewTime = clamped
                },
                onTouchpadPanEnded: {
                    isTouchpadScrubbing = false
                    coordinator.seek(to: previewTime, accurate: true)
                    Task {
                        await streamCache?.setScrubMode(false)
                        await proxy?.setScrubMode(false)
                    }
                },
                onMenu: nil,
                onPlayPause: {
                    togglePlayPause()
                    bumpHUD()
                },
                onSelect: { toggleHUD() },
                onShowHUD: { bumpHUD() }
            )
            .allowsHitTesting(!showHUD && activeDrawer == nil && nextEpisodeCountdown == nil && !previewOpenHUD)

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

            if scrub.isScrubbing || isTouchpadScrubbing {
                compactBottomScrubBar
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
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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

    private func startPlayback(for item: VFSEntry, startAt: Double) async {
        currentEntry = item
        errorMessage = nil
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
            try await proxy.start(preferredPort: 0)
            let route = await proxy.register(fileExtension: ext)
            guard let url = await proxy.localURL(for: route) else {
                errorMessage = "本地代理端口未就绪"
                return
            }
            self.proxy = proxy
            self.lastLoadedURL = url.absoluteString

            coordinator.onPlaybackFinished = {
                Task { @MainActor in await handlePlaybackEnded(currentItem: item) }
            }
            coordinator.load(url: url.absoluteString, startAt: startAt, options: currentEngineOptions, preference: mapPreference(env.settings.enginePreference))
            coordinator.applySubtitleStyle(subtitleStyle)

            if startAt > 10 {
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
            errorMessage = error.localizedDescription
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

    // MARK: - 遥控器短按合并 & 单飞不积压 MX 快进

    private func handleShortPress(forward: Bool) {
        if shortPressDirection != forward {
            shortPressDirection = forward
            shortPressCount = 0
        }
        shortPressCount += 1
        let step = ScrubMath.mergedJump(shortPressCount: shortPressCount)
        let target = coordinator.currentTime + (forward ? step : -step)
        let dur = max(target, coordinator.duration)
        previewTime = min(max(0, target), dur)

        shortPressCommitTask?.cancel()
        shortPressCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            coordinator.seek(to: previewTime, accurate: true)
            shortPressCount = 0
            shortPressDirection = nil
        }
    }

    private func startScrub(forward: Bool) {
        let dur = max(1, coordinator.duration > 0 ? coordinator.duration : 7200)
        previewTime = coordinator.currentTime
        Task {
            await proxy?.setScrubMode(true)
            await streamCache?.setScrubMode(true)
        }

        scrub.onRateChange = { rate in scrubRateBadge = rate }
        scrub.onTick = { target, _ in
            previewTime = target
            latestScrubTarget = target
            if scrubWorkerTask == nil {
                scrubWorkerTask = Task { @MainActor in
                    await runSingleFlightScrubLoop()
                }
            }
        }
        scrub.onRelease = { target in
            scrubWorkerTask?.cancel()
            scrubWorkerTask = nil
            latestScrubTarget = nil
            scrubRateBadge = nil
            coordinator.seek(to: target, accurate: true)
            Task {
                await streamCache?.setScrubMode(false)
                await proxy?.setScrubMode(false)
            }
        }
        scrub.begin(direction: forward ? .forward : .backward, displayedTime: coordinator.currentTime, duration: dur, profile: mapProfile(env.settings.scrubMode))
    }

    private func runSingleFlightScrubLoop() async {
        while scrub.isScrubbing {
            guard let target = latestScrubTarget else { break }
            latestScrubTarget = nil
            await coordinator.seekToKeyframePreview(at: target)
            scrub.update(displayedTime: target)
            previewTime = target
        }
        scrubWorkerTask = nil
    }

    private func endScrub() { scrub.end() }

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
                if coordinator.currentTime > 5 {
                    env.recordHistory(source: source, path: item.path, title: item.name, position: coordinator.currentTime, duration: coordinator.duration)
                }
            }
        }
    }

    private func saveCurrentProgress() {
        guard !previewOpenHUD, coordinator.currentTime > 5 else { return }
        env.recordHistory(source: source, path: activeEntry.path, title: activeEntry.name, position: coordinator.currentTime, duration: coordinator.duration)
    }

    private func teardownTasks() {
        hudAutoHideTask?.cancel()
        statsPollTask?.cancel()
        historySaveTask?.cancel()
        shortPressCommitTask?.cancel()
        scrubWorkerTask?.cancel()
        nextEpisodeTimerTask?.cancel()
    }

    private func handlePlayerMenuBack() {
        if activeDrawer != nil {
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
        saveCurrentProgress()
        coordinator.shutdown()
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

    /// 紧凑底部独立快进胶囊（绝不给全屏贴毛玻璃！）
    private var compactBottomScrubBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 18) {
                if let rate = scrubRateBadge {
                    Text("\(Int(rate))x")
                        .font(.system(size: 30, weight: .heavy, design: .monospaced))
                        .foregroundStyle(TVTokens.Color.accent)
                }
                Text(formatTime(previewTime))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                ProgressView(value: previewTime, total: max(1, coordinator.duration))
                    .tint(TVTokens.Color.accent)
                    .frame(width: 480)
                Text(formatTime(coordinator.duration))
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
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
            Button("返回", action: dismissPlayer)
                .tvAdaptiveGlassButtonStyle(prominent: true)
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
