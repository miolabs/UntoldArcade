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
        // Wire format + transport + retargeting shared with the iPhone capture app.
        .library(name: "CoolMirrorMocap", targets: ["CoolMirrorMocap"]),
    ],
    dependencies: [
        // Tracks the engine's deformation feature branch until it merges into develop.
        .package(url: "https://github.com/miolabs/UntoldEngine.git", branch: "feature/mirror_mocap"),
        // XPBD cloth for Batman's cape (GPU sheet) …
        .package(path: "../CoolCloth"),
        // … and Jolt cloth on the cape mesh itself.
        .package(url: "https://github.com/miolabs/UntoldJoltPhysics.git", branch: "feature/soft_body_cloth"),
    ],
    targets: [
        .target(
            name: "CoolMirrorMocap",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CoolMirror",
            dependencies: [
                "CoolMirrorMocap",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
                .product(name: "CoolCloth", package: "CoolCloth"),
                .product(name: "UntoldJoltPhysics", package: "UntoldJoltPhysics"),
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
                "CoolMirrorMocap",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
                .product(name: "UntoldJoltPhysics", package: "UntoldJoltPhysics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
