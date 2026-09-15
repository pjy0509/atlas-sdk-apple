// swift-tools-version:5.5
import PackageDescription

// One target, not one per module: the modules are source directories and
// CocoaPods subspecs, and splitting them into SPM targets would buy nothing
// but cross-target header plumbing. Public headers live in `include`.
let package = Package(
    name: "AppAtlasSDK",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_13),
    ],
    products: [
        .library(name: "AppAtlasSDK", targets: ["AppAtlasSDK"]),
    ],
    targets: [
        .target(
            name: "AppAtlasSDK",
            path: "Sources/AppAtlasSDK",
            publicHeadersPath: "include"
        ),
    ]
)
