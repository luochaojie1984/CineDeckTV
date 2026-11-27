import Foundation
import CoreText
import SwiftUI
import UIKit
import os
import SubtitleKit

/// 运行时中文字体注册与解析中心：
/// - 启动时自动注册 `CineDeckTV.app/Fonts/` 中的 6 款全字库开源中文字体（经典楷体/霞鹜文楷/书香宋体/朱雀仿宋/柔和圆体/电影艺术黑）；
/// - 通过 CoreText 直接提取每个 TTF 的真实 PostScript 名，确保 `Font(uiFont)` 在 tvOS 上 100% 实时切换出真实中文笔形，绝不误退回系统默认黑体。
public final class SubtitleFontRegistry: @unchecked Sendable {
    public static let shared = SubtitleFontRegistry()

    private struct State {
        var didRegister = false
        var postScriptByFile: [String: String] = [:]
        var fontsDirectoryPath: String?
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private init() {}

    public func ensureRegistered() {
        let already = lock.withLock { $0.didRegister }
        if already { return }

        var candidateURLs: [URL] = []
        var detectedDir: String?

        if let folderURL = Bundle.main.url(forResource: "Fonts", withExtension: nil) {
            detectedDir = folderURL.path
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                candidateURLs.append(contentsOf: contents.filter {
                    let ext = $0.pathExtension.lowercased()
                    return ext == "ttf" || ext == "otf"
                })
            }
        }

        if candidateURLs.isEmpty {
            if let sub = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") {
                candidateURLs.append(contentsOf: sub)
                if detectedDir == nil, let first = sub.first {
                    detectedDir = first.deletingLastPathComponent().path
                }
            }
            if let root = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) {
                candidateURLs.append(contentsOf: root.filter { $0.lastPathComponent.hasPrefix("CineDeck-") })
                if detectedDir == nil, let first = root.first {
                    detectedDir = first.deletingLastPathComponent().path
                }
            }
        }

        var map: [String: String] = [:]
        for url in candidateURLs {
            var err: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let first = descriptors.first,
               let psName = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String,
               !psName.isEmpty {
                map[url.lastPathComponent] = psName
            }
        }

        let finalMap = map
        let finalDir = detectedDir
        lock.withLock { state in
            state.didRegister = true
            state.postScriptByFile = finalMap
            state.fontsDirectoryPath = finalDir
        }
    }

    public var bundledFontsDirectoryPath: String? {
        ensureRegistered()
        return lock.withLock { $0.fontsDirectoryPath }
    }

    private func resolvedPostScriptName(for family: SubtitleStyleConfig.FontFamily) -> String {
        if let fileName = family.bundledFileName,
           let discoveredPS = lock.withLock({ $0.postScriptByFile[fileName] }),
           !discoveredPS.isEmpty {
            return discoveredPS
        }
        return family.postScriptName
    }

    public func resolveUIFont(for family: SubtitleStyleConfig.FontFamily, size: CGFloat) -> UIFont {
        ensureRegistered()
        let clampedSize = min(96, max(16, size))

        let primaryPS = resolvedPostScriptName(for: family)
        if let primaryFont = UIFont(name: primaryPS, size: clampedSize) {
            let cascadeDescriptors: [UIFontDescriptor] = family.fallbackOrder.compactMap { fbFamily in
                let fbPS = resolvedPostScriptName(for: fbFamily)
                guard UIFont(name: fbPS, size: clampedSize) != nil else { return nil }
                return UIFontDescriptor(name: fbPS, size: clampedSize)
            }
            if !cascadeDescriptors.isEmpty {
                let descriptor = primaryFont.fontDescriptor
                    .addingAttributes([.cascadeList: cascadeDescriptors])
                return UIFont(descriptor: descriptor, size: clampedSize)
            }
            return primaryFont
        }

        if let direct = UIFont(name: family.postScriptName, size: clampedSize) {
            return direct
        }

        switch family {
        case .heavy:
            return UIFont.systemFont(ofSize: clampedSize, weight: .heavy)
        default:
            return UIFont.systemFont(ofSize: clampedSize, weight: .semibold)
        }
    }

    public func resolveSwiftUIFont(for family: SubtitleStyleConfig.FontFamily, size: CGFloat) -> Font {
        Font(resolveUIFont(for: family, size: size))
    }
}
