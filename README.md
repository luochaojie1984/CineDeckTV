# CineDeckTV

Apple TV 4K（tvOS 17+）局域网直连影音播放器，主内核 FSPlayer（FFmpeg 8 + VideoToolbox + Metal），AVPlayer 兜底。

## 结构

| 路径 | 说明 |
| :--- | :--- |
| `Packages/MediaCoreKit` | 纯 Swift 跨平台核心层（Linux 可 `swift test`）：NetworkVFS / LocalStreamProxy / SubtitleKit / AppPreferences |
| `Sources/PlaybackEngine` | 播放引擎适配层：PlayerEngineProtocol / FSPlayerEngineAdapter |
| `Sources/TVAdapters` | tvOS 平台适配（AMSMB2 / Keychain / Bonjour） |
| `Sources/TVApp` | 10-foot UI（SwiftUI） |
| `.github/workflows/tvos-ci.yml` | Ubuntu 单测 + macOS(xcode-27) tvOS Release 无签名 IPA + Payload 门禁 |

## 依赖版本（已核对，非臆造）

- FSPlayer-SPM `1.1.3`（GitHub 最新稳定 tag；1.1.4-beta-1 为 beta 未采用）
- FSPlayer 1.1.3 xcframework 切片：ios-arm64 / ios-arm64_x86_64-simulator / macos-arm64_x86_64 / **tvos-arm64** / tvos-arm64_x86_64-simulator
- AMSMB2：Phase 2 引入（源码编译 + 本地补丁，需 `embed: true`）

## 本地能力边界

开发机为 Linux，无 `xcodebuild`。本地只做：代码编辑、`swift test`（MediaCoreKit）、隐私正则审计；tvOS 编译与 IPA 由 GitHub Actions `xcode-27` runner 产出。

## 安装

云端产物为无签名 `CineDeckTV-Unsigned.ipa`，用 Sideloadly / atvloadly 等工具自签后安装到 Apple TV。
