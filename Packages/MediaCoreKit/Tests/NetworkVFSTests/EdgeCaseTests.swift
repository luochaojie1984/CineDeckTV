import Testing
import Foundation
@testable import NetworkVFS

@Suite("NetworkVFS 边界")
struct EdgeCaseTests {
    @Test("并发读取不同区间互不干扰")
    func concurrentReads() async throws {
        let source = MemorySourceForEdge(size: 12 * 1024 * 1024)
        let cache = ReadAheadStreamCache(source: source)
        let ranges: [(Int64, Int)] = [(0, 4096), (3_000_000, 4096), (7_000_000, 8192), (11_000_000, 1024)]
        let results = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (index, range) in ranges.enumerated() {
                group.addTask { (index, try await cache.read(offset: range.0, length: range.1)) }
            }
            var collected: [(Int, Data)] = []
            for try await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }
        }
        #expect(results.count == 4)
        for (index, data) in results {
            #expect(data.count == ranges[index].1)
            #expect(data == source.slice(offset: Int(ranges[index].0), length: ranges[index].1))
        }
    }

    @Test("MP4 尾部 moov 定位")
    func locatesTrailingMoov() async throws {
        // 构造 ftyp + mdat + moov 的顶层 atom 结构（moov 在尾部）。
        var bytes = [UInt8]()
        func appendAtom(_ type: String, payloadSize: Int) {
            let size = UInt32(payloadSize + 8)
            bytes.append(UInt8(size >> 24)); bytes.append(UInt8((size >> 16) & 0xFF))
            bytes.append(UInt8((size >> 8) & 0xFF)); bytes.append(UInt8(size & 0xFF))
            bytes.append(contentsOf: Array(type.utf8))
            bytes.append(contentsOf: [UInt8](repeating: 0, count: payloadSize))
        }
        appendAtom("ftyp", payloadSize: 24)
        appendAtom("mdat", payloadSize: 1024)
        appendAtom("moov", payloadSize: 2048)
        let source = DataChunkSource(data: Data(bytes))
        let cache = ReadAheadStreamCache(source: source)
        let located = try await cache.locateMP4Moov()
        #expect(located?.offset == Int64(8 + 24 + 8 + 1024))
        #expect(located.map { $0.length >= 2056 } ?? false)
    }

    @Test("头尾保护量按 4/16MB 规则夹取")
    func protectedEdgeRule() {
        var config = ReadAheadCacheConfig()
        config.maxCacheBytes = 96 * 1024 * 1024
        #expect(config.protectedEdgeBytes == 16 * 1024 * 1024)
        config.maxCacheBytes = 8 * 1024 * 1024
        #expect(config.protectedEdgeBytes == 4 * 1024 * 1024)
    }
}

final class MemorySourceForEdge: @unchecked Sendable, StreamChunkSource {
    private let data: Data
    init(size: Int) {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size { bytes[i] = UInt8((i &* 31) % 251) }
        data = Data(bytes)
    }
    func contentLength() async throws -> Int64 { Int64(data.count) }
    func read(offset: Int64, length: Int) async throws -> Data {
        let start = Int(offset)
        guard start < data.count else { return Data() }
        return data.subdata(in: start..<min(data.count, start + length))
    }
    func slice(offset: Int, length: Int) -> Data {
        data.subdata(in: offset..<min(data.count, offset + length))
    }
}
