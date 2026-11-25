import Foundation

/// 底层随机读数据源（SMB 常驻句柄 / WebDAV Range 请求都实现它）。
public protocol StreamChunkSource: Sendable {
    func contentLength() async throws -> Int64
    func read(offset: Int64, length: Int) async throws -> Data
}

/// 预读缓存配置。数值取自设计规划 5.5 / 6.3 的实测结论。
public struct ReadAheadCacheConfig: Sendable {
    /// 常规播放分块大小：2 MB。
    public var chunkSize: Int = 2 * 1024 * 1024
    /// Jetsam 硬上限：<= 192 MB，默认 96 MB。
    public var maxCacheBytes: Int = 96 * 1024 * 1024
    /// 头尾保护上限：16 MB（覆盖 10–14 MB 的尾部 moov）。
    public var maxProtectedEdgeBytes: Int = 16 * 1024 * 1024
    /// 头尾保护下限：4 MB。
    public var minProtectedEdgeBytes: Int = 4 * 1024 * 1024
    /// 快进模式单次微缓存：512 KB。
    public var scrubBypassChunkSize: Int = 512 * 1024

    public init() {}

    /// 动态头尾保护量：min(16MB, max(4MB, maxCacheBytes / 4))。
    public var protectedEdgeBytes: Int {
        min(maxProtectedEdgeBytes, max(minProtectedEdgeBytes, maxCacheBytes / 4))
    }
}

/// 2 MB 分块 + 头尾 moov 钉住 + LRU 淘汰 + 快进绕行的读缓存。
/// 全部状态由 actor 串行化，跨线程安全。
public actor ReadAheadStreamCache {
    public struct Statistics: Sendable, Equatable {
        public var hits: Int = 0
        public var misses: Int = 0
        public var evictions: Int = 0
        public var bytesFetched: Int = 0
        public var cachedBytes: Int = 0
    }

    private let source: any StreamChunkSource
    private let config: ReadAheadCacheConfig
    private var chunks: [Int64: Data] = [:]
    private var lastUse: [Int64: UInt64] = [:]
    private var clock: UInt64 = 0
    private var totalSize: Int64 = -1
    private var scrubMode = false
    private var pinnedHeadChunks: Set<Int64> = []
    private var pinnedTailChunks: Set<Int64> = []
    public private(set) var statistics = Statistics()

    public init(source: any StreamChunkSource, config: ReadAheadCacheConfig = .init()) {
        self.source = source
        self.config = config
    }

    public var isScrubMode: Bool { scrubMode }
    public var contentSize: Int64 { totalSize }

    /// 进入/退出快进绕行：绕行时改用 512 KB 微缓存，并清掉非保护块以腾出内存。
    public func setScrubMode(_ enabled: Bool) {
        guard scrubMode != enabled else { return }
        scrubMode = enabled
        if enabled {
            for key in chunks.keys where !pinnedHeadChunks.contains(key) && !pinnedTailChunks.contains(key) {
                chunks.removeValue(forKey: key)
                lastUse.removeValue(forKey: key)
            }
            recalcCachedBytes()
        }
    }

    /// 打开文件后调用：探测 MP4 头尾，把头部与尾部 moov 区域钉进内存。
    public func prepare(totalSize size: Int64, moovOffset: Int64? = nil, moovLength: Int = 0) async throws {
        totalSize = size
        let protect = Int64(config.protectedEdgeBytes)
        let headRange = Int64(0)..<min(size, protect)
        var tailStart = max(0, size - protect)
        if let moovOffset, moovLength > 0 {
            // moov 落在尾部时把它整块纳入保护区间。
            let moovEnd = moovOffset + Int64(moovLength)
            if moovOffset > size / 2 {
                tailStart = min(tailStart, moovOffset)
                _ = moovEnd
            }
        }
        pinnedHeadChunks = Set(chunkIndexes(for: headRange))
        pinnedTailChunks = Set(chunkIndexes(for: tailStart..<size))
        try await prefetch(ranges: [headRange, tailStart..<size])
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        if totalSize < 0 { totalSize = try await source.contentLength() }
        let upper = min(Int64(length), max(0, totalSize - offset))
        guard upper > 0 else { return Data() }

        let range = offset..<(offset + upper)
        let indexes = chunkIndexes(for: range)
        var missing: [Int64] = []
        for idx in indexes {
            if chunks[idx] == nil { missing.append(idx) } else { touch(idx); statistics.hits += 1 }
        }
        if !missing.isEmpty {
            statistics.misses += missing.count
            for idx in missing {
                let data = try await fetchChunk(idx)
                chunks[idx] = data
                touch(idx)
                statistics.bytesFetched += data.count
            }
            evictIfNeeded()
        }
        var out = Data(capacity: Int(upper))
        for idx in indexes {
            guard let chunk = chunks[idx] else { continue }
            let chunkStart = idx * Int64(effectiveChunkSize)
            let localStart = max(0, Int(offset - chunkStart))
            let localEnd = min(chunk.count, Int(offset + Int64(upper) - chunkStart))
            if localEnd > localStart { out.append(chunk[localStart..<localEnd]) }
        }
        recalcCachedBytes()
        return out
    }

    /// 仅探测 MP4 顶部 atoms，定位 moov（最多走 16 步；覆盖 moov 在 5 GB 文件末尾的情况）。
    public func locateMP4Moov() async throws -> (offset: Int64, length: Int)? {
        var cursor: Int64 = 0
        for _ in 0..<16 {
            let header = try await read(offset: cursor, length: 16)
            guard header.count >= 8 else { return nil }
            let size32 = header.readBigEndianUInt32(at: 0)
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
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
            if type == "mdat" { return nil }
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
        chunks.removeAll()
        lastUse.removeAll()
        recalcCachedBytes()
    }

    // MARK: - 内部

    private var effectiveChunkSize: Int { scrubMode ? config.scrubBypassChunkSize : config.chunkSize }

    private func chunkIndexes(for range: Range<Int64>) -> [Int64] {
        let size = Int64(effectiveChunkSize)
        guard range.upperBound > range.lowerBound else { return [] }
        let first = range.lowerBound / size
        let last = (range.upperBound - 1) / size
        return Array(first...last)
    }

    private func fetchChunk(_ index: Int64) async throws -> Data {
        let size = Int64(effectiveChunkSize)
        let offset = index * size
        let wanted = totalSize >= 0 ? min(size, max(0, totalSize - offset)) : size
        return try await source.read(offset: offset, length: Int(wanted))
    }

    private func prefetch(ranges: [Range<Int64>]) async throws {
        for range in ranges {
            for index in chunkIndexes(for: range) where chunks[index] == nil {
                let data = try await fetchChunk(index)
                chunks[index] = data
                touch(index)
                statistics.bytesFetched += data.count
            }
        }
        evictIfNeeded()
        recalcCachedBytes()
    }

    private func touch(_ index: Int64) {
        clock &+= 1
        lastUse[index] = clock
    }

    private func evictIfNeeded() {
        let pinned = pinnedHeadChunks.union(pinnedTailChunks)
        while chunks.count * effectiveChunkSize > config.maxCacheBytes {
            let candidates = lastUse.filter { !pinned.contains($0.key) }
            guard let victim = candidates.min(by: { $0.value < $1.value })?.key else { break }
            chunks.removeValue(forKey: victim)
            lastUse.removeValue(forKey: victim)
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
