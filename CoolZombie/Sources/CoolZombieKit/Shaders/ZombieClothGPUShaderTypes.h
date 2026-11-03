//
//  ZombieClothGPUShaderTypes.h
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// The ABI between the GPU cloth solver (`GPUClothSolver`, Swift) and its
// kernels (`ZombieClothGPU.metal`): the structs the two sides read and
// write, the buffer indices the kernels bind by, and the constants that
// size the rings. `Docs/GPUCloth.md` sections 3 and 4 are the design this
// file lays out; `ZombieClothGPUShaderTypes.swift` mirrors it field for
// field, and `ZCLayout.mismatches()` there pins every size, stride and
// offset written below, so a drift on either side fails a test before it
// scribbles a buffer.
//
// Every struct is laid out in 16-byte lanes (float4 / uint4 / float4x4),
// as CoolCloth's `CoolClothSimParams` is (CC/Shaders/CoolClothShaderTypes.h),
// because Metal's layout of a float4 lane and Swift's of a SIMD4 are the
// same (16 B, 16-aligned) while a bare float3 is not (16 B in Metal, 16 B
// in Swift's SIMD3 but 12 B in C's packed form), so a lane-only struct has
// no padding to disagree about. The two small per-entry structs (`ZCEntry`
// 8 B, `ZCInfluence` 16 B) are the exceptions: they are 4-byte and 8-byte
// typed, and their layouts are written out here too.
//
// Spaces and units: the solver works in the garment's frame — world space
// minus the entity's origin at the attach, rotation identity, the frame
// Jolt's soft body used (`ClothGarmentSetup.origin`) — so positions, the
// targets, the floor, the hull transforms and the balls are all handed
// over in that frame and a particle's world position is the buffer plus
// the origin. Metres, seconds, kilograms, 1/kg for inverse masses, m/N for
// compliances, as Jolt's units are, so Jolt's 1e-2 / 2e-2 / 0.3 compliances
// carry over unchanged.
//
// How the kit finds the kernels: the five metallibs that
// `Scripts/build-cloth-metallib.sh` writes into
// `Sources/CoolZombieKit/Resources/Shaders/` — `ZombieCloth-macos`,
// `-ios`, `-iossim`, `-xros` and `-xrossim` `.metallib` — are copied into
// `Bundle.module` as the `Shaders` directory (`.copy("Resources/Shaders")`
// in Package.swift), and the solver loads the one for the platform it
// runs on with `device.makeLibrary(URL:)` at
// `Bundle.module.url(forResource: RenderShaderLibraryPlatformResource
// .resourceName(baseName: "ZombieCloth"), withExtension: "metallib",
// subdirectory: "Shaders")`. The engine's rule (E/Renderer/
// RenderExtensions.swift:170-197) appends `-` and `currentPlatformSuffix`,
// which is `xros` on visionOS and `xrossim` in its simulator, `ios` on iOS
// and `iossim` in its simulator, `tvos` / `tvossim` on tvOS, and `macos`
// everywhere else; no tvOS library is built because the package does not
// declare the platform, and the solver refuses to build (nil, one printed
// line, the cloth falls back to Jolt) when the file or a kernel is missing,
// so a stale or absent metallib is loud, never a silent Jolt. The libraries
// are compiled with `-mtargetos=` at the package's minimums (macOS 14,
// iOS 17, visionOS 2) because one built against the SDK's own OS is refused
// at `makeLibrary` time on an older device.

#ifndef ZombieClothGPUShaderTypes_h
#define ZombieClothGPUShaderTypes_h

