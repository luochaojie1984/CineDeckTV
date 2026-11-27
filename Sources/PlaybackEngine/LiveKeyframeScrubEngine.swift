import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
import CoreMedia
import AVFoundation
import os
import NetworkVFS

#if canImport(KSPlayer) && !targetEnvironment(simulator)
@preconcurrency import KSPlayer
#if canImport(Libavcodec)
@preconcurrency import Libavcodec
#endif
#if canImport(Libavformat)
@preconcurrency import Libavformat
#endif

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// 零 HTTP 直连 SMB2 的自定义 `AbstractAVIOContext`：钉住头尾 2 MB（MKV Cues / MP4 moov）+ 512 KB 滑动微缓冲。
private final class ScrubAVIOContext: AbstractAVIOContext, @unchecked Sendable {
    private let reader: any SynchronousRandomAccessReader
    private let lock = NSLock()
    private var cursor: Int64 = 0
    private let totalSize: Int64
    private var isClosed: Bool = false

    private let edgePinBytes: Int = 2 * 1024 * 1024
    private var headCache: Data?
    private var tailCacheStart: Int64 = -1
    private var tailCache: Data?

    private var isOpenPhase: Bool = true
    private var didInspectMP4Moov: Bool = false
    private var openMoovStart: Int64 = -1
    private var openMoovData: Data?
    private let openWindowBytes: Int = 2 * 1024 * 1024

    private let microWindowBytes: Int = 512 * 1024
    private var microStart: Int64 = -1
    private var microData: Data = Data()

    private static let averrorEOF: Int32 = -541478725

    init(reader: any SynchronousRandomAccessReader) {
        self.reader = reader
        self.totalSize = max(0, reader.totalSize)
        super.init(bufferSize: 64 * 1024)
    }

    deinit {
        close()
    }

    override func fileSize() -> Int64 {
        totalSize
    }

    override func seek(offset: Int64, whence w: Int32) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if (w & 0x10000) != 0 { // AVSEEK_SIZE
            return totalSize
        }
        guard !isClosed else { return -1 }
        let base = w & 0xFF
        let target: Int64
        switch base {
        case 0: target = offset
        case 1: target = cursor + offset
        case 2: target = totalSize + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        cursor = min(target, totalSize)
        return cursor
    }

    func finishOpenPhase() {
        lock.lock()
        isOpenPhase = false
        openMoovData = nil
        openMoovStart = -1
        lock.unlock()
    }

    private func readHeaderByteRangeLocked(offset: Int64, length: Int) -> Data? {
        if let hc = headCache,
           offset >= 0,
           Int(offset) < hc.count,
           (offset + Int64(length)) <= Int64(hc.count) {
            let base = hc.startIndex
            return Data(hc[(base + Int(offset))..<(base + Int(offset) + length)])
        }
        return try? reader.readSync(offset: offset, length: length)
    }

    private func preloadMP4MoovLocked() {
        didInspectMP4Moov = true
        guard totalSize >= 24 else { return }

        if headCache == nil {
            let headLen = Int(min(totalSize, Int64(edgePinBytes)))
            headCache = try? reader.readSync(offset: 0, length: headLen)
        }
        guard let hc = headCache, hc.count >= 12 else { return }
        let magic = hc.withUnsafeBytes { raw -> UInt32 in
            guard let ptr = raw.baseAddress else { return 0 }
            return ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian
        }
        guard magic == 0x66747970 else { return }

        var off: Int64 = 0
        for _ in 0..<16 {
            guard off + 8 <= totalSize else { break }
            let hdrLen = Int(min(16, totalSize - off))
            guard let hdr = readHeaderByteRangeLocked(offset: off, length: hdrLen), hdr.count >= 8 else { break }
            let (rawSize, boxType) = hdr.withUnsafeBytes { raw -> (UInt32, UInt32) in
                let p = raw.baseAddress!
                return (
                    p.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian,
                    p.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian
                )
            }
            var boxSize = Int64(rawSize)
            if boxSize == 1 {
                guard hdr.count >= 16 else { break }
                let ext = hdr.withUnsafeBytes { raw -> UInt64 in
                    raw.baseAddress!.loadUnaligned(fromByteOffset: 8, as: UInt64.self).bigEndian
                }
                boxSize = ext <= UInt64(Int64.max) ? Int64(ext) : Int64.max
            } else if boxSize == 0 {
                boxSize = totalSize - off
            }
            guard boxSize >= 8 else { break }

            if boxType == 0x6D6F6F76 { // "moov"
                let maxMoovBytes: Int64 = 24 * 1024 * 1024
                guard boxSize <= maxMoovBytes else { break }
                var buf = Data()
                buf.reserveCapacity(Int(boxSize))
                var pos = off
                let end = min(totalSize, off + boxSize)
                let step = Int64(openWindowBytes)
                while pos < end {
                    let wantChunk = Int(min(step, end - pos))
                    guard let chunk = try? reader.readSync(offset: pos, length: wantChunk), !chunk.isEmpty else {
                        return
                    }
                    buf.append(chunk)
                    pos += Int64(chunk.count)
                }
                if !buf.isEmpty {
                    openMoovStart = off
                    openMoovData = buf
                }
                return
            }

            guard off <= totalSize - boxSize else { break }
            off += boxSize
        }
    }

