//
//  ZombieClothGPUShaderTypes.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd

// The Swift side of `Shaders/ZombieClothGPUShaderTypes.h`, field for field:
// the structs `GPUClothSolver` writes into the buffers its kernels read,
// the buffer indices it binds by and the constants that size its rings.
// The header is not imported — the kit has no module map for it, and
// CoolCloth mirrors its params the same way (CC/Sources/CoolCloth/
// CoolClothShaderABI.swift) — so the two files can drift, and `ZCLayout`
// below is what stops a drift: every size, stride and offset the header
// writes down is listed there, `mismatches()` compares the Swift layout
// against the list, and the GPU test suite asserts the list empty. A
// SIMD4 member is 16 B and 16-aligned in Swift as a float4 lane is in
// Metal, which is why the structs are lanes and never bare SIMD3s.

/// Threads per threadgroup of the per-particle kernels.
let zcThreadgroupSize = 64
/// Threads in the one threadgroup `zcStats` runs as.
let zcStatsThreadgroupSize = 1024
/// The substep cap, 32 at a 30 fps hitch.
let zcSubstepCap = 32
/// Slots of every ring the CPU rewrites while a buffer may be in flight.
let zcRingSlots = 4
/// Slots of the wait-off read-back ring.
let zcReadBackRingSlots = 3
/// Balls a frame can hand the solver.
let zcSphereCapacity = 8
/// Entries of the per-region compliance scale table.
let zcRegionCount = 16
/// Influences a particle can carry.
let zcMaxInfluences = 4

/// The buffer index every kernel binds a role at (`ZCBufferIndex`).
enum ZCBufferIndex: Int {
    case params = 0
    case positionIn = 1
    case positionOut = 2
    case previous = 3
    case velocity = 4
    case rest = 5
    case restNormal = 6
    case influences = 7
    case slack = 8
    case target = 9
    case targetNormal = 10
    case skinMatrices = 11
    case csrOffsets = 12
    case csrEntries = 13
    case hullHeaders = 14
    case hullPlanes = 15
    case hullWorld = 16
    case spheres = 17
    case stats = 18
    // Phase 2, the GPU shell (`zcTriangleFrames`, `zcShell`).
    case triangles = 19
    case triangleFrames = 20
    case shellBindings = 21
    case shellOut = 22
    case shellParams = 23
}

/// `ZCParams`: the frame's and the dispatch's scalars, 256 B of sixteen
/// lanes. Lane meanings as the header has them, in short: `gravityDt` xyz
/// gravity and w the substep dt; `compliance` stretch / shear / bend and w
/// the relaxation; `material` damping, speed cap, vertex radius, hull
/// friction; `floor` the floor's top, the xz mix, the slack multiplier,
/// the frame's delta; `pelvis` xyz and w the runaway distance; `counts`
/// N, joints, hulls, spheres; `substep` k, S, the gather index, the
/// gathers; `flags` averaged Jacobi, floor on, hull friction on, 0;
/// `rings` the skin-matrix, hull, previous-hull and sphere bases;
/// `regionScale` the sixteen scales in four lanes; three reserved lanes.
struct ZCParams {
    var gravityDt: SIMD4<Float> = .zero
    var compliance: SIMD4<Float> = .zero
    var material: SIMD4<Float> = .zero
    var floor: SIMD4<Float> = .zero
    var pelvis: SIMD4<Float> = .zero
    var counts: SIMD4<UInt32> = .zero
    var substep: SIMD4<UInt32> = .zero
    var flags: SIMD4<UInt32> = .zero
    var rings: SIMD4<UInt32> = .zero
    // `float4 regionScale[4]` is four consecutive lanes; Swift has no fixed
    // array, so four members at the same offsets (144, 160, 176, 192).
    var regionScale0: SIMD4<Float> = SIMD4(repeating: 1)
    var regionScale1: SIMD4<Float> = SIMD4(repeating: 1)
    var regionScale2: SIMD4<Float> = SIMD4(repeating: 1)
    var regionScale3: SIMD4<Float> = SIMD4(repeating: 1)
    var reserved0: SIMD4<Float> = .zero
    var reserved1: SIMD4<Float> = .zero
    var reserved2: SIMD4<Float> = .zero

