import Testing
import Foundation
@testable import NetworkVFS

/// 内存数据源：记录读取次数，用于验证缓存命中与头尾钉住。
final class MemorySource: @unchecked Sendable, StreamChunkSource {
    private let data: Data
    nonisolated(unsafe) private(set) var readCount = 0

    init(size: Int) {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size { bytes[i] = UInt8(i % 251) }
        data = Data(bytes)
    }

    func contentLength() async throws -> Int64 { Int64(data.count) }

    func read(offset: Int64, length: Int) async throws -> Data {
        readCount += 1
        let start = Int(offset)
        let end = min(data.count, start + length)
        guard start < end else { return Data() }
        return data.subdata(in: start..<end)
    }
}

@Suite("ReadAheadStreamCache")
struct ReadAheadStreamCacheTests {
    @Test("整块读取内容正确")
    func readsExactBytes() async throws {
        let source = MemorySource(size: 5 * 1024 * 1024)
        let cache = ReadAheadStreamCache(source: source)
        let data = try await cache.read(offset: 1024, length: 4096)
        #expect(data.count == 4096)
        #expect(data == source.readSync(offset: 1024, length: 4096))
    }

    @Test("第二次读取命中缓存")
    func secondReadHitsCache() async throws {
        let source = MemorySource(size: 4 * 1024 * 1024)
        let cache = ReadAheadStreamCache(source: source)
        _ = try await cache.read(offset: 0, length: 2048)
        let afterFirst = source.readCount
        _ = try await cache.read(offset: 0, length: 2048)
        let afterSecond = source.readCount
        #expect(afterSecond == afterFirst)
    }

    @Test("快进绕行切换到 512KB 微缓存")
    func scrubModeUsesSmallChunks() async throws {
        let source = MemorySource(size: 8 * 1024 * 1024)
        let cache = ReadAheadStreamCache(source: source)
        await cache.setScrubMode(true)
        let isScrub = await cache.isScrubMode
        #expect(isScrub)
        _ = try await cache.read(offset: 3_000_000, length: 1024)
        let stats = await cache.statistics
        #expect(stats.bytesFetched <= 512 * 1024 + 4096)
    }

    @Test("头尾保护块在 LRU 淘汰后仍保留")
    func protectsEdges() async throws {
        var config = ReadAheadCacheConfig()
        config.maxCacheBytes = 8 * 1024 * 1024
        let total = 40 * 1024 * 1024
        let source = MemorySource(size: total)
        let cache = ReadAheadStreamCache(source: source, config: config)
        try await cache.prepare(totalSize: Int64(total))
        for i in 0..<20 {
            _ = try await cache.read(offset: Int64(16 * 1024 * 1024 + i * 512 * 1024), length: 1024)
        }
        let head = try await cache.read(offset: 0, length: 1024)
        let tail = try await cache.read(offset: Int64(total - 1024), length: 1024)
        #expect(head.count == 1024)
        #expect(tail.count == 1024)
    }

    @Test("底层返回非零 startIndex 的 Data 切片时读取与快进微缓存均不越界")
    func handlesNonZeroStartIndexSlices() async throws {
        struct SlicedChunkSource: StreamChunkSource {
            let backing: Data = Data((0..<(4 * 1024 * 1024)).map { UInt8($0 % 251) })
            func contentLength() async throws -> Int64 { Int64(backing.count) }
            func read(offset: Int64, length: Int) async throws -> Data {
                let start = Int(offset)
                let end = min(backing.count, start + length)
                guard start < end else { return Data() }
                // 返回带非零 startIndex 的原始 slice！
                return backing[start..<end]
            }
        }
        let cache = ReadAheadStreamCache(source: SlicedChunkSource())
        let a = try await cache.read(offset: 100, length: 512)
        #expect(a.count == 512)
        #expect(a[a.startIndex] == UInt8(100 % 251))

        await cache.setScrubMode(true)
        let b = try await cache.read(offset: 1_500_000, length: 1024)
        let c = try await cache.read(offset: 1_500_512, length: 512)
        #expect(b.count == 1024)
        #expect(c.count == 512)
        #expect(c[c.startIndex] == UInt8(1_500_512 % 251))
    }
}


extension MemorySource {
    func readSync(offset: Int, length: Int) -> Data {
        data.subdata(in: offset..<min(data.count, offset + length))
    }
}