#include <metal_stdlib>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Threads per threadgroup of the per-particle kernels (`zcPredict`,
/// `zcSolve`): 1-D dispatches of N threads in groups of 64.
#define ZCThreadgroupSize 64
/// Threads in the one threadgroup `zcStats` runs as, four particles each
/// at 3,995, sixteen at the phase-2 16k.
#define ZCStatsThreadgroupSize 1024
/// The substep cap: clamp(ceil(delta / substep), 1, 32), 32 at a 30 fps
/// hitch. Sizes the per-substep rings.
#define ZCSubstepCap 32
/// Slots in every ring the CPU rewrites while a command buffer may be in
/// flight: the engine's `maxInFlightCommandBuffers` 3 plus one, because
/// the slot is written before the renderer waits on its semaphore, as the
/// engine's joint ring is.
#define ZCRingSlots 4
/// Slots of the read-back ring of the wait-off mode (`-clothGPUWait off`):
/// the frame's last blit lands in one, the CPU reads the last completed.
#define ZCReadBackRingSlots 3
/// Balls a frame can hand the solver (`ZombieProps.capacity`).
#define ZCSphereCapacity 8
/// Entries of the per-region compliance scale table (`ZCParams.regionScale`,
/// four float4 lanes), keyed by `ZCEntry`'s six-bit region.
#define ZCRegionCount 16
/// Joints an influence can name: `ZCInfluence.joints` is `ushort4`, so a
/// garment can have at most 65,535 joints and a particle four influences
/// (one to four on the shirt, 2.60 on average).
#define ZCMaxInfluences 4

// ---------------------------------------------------------------------------
// Buffer indices: the one place a binding is numbered. A kernel that does
// not take a buffer leaves its index unbound; no two roles share a number,
// so the Swift side binds every buffer by role and never by kernel.
// ---------------------------------------------------------------------------

enum ZCBufferIndex {
    /// `constant ZCParams` (256 B), bound per dispatch with `setBytes` or
    /// as an offset into the params ring.
    ZCParamsIndex = 0,
    /// `float4` x N: the positions read (`posSrc`), w = inverse mass.
    ZCPositionInIndex = 1,
    /// `float4` x N: the positions written (`posDst`), w = inverse mass
    /// carried through. The ping-pong pair: `zcPredict` reads A and writes
    /// B, `zcSolve` reads B and writes A (and swaps again on a second
    /// iteration), so the CPU tracks which of the two is current.
    ZCPositionOutIndex = 2,
    /// `float4` x N: the position at the substep's start (w unused).
    ZCPreviousIndex = 3,
    /// `float4` x N: the velocity (w unused).
    ZCVelocityIndex = 4,
    /// `float4` x N: the bind pose, garment frame (w unused).
    ZCRestIndex = 5,
    /// `float4` x N: the area-weighted rest normal, unit (w unused).
    ZCRestNormalIndex = 6,
    /// `ZCInfluence` x N: the joints and weights that skin the particle.
    ZCInfluencesIndex = 7,
    /// `float2` x N: x the slack radius before the multiplier (maxDistance
    /// x slackScale, 0 on a pin), y the back-stop depth in metres or +inf
    /// on a body-facing particle (the rolled cuffs, the collar's inside).
    ZCSlackIndex = 8,
    /// `float4` x N: this substep's skinned target (w unused), written by
    /// `zcPredict`, read by `zcSolve` and `zcStats`.
    ZCTargetIndex = 9,
    /// `float4` x N: this substep's back-stop normal, unit (w unused).
    ZCTargetNormalIndex = 10,
    /// `float4x4` x (ring slots x substep cap x joints): the skin matrices
    /// (joint world x inverse bind world) per substep; `ZCParams.rings.x`
    /// is the index of this substep's first joint.
    ZCSkinMatricesIndex = 11,
    /// `uint` x (N + 1): the CSR row starts; `csrOffsets[N]` is the entry
    /// count.
    ZCCSROffsetsIndex = 12,
    /// `ZCEntry` x entries: the constraint graph, one entry per constraint
    /// end (41,700 on the shirt).
    ZCCSREntriesIndex = 13,
    /// `ZCHullHeader` x hulls (11).
    ZCHullHeadersIndex = 14,
    /// `float4` x planes (832): n.xyz, d in the hull's joint frame, inside
    /// where dot(n, p) + d < 0.
    ZCHullPlanesIndex = 15,
    /// `float4x4` x (ring slots x (substep cap + 1) x hulls): world-from-
    /// hull rigid transforms per substep plus the frame's start;
    /// `ZCParams.rings.y` indexes this substep's first hull, `.z` the
    /// previous substep's.
    ZCHullWorldIndex = 16,
    /// `ZCSphere` x (ring slots x ZCSphereCapacity): the balls after this
    /// frame's physics step; `ZCParams.rings.w` indexes the slot's first.
    ZCSpheresIndex = 17,
    /// `ZCStats` (64 B): the frame's stats slot, bound at its ring offset.
    ZCStatsIndex = 18,
    // Phase 2, reserved so the shell kernels need no renumbering:
    /// `uint4` x T: the proxy's triangles (w unused).
    ZCTrianglesIndex = 19,
    /// `3 x float4` x T: each triangle's (e1, n, t) frame in mesh space.
    ZCTriangleFramesIndex = 20,
    /// 48 B x shell slots: bary + triangle, offset, normal.
    ZCShellBindingsIndex = 21,
    /// `2 x float4` x shell slots: positions (w = 1) and normals (w = 0).
    ZCShellOutIndex = 22,
    /// `constant` phase-2 shell params (`toMesh`), separate from `ZCParams`
    /// so the 256 B stay whole.
    ZCShellParamsIndex = 23,
};