    /// The scale of region `region` (0 to 15), the kernel's lane
    /// region / 4, component region % 4.
    subscript(regionScale region: Int) -> Float {
        get {
            precondition(region >= 0 && region < zcRegionCount)
            switch region >> 2 {
            case 0: return regionScale0[region & 3]
            case 1: return regionScale1[region & 3]
            case 2: return regionScale2[region & 3]
            default: return regionScale3[region & 3]
            }
        }
        set {
            precondition(region >= 0 && region < zcRegionCount)
            switch region >> 2 {
            case 0: regionScale0[region & 3] = newValue
            case 1: regionScale1[region & 3] = newValue
            case 2: regionScale2[region & 3] = newValue
            default: regionScale3[region & 3] = newValue
            }
        }
    }
}

/// `ZCConstraintFamily`: which compliance a pair takes.
enum ZCConstraintFamily: UInt32 {
    case stretch = 0
    case shear = 1
    case bend = 2
}

/// `ZCEntry`: one end of a distance constraint under the particle that
/// owns the CSR run — the neighbour in the low 24 bits of `packed`, the
/// family in bits 24-25, the region in bits 26-31, and the rest length.
/// 8 B, two per constraint, 41,700 on the shirt.
struct ZCEntry {
    static let neighbourMask: UInt32 = 0x00FF_FFFF
    static let familyShift: UInt32 = 24
    static let familyMask: UInt32 = 0x3
    static let regionShift: UInt32 = 26
    static let regionMask: UInt32 = 0x3F

    var packed: UInt32
    var rest: Float

    init(packed: UInt32, rest: Float) {
        self.packed = packed
        self.rest = rest
    }

    /// The builder's form: a neighbour under 16.7 M, a family, a region
    /// under 16, a rest length in metres.
    init(neighbour: Int, family: ZCConstraintFamily, region: Int, rest: Float) {
        precondition(neighbour >= 0 && UInt32(neighbour) <= Self.neighbourMask, "ZCEntry: neighbour \(neighbour) needs more than 24 bits")
        precondition(region >= 0 && region < zcRegionCount, "ZCEntry: region \(region) is not one of the \(zcRegionCount)")
        packed = UInt32(neighbour) | (family.rawValue << Self.familyShift) | (UInt32(region) << Self.regionShift)
        self.rest = rest
    }

    var neighbour: Int { Int(packed & Self.neighbourMask) }
    var family: ZCConstraintFamily { ZCConstraintFamily(rawValue: (packed >> Self.familyShift) & Self.familyMask) ?? .bend }
    var region: Int { Int((packed >> Self.regionShift) & Self.regionMask) }
}

/// `ZCInfluence`: the up-to-four joints that skin a particle (`ushort4`)
/// and their weights (`half4`, summing to one, the unused slots 0 on
/// joint 0). 16 B. The weights are `Float16` on Apple silicon; on an Intel
/// Mac, where Swift has no `Float16`, they are the half's bit pattern in a
/// `UInt16` and `init(joints:weights:)` converts.
struct ZCInfluence {
    var joints: SIMD4<UInt16>
    #if arch(x86_64)
        var weights: SIMD4<UInt16>
    #else
        var weights: SIMD4<Float16>
    #endif

    init(joints: SIMD4<UInt16>, weights: SIMD4<Float>) {
        self.joints = joints
        #if arch(x86_64)
            self.weights = SIMD4<UInt16>(weights.indices.map { Self.halfBits(weights[$0]) })
        #else
            self.weights = SIMD4<Float16>(weights)
        #endif
    }

