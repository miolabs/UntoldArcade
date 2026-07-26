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
    dependencies: [
        // Pinned to the motion matching branch until the animation stack
        // merges into develop; then switch back to branch: "develop".
        .package(url: "https://github.com/miolabs/UntoldEngine.git", branch: "feature/animation_motion_matching"),
    ],
    targets: [
        .executableTarget(
            name: "CoolZombie",
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
    ]
)