// ---------------------------------------------------------------------------
// ZCParams — 256 B, sixteen 16-byte lanes, bound per dispatch.
// ---------------------------------------------------------------------------

/// Everything a dispatch needs that is not a per-particle array. Written by
/// the CPU for every dispatch of the frame (the substep index, the ring
/// bases and the iteration change between them; the rest is the frame's),
/// 256 B so it fits `setBytes` sixteen times over and a 4-slot ring is 1 KB.
///
/// Offsets, in bytes from the struct's start (each lane 16 B):
///   0 gravityDt, 16 compliance, 32 material, 48 floor, 64 pelvis,
///   80 counts, 96 substep, 112 flags, 128 rings, 144 regionScale[0],
///   160 regionScale[1], 176 regionScale[2], 192 regionScale[3],
///   208 reserved0, 224 reserved1, 240 reserved2; size and stride 256,
///   alignment 16.
struct ZCParams {
    /// xyz gravity in the garment frame (world minus origin, so world
    /// gravity, 0 -9.81 0), m/s^2; w the substep length dt, s (0.625 ms at
    /// sixteen substeps per 10 ms).
    metal::float4 gravityDt;
    /// x stretch, y shear, z bend compliance, m/N (Jolt's 1e-2 / 2e-2 /
    /// 0.3); w the relaxation on a particle's summed corrections
    /// (`gpuRelaxation`, 0.5 on the raw sum, about 1.5 averaged).
    metal::float4 compliance;
    /// x linear damping, 1/s (Jolt's factor max(0, 1 - damping dt), 4 by
    /// default or `gpuDamping`); y the speed cap `maxLinearVelocity`, m/s
    /// (4); z `vertexRadius`, m (0.003), the distance the hulls and the
    /// floor keep a particle at; w `gpuHullFriction`, 0 to 1 (0).
    metal::float4 material;
    /// x the floor's top in the garment frame (`floorY` minus origin.y), m;
    /// y the share of a floored particle's xz motion mixed back toward its
    /// previous position, CoolCloth's 0.4; z the slack multiplier in force
    /// this frame (the ramp, 0 right after a hard skin, 1 settled; r = 0
    /// puts a particle on its target); w the frame's delta, s (the sum of
    /// the `willStep` deltas since the last encode), which the spheres are
    /// backed along.
    metal::float4 floor;
    /// xyz the pelvis joint's position this frame in the garment frame, m;
    /// w the runaway distance, m: a particle farther from the pelvis than
    /// this is counted by `zcStats.maxPelvisDistance`'s reader as a runaway.
    metal::float4 pelvis;
    /// x the particle count N; y the joint count (13 on the shirt); z the
    /// hull count (11, 0 under `skinOnly` or `-clothColliders off`); w the
    /// sphere count this frame (0 to ZCSphereCapacity).
    metal::uint4 counts;
    /// x the substep index k, 0-based; y the substep count S this frame;
    /// z the gather iteration index, 0-based; w the gathers per substep
    /// (`gpuIterations`, 1 to 4). The last gather (z == w - 1) writes the
    /// velocity.
    metal::uint4 substep;
    /// x 1 for the averaged Jacobi (relaxation x sum / count), 0 for the raw
    /// sum (CoolCloth); y 1 when the floor plane is on; z 1 when the hulls
    /// apply friction (w of `material` above 0); w reserved, 0.
    metal::uint4 flags;
    /// Ring bases, in elements of the bound buffer: x the index of this
    /// substep's first skin matrix in `ZCSkinMatricesIndex` (slot x cap x
    /// joints + k x joints); y the index of this substep's first hull
    /// transform in `ZCHullWorldIndex` (slot x (cap + 1) x hulls +
    /// (k + 1) x hulls); z the previous substep's (y minus hulls; at k = 0
    /// the frame's start, which is the last frame's end); w the index of
    /// this frame's first sphere in `ZCSpheresIndex` (slot x
    /// ZCSphereCapacity).
    metal::uint4 rings;
    /// The sixteen per-region compliance scales, `ZCEntry`'s region into
    /// lane region / 4, component region % 4; all 1.0 by default, so a
    /// band (the slack schedule's bands by the stiffer end's slack value)
    /// can be stiffened or softened without a layout change.
    metal::float4 regionScale[4];
    /// Zero. Phase 4's capsule count and self-collision cell size go here.
    metal::float4 reserved0;
    metal::float4 reserved1;
    metal::float4 reserved2;
};

