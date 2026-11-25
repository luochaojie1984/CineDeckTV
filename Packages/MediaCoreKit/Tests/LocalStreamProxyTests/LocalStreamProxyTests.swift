import Testing
import Foundation
@testable import LocalStreamProxy

@Suite("LocalStreamProxy")
struct LocalStreamProxyTests {
    @Test("Range 头解析：起止")
    func parsesClosedRange() {
        let parsed = LocalHTTPStreamProxy.parseRange("bytes=100-199", total: 1000)
        #expect(parsed?.0 == 100)
        #expect(parsed?.1 == 199)
    }

    @Test("Range 头解析：开放结尾与后缀")
    func parsesOpenAndSuffix() {
        #expect(LocalHTTPStreamProxy.parseRange("bytes=900-", total: 1000)?.1 == 999)
        let suffix = LocalHTTPStreamProxy.parseRange("bytes=-100", total: 1000)
        #expect(suffix?.0 == 900)
        #expect(suffix?.1 == 999)
    }

    @Test("非法 Range 返回 nil")
    func rejectsInvalid() {
        #expect(LocalHTTPStreamProxy.parseRange("items=0-10", total: 1000) == nil)
        #expect(LocalHTTPStreamProxy.parseRange("bytes=2000-3000", total: 1000) == nil)
    }
}
