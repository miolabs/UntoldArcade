// swift-tools-version: 6.0

import PackageDescription

// Jolt verifies at RegisterTypes() that every translation unit including its
// headers was built with the same feature defines (JPH_VERSION_ID). Keep this
// list the single source of truth for BOTH C++ targets.
//
// SwiftPM never defines NDEBUG for C/C++ targets; without it Jolt turns on
// JPH_DEBUG and therefore JPH_ENABLE_ASSERTS (a version-ID bit) in every
// configuration. Release builds get the real thing here; debug keeps asserts.
let joltDefines: [CXXSetting] = [
    .define("NDEBUG", .when(configuration: .release)),
]

let package = Package(
    name: "UntoldJoltPhysics",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "UntoldJoltPhysics", targets: ["UntoldJoltPhysics"]),
    ],
    dependencies: [
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
    ],
    targets: [
        // Vendored Jolt Physics (MIT), compiled straight from source — no
        // CMake, no binaries. Scripts/update-jolt.sh refreshes the copy and
        // prints the exclude list below.
        .target(
            name: "JoltPhysics",
            path: "Native/JoltPhysics",
            exclude: [
                "LICENSE",
                "JOLT_VERSION.md",
                "Jolt/Shaders/HairApplyDeltaTransform.hlsl",
                "Jolt/Shaders/HairApplyGlobalPose.hlsl",
                "Jolt/Shaders/HairCalculateCollisionPlanes.hlsl",
                "Jolt/Shaders/HairCalculateRenderPositions.hlsl",
                "Jolt/Shaders/HairGridAccumulate.hlsl",
                "Jolt/Shaders/HairGridClear.hlsl",
                "Jolt/Shaders/HairGridNormalize.hlsl",
                "Jolt/Shaders/HairIntegrate.hlsl",
                "Jolt/Shaders/HairSkinRoots.hlsl",
                "Jolt/Shaders/HairSkinVertices.hlsl",
                "Jolt/Shaders/HairTeleport.hlsl",
                "Jolt/Shaders/HairUpdateRoots.hlsl",
                "Jolt/Shaders/HairUpdateStrands.hlsl",
                "Jolt/Shaders/HairUpdateVelocity.hlsl",
                "Jolt/Shaders/HairUpdateVelocityIntegrate.hlsl",
                "Jolt/Shaders/TestCompute.hlsl",
                "Jolt/Shaders/TestCompute2.hlsl",
            ],
            publicHeadersPath: ".",
            cxxSettings: joltDefines
        ),
        // C ABI shim over the Jolt C++ API: opaque handles and plain structs,
        // only what the engine's PhysicsBackend protocol needs.
        .target(
            name: "CJoltBridge",
            dependencies: ["JoltPhysics"],
            path: "Sources/CJoltBridge",
            cxxSettings: joltDefines
        ),
        // The plugin: PhysicsBackend conformance + PhysicsBackendPlugin manifest.
        .target(
            name: "UntoldJoltPhysics",
            dependencies: [
                "CJoltBridge",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            path: "Sources/UntoldJoltPhysics",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "UntoldJoltPhysicsTests",
            dependencies: [
                "UntoldJoltPhysics",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            path: "Tests/UntoldJoltPhysicsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
