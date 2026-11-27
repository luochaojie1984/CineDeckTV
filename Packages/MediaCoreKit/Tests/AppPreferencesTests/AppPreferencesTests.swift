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

    @Test("移植 AuraTV 快进/记忆续播/胶囊色配置默认与编解码一致")
    func auraAlignedControlsSettingsRoundTrip() throws {
        var settings = AppSettings()
        #expect(settings.shortSeekSeconds == 10)
        #expect(settings.shortPressSeekBehavior == .fixedStepJump)
        #expect(settings.longPressSeekMode == .mxLiveKeyframeScrub)
        #expect(settings.enableTouchpadScrub == true)
        #expect(settings.enableResumePlayback == true)
        #expect(settings.scrubBarColorHex == AppSettings.ScrubBarColorPreset.skyBlue.rawValue)

        settings.shortSeekSeconds = 30
        settings.shortPressSeekBehavior = .multiStageShuttle
        settings.longPressSeekMode = .continuousFastPlay
        settings.enableTouchpadScrub = false
        settings.enableResumePlayback = false
        settings.scrubBarColorHex = AppSettings.ScrubBarColorPreset.amberGold.rawValue

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)

        let legacyJSON = Data("{\"cacheMegabytes\": 144}".utf8)
        let legacyDecoded = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        #expect(legacyDecoded.cacheMegabytes == 144)
        #expect(legacyDecoded.shortSeekSeconds == 10)
        #expect(legacyDecoded.shortPressSeekBehavior == .fixedStepJump)
        #expect(legacyDecoded.longPressSeekMode == .mxLiveKeyframeScrub)
        #expect(legacyDecoded.enableTouchpadScrub == true)
        #expect(legacyDecoded.enableResumePlayback == true)
        #expect(legacyDecoded.scrubBarColorHex == "#38BDF8")
    }

    @Test("三引擎偏好包含 KSPlayer / FSPlayer / AVPlayer 且默认自动 KS 优先")
    func ksplayerEnginePreferenceRoundTrip() throws {
        var settings = AppSettings()
        #expect(settings.enginePreference == .automatic)
        #expect(AppSettings.EnginePreference.allCases.contains(.ksplayer))
        #expect(AppSettings.EnginePreference.allCases.contains(.fsplayer))
        #expect(AppSettings.EnginePreference.allCases.contains(.avplayer))

        settings.enginePreference = .ksplayer
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.enginePreference == .ksplayer)
    }
}
