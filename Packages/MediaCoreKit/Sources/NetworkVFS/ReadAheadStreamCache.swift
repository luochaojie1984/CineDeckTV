import Foundation

/// 底层随机读数据源（SMB 常驻句柄 / WebDAV Range 请求都实现它）。
public protocol StreamChunkSource: Sendable {
    func contentLength() async throws -> Int64
    func read(offset: Int64, length: Int) async throws -> Data
}

/// 预读缓存配置。数值取自设计规划 5.5 / 6.3 的实测结论。
public struct ReadAheadCacheConfig: Sendable {
    /// 常规播放分块大小：2 MB（始终固定用于 chunks 字典索引，绝不与快进微缓存混用）。
    public var chunkSize: Int = 2 * 1024 * 1024
    /// Jetsam 硬上限：<= 192 MB，默认 96 MB。
    public var maxCacheBytes: Int = 96 * 1024 * 1024
    /// 头尾保护上限：16 MB（覆盖 10–14 MB 的尾部 moov）。
    public var maxProtectedEdgeBytes: Int = 16 * 1024 * 1024
    /// 头尾保护下限：4 MB。
    public var minProtectedEdgeBytes: Int = 4 * 1024 * 1024
    /// 快进模式单次微缓存：512 KB。
    public var scrubBypassChunkSize: Int = 512 * 1024
    /// 顺序播放向前异步预读块数。
    public var readAheadChunkCount: Int = 2
    /// 大跨度随机跳判定阈值（触发取消旧预读任务）。
    public var largeSeekThresholdBytes: Int64 = 8 * 1024 * 1024

    public init() {}

    /// 动态头尾保护量：min(16MB, max(4MB, maxCacheBytes / 4))。
    public var protectedEdgeBytes: Int {
        min(maxProtectedEdgeBytes, max(minProtectedEdgeBytes, maxCacheBytes / 4))
    }
}

