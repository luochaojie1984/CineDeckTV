import SwiftUI
import UIKit
import PlaybackKit
import NetworkVFS
import LocalStreamProxy
import AppPreferences

/// 播放页：FSPlayer 主引擎（经 127.0.0.1 短 ASCII 代理）+ 遥控长短按快进 + MX 极简条。
@MainActor
public struct PlayerScreenView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    public let source: MediaSourceConfig
    public let entry: VFSEntry

    @StateObject private var coordinator = PlaybackCoordinator()
    @State private var proxy: LocalHTTPStreamProxy?
    @State private var cache: ReadAheadStreamCache?
    @State private var scrubRate: Double = 0
    @State private var scrubDelta: Double = 0
    @State private var showingHUD = false
    @State private var isPreparing = true
    @State private var errorText: String?
    @State private var playhead: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubActive = false
    @State private var layerRevision = 0
    @State private var subtitles: [String] = []
    @State private var selectedSubtitle: String?

    private let scrub = MXScrubController()
    private let keys = RemoteKeyCaptureModel()

    public init(source: MediaSourceConfig, entry: VFSEntry) {
        self.source = source
        self.entry = entry
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoLayer
            RemoteKeyLayer(model: keys)
                .allowsHitTesting(!showingHUD)
                .ignoresSafeArea()
            if isScrubActive { scrubBar }
            if showingHUD { hud }
            if isPreparing { ProgressView().controlSize(.large) }
            if let errorText { errorPanel(errorText) }
        }
        .onAppear { keys.bind(keysModel: keys) }
        .task { await prepare() }
        .onDisappear { teardown() }
    }

    private var videoLayer: some View {
        PlaybackHostView(coordinator: coordinator, revision: layerRevision)
            .ignoresSafeArea()
    }

    private var scrubBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                Text((scrubRate > 0 ? ">>> " : "<<< ") + String(format: "%.0fx", scrubRate))
                    .font(.system(size: 24, weight: .heavy, design: .monospaced))
                Text(String(format: "%+.0fs", scrubDelta))
                    .font(.system(size: 24, weight: .heavy, design: .monospaced))
                Spacer()
                Text("\(timeText(playhead)) / \(timeText(duration))")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 14)
        }
        .tvGlassSurface(cornerRadius: 0, clear: true)
    }

    private var hud: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                Text(entry.name)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1)
                ProgressView(value: duration > 0 ? min(1, playhead / duration) : 0)
                    .progressViewStyle(.linear)
                    .frame(height: 8)
                AdaptiveGlassContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button("⏪ 10s") { seek(by: -10) }.tvAdaptiveGlassButtonStyle()
                        Button(coordinator.isPlaying ? "暂停" : "播放") {
                            coordinator.isPlaying ? coordinator.pause() : coordinator.play()
                        }.tvAdaptiveGlassButtonStyle(prominent: true)
                        Button("⏩ 10s") { seek(by: 10) }.tvAdaptiveGlassButtonStyle()
                        Button("字幕") { cycleSubtitle() }.tvAdaptiveGlassButtonStyle()
                        Button("解码") { toggleDecoder() }.tvAdaptiveGlassButtonStyle()
                        Button("退出") { dismiss() }.tvAdaptiveGlassButtonStyle()
                    }
                }
            }
            .padding(24)
            .tvGlassSurface()
            .padding(.horizontal, 60)
            .padding(.bottom, 48)
        }
    }

    private func errorPanel(_ text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 52)).foregroundStyle(.yellow)
            Text(text).font(.system(size: 24, weight: .semibold)).multilineTextAlignment(.center)
            Button("返回") { dismiss() }.tvAdaptiveGlassButtonStyle(prominent: true)
        }
        .padding(36)
        .tvGlassSurface()
    }

    // MARK: - 生命周期

    private func prepare() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let provider = try await env.provider(for: source)
            let chunkSource = try await provider.makeChunkSource(path: entry.path)
            var config = ReadAheadCacheConfig()
            config.maxCacheBytes = env.settings.clampedCacheBytes
            let cache = ReadAheadStreamCache(source: chunkSource, config: config)
            if let moov = try? await chunkSource.contentLength() {
                try? await cache.prepare(totalSize: moov)
            }
            let proxy = LocalHTTPStreamProxy(cache: cache)
            try await proxy.start()
            let route = await proxy.register(fileExtension: entry.fileExtension)
            guard let url = await proxy.localURL(for: route) else {
                throw PlayerEngineError.loadFailed("本地代理未就绪")
            }
            self.cache = cache
            self.proxy = proxy
            let resume = env.resumePosition(source: source, path: entry.path) ?? 0
            let options = EngineLoadOptions(
                hardwareDecode: env.settings.decodePreference != .software,
                playbackRate: env.settings.playbackRate,
                scaling: ScalingMode(rawValue: env.settings.scalingPreference.rawValue) ?? .aspectFit,
                cacheBytes: env.settings.clampedCacheBytes
            )
            let preference: PlaybackCoordinator.EngineKind = {
                switch env.settings.enginePreference {
                case .automatic: return .automatic
                case .fsplayer: return .fsplayer
                case .avplayer: return .avplayer
                }
            }()
            coordinator.load(url: url.absoluteString, startAt: resume, options: options, preference: preference)
            duration = coordinator.duration
            playhead = resume
            bindScrub()
            Task { await loadSubtitles(provider: provider) }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func bindScrub() {
        scrub.onRateChange = { rate in scrubRate = rate }
        scrub.onTick = { target, _ in
            scrubDelta = target - playhead
            isScrubActive = true
            coordinator.seek(to: target, accurate: false)
            playhead = target
        }
        scrub.onRelease = { target in
            isScrubActive = false
            scrubRate = 0
            coordinator.seek(to: target, accurate: false)
            coordinator.play()
            playhead = target
            env.recordHistory(source: source, path: entry.path, title: entry.name, position: target, duration: duration)
        }
        keys.onShortPress = { forward in
            seek(by: forward ? ScrubMath.mergedJump(shortPressCount: 2) : -ScrubMath.mergedJump(shortPressCount: 2))
        }
        keys.onLongPressBegan = { forward in
            scrub.begin(direction: forward ? .forward : .backward,
                        displayedTime: playhead,
                        duration: duration,
                        profile: profile(for: env.settings.scrubMode))
            coordinator.pause()
        }
        keys.onLongPressEnded = { scrub.end() }
        keys.onMenu = { dismiss() }
        keys.onPlayPause = { coordinator.isPlaying ? coordinator.pause() : coordinator.play() }
        keys.onSelect = { showingHUD.toggle() }
        keys.startPublisher = { true }
    }

    private func profile(for mode: AppSettings.ScrubMode) -> ScrubProfile {
        switch mode {
        case .fine: return .fine
        case .standard: return .standard
        case .turbo: return .turbo
        }
    }

    private func seek(by delta: Double) {
        let target = min(max(0, playhead + delta), max(duration, 0))
        coordinator.seek(to: target, accurate: true)
        playhead = target
    }

    private func cycleSubtitle() {
        guard !subtitles.isEmpty else { return }
        let index = subtitles.firstIndex(of: selectedSubtitle ?? "") ?? -1
        selectedSubtitle = subtitles[(index + 1) % subtitles.count]
    }

    private func toggleDecoder() {
        _ = coordinator.switchDecoder(hardware: env.settings.decodePreference != .hardware)
    }

    private func loadSubtitles(provider: any VFSProvider) async {
        subtitles = (try? await provider.scanSubtitles(forVideoPath: entry.path,
                                                      directories: env.settings.externalSubtitleDirectories)) ?? []
    }

    private func teardown() {
        env.recordHistory(source: source, path: entry.path, title: entry.name, position: playhead, duration: duration)
        coordinator.shutdown()
        Task { await proxy?.stop() }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - 底层视图桥

struct PlaybackHostView: UIViewRepresentable {
    let coordinator: PlaybackCoordinator
    let revision: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let fs = coordinator.engine as? FSPlayerEngineAdapter {
            fs.mount(into: uiView)
        } else if let av = coordinator.engine as? AVPlayerEngineAdapter {
            av.mount(into: uiView)
            av.playerLayer.frame = uiView.bounds
        }
    }
}

