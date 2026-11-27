import Testing
import Foundation
import NetworkVFS
@testable import MetadataKit

@Suite("MetadataKit")
struct MetadataKitTests {
    @Test("NFOParser 完整解析 MDCz XML 字段、演员列表、CDATA 与实体转义")
    func parsesRichMDCzNFO() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <movie>
          <num>DEMO-456</num>
          <uniqueid type="dmm" default="true">demo456</uniqueid>
          <title><![CDATA[光影与星辰 & 远航]]></title>
          <originaltitle>Hikari to Hoshi</originaltitle>
          <plot>这是一部测试完整 NFO 字段解析的电影剧情简介，包含 &amp; 与 &quot;引号&quot;。</plot>
          <premiered>2024-08-15</premiered>
          <year>2024</year>
          <runtime>142</runtime>
          <rating>8.9</rating>
          <studio>Studio Alpha</studio>
          <publisher>Label Beta</publisher>
          <director>Director Gamma</director>
          <set><name>Cosmos Series</name></set>
          <genre>科幻</genre>
          <genre>4K HDR</genre>
          <tag>中文字幕</tag>
          <tag>精校版</tag>
          <actor><name>佐藤遥</name></actor>
          <actor><name>高桥凛</name></actor>
          <actor><name>佐藤遥</name></actor>
        </movie>
        """

        let meta = NFOParser.parse(data: Data(xml.utf8))
        #expect(meta != nil)
        #expect(meta?.code == "DEMO-456")
        #expect(meta?.title == "光影与星辰 & 远航")
        #expect(meta?.originalTitle == "Hikari to Hoshi")
        #expect(meta?.plot == "这是一部测试完整 NFO 字段解析的电影剧情简介，包含 & 与 \"引号\"。")
        #expect(meta?.releaseDate == "2024-08-15")
        #expect(meta?.year == 2024)
        #expect(meta?.runtimeMinutes == 142)
        #expect(meta?.rating == 8.9)
        #expect(meta?.studio == "Studio Alpha")
        #expect(meta?.publisher == "Label Beta")
        #expect(meta?.director == "Director Gamma")
        #expect(meta?.series == "Cosmos Series")
        #expect(meta?.actors == ["佐藤遥", "高桥凛"])
        #expect(meta?.genres == ["科幻", "4K HDR"])
        #expect(meta?.tags == ["中文字幕", "精校版"])
    }

    @Test("单影片目录支持回退 movie.nfo 与 poster/fanart/extrafanart")
    func singleMovieDirectoryFallback() {
        let entries = [
            VFSEntry(path: "/DEMO-100/DEMO-100.mkv", name: "DEMO-100.mkv", isDirectory: false, size: 12_000_000_000, modifiedAt: nil),
            VFSEntry(path: "/DEMO-100/movie.nfo", name: "movie.nfo", isDirectory: false, size: 2048, modifiedAt: nil),
            VFSEntry(path: "/DEMO-100/poster.jpg", name: "poster.jpg", isDirectory: false, size: 512_000, modifiedAt: nil),
            VFSEntry(path: "/DEMO-100/fanart.jpg", name: "fanart.jpg", isDirectory: false, size: 912_000, modifiedAt: nil),
            VFSEntry(path: "/DEMO-100/extrafanart", name: "extrafanart", isDirectory: true, size: 0, modifiedAt: nil),
            VFSEntry(path: "/DEMO-100/DEMO-100.chs.ass", name: "DEMO-100.chs.ass", isDirectory: false, size: 64_000, modifiedAt: nil),
        ]

        let matches = SidecarMatcher.match(entries: entries)
        let hit = matches["/DEMO-100/DEMO-100.mkv"]
        #expect(hit?.nfoEntry?.name == "movie.nfo")
        #expect(hit?.posterEntry?.name == "poster.jpg")
        #expect(hit?.fanartEntry?.name == "fanart.jpg")
        #expect(hit?.extraFanartDirPath == "/DEMO-100/extrafanart")
        #expect(hit?.subtitleCount == 1)
    }

    @Test("同目录多部影片/重复文件严格 1 对 1 匹配且不误套用 movie.nfo，同时识别同番号多版本差异")
    func multiMovieAndDuplicateDisambiguation() {
        let entries = [
            VFSEntry(path: "/Mix/ABC-123_4K_中字.mkv", name: "ABC-123_4K_中字.mkv", isDirectory: false, size: 20_000_000_000, modifiedAt: nil),
            VFSEntry(path: "/Mix/ABC-123_4K_中字.nfo", name: "ABC-123_4K_中字.nfo", isDirectory: false, size: 1500, modifiedAt: nil),
            VFSEntry(path: "/Mix/ABC-123_4K_中字-poster.jpg", name: "ABC-123_4K_中字-poster.jpg", isDirectory: false, size: 400_000, modifiedAt: nil),
            VFSEntry(path: "/Mix/ABC-123_4K_中字-fanart.jpg", name: "ABC-123_4K_中字-fanart.jpg", isDirectory: false, size: 800_000, modifiedAt: nil),
            VFSEntry(path: "/Mix/ABC-123_1080p_无码.mp4", name: "ABC-123_1080p_无码.mp4", isDirectory: false, size: 6_000_000_000, modifiedAt: nil),
            VFSEntry(path: "/Mix/ABC-123_1080p_无码.nfo", name: "ABC-123_1080p_无码.nfo", isDirectory: false, size: 1500, modifiedAt: nil),
            VFSEntry(path: "/Mix/ABC-123_1080p_无码-poster.jpg", name: "ABC-123_1080p_无码-poster.jpg", isDirectory: false, size: 380_000, modifiedAt: nil),
            VFSEntry(path: "/Mix/unscraped_home_clip.mp4", name: "unscraped_home_clip.mp4", isDirectory: false, size: 900_000_000, modifiedAt: nil),
            VFSEntry(path: "/Mix/movie.nfo", name: "movie.nfo", isDirectory: false, size: 1000, modifiedAt: nil),
            VFSEntry(path: "/Mix/poster.jpg", name: "poster.jpg", isDirectory: false, size: 300_000, modifiedAt: nil),
        ]

        let matches = SidecarMatcher.match(entries: entries)
        let v1 = matches["/Mix/ABC-123_4K_中字.mkv"]
        let v2 = matches["/Mix/ABC-123_1080p_无码.mp4"]
        let unscraped = matches["/Mix/unscraped_home_clip.mp4"]

        #expect(v1?.nfoEntry?.name == "ABC-123_4K_中字.nfo")
        #expect(v1?.posterEntry?.name == "ABC-123_4K_中字-poster.jpg")
        #expect(v1?.versionTags.contains("4K") == true)
        #expect(v1?.versionTags.contains("中字") == true)

        #expect(v2?.nfoEntry?.name == "ABC-123_1080p_无码.nfo")
        #expect(v2?.fanartEntry == nil) // 多片目录严禁串图回退 fanart.jpg
        #expect(v2?.versionTags.contains("1080P") == true)
        #expect(v2?.versionTags.contains("无码") == true)

        // 未刮削普通视频绝不误套用目录级的 movie.nfo 或 poster.jpg
        #expect(unscraped?.nfoEntry == nil)
        #expect(unscraped?.posterEntry == nil)
        #expect(unscraped?.hasMetadataOrArtwork == false)

        let metaMap: [String: MovieMetadata] = [
            "/Mix/ABC-123_4K_中字.mkv": MovieMetadata(code: "ABC-123", title: "测试影片"),
            "/Mix/ABC-123_1080p_无码.mp4": MovieMetadata(code: "abc-123", title: "测试影片"),
        ]
        let dupes = SidecarMatcher.duplicateMap(videos: entries.filter(\.isVideo), metadataByPath: metaMap)
        #expect(dupes.count == 2)
        #expect(dupes["/Mix/ABC-123_4K_中字.mkv"] == DuplicateVersionInfo(normalizedCode: "ABC-123", index: 1, total: 2))
        #expect(dupes["/Mix/ABC-123_1080p_无码.mp4"] == DuplicateVersionInfo(normalizedCode: "ABC-123", index: 2, total: 2))
    }
}
