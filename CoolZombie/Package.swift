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
        // The miolabs fork's develop: the physics-pose seam, reach IK, the
        // per-frame simulation step the headset needs. Package.resolved pins
        // the commit.
        .package(url: "https://github.com/miolabs/UntoldEngine.git", branch: "develop"),
        // The Jolt physics plugin: the room as static boxes on their own
        // layer, the zombie as a character controller, a powered ragdoll,
        // and the shirt as a soft body skinned to the skeleton. Those live
        // on the fork's feature/zombie_cloth (feature/ragdoll plus the
        // skinned soft bodies) until upstream takes them. To work on the
        // plugin and the demo together:
        // `swift package edit UntoldJoltPhysics --path ../../UntoldJoltPhysics-cloth`.
        .package(url: "https://github.com/miolabs/UntoldJoltPhysics.git", branch: "feature/zombie_cloth"),
    ],
    targets: [
        .target(
            name: "CoolZombieKit",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
                .product(name: "UntoldJoltPhysics", package: "UntoldJoltPhysics"),
            ],
            // The GPU cloth kernels (`Shaders/ZombieClothGPU.metal`) are not
            // compiled by SwiftPM: `Scripts/build-cloth-metallib.sh` builds
            // them into the five committed `Resources/Shaders/ZombieCloth-
            // <platform>.metallib`, one per OS and simulator at the minimums
            // above, as the engine and CoolCloth ship theirs, because a
            // metallib built against the SDK's own OS is refused on an
            // older device and no runtime shader compilation exists in
            // either tree (`Docs/GPUCloth.md`).
            exclude: ["Shaders"],
            resources: [
                .copy("Resources/Models"),
                .copy("Resources/Animations"),
                .copy("Resources/HDR"),
                .copy("Resources/Rooms"),
                .copy("Resources/Shaders"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolZombieKitTests",
            dependencies: ["CoolZombieKit"],
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
