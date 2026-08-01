// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolWeb",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoolWeb", targets: ["CoolWeb"]),
    ],
    dependencies: [
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
    ],
    targets: [
        .target(
            name: "CoolWeb",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            exclude: ["Shaders"],
            resources: [
                .copy("Resources/CoolWeb-macos.metallib"),
                .copy("Resources/CoolWeb-ios.metallib"),
                .copy("Resources/CoolWeb-iossim.metallib"),
                .copy("Resources/CoolWeb-xros.metallib"),
                .copy("Resources/CoolWeb-xrossim.metallib"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolWebTests",
            dependencies: [
                "CoolWeb",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
