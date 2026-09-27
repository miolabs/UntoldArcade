// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolMirror",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoolMirror", targets: ["CoolMirror"]),
    ],
    dependencies: [
        // Tracks the engine's deformation feature branch until it merges into develop.
        .package(url: "https://github.com/miolabs/UntoldEngine.git", branch: "feature/ml_deformer"),
    ],
    targets: [
        .target(
            name: "CoolMirror",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // macOS tool: bakes the ML deformer training set of a demo character
        // (see scripts/train_mldeformer.py in the engine for the second step).
        .executableTarget(
            name: "CoolMirrorBake",
            dependencies: [
                "CoolMirror",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolMirrorTests",
            dependencies: [
                "CoolMirror",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