/// 遥控事件模型：把 UIView 的回调桥到 SwiftUI 状态。
@MainActor
final class RemoteKeyCaptureModel {
    var onShortPress: ((Bool) -> Void)?
    var onLongPressBegan: ((Bool) -> Void)?
    var onLongPressEnded: (() -> Void)?
    var onMenu: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onSelect: (() -> Void)?
    var startPublisher: ((Bool) -> Void)?

    func bind(keysModel: RemoteKeyCaptureModel) {}
}

struct RemoteKeyLayer: UIViewRepresentable {
    let model: RemoteKeyCaptureModel

    func makeUIView(context: Context) -> RemoteKeyCaptureView {
        let view = RemoteKeyCaptureView(frame: .zero)
        wire(view)
        return view
    }

    func updateUIView(_ uiView: RemoteKeyCaptureView, context: Context) {
        wire(uiView)
    }

    private func wire(_ view: RemoteKeyCaptureView) {
        view.onShortPress = { forward in model.onShortPress?(forward) }
        view.onLongPressBegan = { forward in model.onLongPressBegan?(forward) }
        view.onLongPressEnded = { model.onLongPressEnded?() }
        view.onMenu = { model.onMenu?() }
        view.onPlayPause = { model.onPlayPause?() }
        view.onSelect = { model.onSelect?() }
    }
}
