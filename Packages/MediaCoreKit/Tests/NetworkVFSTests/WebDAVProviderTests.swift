import Testing
import Foundation
@testable import NetworkVFS

@Suite("WebDAV")
struct WebDAVProviderTests {
    @Test("multistatus 解析出目录、文件、大小与时间")
    func parsesMultiStatus() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/Movies/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/%E5%89%A7%E9%9B%86.S01E01.mkv</d:href>
            <d:propstat><d:prop>
              <d:resourcetype/>
              <d:getcontentlength>1073741824</d:getcontentlength>
              <d:getlastmodified>Wed, 12 Nov 2025 10:00:00 GMT</d:getlastmodified>
            </d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """
        let entries = WebDAVMultiStatusParser().parse(Data(xml.utf8))
        #expect(entries.count == 3)
        let file = entries.first { $0.hrefPath.contains(".mkv") }
        #expect(file?.size == 1_073_741_824)
        #expect(file?.isDirectory == false)
        #expect(entries.first { $0.hrefPath == "/dav/Movies/" }?.isDirectory == true)
    }

    @Test("视频扩展名与徽章识别")
    func videoBadges() {
        let entry = VFSEntry(path: "/a/movie.mkv", name: "Movie.2024.2160p.HDR10.HEVC.10bit.Atmos.mkv", isDirectory: false, size: 1, modifiedAt: nil)
        #expect(entry.isVideo)
        let badges = entry.badges
        #expect(badges.contains("4K"))
        #expect(badges.contains("HEVC"))
        #expect(badges.contains("10bit"))
        #expect(badges.contains("Atmos"))
    }

    @Test("DataChunkSource 越界返回空")
    func chunkSourceBounds() async throws {
        let source = DataChunkSource(data: Data([1, 2, 3, 4]))
        let tail = try await source.read(offset: 2, length: 100)
        #expect(tail.count == 2)
        let beyond = try await source.read(offset: 10, length: 4)
        #expect(beyond.isEmpty)
    }
}