// ---------------------------------------------------------------------------
// ZCEntry — 8 B, one per constraint end.
// ---------------------------------------------------------------------------

/// The family of a distance constraint: the compliance it takes.
enum ZCConstraintFamily {
    /// An edge of the proxy: `compliance.x`.
    ZCFamilyStretch = 0,
    /// A pair across an interior edge whose quad is coplanar (a diagonal,
    /// Jolt's shear): `compliance.y`.
    ZCFamilyShear = 1,
    /// A pair across any other interior edge (Jolt's `.distance` bend):
    /// `compliance.z`.
    ZCFamilyBend = 2,
};

/// Bit layout of `ZCEntry.packed`: the neighbour's particle index in the
/// low 24 bits (16.7 M particles, the 16k cook's 15,994 and anything
/// after), the family in bits 24-25, the region in bits 26-31.
#define ZCEntryNeighbourBits 24
#define ZCEntryNeighbourMask 0x00FFFFFFu
#define ZCEntryFamilyShift 24
#define ZCEntryFamilyMask 0x3u
#define ZCEntryRegionShift 26
#define ZCEntryRegionMask 0x3Fu

/// One end of a distance constraint as the CSR stores it under the
/// particle that owns the run: the other particle, which family's
/// compliance the pair takes, which region's scale, and the rest length.
/// Two per constraint, 41,700 on the shirt (10,425 stretch + 10,425 bend
/// after the pin-pin drop, 22 at most on a particle, 10.44 on average).
///
/// Offsets: 0 packed (uint), 4 rest (float); size and stride 8, alignment 4.
struct ZCEntry {
    /// neighbour | family << 24 | region << 26 (the masks above).
    uint packed;
    /// The rest length, m (the shirt's edges 8.5 to 39.2 mm).
    float rest;
};

// ---------------------------------------------------------------------------
// ZCInfluence — 16 B, one per particle.
// ---------------------------------------------------------------------------

/// The up-to-four joints that skin a particle and their weights, the
/// weights summing to one and the unused slots weight 0 (joint 0). The
/// predict kernel blends the four skin matrices by these into the
/// substep's target and the four rotations into the back-stop normal.
///
/// Offsets: 0 joints (ushort4), 8 weights (half4); size and stride 16,
/// alignment 8.
struct ZCInfluence {
    metal::ushort4 joints;
    metal::half4 weights;
};

// ---------------------------------------------------------------------------
// ZCHullHeader — 48 B, one per hull.
// ---------------------------------------------------------------------------