    override func read(buffer buf: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let buf, size > 0, cursor < totalSize else {
            return Self.averrorEOF
        }

        let want = Int(min(Int64(size), totalSize - cursor))
        guard want > 0 else { return Self.averrorEOF }

        if isOpenPhase && !didInspectMP4Moov {
            preloadMP4MoovLocked()
        }

        if openMoovStart >= 0,
           let moov = openMoovData,
           cursor >= openMoovStart,
           (cursor + Int64(want)) <= (openMoovStart + Int64(moov.count)) {
            Self.copySlice(from: moov, localStart: Int(cursor - openMoovStart), count: want, into: buf)
            cursor += Int64(want)
            return Int32(want)
        }

        if cursor < Int64(edgePinBytes) {
            if headCache == nil {
                let len = Int(min(totalSize, Int64(edgePinBytes)))
                headCache = try? reader.readSync(offset: 0, length: len)
            }
            if let hc = headCache,
               Int(cursor) < hc.count,
               (cursor + Int64(want)) <= Int64(hc.count) {
                Self.copySlice(from: hc, localStart: Int(cursor), count: want, into: buf)
                cursor += Int64(want)
                return Int32(want)
            }
        }

        let tailEdge = max(Int64(0), totalSize - Int64(edgePinBytes))
        if cursor >= tailEdge {
            if tailCache == nil {
                let len = Int(totalSize - tailEdge)
                if len > 0, let tc = try? reader.readSync(offset: tailEdge, length: len) {
                    tailCacheStart = tailEdge
                    tailCache = tc
                }
            }
            if let tc = tailCache,
               tailCacheStart >= 0,
               cursor >= tailCacheStart,
               (cursor + Int64(want)) <= (tailCacheStart + Int64(tc.count)) {
                Self.copySlice(from: tc, localStart: Int(cursor - tailCacheStart), count: want, into: buf)
                cursor += Int64(want)
                return Int32(want)
            }
        }

        if microStart >= 0,
           cursor >= microStart,
           (cursor + Int64(want)) <= (microStart + Int64(microData.count)) {
            Self.copySlice(from: microData, localStart: Int(cursor - microStart), count: want, into: buf)
            cursor += Int64(want)
            return Int32(want)
        }

        let windowSize = isOpenPhase ? openWindowBytes : microWindowBytes
        let fetchLen = Int(min(Int64(max(want, windowSize)), totalSize - cursor))
        guard let fetched = try? reader.readSync(offset: cursor, length: fetchLen), !fetched.isEmpty else {
            return Self.averrorEOF
        }
        microStart = cursor
        microData = fetched
        let n = min(want, fetched.count)
        Self.copySlice(from: fetched, localStart: 0, count: n, into: buf)
        cursor += Int64(n)
        return Int32(n)
    }

    override func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        isOpenPhase = false
        openMoovData = nil
        openMoovStart = -1
        headCache = nil
        tailCache = nil
        tailCacheStart = -1
        microStart = -1
        microData = Data()
        lock.unlock()
        reader.closeSync()
    }

    @inline(__always)
    private static func copySlice(from source: Data, localStart: Int, count: Int, into dest: UnsafeMutablePointer<UInt8>) {
        source.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            dest.update(from: base.advanced(by: localStart), count: count)
        }
    }
}

