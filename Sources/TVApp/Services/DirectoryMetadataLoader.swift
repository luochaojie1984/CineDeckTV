import Foundation
import UIKit
import SwiftUI
import CryptoKit
import NetworkVFS
import MetadataKit
import AppPreferences

/// 磁盘图片缓存（按 `sourceID::path::size` 隔离缓存海报/背景图原图，避免重复跨 SMB 拉取）。
private actor MetadataDiskImageCache {
    static let shared = MetadataDiskImageCache()

    private let cacheDir: URL?

    init() {
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("CineDeckMetadataImages", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.cacheDir = dir
        } else {
            self.cacheDir = nil
        }
    }

    func load(key: String) -> Data? {
        guard let url = fileURL(for: key), FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    func store(_ data: Data, key: String) {
        guard let url = fileURL(for: key), !data.isEmpty else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(for key: String) -> URL? {
        guard let cacheDir else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(digest).img")
    }
}

/// 共享目录侧车元数据与高清封面按需加载器：
/// - 仅在用户开启首页「刮削详情」开关且真正进入共享目录时运行；
/// - 离开目录或开始播放视频时立即 `cancel()` 全部后台预读，确保 4K 高码率播放零带宽抢占。
@MainActor
public final class DirectoryMetadataLoader: ObservableObject {
    @Published public private(set) var matchesByPath: [String: VideoSidecarMatch] = [:]
    @Published public private(set) var metadataByPath: [String: MovieMetadata] = [:]
    @Published public private(set) var duplicateMap: [String: DuplicateVersionInfo] = [:]
    @Published public private(set) var postersByPath: [String: UIImage] = [:]
    @Published public private(set) var fanartsByPath: [String: UIImage] = [:]
    @Published public private(set) var isLoading = false

    private let memoryImageCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    private var activeKey: String?
    private var loadTask: Task<Void, Never>?

    private static let maxNFOSize: Int64 = 256 * 1024
    private static let maxImageSize: Int64 = 8 * 1024 * 1024
    private static let maxConcurrency = 3

    public init() {}

    public func clearAndCancel() {
        loadTask?.cancel()
        loadTask = nil
        activeKey = nil
        isLoading = false
        matchesByPath = [:]
        metadataByPath = [:]
        duplicateMap = [:]
        postersByPath = [:]
        fanartsByPath = [:]
    }

    public func cancelInFlight() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    public func thumbnail(for videoPath: String) -> UIImage? {
        fanartsByPath[videoPath] ?? postersByPath[videoPath]
    }

    public func posterOrFanart(for videoPath: String) -> UIImage? {
        postersByPath[videoPath] ?? fanartsByPath[videoPath]
    }

    public func load(entries: [VFSEntry], source: MediaSourceConfig, directoryPath: String, env: AppEnvironment) {
        let key = "\(source.id.uuidString)::\(directoryPath)::\(entries.count)"
        if activeKey == key && !matchesByPath.isEmpty {
            return
        }
        cancelInFlight()
        activeKey = key

        let matches = SidecarMatcher.match(entries: entries)
        matchesByPath = matches
        metadataByPath = [:]
        duplicateMap = [:]
        postersByPath = [:]
        fanartsByPath = [:]

        let videos = entries.filter(\.isVideo)
        let hasWork = matches.values.contains { $0.hasMetadataOrArtwork }
        guard hasWork else {
            isLoading = false
            return
        }

        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }

            guard let provider = try? await env.provider(for: source) else { return }
            if Task.isCancelled { return }

            // 1. 并发拉取并解析 .nfo（有界并发 <= 3）
            let nfoTargets: [(videoPath: String, entry: VFSEntry)] = videos.compactMap { v in
                guard let nfo = matches[v.path]?.nfoEntry else { return nil }
                return (v.path, nfo)
            }
            var parsedMetadata: [String: MovieMetadata] = [:]
            for batch in Self.chunked(nfoTargets, size: Self.maxConcurrency) {
                if Task.isCancelled { return }
                let batchResults = await withTaskGroup(of: (String, MovieMetadata?).self) { group in
                    for item in batch {
                        group.addTask {
                            if Task.isCancelled { return (item.videoPath, nil) }
                            let limit = Int(min(item.entry.size > 0 ? item.entry.size : Self.maxNFOSize, Self.maxNFOSize))
                            guard let data = try? await provider.read(path: item.entry.path, offset: 0, length: limit) else {
                                return (item.videoPath, nil)
                            }
                            return (item.videoPath, NFOParser.parse(data: data))
                        }
                    }
                    var collected: [(String, MovieMetadata?)] = []
                    for await res in group { collected.append(res) }
                    return collected
                }
                for (vPath, meta) in batchResults {
                    if let meta { parsedMetadata[vPath] = meta }
                }
            }

            if Task.isCancelled { return }
            self.metadataByPath = parsedMetadata
            self.duplicateMap = SidecarMatcher.duplicateMap(videos: videos, metadataByPath: parsedMetadata)

            // 2. 并发拉取高清 poster / fanart 原图（优先命中内存/磁盘缓存）
            enum ArtworkKind: Sendable { case poster, fanart }
            struct ArtTarget: Sendable {
                let videoPath: String
                let kind: ArtworkKind
                let entry: VFSEntry
                let cacheKey: String
            }

            var artTargets: [ArtTarget] = []
            for v in videos {
                guard let m = matches[v.path] else { continue }
                if let fanart = m.fanartEntry {
                    artTargets.append(ArtTarget(
                        videoPath: v.path,
                        kind: .fanart,
                        entry: fanart,
                        cacheKey: "\(source.id.uuidString)::\(fanart.path)::\(fanart.size)"
                    ))
                }
                if let poster = m.posterEntry {
                    artTargets.append(ArtTarget(
                        videoPath: v.path,
                        kind: .poster,
                        entry: poster,
                        cacheKey: "\(source.id.uuidString)::\(poster.path)::\(poster.size)"
                    ))
                }
            }

            for batch in Self.chunked(artTargets, size: Self.maxConcurrency) {
                if Task.isCancelled { return }
                // 先在 MainActor 检查内存缓存，未命中才交由后台拉取
                var pending: [ArtTarget] = []
                for target in batch {
                    if let cached = self.memoryImageCache.object(forKey: target.cacheKey as NSString) {
                        switch target.kind {
                        case .fanart: self.fanartsByPath[target.videoPath] = cached
                        case .poster: self.postersByPath[target.videoPath] = cached
                        }
                    } else {
                        pending.append(target)
                    }
                }
                guard !pending.isEmpty else { continue }

                let fetched = await withTaskGroup(of: (ArtTarget, Data?).self) { group in
                    for target in pending {
                        group.addTask {
                            if Task.isCancelled { return (target, nil) }
                            if let diskData = await MetadataDiskImageCache.shared.load(key: target.cacheKey) {
                                return (target, diskData)
                            }
                            let readLen = Int(min(target.entry.size > 0 ? target.entry.size : Self.maxImageSize, Self.maxImageSize))
                            guard readLen > 0,
                                  let data = try? await provider.read(path: target.entry.path, offset: 0, length: readLen) else {
                                return (target, nil)
                            }
                            await MetadataDiskImageCache.shared.store(data, key: target.cacheKey)
                            return (target, data)
                        }
                    }
                    var out: [(ArtTarget, Data?)] = []
                    for await res in group { out.append(res) }
                    return out
                }

                if Task.isCancelled { return }
                for (target, data) in fetched {
                    guard let data, let image = UIImage(data: data) else { continue }
                    self.memoryImageCache.setObject(image, forKey: target.cacheKey as NSString, cost: data.count)
                    switch target.kind {
                    case .fanart: self.fanartsByPath[target.videoPath] = image
                    case .poster: self.postersByPath[target.videoPath] = image
                    }
                }
            }
        }
    }

    /// 详情页按需加载 `extrafanart` 高清剧照（最多 8 张，平时浏览目录绝不预拉）。
    public func loadExtraStills(dirPath: String?, source: MediaSourceConfig, env: AppEnvironment) async -> [UIImage] {
        guard let dirPath, let provider = try? await env.provider(for: source),
              let entries = try? await provider.list(path: dirPath) else {
            return []
        }
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp"]
        let stills = entries.filter { !$0.isDirectory && imageExts.contains($0.fileExtension) }.prefix(8)
        var result: [UIImage] = []
        for entry in stills {
            if Task.isCancelled { break }
            let cacheKey = "\(source.id.uuidString)::\(entry.path)::\(entry.size)"
            if let mem = memoryImageCache.object(forKey: cacheKey as NSString) {
                result.append(mem)
                continue
            }
            if let disk = await MetadataDiskImageCache.shared.load(key: cacheKey),
               let img = UIImage(data: disk) {
                memoryImageCache.setObject(img, forKey: cacheKey as NSString, cost: disk.count)
                result.append(img)
                continue
            }
            let readLen = Int(min(entry.size > 0 ? entry.size : Self.maxImageSize, Self.maxImageSize))
            if readLen > 0,
               let data = try? await provider.read(path: entry.path, offset: 0, length: readLen),
               let img = UIImage(data: data) {
                await MetadataDiskImageCache.shared.store(data, key: cacheKey)
                memoryImageCache.setObject(img, forKey: cacheKey as NSString, cost: data.count)
                result.append(img)
            }
        }
        return result
    }

    private static func chunked<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0, !array.isEmpty else { return [] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<min($0 + size, array.count)])
        }
    }
}