/// One skin hull as a plane set: where its planes sit in
/// `ZCHullPlanesIndex`, which joint it follows, and the box in the hull's
/// own frame a particle tests before entering the planes. A box, not the
/// design's bounding sphere, because the shirt hangs 2 to 15 cm off the
/// torso hulls everywhere and a torso hull's sphere holds most of it, so
/// nearly every particle entered a plane loop that a simdgroup runs until
/// its last lane leaves (2.7-7.0 ms of GPU per Mac frame against 0.7-1.6
/// with the hulls off, 2026-11-03); the box, inflated by twice
/// `vertexRadius` (the plane test reaches r x sqrt 2 past a right-angled
/// edge, and the box must not cut off what the planes would push), holds
/// only the particles within 6 mm of the hull's extent along its own axes,
/// which is the handful that can be inside it. The planes and the box are
/// in the hull's joint frame; `ZCHullWorldIndex` moves them.
///
/// Offsets: 0 range (uint4), 16 boundsMin (float4), 32 boundsMax
/// (float4); size and stride 48, alignment 16.
struct ZCHullHeader {
    /// x the index of the hull's first plane; y its plane count (60 to 88
    /// on the shirt's eleven, 832 in all); z the joint the hull follows,
    /// an index into the feed's joints; w reserved, 0.
    metal::uint4 range;
    /// xyz the box's lower corner in the joint frame, m, the hull points'
    /// minimum less twice `vertexRadius`; w 0.
    metal::float4 boundsMin;
    /// xyz the box's upper corner, the points' maximum plus twice
    /// `vertexRadius`; w 0. A particle outside the box is one the plane
    /// test would never push.
    metal::float4 boundsMax;
};

// ---------------------------------------------------------------------------
// ZCSphere — 32 B, one per ball.
// ---------------------------------------------------------------------------

/// A ball as the solve kernel sees it: its centre and velocity after this
/// frame's physics step, in the garment frame, and its radius. The kernel
/// backs the centre along the velocity to the substep's time,
/// c_k = c - v (1 - (k + 1) / S) delta, so a ball that crosses 5 cm inside
/// a frame meets the fabric where it is at every substep.
///
/// Offsets: 0 center (float4), 16 velocity (float4); size and stride 32,
/// alignment 16.
struct ZCSphere {
    /// xyz the centre, m; w the radius, m (0.12 in the game, 0.06 in the
    /// tests).
    metal::float4 center;
    /// xyz the velocity, m/s; w unused, 0.
    metal::float4 velocity;
};

// ---------------------------------------------------------------------------
// ZCStats — 64 B, one per frame, written by zcStats.
// ---------------------------------------------------------------------------

/// What the stats kernel reduces over the frame's final positions: the
/// bounds (the swept-AABB wake test while asleep), the top speed and the
/// farthest particle from the pelvis (the speed and runaway rules once the
/// positions stop coming back, phase 2), the NaN count (the runaway's other
/// face) and how many free particles sit on their slack ball (`onClamp=`
/// in the report, the number that says whether the look is bounded by the
/// schedule or by the solver). Read by the CPU after the wait; a frame that
/// dispatches nothing leaves the slot as it was.
///
/// Offsets: 0 boundsMin (float4), 16 boundsMax (float4), 32 counts
/// (uint4), 48 reserved (uint4); size and stride 64, alignment 16.
struct ZCStats {
    /// xyz the particles' minimum corner, garment frame, m; w the top
    /// particle speed, m/s.
    metal::float4 boundsMin;
    /// xyz the maximum corner, m; w the largest distance from the pelvis,
    /// m.
    metal::float4 boundsMax;
    /// x the particles with a non-finite coordinate; y the free particles
    /// within 1e-6 m of their slack radius (on the clamp); z the free
    /// particles counted (the share's denominator); w the particles
    /// reduced, N, so a reader can tell a written slot from a stale one.
    metal::uint4 counts;
    /// Zero.
    metal::uint4 reserved;
};

#endif /* ZombieClothGPUShaderTypes_h */
