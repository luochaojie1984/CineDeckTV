import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LocalStreamProxy
@testable import NetworkVFS

private final class PatternChunkSource: @unchecked Sendable, StreamChunkSource {
    let totalBytes: Int64
    init(totalBytes: Int64) { self.totalBytes = totalBytes }

    func contentLength() async throws -> Int64 { totalBytes }

    func read(offset: Int64, length: Int) async throws -> Data {
        let count = Int(min(Int64(length), max(0, totalBytes - offset)))
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8((Int(offset) + i) % 251)
        }
        return Data(bytes)
    }
}

@Suite("LocalHTTPStreamProxy Live Loopback")
struct LocalProxyLiveStreamingTests {
    @Test("start 后立即返回有效回环端口并正确响应 HEAD / 206 流式 Range / 416")
    func loopbackStreamingAndHead() async throws {
        let totalSize: Int64 = 3 * 1024 * 1024 + 123
        let cache = ReadAheadStreamCache(source: PatternChunkSource(totalBytes: totalSize))
        let proxy = LocalHTTPStreamProxy(cache: cache)

        try await proxy.start(preferredPort: 0)
        let boundPort = await proxy.port
        #expect(boundPort != nil)
        #expect((boundPort ?? 0) > 0)

        let route = await proxy.register(fileExtension: "mkv")
        let url = await proxy.localURL(for: route)!

        // 1. HEAD 请求检查 Content-Length 与视频 MIME
        var headReq = URLRequest(url: url)
        headReq.httpMethod = "HEAD"
        let (headBody, headResp) = try await URLSession.shared.data(for: headReq)
        let headHTTP = headResp as? HTTPURLResponse
        #expect(headHTTP?.statusCode == 200)
        #expect(headHTTP?.value(forHTTPHeaderField: "Content-Length") == "\(totalSize)")
        #expect(headHTTP?.value(forHTTPHeaderField: "Content-Type") == "video/x-matroska")
        #expect(headBody.isEmpty)

        // 2. 跨分块大范围 Range (跨越 2 MB 边界验证流式拼接正确)
        var rangeReq = URLRequest(url: url)
        let reqStart = 1_500_000
        let reqEnd = 2_600_000
        rangeReq.setValue("bytes=\(reqStart)-\(reqEnd)", forHTTPHeaderField: "Range")
        let (rangeData, rangeResp) = try await URLSession.shared.data(for: rangeReq)
        let rangeHTTP = rangeResp as? HTTPURLResponse
        #expect(rangeHTTP?.statusCode == 206)
        #expect(rangeData.count == (reqEnd - reqStart + 1))
        for i in [0, 123, 597_151, 597_152, rangeData.count - 1] {
            #expect(rangeData[i] == UInt8((reqStart + i) % 251))
        }

        // 3. 越界 Range 返回 416
        var badRangeReq = URLRequest(url: url)
        badRangeReq.setValue("bytes=\(totalSize + 100)-", forHTTPHeaderField: "Range")
        let (_, badResp) = try await URLSession.shared.data(for: badRangeReq)
        #expect((badResp as? HTTPURLResponse)?.statusCode == 416)

        await proxy.stop()
    }

    @Test("进入与退出快进模式后主缓存与尾部钉住块字节不发生偏移错乱")
    func scrubToggleKeepsChunkIntegrity() async throws {
        let total = 6 * 1024 * 1024
        let source = PatternChunkSource(totalBytes: Int64(total))
        let cache = ReadAheadStreamCache(source: source)
        try await cache.prepare(totalSize: Int64(total))

        // 正常读取尾部（钉住块进入 2 MB 主缓存）
        let tailOffset = Int64(total - 1024)
        let tailBefore = try await cache.read(offset: tailOffset, length: 512)

        // 进入快进并在中部用 512 KB 微缓存读取
        await cache.setScrubMode(true)
        let midData = try await cache.read(offset: 2_500_000, length: 4096)
        #expect(midData.count == 4096)
        #expect(midData[0] == UInt8(2_500_000 % 251))
        #expect(midData[4095] == UInt8((2_500_000 + 4095) % 251))

        // 在快进态回读尾部钉住块，字节必须与之前逐字节一致
        let tailDuringScrub = try await cache.read(offset: tailOffset, length: 512)
        #expect(tailDuringScrub == tailBefore)

        // 退出快进，恢复顺序读取
        await cache.setScrubMode(false)
        let headData = try await cache.read(offset: 100, length: 1024)
        #expect(headData[0] == UInt8(100 % 251))
        #expect(headData[1023] == UInt8(1123 % 251))
    }

    @Test("ensureRunning 支持强制重启与停止后自动恢复回环端口")
    func ensureRunningRecoversListener() async throws {
        let totalSize: Int64 = 128 * 1024
        let cache = ReadAheadStreamCache(source: PatternChunkSource(totalBytes: totalSize))
        let proxy = LocalHTTPStreamProxy(cache: cache)

        try await proxy.start(preferredPort: 0)
        let firstPort = await proxy.port
        #expect((firstPort ?? 0) > 0)

        let route = await proxy.register(fileExtension: "mkv")
        let url1 = await proxy.localURL(for: route)!
        var headReq = URLRequest(url: url1)
        headReq.httpMethod = "HEAD"
        let (_, resp1) = try await URLSession.shared.data(for: headReq)
        #expect((resp1 as? HTTPURLResponse)?.statusCode == 200)

        // Live listener stays on same port when forceRestart is false
        try await proxy.ensureRunning(forceRestart: false)
        let keptPort = await proxy.port
        #expect(keptPort == firstPort)

        // Force restart rebinds while keeping registered route
        try await proxy.ensureRunning(forceRestart: true)
        let restartedPort = await proxy.port
        #expect((restartedPort ?? 0) > 0)
        let url2 = await proxy.localURL(for: route)!
        var rangeReq = URLRequest(url: url2)
        rangeReq.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (rangeData, resp2) = try await URLSession.shared.data(for: rangeReq)
        #expect((resp2 as? HTTPURLResponse)?.statusCode == 206)
        #expect(rangeData.count == 1024)

        // Full stop -> ensureRunning() recovers and serves new route cleanly
        await proxy.stop()
        let stoppedPort = await proxy.port
        #expect(stoppedPort == nil)

        try await proxy.ensureRunning()
        let recoveredPort = await proxy.port
        #expect((recoveredPort ?? 0) > 0)
        let route2 = await proxy.register(fileExtension: "mp4")
        let url3 = await proxy.localURL(for: route2)!
        let (fullData, resp3) = try await URLSession.shared.data(for: URLRequest(url: url3))
        #expect((resp3 as? HTTPURLResponse)?.statusCode == 200)
        #expect(fullData.count == Int(totalSize))

        await proxy.stop()
    }
}
