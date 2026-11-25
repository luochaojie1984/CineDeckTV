// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaCoreKit",
    platforms: [
        .tvOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "NetworkVFS", targets: ["NetworkVFS"]),
        .library(name: "LocalStreamProxy", targets: ["LocalStreamProxy"]),
        .library(name: "SubtitleKit", targets: ["SubtitleKit"]),
        .library(name: "AppPreferences", targets: ["AppPreferences"]),
    ],
    targets: [
        .target(name: "NetworkVFS"),
        .target(name: "LocalStreamProxy", dependencies: ["NetworkVFS"]),
        .target(name: "SubtitleKit"),
        .target(name: "AppPreferences", dependencies: ["NetworkVFS", "SubtitleKit"]),
        .testTarget(name: "NetworkVFSTests", dependencies: ["NetworkVFS"]),
        .testTarget(name: "LocalStreamProxyTests", dependencies: ["LocalStreamProxy"]),
        .testTarget(name: "SubtitleKitTests", dependencies: ["SubtitleKit"]),
        .testTarget(name: "AppPreferencesTests", dependencies: ["AppPreferences"]),
    ]
)
