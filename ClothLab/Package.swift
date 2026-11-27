// swift-tools-version: 6.0
// ClothLab — a bench for cloth, one layer at a time, judged by eye.
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "ClothLab",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        // The miolabs fork's develop, as CoolZombie uses; Package.resolved
        // pins the commit.
        .package(url: "https://github.com/miolabs/UntoldEngine.git", branch: "develop"),
    ],
    targets: [
        .executableTarget(
            name: "ClothLab",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            resources: [
                .copy("Resources/HDR"),
                .copy("Resources/Garments"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
