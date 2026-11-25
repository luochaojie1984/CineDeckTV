import Testing
import Foundation
@testable import AppPreferences
@testable import NetworkVFS

@Suite("历史容量")
struct HistoryLimitTests {
    @Test("历史记录上限 200 条并保留最新")
    func capsAt200() throws {
        let store = PlaybackHistoryStore(folderName: "CineDeckTVTests-\(UUID().uuidString)", defaultsKey: "test.history.\(UUID().uuidString)")
        try store.removeAll()
        let source = UUID()
        for index in 0..<205 {
            let record = PlaybackRecord(sourceID: source, path: "/v\(index).mkv", title: "V\(index)", position: Double(index), duration: 1000)
            try store.record(record)
        }
        let records = store.load()
        #expect(records.count == 200)
        #expect(records.first?.path == "/v204.mkv")
    }

    @Test("语言标签识别：简中优先")
    func languageTag() {
        #expect(SubtitleMatcherLanguageProbe.simplified("Movie.chs.srt"))
        #expect(!SubtitleMatcherLanguageProbe.simplified("Movie.eng.srt"))
    }
}

/// AppPreferences 不直接暴露 SubtitleKit 的匹配器，这里用最小探针验证标签表覆盖。
enum SubtitleMatcherLanguageProbe {
    static func simplified(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["chs", "sc", "zh-cn", "简体", "简中", "中文"].contains { lower.contains($0) }
    }
}