/// 2 MB 固定分块 + 头尾 moov 钉住 + LRU 淘汰 + 单槽 512 KB 快进微缓存 + 异步顺序预读。
/// 全部状态由 actor 串行化，跨线程安全。
public actor ReadAheadStreamCache {
    public struct Statistics: Sendable, Equatable {
        public var hits: Int = 0
        public var misses: Int = 0
        public var evictions: Int = 0
        public var bytesFetched: Int = 0
        public var cachedBytes: Int = 0
        public var prefetches: Int = 0
    }

    private let source: any StreamChunkSource
    private let config: ReadAheadCacheConfig
    /// 始终以 fixed config.chunkSize (2 MB) 为索引单位，永不因 scrubMode 切换而错位。
    private var chunks: [Int64: Data] = [:]
    private var lastUse: [Int64: UInt64] = [:]
    private var clock: UInt64 = 0
    private var totalSize: Int64 = -1
    private var scrubMode = false
    private var pinnedHeadChunks: Set<Int64> = []
    private var pinnedTailChunks: Set<Int64> = []

    /// 快进模式专用单槽 512 KB 微缓存（与 2 MB 主缓存字典物理隔离）。
    private var scrubMicroStart: Int64 = -1
    private var scrubMicroData = Data()

    /// 异步预读与并发去重。
    private var inFlightLoads: [Int64: Task<Data, Error>] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var lastSequentialEnd: Int64 = -1

    public private(set) var statistics = Statistics()

    public init(source: any StreamChunkSource, config: ReadAheadCacheConfig = .init()) {
        self.source = source
        self.config = config
    }

    public var isScrubMode: Bool { scrubMode }
    public var contentSize: Int64 { totalSize }

    /// 进入/退出快进绕行：绕行时启用单槽 512 KB 微缓存并取消后台预读，绝不破坏主缓存索引。
    public func setScrubMode(_ enabled: Bool) {
        guard scrubMode != enabled else { return }
        scrubMode = enabled
        if enabled {
            cancelBackgroundPrefetch()
            for key in chunks.keys where !pinnedHeadChunks.contains(key) && !pinnedTailChunks.contains(key) {
                chunks.removeValue(forKey: key)
                lastUse.removeValue(forKey: key)
            }
            recalcCachedBytes()
        } else {
            scrubMicroStart = -1
            scrubMicroData.removeAll(keepingCapacity: false)
        }
    }

    /// 打开文件后非阻塞初始化：记录总长与头尾钉住集合（仅在显式提供 <= 24 MB 的尾部 moov 区间时主动预载，避免开片 32 MB 阻塞）。
    public func prepare(totalSize size: Int64, moovOffset: Int64? = nil, moovLength: Int = 0) async throws {
        totalSize = size
        guard size > 0 else { return }
        let protect = Int64(config.protectedEdgeBytes)
        let headRange = Int64(0)..<min(size, protect)
        var tailStart = max(0, size - protect)
        if let moovOffset, moovLength > 0, moovOffset > size / 2 {
            tailStart = min(tailStart, moovOffset)
        }
        pinnedHeadChunks = Set(chunkIndexes(for: headRange))
        pinnedTailChunks = Set(chunkIndexes(for: tailStart..<size))
        if let moovOffset, moovLength > 0, moovLength <= 24 * 1024 * 1024 {
            let moovEnd = min(size, moovOffset + Int64(moovLength))
            try await prefetch(ranges: [moovOffset..<moovEnd])
        }
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        guard length > 0, offset >= 0 else { return Data() }
        if totalSize < 0 { totalSize = try await source.contentLength() }
        let upper = min(Int64(length), max(0, totalSize - offset))
        guard upper > 0 else { return Data() }

        if scrubMode {
            return try await readDuringScrub(offset: offset, length: Int(upper))
        }

        // 大跨度跳转时取消旧顺序预读任务，避免浪费局域网带宽。
        if lastSequentialEnd >= 0 && abs(offset - lastSequentialEnd) > config.largeSeekThresholdBytes {
            cancelBackgroundPrefetch()
        }

        let range = offset..<(offset + upper)
        let indexes = chunkIndexes(for: range)

        var out = Data(capacity: Int(upper))
        for idx in indexes {
            let chunk = try await obtainMainChunk(idx)
            let chunkStart = idx * Int64(config.chunkSize)
            let localStart = max(0, Int(offset - chunkStart))
            let localEnd = min(chunk.count, Int(offset + upper - chunkStart))
            if localEnd > localStart {
                let base = chunk.startIndex
                out.append(chunk[(base + localStart)..<(base + localEnd)])
            }
        }

        let endOffset = offset + upper
        let isSequentialStep = lastSequentialEnd > 0
            && offset >= max(0, lastSequentialEnd - 65_536)
            && offset <= lastSequentialEnd + Int64(config.chunkSize)
            && endOffset > lastSequentialEnd
        lastSequentialEnd = endOffset

        if isSequentialStep, let lastIdx = indexes.last {
            schedulePrefetch(afterChunk: lastIdx)
        }
        return out
    }

    /// 仅探测 MP4 顶部 atoms，定位 moov（最多走 16 步；覆盖 moov 在 5 GB 文件末尾的情况）。
    public func locateMP4Moov() async throws -> (offset: Int64, length: Int)? {
        if totalSize < 0 { totalSize = try await source.contentLength() }
        var cursor: Int64 = 0
        for _ in 0..<16 {
            let header = try await read(offset: cursor, length: 16)
            guard header.count >= 8 else { return nil }
            let size32 = header.readBigEndianUInt32(at: 0)
            let base = header.startIndex
            let type = String(bytes: header[(base + 4)..<(base + 8)], encoding: .ascii) ?? ""
            var atomSize = Int64(size32)
            var headerLen: Int64 = 8
            if size32 == 1 {
                guard header.count >= 16 else { return nil }
                atomSize = Int64(bitPattern: header.readBigEndianUInt64(at: 8))
                headerLen = 16
            } else if size32 == 0 {
                atomSize = totalSize - cursor
            }
            if atomSize < headerLen { return nil }
            if type == "moov" {
                return (cursor, Int(min(atomSize, Int64(Int.max))))
            }
            cursor += atomSize
            if cursor >= totalSize { return nil }
        }
        return nil
    }

    /// 供本地 HTTP 代理获取总长度（首次调用会探测一次）。
    public func fetchContentSize() async throws -> Int64 {
        if totalSize < 0 { totalSize = try await source.contentLength() }
        return totalSize
    }

    public func trimAll() {
        cancelBackgroundPrefetch()
        chunks.removeAll()
        lastUse.removeAll()
        scrubMicroStart = -1
        scrubMicroData.removeAll(keepingCapacity: false)
        recalcCachedBytes()
    }

    // MARK: - 内部实现

    private func readDuringScrub(offset: Int64, length: Int) async throws -> Data {
        let range = offset..<(offset + Int64(length))
        let indexes = chunkIndexes(for: range)
        // 若全部落在已缓存的 2 MB 块（如头尾 moov 块）中，零额外 I/O 直接命中！
        if indexes.allSatisfy({ chunks[$0] != nil }) {
            var out = Data(capacity: length)
            for idx in indexes {
                if let chunk = chunks[idx] {
                    touch(idx)
                    statistics.hits += 1
                    let chunkStart = idx * Int64(config.chunkSize)
                    let localStart = max(0, Int(offset - chunkStart))
                    let localEnd = min(chunk.count, Int(offset + Int64(length) - chunkStart))
                    if localEnd > localStart {
                        let base = chunk.startIndex
                        out.append(chunk[(base + localStart)..<(base + localEnd)])
                    }
                }
            }
            return out
        }

        // 检查单槽 512 KB 微缓存是否覆盖整个区间
        if scrubMicroStart >= 0,
           offset >= scrubMicroStart,
           offset + Int64(length) <= scrubMicroStart + Int64(scrubMicroData.count) {
            statistics.hits += 1
            let localStart = Int(offset - scrubMicroStart)
            let base = scrubMicroData.startIndex
            return Data(scrubMicroData[(base + localStart)..<(base + localStart + length)])
        }

        statistics.misses += 1
        let fetchLen = min(
            max(length, config.scrubBypassChunkSize),
            Int(max(0, totalSize - offset))
        )
        let data = try await source.read(offset: offset, length: fetchLen)
        statistics.bytesFetched += data.count
        let owned = Data(data)
        if owned.count <= max(length, config.scrubBypassChunkSize) {
            scrubMicroStart = offset
            scrubMicroData = owned
        }
        let sliceLen = min(length, owned.count)
        return Data(owned.prefix(sliceLen))
    }

    private func obtainMainChunk(_ index: Int64) async throws -> Data {
        if let existing = chunks[index] {
            touch(index)
            statistics.hits += 1
            return existing
        }

        if let task = inFlightLoads[index] {
            statistics.hits += 1
            return try await task.value
        }

        statistics.misses += 1
        let chunkSize = config.chunkSize
        let sizeSnapshot = totalSize
        let sourceRef = source
        let task = Task<Data, Error> {
            let offset = index * Int64(chunkSize)
            let wanted = sizeSnapshot >= 0 ? min(chunkSize, Int(max(0, sizeSnapshot - offset))) : chunkSize
            return try await sourceRef.read(offset: offset, length: wanted)
        }
        inFlightLoads[index] = task
        do {
            let data = try await task.value
            inFlightLoads.removeValue(forKey: index)
            chunks[index] = Data(data)
            touch(index)
            statistics.bytesFetched += data.count
            evictIfNeeded()
            recalcCachedBytes()
            return data
        } catch {
            inFlightLoads.removeValue(forKey: index)
            throw error
        }
    }

    private func schedulePrefetch(afterChunk lastIdx: Int64) {
        guard !scrubMode, config.readAheadChunkCount > 0, totalSize > 0 else { return }
        let maxChunkIdx = (totalSize - 1) / Int64(config.chunkSize)
        var targets: [Int64] = []
        for delta in 1...config.readAheadChunkCount {
            let nextIdx = lastIdx + Int64(delta)
            if nextIdx <= maxChunkIdx && chunks[nextIdx] == nil && inFlightLoads[nextIdx] == nil {
                targets.append(nextIdx)
            }
        }
        guard !targets.isEmpty else { return }
        cancelBackgroundPrefetch()
        prefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            for idx in targets {
                if Task.isCancelled { return }
                let stillScrub = await self.isScrubMode
                if stillScrub { return }
                await self.prefetchSingleChunk(idx)
            }
        }
    }

    private func prefetchSingleChunk(_ index: Int64) async {
        guard !scrubMode, chunks[index] == nil else { return }
        do {
            _ = try await obtainMainChunk(index)
            statistics.prefetches += 1
        } catch {
            // 后台预读失败静默忽略，真正消费时再报错
        }
    }

    private func cancelBackgroundPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    private func chunkIndexes(for range: Range<Int64>) -> [Int64] {
        let size = Int64(config.chunkSize)
        guard range.upperBound > range.lowerBound else { return [] }
        let first = range.lowerBound / size
        let last = (range.upperBound - 1) / size
        return Array(first...last)
    }

    private func prefetch(ranges: [Range<Int64>]) async throws {
        for range in ranges {
            for index in chunkIndexes(for: range) where chunks[index] == nil {
                _ = try await obtainMainChunk(index)
            }
        }
    }

    private func touch(_ index: Int64) {
        clock &+= 1
        lastUse[index] = clock
    }

    private func evictIfNeeded() {
        let pinned = pinnedHeadChunks.union(pinnedTailChunks)
        var totalCached = chunks.values.reduce(0) { $0 + $1.count }
        while totalCached > config.maxCacheBytes {
            let candidates = lastUse.filter { !pinned.contains($0.key) }
            guard let victim = candidates.min(by: { $0.value < $1.value })?.key else { break }
            let removedSize = chunks.removeValue(forKey: victim)?.count ?? 0
            lastUse.removeValue(forKey: victim)
            totalCached -= removedSize
            statistics.evictions += 1
        }
    }

    private func recalcCachedBytes() {
        statistics.cachedBytes = chunks.values.reduce(0) { $0 + $1.count }
    }
}

extension Data {
    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1])
        let b2 = UInt32(self[startIndex + offset + 2])
        let b3 = UInt32(self[startIndex + offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        guard count >= offset + 8 else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(self[startIndex + offset + i]) }
        return value
    }
}