    #if arch(x86_64)
        /// IEEE 754 binary16 of a float, round to nearest even; enough for
        /// weights in [0, 1].
        private static func halfBits(_ value: Float) -> UInt16 {
            let bits = value.bitPattern
            let sign = UInt16((bits >> 16) & 0x8000)
            let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
            var mantissa = bits & 0x7F_FFFF
            if exponent <= 0 {
                if exponent < -10 { return sign }
                mantissa |= 0x80_0000
                let shift = UInt32(14 - exponent)
                var half = UInt16(mantissa >> shift)
                let remainder = mantissa & ((1 << shift) - 1)
                let halfway: UInt32 = 1 << (shift - 1)
                if remainder > halfway || (remainder == halfway && (half & 1) == 1) { half += 1 }
                return sign | half
            }
            if exponent >= 0x1F { return sign | 0x7C00 }
            var half = UInt16(exponent << 10) | UInt16(mantissa >> 13)
            let remainder = mantissa & 0x1FFF
            if remainder > 0x1000 || (remainder == 0x1000 && (half & 1) == 1) { half += 1 }
            return sign | half
        }
    #endif
}

/// `ZCHullHeader`: a skin hull's planes (`range.x` the first, `.y` the
/// count, `.z` the joint it follows, `.w` 0) and its box in the joint
/// frame (the hull points' extent inflated by twice `vertexRadius`, w 0),
/// which the solve kernel tests before the planes. 48 B, eleven on the shirt.
struct ZCHullHeader {
    var range: SIMD4<UInt32> = .zero
    var boundsMin: SIMD4<Float> = .zero
    var boundsMax: SIMD4<Float> = .zero
}

/// `ZCSphere`: a ball after this frame's physics step, garment frame —
/// xyz the centre and w the radius, xyz the velocity and w 0. 32 B.
struct ZCSphere {
    var center: SIMD4<Float> = .zero
    var velocity: SIMD4<Float> = .zero

    init() {}

    init(_ sphere: ClothSphere, origin: SIMD3<Float>) {
        center = SIMD4(sphere.center - origin, sphere.radius)
        velocity = SIMD4(sphere.velocity, 0)
    }
}

/// `ZCStats`: the stats kernel's reduction over the frame's final
/// positions — the bounds with the top speed and the largest pelvis
/// distance in their w lanes, then the NaN count, the on-clamp count, its
/// denominator and N as the written mark. 64 B.
struct ZCStats {
    var boundsMin: SIMD4<Float> = .zero
    var boundsMax: SIMD4<Float> = .zero
    var counts: SIMD4<UInt32> = .zero
    var reserved: SIMD4<UInt32> = .zero

    var maxSpeed: Float { boundsMin.w }
    var maxPelvisDistance: Float { boundsMax.w }
    var nanCount: Int { Int(counts.x) }
    var onClampCount: Int { Int(counts.y) }
    var freeCount: Int { Int(counts.z) }
    var particlesReduced: Int { Int(counts.w) }
    /// The share of free particles on their slack ball, 0 to 1; 0 when the
    /// slot was never written.
    var onClampShare: Float { freeCount > 0 ? Float(onClampCount) / Float(freeCount) : 0 }
}

// MARK: - Phase 2: the GPU shell

/// `ZCShellParams`: what the two shell kernels need beyond the particles —
/// `toMesh`, mesh space from world space (`meshToWorld.inverse`, as
/// `readBack` hands it to `expandOverride`); `origin`, the garment origin
/// the kernels add to a garment-frame position before the matrix, the
/// CPU's order, so the GPU shell lands on the CPU shell to the float
/// arithmetic; `counts` x the shell slot count (the driven exported
/// vertices, 32,530 in the game and 29,402 in the tests' shell-only mesh),
/// y the triangle count T. 128 B, bound with `setBytes` once per frame to
/// both kernels at `ZCBufferIndex.shellParams`.
struct ZCShellParams {
    var toMesh: simd_float4x4 = matrix_identity_float4x4
    var origin: SIMD4<Float> = .zero
    var counts: SIMD4<UInt32> = .zero
    var reserved0: SIMD4<UInt32> = .zero
    var reserved1: SIMD4<UInt32> = .zero

    init() {}

    init(toMesh: simd_float4x4, origin: SIMD3<Float>, slotCount: Int, triangleCount: Int) {
        self.toMesh = toMesh
        self.origin = SIMD4(origin, 0)
        counts = SIMD4(UInt32(slotCount), UInt32(triangleCount), 0, 0)
    }
}

