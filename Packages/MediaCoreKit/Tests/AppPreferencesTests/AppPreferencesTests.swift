import Testing
import Foundation
@testable import AppPreferences

@Suite("AppPreferences")
struct AppPreferencesTests {
    @Test("默认设置在缓存硬上限内")
    func cacheWithinLimit() {
        let settings = AppSettings()
        #expect(settings.clampedCacheBytes <= 192 * 1024 * 1024)
        #expect(settings.clampedCacheBytes >= 16 * 1024 * 1024)
    }

    @Test("往返编解码保持字段一致")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.playbackRate = 1.5
        settings.scrubMode = .turbo
        settings.cacheMegabytes = 128
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("快进曲线封顶符合文档")
    func scrubCeiling() {
        #expect(AppSettings.ScrubMode.fine.ceiling == 60)
        #expect(AppSettings.ScrubMode.standard.ceiling == 120)
        #expect(AppSettings.ScrubMode.turbo.ceiling == 240)
    }
}
