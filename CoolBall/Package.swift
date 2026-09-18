// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolBall",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoolBall", targets: ["CoolBall"]),
    ],
    dependencies: [
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
        // The Jolt backend plugin, selectable at launch as an alternative to
        // the demo's own pure-Swift backend. Local path until the plugin has
        // a published repository.
        .package(path: "../../UntoldJolt"),
    ],
    targets: [
        .target(
            name: "CoolBall",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
                .product(name: "UntoldJoltPhysics", package: "UntoldJolt"),
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
            name: "CoolBallTests",
            dependencies: [
                "CoolBall",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