/// `ZCTriangleFrame`: one proxy triangle's frame in mesh space as
/// `zcTriangleFrames` writes it and `zcShell` reads it — `e1` the unit
/// first edge, `n` the unit face normal, `t = n x e1`, w lanes 0 — the
/// `RenderShell.Frame` without the corners. 48 B, one per triangle. The
/// CPU fills the buffer once at the attach with the bind-pose frames (the
/// same rule over the rest positions, as `RenderShell.init` does) because
/// a collapsed triangle keeps whatever frame the buffer holds; the
/// defaults are the CPU's rest default, the identity frame.
struct ZCTriangleFrame {
    var e1: SIMD4<Float> = SIMD4(1, 0, 0, 0)
    var n: SIMD4<Float> = SIMD4(0, 1, 0, 0)
    var t: SIMD4<Float> = SIMD4(0, 0, 1, 0)

    init() {}

    init(e1: SIMD3<Float>, n: SIMD3<Float>, t: SIMD3<Float>) {
        self.e1 = SIMD4(e1, 0)
        self.n = SIMD4(n, 0)
        self.t = SIMD4(t, 0)
    }
}

/// `ZCShellBinding`: one driven exported vertex's binding, `RenderShell.
/// Binding` in lanes — the barycentric weights with the triangle index in
/// `barycentric.w` as a float (exact below 2^24; the 16k cook has 31,681
/// triangles), the rest offset in the triangle's bind frame (e1, n, t) and
/// the exported copy's own unit rest normal in that frame. 48 B, one per
/// slot in the override's order.
struct ZCShellBinding {
    var barycentric: SIMD4<Float> = .zero
    var offset: SIMD4<Float> = .zero
    var normal: SIMD4<Float> = SIMD4(0, 1, 0, 0)

    init() {}

    init(triangle: Int, barycentric: SIMD3<Float>, offset: SIMD3<Float>, normal: SIMD3<Float>) {
        precondition(triangle >= 0 && triangle < 1 << 24, "ZCShellBinding: triangle \(triangle) is not exact as a float")
        self.barycentric = SIMD4(barycentric, Float(triangle))
        self.offset = SIMD4(offset, 0)
        self.normal = SIMD4(normal, 0)
    }

    var triangle: Int { Int(barycentric.w) }
}

/// The layout the header writes down, so a test can pin the Swift mirror
/// to it: `mismatches()` is empty when every size, stride and offset
/// agrees, and names each disagreement otherwise. `testTheMetallibExposesTheKernels`
/// asserts it empty beside the strides 256 / 8 / 32 / 64.
enum ZCLayout {
    /// A struct's expected size, stride and member offsets, bytes.
    struct Expected {
        let name: String
        let size: Int
        let stride: Int
        let alignment: Int
        let offsets: [(String, Int)]
    }

    static let params = Expected(name: "ZCParams", size: 256, stride: 256, alignment: 16, offsets: [
        ("gravityDt", 0), ("compliance", 16), ("material", 32), ("floor", 48), ("pelvis", 64),
        ("counts", 80), ("substep", 96), ("flags", 112), ("rings", 128),
        ("regionScale0", 144), ("regionScale1", 160), ("regionScale2", 176), ("regionScale3", 192),
        ("reserved0", 208), ("reserved1", 224), ("reserved2", 240),
    ])
    static let entry = Expected(name: "ZCEntry", size: 8, stride: 8, alignment: 4, offsets: [("packed", 0), ("rest", 4)])
    static let influence = Expected(name: "ZCInfluence", size: 16, stride: 16, alignment: 8, offsets: [("joints", 0), ("weights", 8)])
    static let hullHeader = Expected(name: "ZCHullHeader", size: 48, stride: 48, alignment: 16, offsets: [("range", 0), ("boundsMin", 16), ("boundsMax", 32)])
    static let sphere = Expected(name: "ZCSphere", size: 32, stride: 32, alignment: 16, offsets: [("center", 0), ("velocity", 16)])
    static let stats = Expected(name: "ZCStats", size: 64, stride: 64, alignment: 16, offsets: [("boundsMin", 0), ("boundsMax", 16), ("counts", 32), ("reserved", 48)])
    static let shellParams = Expected(name: "ZCShellParams", size: 128, stride: 128, alignment: 16, offsets: [
        ("toMesh", 0), ("origin", 64), ("counts", 80), ("reserved0", 96), ("reserved1", 112),
    ])
    static let triangleFrame = Expected(name: "ZCTriangleFrame", size: 48, stride: 48, alignment: 16, offsets: [("e1", 0), ("n", 16), ("t", 32)])
    static let shellBinding = Expected(name: "ZCShellBinding", size: 48, stride: 48, alignment: 16, offsets: [("barycentric", 0), ("offset", 16), ("normal", 32)])

