// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolBasket",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoolBasket", targets: ["CoolBasket"]),
    ],
    dependencies: [
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
        // The Jolt backend plugin, selectable at launch as an alternative to
        // the demo's own pure-Swift backend. Shared by the demos under
        // Plugins/ until it has a repository of its own.
        .package(path: "../Plugins/UntoldJoltPhysics"),
    ],
    targets: [
        .target(
            name: "CoolBasket",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
                .product(name: "UntoldJoltPhysics", package: "UntoldJoltPhysics"),
            ],
            resources: [
                .copy("Resources/basketball_baseColor.png"),
                .copy("Resources/backboard_baseColor.png"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolBasketTests",
            dependencies: [
                "CoolBasket",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
