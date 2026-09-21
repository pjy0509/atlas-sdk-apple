// swift-tools-version:5.5
import PackageDescription

// One target, not one per module: the modules are source directories and
// CocoaPods subspecs, and splitting them into SPM targets would buy nothing
// but cross-target header plumbing. Public headers live in `include`. The
// crash module's capture core is plain C in the same target; MetricKit is
// loaded by name at runtime, so nothing here links a framework the floor
// does not have.
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
            resources: [
                // The required-reason API declarations for App Store review.
                .copy("PrivacyInfo.xcprivacy"),
            ],
            publicHeadersPath: "include",
            linkerSettings: [
                // Envelopes leave gzipped; libz ships with every platform here.
                .linkedLibrary("z"),
            ]
        ),
        // Swift consumes this as a module; the test holds that shape in place.
        .testTarget(
            name: "AppAtlasSDKTests",
            dependencies: ["AppAtlasSDK"],
            path: "Tests/AppAtlasSDKTests"
        ),
    ]
)