    /// Every disagreement between the Swift structs and the header's
    /// layout, one line each; empty when the mirror is exact.
    static func mismatches() -> [String] {
        var out: [String] = []
        func check<T>(_ type: T.Type, _ expected: Expected, _ offsets: [(String, PartialKeyPath<T>)]) {
            if MemoryLayout<T>.size != expected.size { out.append("\(expected.name): size \(MemoryLayout<T>.size), expected \(expected.size)") }
            if MemoryLayout<T>.stride != expected.stride { out.append("\(expected.name): stride \(MemoryLayout<T>.stride), expected \(expected.stride)") }
            if MemoryLayout<T>.alignment != expected.alignment { out.append("\(expected.name): alignment \(MemoryLayout<T>.alignment), expected \(expected.alignment)") }
            for (name, path) in offsets {
                let want = expected.offsets.first { $0.0 == name }?.1
                let have = MemoryLayout<T>.offset(of: path)
                if want == nil { out.append("\(expected.name).\(name): not in the expected list"); continue }
                if have != want { out.append("\(expected.name).\(name): offset \(have.map(String.init) ?? "nil"), expected \(want!)") }
            }
            if offsets.count != expected.offsets.count { out.append("\(expected.name): \(offsets.count) members checked, \(expected.offsets.count) expected") }
        }
        check(ZCParams.self, params, [
            ("gravityDt", \ZCParams.gravityDt), ("compliance", \ZCParams.compliance), ("material", \ZCParams.material),
            ("floor", \ZCParams.floor), ("pelvis", \ZCParams.pelvis), ("counts", \ZCParams.counts),
            ("substep", \ZCParams.substep), ("flags", \ZCParams.flags), ("rings", \ZCParams.rings),
            ("regionScale0", \ZCParams.regionScale0), ("regionScale1", \ZCParams.regionScale1),
            ("regionScale2", \ZCParams.regionScale2), ("regionScale3", \ZCParams.regionScale3),
            ("reserved0", \ZCParams.reserved0), ("reserved1", \ZCParams.reserved1), ("reserved2", \ZCParams.reserved2),
        ])
        check(ZCEntry.self, entry, [("packed", \ZCEntry.packed), ("rest", \ZCEntry.rest)])
        check(ZCInfluence.self, influence, [("joints", \ZCInfluence.joints), ("weights", \ZCInfluence.weights)])
        check(ZCHullHeader.self, hullHeader, [("range", \ZCHullHeader.range), ("boundsMin", \ZCHullHeader.boundsMin), ("boundsMax", \ZCHullHeader.boundsMax)])
        check(ZCSphere.self, sphere, [("center", \ZCSphere.center), ("velocity", \ZCSphere.velocity)])
        check(ZCStats.self, stats, [("boundsMin", \ZCStats.boundsMin), ("boundsMax", \ZCStats.boundsMax), ("counts", \ZCStats.counts), ("reserved", \ZCStats.reserved)])
        check(ZCShellParams.self, shellParams, [
            ("toMesh", \ZCShellParams.toMesh), ("origin", \ZCShellParams.origin), ("counts", \ZCShellParams.counts),
            ("reserved0", \ZCShellParams.reserved0), ("reserved1", \ZCShellParams.reserved1),
        ])
        check(ZCTriangleFrame.self, triangleFrame, [("e1", \ZCTriangleFrame.e1), ("n", \ZCTriangleFrame.n), ("t", \ZCTriangleFrame.t)])
        check(ZCShellBinding.self, shellBinding, [("barycentric", \ZCShellBinding.barycentric), ("offset", \ZCShellBinding.offset), ("normal", \ZCShellBinding.normal)])
        return out
    }
}