/// 基于 KSPlayer `FormatContext` + 同步 `VideoToolboxDecode`（自动回退 `FFmpegDecode`）的独立硬件关键帧预览引擎。
public final class LiveKeyframeScrubEngine: @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "local.personal.cinedecktv.live-scrub", qos: .userInteractive)
    private let latestGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    private var preparedURL: URL?
    private var formatContext: FormatContext?
    private var avioContext: ScrubAVIOContext?
    private var videoTrack: FFmpegAssetTrack?
    private var decoder: (any DecodeProtocol)?
    private var scrubOptions: KSOptions?
    private var usingSoftwareFallback: Bool = false
    private var isClosed: Bool = false

    private var lastRenderedPTS: Int64 = Int64.min
    private var lastRenderedTime: TimeInterval = -.infinity
    private var lastRequestedTarget: TimeInterval = -.infinity
    private var demuxerIsContinuous: Bool = false
    private var demuxerCursorTime: TimeInterval = -.infinity

    private lazy var ciContext: CIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let maxPreviewWidth: CGFloat = 720

    public init() {}

    deinit {
        latestGeneration.withLock { $0 &+= 1 }
        let box = UncheckedSendableBox(value: (decoder, formatContext, avioContext))
        decoder = nil
        formatContext = nil
        avioContext = nil
        videoTrack = nil
        scrubOptions = nil
        if box.value.0 != nil || box.value.1 != nil || box.value.2 != nil {
            workQueue.async {
                box.value.0?.shutdown()
                box.value.1?.close()
                box.value.2?.close()
            }
        }
    }

    public var isReady: Bool {
        workQueue.sync {
            !isClosed && formatContext != nil && videoTrack != nil && decoder != nil
        }
    }

    public func resetTracking() {
        workQueue.async { [self] in
            lastRenderedPTS = Int64.min
            lastRenderedTime = -.infinity
            lastRequestedTarget = -.infinity
            demuxerIsContinuous = false
            demuxerCursorTime = -.infinity
        }
    }

    public func prepare(url: URL, directReader: (any SynchronousRandomAccessReader)? = nil) async {
        let alreadyPrepared: Bool = await withCheckedContinuation { cont in
            workQueue.async { [self] in
                cont.resume(returning: !isClosed && preparedURL == url && formatContext != nil && decoder != nil)
            }
        }
        if alreadyPrepared {
            directReader?.closeSync()
            return
        }

        let opts = KSOptions()
        opts.seekInterruptIO = true
        opts.seekFlags = 1
        opts.isAccurateSeek = false
        opts.autoSelectEmbedSubtitle = false
        opts.subtitleDisable = true
        opts.formatContextOptions["probesize"] = 512 * 1024
        opts.formatContextOptions["analyzeduration"] = 500_000
        opts.decoderOptions["threads"] = "4"
        opts.videoSoftDecodeThreadCount = 4

        var openedCtx: FormatContext?
        var openedAVIO: ScrubAVIOContext?

        if let directReader {
            let avio = ScrubAVIOContext(reader: directReader)
            if let directCtx = try? await FormatContext(io: .right(avio), options: opts),
               directCtx.assetTracks.contains(where: { $0.mediaType == .video }) {
                avio.finishOpenPhase()
                openedCtx = directCtx
                openedAVIO = avio
            } else {
                avio.close()
            }
        }

        if openedCtx == nil {
            openedCtx = try? await FormatContext(url: url, options: opts)
        }

        guard let ctx = openedCtx else { return }

        guard let vTrack = ctx.assetTracks.first(where: { $0.mediaType == .video && !$0.isImage && !$0.isStillImage })
            ?? ctx.assetTracks.first(where: { $0.mediaType == .video }) else {
            ctx.close()
            openedAVIO?.close()
            return
        }

        for track in ctx.assetTracks {
            let isVideo = (track.trackID == vTrack.trackID)
            track.isEnabled = isVideo
            #if canImport(Libavcodec) && canImport(Libavformat)
            if !isVideo, let stream = track.stream {
                stream.pointee.discard = AVDISCARD_ALL
            }
            #endif
        }

        let createdDecoder: any DecodeProtocol
        let isSW: Bool
        if let vt = VideoToolboxDecode(assetTrack: vTrack, options: opts, asynchronous: false) {
            createdDecoder = vt
            isSW = false
        } else {
            createdDecoder = FFmpegDecode(assetTrack: vTrack, options: opts)
            isSW = true
        }

        let payload = UncheckedSendableBox(value: (ctx, openedAVIO, vTrack, createdDecoder, opts, isSW))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            workQueue.async { [self] in
                let (c, a, v, d, o, sw) = payload.value
                if isClosed {
                    d.shutdown()
                    c.close()
                    a?.close()
                    cont.resume()
                    return
                }
                teardownOnQueue()
                preparedURL = url
                formatContext = c
                avioContext = a
                videoTrack = v
                decoder = d
                scrubOptions = o
                usingSoftwareFallback = sw
                cont.resume()
            }
        }
    }

    public func decodePreviewFrame(at targetTime: TimeInterval, requestedSpeed: Double = 8.0) async -> ScrubDecodeOutcome {
        let myGen = latestGeneration.withLock { gen -> UInt64 in
            gen &+= 1
            return gen
        }

        return await withCheckedContinuation { cont in
            workQueue.async { [self] in
                if isClosed || currentGeneration() != myGen {
                    cont.resume(returning: .unavailable)
                    return
                }
                let outcome = decodeOnQueue(
                    targetTime: max(0, targetTime),
                    requestedSpeed: max(1.0, requestedSpeed),
                    generation: myGen
                )
                cont.resume(returning: outcome)
            }
        }
    }

    public func close() async {
        latestGeneration.withLock { $0 &+= 1 }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            workQueue.async { [self] in
                isClosed = true
                teardownOnQueue()
                cont.resume()
            }
        }
    }

    private func currentGeneration() -> UInt64 {
        latestGeneration.withLock { $0 }
    }

    private func teardownOnQueue() {
        decoder?.shutdown()
        decoder = nil
        formatContext?.close()
        formatContext = nil
        avioContext?.close()
        avioContext = nil
        videoTrack = nil
        scrubOptions = nil
        preparedURL = nil
        usingSoftwareFallback = false
        lastRenderedPTS = Int64.min
        lastRenderedTime = -.infinity
        lastRequestedTarget = -.infinity
        demuxerIsContinuous = false
        demuxerCursorTime = -.infinity
    }

    private func frameSeconds(_ frame: VideoVTBFrame, vTrack: FFmpegAssetTrack, fallback: TimeInterval) -> TimeInterval {
        if frame.timestamp != Int64.min && frame.timestamp >= 0 {
            let sec = vTrack.seconds(for: frame.timestamp)
            if sec.isFinite && sec >= 0 {
                return sec
            }
        }
        return fallback
    }

    private func decodeOnQueue(targetTime: TimeInterval, requestedSpeed: Double, generation: UInt64) -> ScrubDecodeOutcome {
        guard let ctx = formatContext, let vTrack = videoTrack else {
            return .unavailable
        }

        let movingBackward = (lastRequestedTarget.isFinite && targetTime < lastRequestedTarget - 0.15)
        let movingForward = !movingBackward
        lastRequestedTarget = targetTime

        var frame: VideoVTBFrame?
        let preferSequential = !usingSoftwareFallback && requestedSpeed <= 10.0

        if movingForward {
            if demuxerIsContinuous, lastRenderedTime.isFinite, targetTime <= demuxerCursorTime + 0.02 {
                return .unchanged(actualTime: lastRenderedTime)
            }

            let priorCursor = demuxerCursorTime
            if preferSequential,
               demuxerIsContinuous,
               priorCursor.isFinite,
               targetTime > priorCursor,
               (targetTime - priorCursor) <= 4.0 {
                if let stepped = stepForwardWithoutSeek(
                    ctx: ctx,
                    vTrack: vTrack,
                    targetTime: targetTime,
                    generation: generation,
                    maxVideoFrames: 48,
                    timeBudget: 0.045
                ) {
                    let steppedTime = frameSeconds(stepped, vTrack: vTrack, fallback: targetTime)
                    if steppedTime > priorCursor + 0.01 {
                        frame = stepped
                    }
                }
                if currentGeneration() != generation || isClosed {
                    demuxerIsContinuous = false
                    return .unavailable
                }
            }

            if frame == nil {
                demuxerIsContinuous = false
                var primary = seekAndDecodeSingleFrame(
                    ctx: ctx,
                    vTrack: vTrack,
                    seekTime: targetTime,
                    flags: 1,
                    generation: generation
                )

                if let f1 = primary {
                    let t1 = frameSeconds(f1, vTrack: vTrack, fallback: targetTime)
                    let behindLast = lastRenderedTime.isFinite && (t1 <= lastRenderedTime + 0.04)
                    let stepFromCursor = lastRenderedTime.isFinite ? lastRenderedTime : t1
                    let forwardGap = targetTime - t1

                    if behindLast {
                        if preferSequential,
                           forwardGap <= 4.5,
                           targetTime > stepFromCursor,
                           let stepped = stepForwardWithoutSeek(
                               ctx: ctx,
                               vTrack: vTrack,
                               targetTime: targetTime,
                               generation: generation,
                               maxVideoFrames: 54,
                               timeBudget: 0.06
                           ) {
                            primary = stepped
                        } else if let nextIFrame = seekAndDecodeSingleFrame(
                            ctx: ctx,
                            vTrack: vTrack,
                            seekTime: max(targetTime, stepFromCursor + 0.5),
                            flags: 0,
                            generation: generation
                        ) {
                            primary = nextIFrame
                        }
                    } else if !lastRenderedTime.isFinite,
                              preferSequential,
                              forwardGap > 0.15,
                              forwardGap <= 4.0,
                              let stepped = stepForwardWithoutSeek(
                                  ctx: ctx,
                                  vTrack: vTrack,
                                  targetTime: targetTime,
                                  generation: generation,
                                  maxVideoFrames: 64,
                                  timeBudget: 0.075
                              ) {
                        primary = stepped
                    }
                }

                frame = primary
            }
        } else {
            demuxerIsContinuous = false
            var primary = seekAndDecodeSingleFrame(
                ctx: ctx,
                vTrack: vTrack,
                seekTime: targetTime,
                flags: 1,
                generation: generation
            )

            if let f1 = primary,
               lastRenderedTime.isFinite,
               lastRenderedTime > 0.5,
               currentGeneration() == generation,
               !isClosed {
                let t1 = frameSeconds(f1, vTrack: vTrack, fallback: targetTime)
                let stuckOnSameGOP = (f1.timestamp != Int64.min && f1.timestamp == lastRenderedPTS)
                    || (t1 >= lastRenderedTime - 0.05)
                if stuckOnSameGOP && (lastRenderedTime - targetTime) >= 0.8 {
                    if let earlier1 = seekAndDecodeSingleFrame(
                        ctx: ctx,
                        vTrack: vTrack,
                        seekTime: max(0, lastRenderedTime - 1.2),
                        flags: 1,
                        generation: generation
                    ) {
                        let e1Time = frameSeconds(earlier1, vTrack: vTrack, fallback: targetTime)
                        if (earlier1.timestamp != lastRenderedPTS && e1Time < lastRenderedTime - 0.05) || lastRenderedTime <= 3.0 {
                            primary = earlier1
                        } else if let earlier2 = seekAndDecodeSingleFrame(
                            ctx: ctx,
                            vTrack: vTrack,
                            seekTime: max(0, lastRenderedTime - 9.0),
                            flags: 1,
                            generation: generation
                        ) {
                            primary = earlier2
                        }
                    }
                }
            }

            frame = primary
        }

        guard let decoded = frame else {
            demuxerIsContinuous = false
            return .unavailable
        }
        if currentGeneration() != generation || isClosed {
            demuxerIsContinuous = false
            return .unavailable
        }

        let actualTime = frameSeconds(decoded, vTrack: vTrack, fallback: targetTime)
        demuxerIsContinuous = true
        demuxerCursorTime = actualTime

        if decoded.timestamp != Int64.min && decoded.timestamp == lastRenderedPTS {
            return .unchanged(actualTime: actualTime)
        }
        if movingForward, lastRenderedTime.isFinite, actualTime < lastRenderedTime - 0.05 {
            demuxerCursorTime = lastRenderedTime
            return .unchanged(actualTime: lastRenderedTime)
        }
        if movingBackward, lastRenderedTime.isFinite, actualTime > lastRenderedTime + 0.05 {
            demuxerCursorTime = lastRenderedTime
            return .unchanged(actualTime: lastRenderedTime)
        }

        if let cvBuffer = decoded.pixelBuffer.cvPixelBuffer {
            lastRenderedPTS = decoded.timestamp
            lastRenderedTime = actualTime
            return .frame(ScrubPreviewFrame(pixelBuffer: cvBuffer, rotation: vTrack.rotation, actualTime: actualTime))
        }

        guard let cgImage = renderPreviewCGImage(from: decoded, rotation: vTrack.rotation) else {
            return .unavailable
        }

        lastRenderedPTS = decoded.timestamp
        lastRenderedTime = actualTime
        return .frame(ScrubPreviewFrame(cgImage: cgImage, actualTime: actualTime))
    }

    private func decodeVideoPacket(
        _ corePkt: UnsafeMutablePointer<AVPacket>,
        vTrack: FFmpegAssetTrack,
        consecutiveErrors: inout Int
    ) -> VideoVTBFrame? {
        guard var activeDecoder = decoder else { return nil }
        var localFrame: VideoVTBFrame?
        var localError = false

        activeDecoder.decodeFrame(from: corePkt) { result in
            switch result {
            case .success(let meFrame):
                if let vFrame = meFrame as? VideoVTBFrame {
                    localFrame = vFrame
                }
            case .failure:
                localError = true
            }
        }

        if let localFrame {
            consecutiveErrors = 0
            return localFrame
        }

        if localError {
            consecutiveErrors += 1
            if consecutiveErrors >= 2 && !usingSoftwareFallback, let opts = scrubOptions {
                activeDecoder.shutdown()
                let swDecoder = FFmpegDecode(assetTrack: vTrack, options: opts)
                self.decoder = swDecoder
                self.usingSoftwareFallback = true
                activeDecoder = swDecoder

                var swFrame: VideoVTBFrame?
                activeDecoder.decodeFrame(from: corePkt) { result in
                    if case .success(let meFrame) = result, let vFrame = meFrame as? VideoVTBFrame {
                        swFrame = vFrame
                    }
                }
                return swFrame
            }
        }
        return nil
    }

    private func stepForwardWithoutSeek(
        ctx: FormatContext,
        vTrack: FFmpegAssetTrack,
        targetTime: TimeInterval,
        generation: UInt64,
        maxVideoFrames: Int,
        timeBudget: TimeInterval = 0.05
    ) -> VideoVTBFrame? {
        guard decoder != nil else { return nil }

        var totalPackets = 0
        var videoFramesDecoded = 0
        var consecutiveErrors = 0
        var bestFrame: VideoVTBFrame?
        var bestTime: TimeInterval = -.infinity

        let deadline = CFAbsoluteTimeGetCurrent() + timeBudget
        while totalPackets < 260 && videoFramesDecoded < maxVideoFrames && CFAbsoluteTimeGetCurrent() < deadline {
            if currentGeneration() != generation || isClosed { return nil }
            guard let packet = ctx.read() else { break }
            totalPackets += 1

            guard let pktTrack = packet.assetTrack,
                  pktTrack.trackID == vTrack.trackID,
                  let corePkt = packet.corePacket else {
                continue
            }

            if let decoded = decodeVideoPacket(corePkt, vTrack: vTrack, consecutiveErrors: &consecutiveErrors) {
                videoFramesDecoded += 1
                let sec = frameSeconds(decoded, vTrack: vTrack, fallback: targetTime)
                if !bestTime.isFinite || sec >= bestTime {
                    bestFrame = decoded
                    bestTime = sec
                }
                if sec >= targetTime - 0.03 {
                    break
                }
            }
        }

        return bestFrame
    }

    private func seekAndDecodeSingleFrame(
        ctx: FormatContext,
        vTrack: FFmpegAssetTrack,
        seekTime: TimeInterval,
        flags: Int32,
        generation: UInt64
    ) -> VideoVTBFrame? {
        guard let activeDecoder = decoder else { return nil }

        let seekResult = ctx.performSeek(time: max(0, seekTime), flags: flags, streamIndex: vTrack.trackID)
        if seekResult < 0 {
            let fallbackSeek = ctx.performSeek(time: max(0, seekTime), flags: flags, streamIndex: -1)
            if fallbackSeek < 0 { return nil }
        }
        activeDecoder.doFlushCodec()

        if currentGeneration() != generation || isClosed { return nil }

        var seenKeyframe = false
        var totalPackets = 0
        var videoPacketsFed = 0
        var consecutiveErrors = 0
        var decodedFrame: VideoVTBFrame?

        while totalPackets < 240 && videoPacketsFed < 32 && decodedFrame == nil {
            if currentGeneration() != generation || isClosed { return nil }
            guard let packet = ctx.read() else { break }
            totalPackets += 1

            guard let pktTrack = packet.assetTrack,
                  pktTrack.trackID == vTrack.trackID,
                  let corePkt = packet.corePacket else {
                continue
            }

            if !seenKeyframe {
                if corePkt.pointee.isKeyFrame {
                    seenKeyframe = true
                } else if totalPackets < 80 {
                    continue
                } else {
                    seenKeyframe = true
                }
            }

            videoPacketsFed += 1
            if let decoded = decodeVideoPacket(corePkt, vTrack: vTrack, consecutiveErrors: &consecutiveErrors) {
                decodedFrame = decoded
                break
            }
        }

        return decodedFrame
    }

    private func renderPreviewCGImage(from frame: VideoVTBFrame, rotation: UInt16) -> CGImage? {
        if let cvBuffer = frame.pixelBuffer.cvPixelBuffer {
            var ciImage = CIImage(cvPixelBuffer: cvBuffer)
            if rotation == 90 { ciImage = ciImage.oriented(.right) }
            else if rotation == 180 { ciImage = ciImage.oriented(.down) }
            else if rotation == 270 { ciImage = ciImage.oriented(.left) }

            let extent = ciImage.extent
            guard extent.width > 0, extent.height > 0 else { return nil }
            if extent.width > maxPreviewWidth {
                let scale = maxPreviewWidth / extent.width
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            return ciContext.createCGImage(ciImage, from: ciImage.extent.integral, format: .RGBA8, colorSpace: srgbColorSpace)
        }

        guard let rawCG = frame.pixelBuffer.cgImage() else { return nil }
        if CGFloat(rawCG.width) <= maxPreviewWidth && rotation == 0 {
            return rawCG
        }
        var ciImage = CIImage(cgImage: rawCG)
        if rotation == 90 { ciImage = ciImage.oriented(.right) }
        else if rotation == 180 { ciImage = ciImage.oriented(.down) }
        else if rotation == 270 { ciImage = ciImage.oriented(.left) }
        let extent = ciImage.extent
        if extent.width > maxPreviewWidth {
            let scale = maxPreviewWidth / extent.width
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return ciContext.createCGImage(ciImage, from: ciImage.extent.integral, format: .RGBA8, colorSpace: srgbColorSpace)
    }
}

#else
/// Simulator fallback backed by `AVAssetImageGenerator` (Swift 6 strict-concurrency safe).
public final class LiveKeyframeScrubEngine: @unchecked Sendable {
    private final class GeneratorBox: @unchecked Sendable {
        let generator: AVAssetImageGenerator
        init(_ generator: AVAssetImageGenerator) { self.generator = generator }
    }

    private let boxLock = OSAllocatedUnfairLock<GeneratorBox?>(initialState: nil)

    public init() {}

    public var isReady: Bool {
        boxLock.withLock { $0 != nil }
    }

    public func resetTracking() {}

    public func prepare(url: URL, directReader: (any SynchronousRandomAccessReader)? = nil) async {
        directReader?.closeSync()
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 540)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let box = GeneratorBox(gen)
        boxLock.withLock { $0 = box }
    }

    public func decodePreviewFrame(at targetTime: TimeInterval, requestedSpeed: Double = 8.0) async -> ScrubDecodeOutcome {
        _ = requestedSpeed
        guard let box = boxLock.withLock({ $0 }) else { return .unavailable }
        let cmTime = CMTime(seconds: max(0, targetTime), preferredTimescale: 600)
        do {
            let (image, actual) = try await box.generator.image(at: cmTime)
            let sec = actual.isNumeric ? actual.seconds : targetTime
            return .frame(ScrubPreviewFrame(cgImage: image, actualTime: sec))
        } catch {
            return .unavailable
        }
    }

    public func close() async {
        let box = boxLock.withLock { current -> GeneratorBox? in
            let saved = current
            current = nil
            return saved
        }
        box?.generator.cancelAllCGImageGeneration()
    }
}
#endif
