// swift-tools-version: 6.0

import PackageDescription

// Mac reconstruction server for CoolScan. Kept as its own package so the
// demo plugin package stays free of server dependencies.
let package = Package(
    name: "CoolScanServer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "CoolScanServer", targets: ["CoolScanServer"]),
        .library(name: "CoolScanServerCore", targets: ["CoolScanServerCore"]),
    ],
    dependencies: [
        .package(path: ".."),
        // MIOServerKit tags depend on MIOCore by branch, which SwiftPM refuses
        // to mix with a version requirement; track its default branch instead.
        .package(url: "https://github.com/miolabs/MIOServerKit.git", branch: "master"),
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "CoolScanServerCore",
            dependencies: [
                .product(name: "CoolScanPipeline", package: "CoolScan"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CoolScanServer",
            dependencies: [
                "CoolScanServerCore",
                .product(name: "MIOServerKit", package: "MIOServerKit"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "CoolScanServerCoreTests",
            dependencies: [
                "CoolScanServerCore",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            resources: [
                .copy("Resources/ball.usdz"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
