import Foundation

/// 统一的网络文件系统访问接口：SMB（AMSMB2）与 WebDAV 各实现一份。
public protocol VFSProvider: Sendable {
    var kind: MediaSourceKind { get }
    func connect() async throws
    func disconnect() async
    func list(path: String) async throws -> [VFSEntry]
    func readHead(path: String, length: Int) async throws -> Data
    func readTail(path: String, length: Int) async throws -> Data
    func read(path: String, offset: Int64, length: Int) async throws -> Data
    func size(path: String) async throws -> Int64
    /// 为随机读建立常驻句柄（SMB）或复用连接（WebDAV）。
    func makeChunkSource(path: String) async throws -> any StreamChunkSource
}

public extension VFSProvider {
    /// 探测 MP4 顶部 atoms 定位 moov；命中尾部大 moov 时一次拉全表。
    func locateMoov(path: String) async throws -> (offset: Int64, length: Int)? {
        let total = try await size(path: path)
        var cursor: Int64 = 0
        for _ in 0..<16 {
            let header = try await read(path: path, offset: cursor, length: 16)
            guard header.count >= 8 else { return nil }
            let size32 = header.readBigEndianUInt32(at: 0)
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            var atomSize = Int64(size32)
            var headerLen: Int64 = 8
            if size32 == 1, header.count >= 16 {
                atomSize = Int64(bitPattern: header.readBigEndianUInt64(at: 8))
                headerLen = 16
            } else if size32 == 0 {
                atomSize = total - cursor
            }
            if atomSize < headerLen { return nil }
            if type == "moov" { return (cursor, Int(min(atomSize, 64 * 1024 * 1024))) }
            cursor += atomSize
            if cursor >= total { return nil }
        }
        return nil
    }

    /// 扫描同目录及 Subs/Subtitles/Subtitle/字幕 子目录下的字幕文件。
    func scanSubtitles(forVideoPath videoPath: String, directories: [String]) async throws -> [String] {
        let parent = (videoPath as NSString).deletingLastPathComponent
        let videoName = (videoPath as NSString).lastPathComponent
        let videoBase = (videoName as NSString).deletingPathExtension
        var found: [String] = []
        let siblings = try await list(path: parent)
        for entry in siblings where entry.isSubtitle && entry.name.hasPrefix(videoBase) {
            found.append(entry.path)
        }
        for dirName in directories {
            let sub = parent.isEmpty ? dirName : "\(parent)/\(dirName)"
            guard let entries = try? await list(path: sub) else { continue }
            for entry in entries where entry.isSubtitle {
                found.append(entry.path)
            }
        }
        return found
    }
}

/// 内存随机读源：把已抓取的整段数据包装成 StreamChunkSource（WebDAV 小文件场景）。
public struct DataChunkSource: StreamChunkSource {
    private let data: Data
    public init(data: Data) { self.data = data }
    public func contentLength() async throws -> Int64 { Int64(data.count) }
    public func read(offset: Int64, length: Int) async throws -> Data {
        let start = Int(offset)
        guard start < data.count else { return Data() }
        return data.subdata(in: start..<min(data.count, start + length))
    }
}
