// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolScan",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoolScan", targets: ["CoolScan"]),
        .library(name: "CoolScanPipeline", targets: ["CoolScanPipeline"]),
    ],
    dependencies: [
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
    ],
    targets: [
        .target(
            name: "CoolScan",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            exclude: ["Shaders"],
            resources: [
                .copy("Resources/CoolScan-macos.metallib"),
                .copy("Resources/CoolScan-ios.metallib"),
                .copy("Resources/CoolScan-iossim.metallib"),
                .copy("Resources/CoolScan-xros.metallib"),
                .copy("Resources/CoolScan-xrossim.metallib"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CoolScanPipeline",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolScanTests",
            dependencies: [
                "CoolScan",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolScanPipelineTests",
            dependencies: [
                "CoolScanPipeline",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
