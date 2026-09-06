// swift-tools-version: 6.0
// CoolZombie — AI character locomotion demo for Untold Engine.
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "CoolZombie",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        // Platform-neutral zombie: model, clips, and the motion-matched
        // chase logic. The macOS executable below and the visionOS app in
        // Examples/ are thin hosts around it.
        .library(name: "CoolZombieKit", targets: ["CoolZombieKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/miolabs/UntoldEngine.git", branch: "develop"),
    ],
    targets: [
        .target(
            name: "CoolZombieKit",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            resources: [
                .copy("Resources/Models"),
                .copy("Resources/Animations"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CoolZombie",
            dependencies: [
                "CoolZombieKit",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
