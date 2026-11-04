//
//  ZombieClothGPUSolver.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Metal
import QuartzCore
import simd
import UntoldEngine

/// The GPU arm of the seam: the shirt's proxy solved as an XPBD "small
/// steps" cloth in Metal compute, phase 1 of `Docs/GPUCloth.md`. The owner
/// chose it on 2026-11-03 after three headset rounds read the Jolt shirt
/// as paper, and what limits the Jolt shirt is its solver as much as its
/// resolution: eight Gauss-Seidel passes of 1.25 ms per 10 ms frame, the
/// skin constraint applied before the edges so neither the slack clamp nor
/// the back-stop is exact at a pass's end (the worst cuff 3 mm behind its
/// target), the skinned target interpolated only over the first collision
/// step after a feed, and one thread per soft body, so four times the
/// particles — the 16,000 the drawn shell's 8.25 mm edge can show — would
/// be four times its 3.4 ms. On the GPU the price of the particle count is
/// nearly flat: a 3,995-particle frame is dispatch-latency bound (33
/// dispatches of a few thousand threads, about 0.6-0.9 ms), and a
/// 16,000-particle one costs about twice that, not four times.
///
/// What it solves, per substep of dt (0.625 ms at sixteen substeps per
/// 10 ms frame; the count follows the frame's delta, `substepCount`):
/// `zcPredict` integrates every free particle as Jolt does (v += g dt,
/// v *= max(0, 1 - damping dt), prev = x, x += v dt) and blends this
/// substep's skin matrices into its target and its back-stop normal;
/// `zcSolve` gathers the particle's distance constraints over its CSR run
/// (`ConstraintGraph`: one per edge and one across every interior edge,
/// Jolt's own set, 10,425 + 10,425 on the shirt after the pin-pin drop),
/// then applies the slack ball and the back-stop AFTER the edges so they
/// are exact, the eleven skin hulls as plane sets (`HullPlaneSet`, 832
/// planes), the floor and the balls, and on the last gather writes the
/// velocity; `zcStats` reduces the frame's final positions once (the
/// bounds for the swept-AABB wake test, the on-clamp share, the NaN
/// count). The thirteen joints are slerped per substep on the CPU and the
/// matrices uploaded (16 x 13 x 64 B), so the skinned target moves
/// continuously inside the frame and the hulls move with it.
///
/// Where it runs in the frame, on the frame thread alone: `feed` inside
/// `willStep` records the frame (the joints now and before, the slack
/// multiplier, the delta accumulated over a long frame's several calls,
/// whether the feed is hard) and encodes nothing; `beginFrame`, at the top
/// of the game update after Jolt has stepped (so the balls it is handed
/// are this frame's), fills a slot of the input rings, encodes the frame's
/// substeps into ONE command buffer on the solver's own `MTLCommandQueue`
/// and commits; `readPositions`, at the game update's end, waits for that
/// buffer once (`gpuWait`) and copies the positions out — the game's own
/// step runs between the commit and the wait, so whatever of the GPU's
/// time it covers is free, and the particles are current for the same
/// frame's override as on the Jolt path. Its own queue, not the engine's,
/// because on the engine's a buffer committed during update N queues
/// behind render N - 1 and the wait would absorb that frame's GPU time;
/// and not a render-extension pass, which runs once per eye in the
/// submission phase, a frame late for a CPU-written override and
/// unreachable from the test harness. With `gpuWait` off the buffer ends
/// with a blit of the positions into a three-slot read-back ring and the
/// read takes the last completed slot without waiting: a frame of shirt
/// lag (`lag=1f`), the fallback should the wait be the cost. A hard skin
/// — the attach, a re-seat, the LOD's return, a runaway — waits for
/// anything in flight and writes the skinned targets into the shared
/// position, previous and velocity buffers on the CPU, which settles the
/// two cases the designs left open (a runaway found after the frame's
/// GPU work, a re-seat fired inside the game step while it is in flight)
/// without a second command buffer. Resting (asleep or out of range) it
/// encodes nothing, so the particle buffers are bitwise untouched across
/// sleeping frames, and a ball reaching the resting shirt wakes it by the
/// swept-AABB test (`beginFrame`), as Jolt's pairing woke the Jolt one.
///
/// Spaces: the garment's frame, world minus the entity's origin at the
/// attach, rotation identity — the frame Jolt's soft body used — so the
/// targets, the hulls, the floor and the balls need no change of space
/// and a particle's world position is the buffer plus the origin. The
/// kernels, the buffer roles and the structs are the contract of
/// `Shaders/ZombieClothGPUShaderTypes.h`, mirrored in
/// `ZombieClothGPUShaderTypes.swift`. Frame thread only, like
/// `ZombieCloth`; the one thing another thread touches is the completed
/// handler's record (`Completion`), under its lock.
///
/// Phase 2 of the design (2026-11-04) moves the drawn shell onto the GPU
/// too: `RenderShell.evaluate` was the largest CPU item of the phase-1
/// frame — 503 us median and 1,008 max on the M4 Max's cores for the
/// shirt's 32,530 driven vertices, about a millisecond on the headset,
/// against a 0.6 ms budget for the whole read and bind at gate 2 — so when
/// the garment comes with a `ClothShellSetup` the frame's command buffer
/// runs two more dispatches after the stats, `zcTriangleFrames` (one
/// thread per proxy triangle: the frame e1, n, t in mesh space) and
/// `zcShell` (one per slot: the barycentric point plus the rest offset in
/// that frame, and the exported copy's rest normal turned by it, line for
/// line the CPU's formula), into a shared `shellOut` of two planar
/// `float4` streams, and `copyShellOutput` hands the CPU 32,530 x 2 lanes
/// to copy into the override arrays — the design's 100-150 us — instead
/// of a shell to evaluate. The kernels need the mesh-from-world matrix of
/// the frame (`shellMeshFromWorld`, set by the cloth before `beginFrame`),
/// since the override is written in the mesh's own space while the
/// solver works in the garment frame; the game's step runs between the
/// encode and the read and may move the entity (the controller's
/// corrections), so the copy compares the matrix it was encoded with
/// against the one the read wants and re-expresses the output through
/// the difference when they disagree rather than draw the shirt a frame
/// of motion behind the body — a rigid change of frame per slot, in the
/// same loop. A hard skin invalidates the output (the particles were
/// rewritten on the CPU) and the cloth evaluates that frame's shell on
/// the cores; `-clothGPUShell off` keeps the CPU shell on the GPU arm for
/// the A/B, and the Jolt arm never has one. In the wait-off mode the
/// output is ringed with the read-back, three slots, so the copy reads
/// the completed frame's while the next is being written.
public final class GPUClothSolver: ClothSolver, @unchecked Sendable {
    // MARK: - The constraint graph

    /// The proxy's distance constraints as the solve kernel gathers them:
    /// Jolt's own set (`SoftBodySharedSettings::CreateConstraints`), built
    /// once at the attach from the faces so the GPU arm holds the shirt with
    /// the constraints the Jolt arm holds it with — one constraint per
    /// unique edge, one across every interior edge between the two opposite
    /// vertices (Jolt's `.distance` bend; the pair of a quad-like coplanar
    /// pair of faces is a shear constraint and its diagonal edge takes the
    /// shear compliance too, within Jolt's 8 degrees), and none between
    /// two pins, since a constraint with both ends immovable does nothing
    /// (Jolt keeps an edge only when one end is movable). On the shirt as
    /// cooked on 2026-11-03 that is 11,849 edges of which 1,424 are pin-pin
    /// and 11,707 interior edges of which 1,282 opposite pairs are pin-pin
    /// (45 pairs coincide with an edge and are kept, as Jolt keeps them),
    /// so 10,425 + 10,425 = 20,850 constraints and 41,700 entries, two per
    /// constraint, 22 at most on a particle and 10.44 on average. Stored
    /// as CSR — `offsets[i] ..< offsets[i + 1]` is particle i's run of
    /// `entries`, each the neighbour, the family and the region in one
    /// word and the rest length — in a fixed order (by neighbour, then
    /// family), so the gather is order-fixed and atomic-free and two runs
    /// on one device are bitwise equal. The region is the slack value of
    /// the stiffer end (the smaller `maxDistance`), keyed into the
    /// sixteen-entry `regionScale` table of the params, all 1 by default,
    /// so a band can be stiffened or softened without a layout change;
    /// `regionSlack` lists the values by index.
    public struct ConstraintGraph: Sendable {
        public let particleCount: Int
        /// Unique edges of the faces, and those on the boundary (one face).
        public let edgeCount: Int
        public let boundaryEdgeCount: Int
        /// Interior edges whose two opposite vertices differ (a pair across
        /// each; two faces back to back give none).
        public let bendPairCount: Int
        /// Dropped for having two pins at the ends.
        public let pinPinEdgesDropped: Int
        public let pinPinBendPairsDropped: Int
        /// The constraints kept: the edges (stretch or, on a quad's diagonal,
        /// shear compliance) and the opposite pairs (shear or bend).
        public let stretchConstraintCount: Int
        public let bendConstraintCount: Int
        /// The cross pairs across a quad-like coplanar pair of faces (under
        /// 8 degrees, Jolt's rule), which take the shear compliance — counted
        /// before the pin-pin drop, so 1,556 on the shirt of which 68 are
        /// dropped and 1,488 kept (single precision; a double-precision
        /// judge puts one pair on the other side of the 8 degrees).
        public let shearPairCount: Int
        /// `offsets[particleCount]`: two per constraint.
        public let entryCount: Int
        public let maxEntriesPerParticle: Int
        public let meanEntriesPerParticle: Float
        /// Over the edges kept, metres (the shirt's 8.5 to 39.2 mm); the
        /// opposite pairs, diagonals and bends, are longer and not in it.
        public let restLengthRange: ClosedRange<Float>
        /// The distinct slack values, ascending, by region index.
        public let regionSlack: [Float]
        /// The CSR row starts, `particleCount + 1` of them.
        public let offsets: [UInt32]
        /// The CSR entries (`ZCEntry`), `entryCount` of them.
        let entries: [ZCEntry]

        /// Jolt's tolerance for a quad: the two faces within this of
        /// coplanar and the two diagonals within it of perpendicular.
        static let quadAngleTolerance: Float = 8 * .pi / 180

        /// Builds the graph from `faces` over `positions` (rest lengths),
        /// dropping every constraint whose two ends have no inverse mass,
        /// with the region of a constraint the smaller `maxDistance` of its
        /// ends.
        init(faces: [SIMD3<UInt32>], positions: [SIMD3<Float>], inverseMasses: [Float], maxDistance: [Float]) {
            let count = positions.count
            particleCount = count
            // The regions: the distinct slack values, ascending, sixteen at
            // most (the schedule has nine on the shirt); more are binned by
            // rank into the sixteen.
            let distinct = Array(Set(maxDistance)).sorted()
            let binned: [Float] = distinct.count <= zcRegionCount ? distinct : (0 ..< zcRegionCount).map { distinct[$0 * distinct.count / zcRegionCount] }
            regionSlack = binned
            var regionOf: [Float: Int] = [:]
            for (rank, value) in distinct.enumerated() {
                regionOf[value] = distinct.count <= zcRegionCount ? rank : min(rank * zcRegionCount / distinct.count, zcRegionCount - 1)
            }
            func region(_ a: Int, _ b: Int) -> Int { regionOf[min(maxDistance[a], maxDistance[b])] ?? 0 }

            // Every edge with the faces that share it and the vertex each
            // face has opposite it, keyed (min, max).
            struct Side { let face: Int; let opposite: UInt32 }
            var edges: [UInt64: [Side]] = [:]
            edges.reserveCapacity(faces.count * 3 / 2)
            for (f, face) in faces.enumerated() {
                let corners = [face.x, face.y, face.z]
                for i in 0 ..< 3 {
                    let a = corners[i], b = corners[(i + 1) % 3], o = corners[(i + 2) % 3]
                    let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                    edges[key, default: []].append(Side(face: f, opposite: o))
                }
            }
            func faceNormal(_ f: Int) -> SIMD3<Float> {
                // Jolt's (v2 - v0) x (v1 - v0): the sign cancels in the dot.
                let face = faces[f]
                let p0 = positions[Int(face.x)], p1 = positions[Int(face.y)], p2 = positions[Int(face.z)]
                return simd_cross(p2 - p0, p1 - p0)
            }
            let sinSquared = sin(Self.quadAngleTolerance) * sin(Self.quadAngleTolerance)
            let cosSquared = cos(Self.quadAngleTolerance) * cos(Self.quadAngleTolerance)

            var constraints: [(a: Int, b: Int, family: ZCConstraintFamily, edge: Bool)] = []
            constraints.reserveCapacity(edges.count * 2)
            var boundary = 0, pairs = 0, pinPinEdges = 0, pinPinPairs = 0, shearPairs = 0, edgesKept = 0, pairsKept = 0
            for key in edges.keys.sorted() {
                let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
                let sides = edges[key]!
                if sides.count == 1 { boundary += 1 }
                var isShear = false
                if sides.count >= 2 {
                    let o0 = Int(sides[0].opposite), o1 = Int(sides[1].opposite)
                    if o0 != o1 {
                        pairs += 1
                        let n0 = faceNormal(sides[0].face), n1 = faceNormal(sides[1].face)
                        let dot = simd_dot(n0, n1)
                        if dot > 0, dot * dot > cosSquared * simd_length_squared(n0) * simd_length_squared(n1) {
                            let e0 = positions[o0] - positions[a], e1 = positions[o1] - positions[a]
                            let d = simd_dot(e0, e1)
                            if d * d < sinSquared * simd_length_squared(e0) * simd_length_squared(e1) {
                                isShear = true
                            }
                        }
                        if isShear { shearPairs += 1 }
                        if inverseMasses[o0] > 0 || inverseMasses[o1] > 0 {
                            constraints.append((o0, o1, isShear ? .shear : .bend, false))
                            pairsKept += 1
                        } else {
                            pinPinPairs += 1
                        }
                    }
                }
                if inverseMasses[a] > 0 || inverseMasses[b] > 0 {
                    constraints.append((a, b, isShear ? .shear : .stretch, true))
                    edgesKept += 1
                } else {
                    pinPinEdges += 1
                }
            }
            edgeCount = edges.count
            boundaryEdgeCount = boundary
            bendPairCount = pairs
            pinPinEdgesDropped = pinPinEdges
            pinPinBendPairsDropped = pinPinPairs
            stretchConstraintCount = edgesKept
            bendConstraintCount = pairsKept
            shearPairCount = shearPairs

            // The CSR: every constraint under both ends, each run sorted.
            var runs = [[ZCEntry]](repeating: [], count: count)
            var shortest = Float.greatestFiniteMagnitude, longest: Float = 0
            for c in constraints {
                let rest = simd_distance(positions[c.a], positions[c.b])
                let r = region(c.a, c.b)
                runs[c.a].append(ZCEntry(neighbour: c.b, family: c.family, region: r, rest: rest))
                runs[c.b].append(ZCEntry(neighbour: c.a, family: c.family, region: r, rest: rest))
                if c.edge {
                    shortest = min(shortest, rest)
                    longest = max(longest, rest)
                }
            }
            var offsets = [UInt32](repeating: 0, count: count + 1)
            var entries: [ZCEntry] = []
            entries.reserveCapacity(constraints.count * 2)
            var widest = 0
            for i in 0 ..< count {
                let run = runs[i].sorted { ($0.neighbour, $0.family.rawValue) < ($1.neighbour, $1.family.rawValue) }
                offsets[i] = UInt32(entries.count)
                entries.append(contentsOf: run)
                widest = max(widest, run.count)
            }
            offsets[count] = UInt32(entries.count)
            self.offsets = offsets
            self.entries = entries
            entryCount = entries.count
            maxEntriesPerParticle = widest
            meanEntriesPerParticle = count > 0 ? Float(entries.count) / Float(count) : 0
            restLengthRange = shortest <= longest ? shortest ... longest : 0 ... 0
        }
    }

    // MARK: - The hull planes

    /// One of the skin's hulls as the solve kernel collides with it: the
    /// planes of the convex hull of the sidecar's 32 to 48 points, in the
    /// joint's frame, and the points' box in that frame, inflated by the
    /// vertex radius, which a particle tests before entering the planes
    /// (the design's bounding sphere culled eight of the eleven hulls but
    /// a torso hull's sphere held most of the shirt; the box culls every
    /// particle more than 3 mm off the hull's extent, 2026-11-03). A
    /// particle is inside iff every signed distance is below the vertex
    /// radius, and is pushed out along the plane of the largest signed
    /// distance — the most-facing plane, as Jolt's `ConvexHullShape::
    /// CollideSoftBodyVertices` picks it. The planes are found by brute
    /// force once at the attach: every triple's plane kept when all the
    /// points lie on one side (within a micrometre), oriented outward,
    /// deduplicated at 1e-4 in the normal and the offset — on the shirt 87,
    /// 83, 82, 88, 66, 84, 82, 66, 70, 60 and 64 planes for the pelvis, the
    /// three spine links, the neck, the two clavicles, the two upper arms
    /// and the two forearms, 832 in all, under the 2n - 4 bound of 848;
    /// about 190,000 triples times 48 tests, a few milliseconds, done in
    /// double precision as the design's judge did it. Phase 2's cook writes
    /// the planes into the sidecar and the runtime keeps this for one
    /// without them.
    public struct HullPlaneSet: Sendable {
        /// The feed joint the hull follows.
        public let joint: Int
        public let pointCount: Int
        /// n.xyz and d: inside where dot(n, p) + d < 0, joint frame.
        public let planes: [SIMD4<Float>]
        /// The bounding sphere, joint frame; the radius is inflated by the
        /// vertex radius, so a particle outside it is outside every plane by
        /// more than the radius.
        public let sphereCenter: SIMD3<Float>
        public let sphereRadius: Float
        /// The points' box in the joint frame, inflated by twice the vertex
        /// radius on every side: what the kernel tests before the planes
        /// (`ZCHullHeader`), since a torso hull's sphere holds most of the
        /// shirt and its box only the particles within 6 mm of the hull's
        /// extent along the joint's axes. Two radii, not one, because the
        /// plane test — inside iff every plane reads under the radius —
        /// reaches past the hull near an edge (r x sqrt 2 at a right
        /// angle), and the box must not cut off what the planes would push.
        public let boundsMin: SIMD3<Float>
        public let boundsMax: SIMD3<Float>

        public var planeCount: Int { planes.count }

        /// Nil for fewer than four points or points with no volume.
        init?(points: [SIMD3<Float>], joint: Int, vertexRadius: Float) {
            guard points.count >= 4 else { return nil }
            let p = points.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
            let n = p.count
            var found: [SIMD4<Double>] = []
            for i in 0 ..< n - 2 {
                for j in i + 1 ..< n - 1 {
                    for k in j + 1 ..< n {
                        var normal = simd_cross(p[j] - p[i], p[k] - p[i])
                        let length = simd_length(normal)
                        if length < 1e-12 { continue }
                        normal /= length
                        var low = Double.greatestFiniteMagnitude, high = -Double.greatestFiniteMagnitude
                        for q in p {
                            let s = simd_dot(q - p[i], normal)
                            low = min(low, s)
                            high = max(high, s)
                        }
                        if high <= 1e-6 {
                            // Every point behind: outward already.
                        } else if low >= -1e-6 {
                            normal = -normal
                        } else {
                            continue
                        }
                        let d = -simd_dot(normal, p[i])
                        let candidate = SIMD4(normal, d)
                        var duplicate = false
                        for q in found where abs(q.x - candidate.x) <= 1e-4 && abs(q.y - candidate.y) <= 1e-4 && abs(q.z - candidate.z) <= 1e-4 && abs(q.w - candidate.w) <= 1e-4 {
                            duplicate = true
                            break
                        }
                        if !duplicate { found.append(candidate) }
                    }
                }
            }
            guard !found.isEmpty else { return nil }
            self.joint = joint
            pointCount = n
            planes = found.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), Float($0.w)) }
            var center = SIMD3<Double>.zero
            for q in p { center += q }
            center /= Double(n)
            var radius = 0.0
            for q in p { radius = max(radius, simd_distance(q, center)) }
            sphereCenter = SIMD3(Float(center.x), Float(center.y), Float(center.z))
            sphereRadius = Float(radius) + vertexRadius
            var low = p[0], high = p[0]
            for q in p { low = simd_min(low, q); high = simd_max(high, q) }
            boundsMin = SIMD3(Float(low.x), Float(low.y), Float(low.z)) - SIMD3(repeating: 2 * vertexRadius)
            boundsMax = SIMD3(Float(high.x), Float(high.y), Float(high.z)) + SIMD3(repeating: 2 * vertexRadius)
        }

        /// The largest signed distance of `point` (joint frame) to the
        /// planes: negative inside, by how far.
        public func signedDistance(to point: SIMD3<Float>) -> Float {
            var worst = -Float.greatestFiniteMagnitude
            for plane in planes {
                worst = max(worst, simd_dot(SIMD3(plane.x, plane.y, plane.z), point) + plane.w)
            }
            return worst
        }

        /// Whether `point` is inside every plane within `tolerance`.
        public func contains(_ point: SIMD3<Float>, tolerance: Float = 0) -> Bool {
            signedDistance(to: point) <= tolerance
        }
    }

    // MARK: - The ring state, for the tests

    /// Where the rings stand: the frames encoded so far, the slot the last
    /// one filled, its substeps and dispatches, which of the ping-pong
    /// buffers holds the positions now, whether a command buffer is in
    /// flight unread, how many command buffers were in flight after the
    /// last encode (at most two in the wait-off mode, one with the wait
    /// on), and the read-back slot the wait-off mode last took.
    public struct RingState: Sendable {
        public var encodedFrames = 0
        public var slot = 0
        public var substeps = 0
        public var dispatches = 0
        public var currentIsA = true
        public var pending = false
        public var inFlight = 0
        public var readBackSlot: Int?
    }

    // MARK: - The completed handler's record

    /// What the command buffers' completed handlers write, on Metal's
    /// thread, under a lock: the GPU's time on the last buffer to complete
    /// and the newest completed frame with its read-back slot. The frame
    /// thread reads it at `readPositions` and `stats`. A new one per
    /// `build`: frame numbers start over with the garment, and a record
    /// from the last garment's buffers would otherwise hide the new one's
    /// frames behind its count and hand the wait-off read a slot nothing
    /// has written yet.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var gpuMilliseconds: Double = 0
        private var completedFrame = -1
        private var readBackSlot: Int?

        func record(frame: Int, start: CFTimeInterval, end: CFTimeInterval, readBackSlot slot: Int?) {
            lock.lock()
            defer { lock.unlock() }
            gpuMilliseconds = max(0, end - start) * 1000
            if frame > completedFrame {
                completedFrame = frame
                readBackSlot = slot
            }
        }

        var snapshot: (gpuMilliseconds: Double, completedFrame: Int, readBackSlot: Int?) {
            lock.lock()
            defer { lock.unlock() }
            return (gpuMilliseconds, completedFrame, readBackSlot)
        }
    }

    /// A joint's world transform taken apart for the per-substep slerp:
    /// the rotation of its normalised axes, its translation and its axes'
    /// lengths (the scale, kept for the skin matrix, dropped for the hull's
    /// rigid transform). The slerp is kept over the cheaper lerp of two end
    /// targets because the end-target chord of a 30 cm bone turning 10
    /// degrees in a frame is 1.1 mm off the arc at mid-frame, and because
    /// the hulls are slerped the same way, so the skin and the hulls agree
    /// at every substep.
    private struct JointFrame {
        var rotation: simd_quatf
        var translation: SIMD3<Float>
        var scale: SIMD3<Float>
        /// What the matrix has that the rotation, translation and scale do
        /// not give back — a joint's shear, and the float rounding of the
        /// quaternion round trip — lerped between the ends, so the substep
        /// at t = 1 reproduces the fed matrix exactly and the end of the
        /// frame puts a pin where the CPU's blend of the same matrices puts
        /// it, rather than a rebuilt matrix's few hundred micrometres off.
        var residual: simd_float4x4

        init(_ m: simd_float4x4) {
            let x = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
            let y = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
            let z = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            scale = SIMD3(simd_length(x), simd_length(y), simd_length(z))
            let safe = SIMD3<Float>(max(scale.x, 1e-9), max(scale.y, 1e-9), max(scale.z, 1e-9))
            rotation = simd_normalize(simd_quatf(simd_float3x3(columns: (x / safe.x, y / safe.y, z / safe.z))))
            translation = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            residual = matrix_identity_float4x4
            residual = m - rebuilt
        }

        static func between(_ a: JointFrame, _ b: JointFrame, at t: Float) -> JointFrame {
            var out = b
            out.rotation = simd_normalize(simd_slerp(a.rotation, b.rotation, t))
            out.translation = simd_mix(a.translation, b.translation, SIMD3(repeating: t))
            out.scale = simd_mix(a.scale, b.scale, SIMD3(repeating: t))
            out.residual = a.residual + (b.residual - a.residual) * t
            return out
        }

        /// The rotation, scale and translation alone.
        private var rebuilt: simd_float4x4 {
            let r = simd_float3x3(rotation)
            return simd_float4x4(columns: (
                SIMD4(r.columns.0 * scale.x, 0), SIMD4(r.columns.1 * scale.y, 0), SIMD4(r.columns.2 * scale.z, 0), SIMD4(translation, 1)
            ))
        }

        /// With the scale and the residual: the fed matrix at either end.
        var matrix: simd_float4x4 { rebuilt + residual }

        /// Rigid: the kernel inverts it as a transpose.
        var rigidMatrix: simd_float4x4 {
            let r = simd_float3x3(rotation)
            return simd_float4x4(columns: (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(translation, 1)))
        }
    }

    /// The garment's buffers, all shared storage, allocated at `build`.
    private struct Buffers {
        let positionA: MTLBuffer
        let positionB: MTLBuffer
        let previous: MTLBuffer
        let velocity: MTLBuffer
        let rest: MTLBuffer
        let restNormal: MTLBuffer
        let influences: MTLBuffer
        let slack: MTLBuffer
        let target: MTLBuffer
        let targetNormal: MTLBuffer
        let csrOffsets: MTLBuffer
        let csrEntries: MTLBuffer
        let hullHeaders: MTLBuffer
        let hullPlanes: MTLBuffer
        let skinMatrices: MTLBuffer
        let hullWorld: MTLBuffer
        let spheres: MTLBuffer
        let stats: MTLBuffer
        let readBack: MTLBuffer
    }

    /// The shell's buffers (phase 2), allocated at `build` when the garment
    /// comes with a `ClothShellSetup`: the proxy's triangles as `uint4`,
    /// the triangle frames (filled with the bind pose's at the build, since
    /// a collapsed triangle keeps the frame the buffer holds), the bindings
    /// per slot and the output — two planar `float4` streams per slot,
    /// positions then normals, mesh space — in `outputSlots` ring slots:
    /// one with the wait on, since the read waits for the frame that wrote
    /// it, three with it off, where the read takes the last completed
    /// frame while the next is being written. At the 16k cook's 31,681
    /// triangles and the game's 32,530 slots that is 507 KB + 1.52 MB +
    /// 1.56 MB + 1.04 MB per output slot (the design's section 3 projected
    /// 476 KB + 1.43 MB at its 29,783 triangles).
    private struct ShellBuffers {
        let triangles: MTLBuffer
        let frames: MTLBuffer
        let bindings: MTLBuffer
        let output: MTLBuffer
        let slotCount: Int
        let triangleCount: Int
        let outputSlots: Int

        /// The byte size of one output slot: the positions and the normals.
        var outputSlotBytes: Int { 2 * slotCount * MemoryLayout<SIMD4<Float>>.stride }
    }

    /// What `zcShell` last wrote, per output slot: the frame it was written
    /// at and the mesh-from-world matrix it was evaluated with, so a read
    /// can tell whether the slot holds the frame it wants and in which
    /// frame of reference.
    private struct ShellRecord {
        var frame: Int
        var toMesh: simd_float4x4
    }

    /// The last feed as recorded: the joints now and at the frame's start,
    /// the slack multiplier, and the frame's delta.
    private struct Feed {
        var jointWorld: [simd_float4x4]
        var previousJointWorld: [simd_float4x4]
        var multiplier: Float
        var deltaTime: Float
        /// Whether the feed was a hard skin, so the next feed's
        /// interpolation starts from its pose rather than from the pose
        /// before the jump.
        var hardStart = false
    }

    // MARK: - Statics

    /// The platform's metallib in the kit's bundle: `ZombieCloth-<suffix>
    /// .metallib` under `Shaders`, the suffix the engine's rule
    /// (`RenderShaderLibraryPlatformResource`): `macos`, `ios` / `iossim`,
    /// `xros` / `xrossim`. Nil when the bundle lacks it (a stale checkout
    /// without the script's output).
    public static var metallibURL: URL? {
        Bundle.module.url(
            forResource: RenderShaderLibraryPlatformResource.resourceName(baseName: "ZombieCloth"),
            withExtension: "metallib", subdirectory: "Shaders"
        )
    }

    /// The kernels the metallib must expose: the three of phase 1 and the
    /// two shell kernels of phase 2, in the order the pipelines are built.
    public static let kernelNames = ["zcPredict", "zcSolve", "zcStats", "zcTriangleFrames", "zcShell"]

    /// The gathers per substep the encode runs for a configured
    /// `gpuIterations`: clamped to 1...4 as the launch argument's parser
    /// clamps it, so the report's `it=` is what the frame ran, not what a
    /// programmatic configuration asked for.
    public static func gatherCount(configured: Int) -> Int {
        min(max(configured, 1), 4)
    }

    /// The substep length at `substeps` per 10 ms frame (0.625 ms at 16).
    public static func substepLength(substeps: Int) -> Float {
        0.01 / Float(max(substeps, 1))
    }

    /// How many substeps a frame of `frameDelta` is cut into: the delta
    /// clamped to [1/240, 1/30] s as CoolCloth does, then clamp(ceil(delta
    /// / substep), 1, 32) — 16 at the headset's 10 ms, 18 at 11.1 ms, 27 at
    /// the Mac's 16.7 ms, 32 at a 30 fps hitch, 8 at 5 ms; and 8 at 10 ms
    /// with `gpuSubsteps` 8. Never a constant: the engine's contract is that
    /// a simulation follows the frame's delta.
    public static func substepCount(frameDelta: Float, substeps: Int) -> Int {
        let delta = Self.clampedFrameDelta(frameDelta)
        let needed = Int((delta / substepLength(substeps: substeps)).rounded(.up))
        return min(max(needed, 1), zcSubstepCap)
    }

    static func clampedFrameDelta(_ frameDelta: Float) -> Float {
        min(max(frameDelta.isFinite ? frameDelta : 1.0 / 60.0, 1.0 / 240.0), 1.0 / 30.0)
    }

    // MARK: - State

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let predictPipeline: MTLComputePipelineState
    private let solvePipeline: MTLComputePipelineState
    private let statsPipeline: MTLComputePipelineState
    private let triangleFramesPipeline: MTLComputePipelineState
    private let shellPipeline: MTLComputePipelineState
    private let configuration: ZombieCloth.Configuration
    private var completion = Completion()

    private var buffers: Buffers?
    /// The shell's buffers, when the garment came with a shell to evaluate
    /// on the GPU (phase 2); nil on a garment drawn as its proxy or with
    /// `gpuShell` off.
    private var shell: ShellBuffers?
    /// What each output slot holds (`ShellRecord`), by slot; nil for a slot
    /// nothing has written since the build or the last hard skin.
    private var shellRecords: [ShellRecord?] = []
    /// The frame a hard skin last invalidated the shell output at: an
    /// output written by a frame at or before it is of particles the CPU
    /// has since rewritten, and the cloth evaluates that frame's shell on
    /// the cores.
    private var shellInvalidFrame = -1
    /// The frame `readPositions` last handed the cloth — `encodedFrames
    /// - 1` with the wait on, the completed frame it took off the ring
    /// with it off — so `copyShellOutput` copies that frame's shell and
    /// not a newer one that completed between the two reads (-1 before
    /// any read; the two took their own snapshots until 2026-11-04, and
    /// the override's shell could run a frame ahead of the positions the
    /// speed sample and the runaway check read).
    private var lastReadFrame = -1
    /// Mesh space from world space for the frame being encoded — the
    /// inverse of the entity's world times the mesh's local matrix, which
    /// `ZombieCloth.beginUpdate` sets before `beginFrame` — so the shell
    /// kernels write the override's own space. Nil leaves the shell
    /// kernels out of the frame (a cloth without a shell setup never sets
    /// it).
    public var shellMeshFromWorld: simd_float4x4?
    private var count = 0
    private var jointCount = 0
    private var origin: SIMD3<Float> = .zero
    private var faces: [SIMD3<UInt32>] = []
    private var restPositions: [SIMD3<Float>] = []
    private var restNormals: [SIMD3<Float>] = []
    private var influences: [[ClothInfluence]] = []
    private var inverseMasses: [Float] = []
    private var inverseBindWorld: [simd_float4x4] = []
    private var pelvisJoint = 0
    private var garment: ClothGarmentSetup?
    /// The constraint graph and the hull planes as built, for the report
    /// and the tests.
    public private(set) var constraintGraph: ConstraintGraph?
    public private(set) var hullPlaneSets: [HullPlaneSet] = []
    /// The planes over every hull (832 on the shirt).
    public var planeCount: Int { hullPlaneSets.reduce(0) { $0 + $1.planeCount } }

    /// The world's gravity the particles fall under, m/s^2 (the setup's;
    /// a test raises it to read the on-clamp share).
    public var gravity = SIMD3<Float>(0, -9.8, 0)
    /// The floor's top, world space (`ZombieCloth.floorY`), read at every
    /// `beginFrame`.
    public var floorY: Float = 0
    /// Whether the floor plane is applied at all.
    public var floorEnabled = true

    private var lastFeed: Feed?
    private var accumulatedDelta: Float = 0
    /// Whether a feed or a hard skin arrived since the last encode: a game
    /// frame without a physics step has none, and encodes nothing.
    private var fedSinceEncode = false
    /// The frame thread's waits on command buffers outside the read — a
    /// hard skin's wait for anything in flight, the ring's slot waits at
    /// the encode — folded into the frame's `wait=`.
    private var waitAccumulator: Double = 0
    private var active = true
    private var restLayer: ClothRestLayer?
    /// The positions now: A or B of the ping-pong pair.
    private var currentIsA = true
    private var encodedFrames = 0
    private var ring = RingState()
    /// The command buffers committed and not yet known complete, oldest
    /// first, each with its frame and its ring slot.
    private var inFlight: [(frame: Int, slot: Int, buffer: MTLCommandBuffer)] = []
    /// The frame's own buffer, until the first read waited for it.
    private var pendingFrame: (frame: Int, slot: Int, buffer: MTLCommandBuffer)?
    /// The frame a hard skin last wrote the buffers at: a read-back slot
    /// older than it is stale.
    private var hardSkinFrame = -1
    private var frameStats = ClothSolverStats()
    private var lastStats: ZCStats?
    /// The skin matrices of the last encode, per substep then joint,
    /// garment frame, for the tests (the targets interpolate).
    public private(set) var lastSkinMatrices: [[simd_float4x4]] = []
    private var lastSubstepLength: Float = 0
    /// Dispatches over the solver's life (constant while it sleeps).
    public private(set) var totalDispatches = 0

    // MARK: - Init

    /// Loads the platform's metallib from the kit's bundle and builds the
    /// five pipelines on `device` (the three of phase 1 and the two shell
    /// kernels of phase 2, so a metallib from before the shell is a stale
    /// one); nil, and one printed line, when the file, a kernel or a
    /// pipeline is missing, so a stale or absent metallib is loud and the
    /// cloth falls back to Jolt rather than drawing nothing.
    /// `configuration` is read for the GPU arm's knobs (`gpuSubsteps`,
    /// `gpuIterations`, `gpuRelaxation`, `gpuAveragedJacobi`,
    /// `gpuDamping`, `gpuHullFriction`, `gpuWait`, `gpuShell`) and the
    /// material the Jolt arm shares.
    public init?(device: MTLDevice, configuration: ZombieCloth.Configuration) {
        self.device = device
        self.configuration = configuration
        guard let url = Self.metallibURL else {
            print("CoolZombie: cloth: the GPU solver has no \(RenderShaderLibraryPlatformResource.resourceName(baseName: "ZombieCloth")).metallib in the bundle (run Scripts/build-cloth-metallib.sh); Jolt stands in")
            return nil
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(URL: url)
        } catch {
            print("CoolZombie: cloth: the GPU solver's metallib \(url.lastPathComponent) did not load — \(error); Jolt stands in")
            return nil
        }
        var pipelines: [MTLComputePipelineState] = []
        for name in Self.kernelNames {
            guard let function = library.makeFunction(name: name) else {
                print("CoolZombie: cloth: the GPU solver's metallib \(url.lastPathComponent) lacks \(name) (a stale build; run Scripts/build-cloth-metallib.sh); Jolt stands in")
                return nil
            }
            do {
                pipelines.append(try device.makeComputePipelineState(function: function))
            } catch {
                print("CoolZombie: cloth: the GPU solver's \(name) pipeline failed — \(error); Jolt stands in")
                return nil
            }
        }
        guard let queue = device.makeCommandQueue() else {
            print("CoolZombie: cloth: the GPU solver got no command queue from \(device.name); Jolt stands in")
            return nil
        }
        queue.label = "CoolZombie cloth"
        self.queue = queue
        predictPipeline = pipelines[0]
        solvePipeline = pipelines[1]
        statsPipeline = pipelines[2]
        triangleFramesPipeline = pipelines[3]
        shellPipeline = pipelines[4]
    }

    // MARK: - ClothSolver

    public var particleCount: Int { count }
    public var hullCount: Int { hullPlaneSets.count }
    public var isActive: Bool { active && buffers != nil }

    /// The garment into the buffers at the bind pose: the constraint graph
    /// from the faces, the rest normals (area-weighted over each particle's
    /// rest faces, rotated per substep into the back-stop normal), the
    /// influences, the slack and the back-stop per particle, the hulls as
    /// plane sets with their headers, and the rings sized by the substep
    /// cap; and, when the garment comes with a shell (`ClothGarmentSetup.
    /// shell`, phase 2), the shell's buffers — the triangles, the frames at
    /// the bind pose (mesh space, through the setup's `meshFromWorld`,
    /// the CPU's own `RenderShell.frames` arithmetic, so a triangle that
    /// collapses on a later frame keeps a frame that exists), the bindings
    /// and the ringed output. Positions start at the bind pose with the
    /// inverse mass in w and no velocity; the first feed is always hard
    /// (the cloth's attach calls `hardSkin` before anything steps), so the
    /// particles are never solved from the bind pose. False, and nothing
    /// kept, when a buffer cannot be made or a shell binding names a
    /// triangle the faces lack; a hull with fewer than four points or no
    /// volume is skipped and `hullCount` says how many stand.
    public func build(_ garment: ClothGarmentSetup, hulls: [ClothHullSetup]) -> Bool {
        destroy()
        let n = garment.bindPositions.count
        guard n > 0, garment.influences.count == n, garment.maxDistance.count == n, garment.backstop.count == n, garment.inverseMasses.count == n,
              !garment.bindJointWorld.isEmpty
        else { return false }
        let graph = ConstraintGraph(faces: garment.faces, positions: garment.bindPositions, inverseMasses: garment.inverseMasses, maxDistance: garment.maxDistance)
        let planeSets = hulls.compactMap { HullPlaneSet(points: $0.points, joint: $0.joint, vertexRadius: garment.vertexRadius) }
        let joints = garment.bindJointWorld.count
        let hullCount = planeSets.count

        func makeBuffer(bytes: Int, label: String) -> MTLBuffer? {
            let buffer = device.makeBuffer(length: max(bytes, 16), options: .storageModeShared)
            buffer?.label = "cloth \(garment.name) \(label)"
            return buffer
        }
        let float4 = MemoryLayout<SIMD4<Float>>.stride
        let matrix = MemoryLayout<simd_float4x4>.stride
        let planeTotal = planeSets.reduce(0) { $0 + $1.planeCount }
        guard let positionA = makeBuffer(bytes: n * float4, label: "positions A"),
              let positionB = makeBuffer(bytes: n * float4, label: "positions B"),
              let previous = makeBuffer(bytes: n * float4, label: "previous"),
              let velocity = makeBuffer(bytes: n * float4, label: "velocity"),
              let rest = makeBuffer(bytes: n * float4, label: "rest"),
              let restNormal = makeBuffer(bytes: n * float4, label: "rest normals"),
              let influenceBuffer = makeBuffer(bytes: n * MemoryLayout<ZCInfluence>.stride, label: "influences"),
              let slack = makeBuffer(bytes: n * MemoryLayout<SIMD2<Float>>.stride, label: "slack"),
              let target = makeBuffer(bytes: n * float4, label: "targets"),
              let targetNormal = makeBuffer(bytes: n * float4, label: "target normals"),
              let csrOffsets = makeBuffer(bytes: (n + 1) * MemoryLayout<UInt32>.stride, label: "csr offsets"),
              let csrEntries = makeBuffer(bytes: graph.entryCount * MemoryLayout<ZCEntry>.stride, label: "csr entries"),
              let hullHeaders = makeBuffer(bytes: hullCount * MemoryLayout<ZCHullHeader>.stride, label: "hull headers"),
              let hullPlanes = makeBuffer(bytes: planeTotal * float4, label: "hull planes"),
              let skinMatrices = makeBuffer(bytes: zcRingSlots * zcSubstepCap * joints * matrix, label: "skin matrices"),
              let hullWorld = makeBuffer(bytes: zcRingSlots * (zcSubstepCap + 1) * hullCount * matrix, label: "hull transforms"),
              let spheres = makeBuffer(bytes: zcRingSlots * zcSphereCapacity * MemoryLayout<ZCSphere>.stride, label: "spheres"),
              let stats = makeBuffer(bytes: zcRingSlots * Self.statsSlotStride, label: "stats"),
              let readBack = makeBuffer(bytes: zcReadBackRingSlots * n * float4, label: "read-back")
        else {
            print("CoolZombie: cloth \(garment.name): the GPU solver could not allocate its buffers on \(device.name)")
            return false
        }
        var shellBuffers: ShellBuffers?
        if let setup = garment.shell {
            let slots = setup.slotCount
            let triangleCount = garment.faces.count
            guard slots > 0, setup.barycentric.count == slots, setup.offset.count == slots, setup.normal.count == slots,
                  setup.triangle.allSatisfy({ Int($0) < triangleCount })
            else {
                print("CoolZombie: cloth \(garment.name): the shell binding disagrees with the faces (\(slots) slots over \(triangleCount) triangles); the GPU solver refused it")
                return false
            }
            let outputSlots = configuration.gpuWait ? 1 : zcReadBackRingSlots
            guard let triangles = makeBuffer(bytes: triangleCount * MemoryLayout<SIMD4<UInt32>>.stride, label: "shell triangles"),
                  let frames = makeBuffer(bytes: triangleCount * MemoryLayout<ZCTriangleFrame>.stride, label: "shell triangle frames"),
                  let bindings = makeBuffer(bytes: slots * MemoryLayout<ZCShellBinding>.stride, label: "shell bindings"),
                  let output = makeBuffer(bytes: outputSlots * 2 * slots * float4, label: "shell output")
            else {
                print("CoolZombie: cloth \(garment.name): the GPU solver could not allocate the shell's buffers on \(device.name)")
                return false
            }
            let trianglePointer = triangles.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: triangleCount)
            for (t, face) in garment.faces.enumerated() { trianglePointer[t] = SIMD4(face.x, face.y, face.z, 0) }
            let bindingPointer = bindings.contents().bindMemory(to: ZCShellBinding.self, capacity: slots)
            for s in 0 ..< slots {
                bindingPointer[s] = ZCShellBinding(triangle: Int(setup.triangle[s]), barycentric: setup.barycentric[s], offset: setup.offset[s], normal: setup.normal[s])
            }
            // The bind pose's frames, mesh space, as the CPU shell computes
            // its rest frames: the particles through the attach's matrix.
            let meshBind = garment.bindPositions.map { p -> SIMD3<Float> in
                let m = setup.meshFromWorld * SIMD4(p + garment.origin, 1)
                return SIMD3(m.x, m.y, m.z)
            }
            let framePointer = frames.contents().bindMemory(to: ZCTriangleFrame.self, capacity: triangleCount)
            for (t, face) in garment.faces.enumerated() {
                framePointer[t] = ZCTriangleFrame()
                let a = meshBind[Int(face.x)], b = meshBind[Int(face.y)], c = meshBind[Int(face.z)]
                let ab = b - a
                let cross = simd_cross(ab, c - a)
                let lab = simd_length(ab), lcross = simd_length(cross)
                guard lab > 1e-9, lcross > 1e-12 else { continue }
                let e1 = ab / lab, n = cross / lcross
                framePointer[t] = ZCTriangleFrame(e1: e1, n: n, t: simd_cross(n, e1))
            }
            memset(output.contents(), 0, outputSlots * 2 * slots * float4)
            shellBuffers = ShellBuffers(triangles: triangles, frames: frames, bindings: bindings, output: output, slotCount: slots, triangleCount: triangleCount, outputSlots: outputSlots)
        }
        let built = Buffers(
            positionA: positionA, positionB: positionB, previous: previous, velocity: velocity, rest: rest, restNormal: restNormal,
            influences: influenceBuffer, slack: slack, target: target, targetNormal: targetNormal, csrOffsets: csrOffsets, csrEntries: csrEntries,
            hullHeaders: hullHeaders, hullPlanes: hullPlanes, skinMatrices: skinMatrices, hullWorld: hullWorld, spheres: spheres, stats: stats,
            readBack: readBack
        )

        // The static arrays.
        let normals = Self.areaWeightedNormals(faces: garment.faces, positions: garment.bindPositions)
        let positions = positionA.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let positionsB = positionB.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let previousPointer = previous.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let velocityPointer = velocity.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let restPointer = rest.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let restNormalPointer = restNormal.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let targetPointer = target.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let targetNormalPointer = targetNormal.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let influencePointer = influenceBuffer.contents().bindMemory(to: ZCInfluence.self, capacity: n)
        let slackPointer = slack.contents().bindMemory(to: SIMD2<Float>.self, capacity: n)
        for i in 0 ..< n {
            let w = garment.inverseMasses[i]
            let p = SIMD4(garment.bindPositions[i], w)
            positions[i] = p
            positionsB[i] = p
            previousPointer[i] = SIMD4(garment.bindPositions[i], 0)
            velocityPointer[i] = .zero
            restPointer[i] = SIMD4(garment.bindPositions[i], 0)
            restNormalPointer[i] = SIMD4(normals[i], 0)
            targetPointer[i] = SIMD4(garment.bindPositions[i], 0)
            targetNormalPointer[i] = SIMD4(normals[i], 0)
            var joints4 = SIMD4<UInt16>(repeating: 0)
            var weights4 = SIMD4<Float>(repeating: 0)
            for (k, influence) in garment.influences[i].prefix(zcMaxInfluences).enumerated() {
                joints4[k] = UInt16(clamping: influence.joint)
                weights4[k] = influence.weight
            }
            influencePointer[i] = ZCInfluence(joints: joints4, weights: weights4)
            let backstop = garment.bodyFacing.contains(i) || garment.backstop[i] == .greatestFiniteMagnitude ? Float.infinity : garment.backstop[i]
            slackPointer[i] = SIMD2(garment.maxDistance[i], backstop)
        }
        graph.offsets.withUnsafeBytes { csrOffsets.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if graph.entryCount > 0 {
            graph.entries.withUnsafeBytes { csrEntries.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        if hullCount > 0 {
            let headers = hullHeaders.contents().bindMemory(to: ZCHullHeader.self, capacity: hullCount)
            let planes = hullPlanes.contents().bindMemory(to: SIMD4<Float>.self, capacity: max(planeTotal, 1))
            var first = 0
            for (h, set) in planeSets.enumerated() {
                var header = ZCHullHeader()
                header.range = SIMD4(UInt32(first), UInt32(set.planeCount), UInt32(set.joint), 0)
                header.boundsMin = SIMD4(set.boundsMin, 0)
                header.boundsMax = SIMD4(set.boundsMax, 0)
                headers[h] = header
                for (k, plane) in set.planes.enumerated() { planes[first + k] = plane }
                first += set.planeCount
            }
        }
        // The hull transforms start at the hulls' build pose, every slot
        // and substep, so a frame that reads the previous substep's at k = 0
        // before any feed finds a transform, not zeros.
        let transforms = hullWorld.contents().bindMemory(to: simd_float4x4.self, capacity: max(zcRingSlots * (zcSubstepCap + 1) * hullCount, 1))
        let toGarment = Self.translation(-garment.origin)
        for (h, set) in planeSets.enumerated() {
            let world = toGarment * (hulls.first { $0.joint == set.joint }?.world ?? matrix_identity_float4x4)
            for slot in 0 ..< zcRingSlots {
                for k in 0 ... zcSubstepCap {
                    transforms[(slot * (zcSubstepCap + 1) + k) * hullCount + h] = world
                }
            }
        }
        memset(stats.contents(), 0, zcRingSlots * Self.statsSlotStride)

        buffers = built
        shell = shellBuffers
        shellRecords = Array(repeating: nil, count: shellBuffers?.outputSlots ?? 0)
        shellInvalidFrame = -1
        lastReadFrame = -1
        count = n
        jointCount = joints
        origin = garment.origin
        faces = garment.faces
        restPositions = garment.bindPositions
        restNormals = normals
        influences = garment.influences
        inverseMasses = garment.inverseMasses
        inverseBindWorld = garment.bindJointWorld.map(\.inverse)
        pelvisJoint = min(max(garment.pelvisJoint, 0), joints - 1)
        gravity = garment.gravity
        self.garment = garment
        constraintGraph = graph
        hullPlaneSets = planeSets
        currentIsA = true
        active = true
        restLayer = nil
        lastFeed = nil
        accumulatedDelta = 0
        fedSinceEncode = false
        waitAccumulator = 0
        completion = Completion()
        encodedFrames = 0
        ring = RingState()
        hardSkinFrame = -1
        frameStats = ClothSolverStats()
        lastStats = nil
        lastSkinMatrices = []
        totalDispatches = 0
        return true
    }

    /// Waits for anything in flight (a buffer that completes after its
    /// buffers are freed would scribble freed memory) and drops everything
    /// `build` made.
    public func destroy() {
        waitForAll()
        buffers = nil
        shell = nil
        shellRecords = []
        count = 0
        jointCount = 0
        constraintGraph = nil
        hullPlaneSets = []
        garment = nil
        lastFeed = nil
        pendingFrame = nil
        inFlight = []
        active = false
    }

    /// The frame recorded, nothing encoded: the joints now and before, the
    /// multiplier, the delta added to the frame's (a long frame reaches
    /// the cloth as several `willStep` calls on one pose, and the one
    /// encode at `beginFrame` takes their sum; the previous and the current
    /// joints are then identical and the per-substep interpolation is a
    /// no-op, so nothing jumps). A hard feed is a hard skin onto the feed's
    /// pose, now, on the CPU — the step's pose may already differ from the
    /// one `hardSkin` placed. The first soft feed after a hard skin
    /// interpolates from the hard-skinned pose, whatever previous pose the
    /// feed carries: the cloth's snapshot normally holds that pose already,
    /// but a step in the frame the attach hard skinned carries the pose
    /// before it, and a sweep from there would be the jump the hard skin
    /// was meant to replace. A feed wakes a resting solver, as it wakes
    /// Jolt's body.
    public func feed(_ feed: ClothFeed) {
        guard buffers != nil, feed.jointWorld.count == jointCount, feed.previousJointWorld.count == jointCount else { return }
        if feed.hard {
            hardSkin(feed)
            return
        }
        let previous: [simd_float4x4]
        if let last = lastFeed {
            previous = last.hardStart ? last.jointWorld : feed.previousJointWorld
        } else {
            previous = feed.jointWorld
        }
        lastFeed = Feed(jointWorld: feed.jointWorld, previousJointWorld: previous, multiplier: feed.multiplier, deltaTime: feed.deltaTime)
        accumulatedDelta += max(feed.deltaTime, 0)
        fedSinceEncode = true
        active = true
    }

    /// Every particle onto its skinned position at rest, on the CPU: the
    /// solver waits for anything in flight, skins the particles with the
    /// blend the kernel does (about 40 us for 3,995) and writes the
    /// position, previous and velocity buffers directly, since they are
    /// shared storage — Jolt's `SkinVertices(hard)`, without a command
    /// buffer. The targets and their normals are written too, so a frame
    /// that reads them before any substep (the stats of a sleeping shirt)
    /// finds this pose. The next frame interpolates from this pose: a
    /// re-seat is a jump, not a motion to slerp across. The wait for a
    /// buffer in flight (a re-seat or a runaway while the frame's buffer
    /// runs) counts in the frame's `wait=`.
    public func hardSkin(_ feed: ClothFeed) {
        guard let buffers, count > 0, feed.jointWorld.count == jointCount else { return }
        let waitStarted = CACurrentMediaTime()
        waitForAll()
        waitAccumulator += (CACurrentMediaTime() - waitStarted) * 1e6
        let skin = skinMatrices(for: feed.jointWorld)
        let positions = currentPositions(buffers)
        let other = (currentIsA ? buffers.positionB : buffers.positionA).contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let previous = buffers.previous.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let velocity = buffers.velocity.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let target = buffers.target.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let targetNormal = buffers.targetNormal.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        for i in 0 ..< count {
            let (p, n) = skinnedTarget(particle: i, skin: skin)
            let w = inverseMasses[i]
            positions[i] = SIMD4(p, w)
            other[i] = SIMD4(p, w)
            previous[i] = SIMD4(p, 0)
            velocity[i] = .zero
            target[i] = SIMD4(p, 0)
            targetNormal[i] = SIMD4(n, 0)
        }
        var recorded = Feed(jointWorld: feed.jointWorld, previousJointWorld: feed.jointWorld, multiplier: feed.multiplier, deltaTime: feed.deltaTime)
        recorded.hardStart = true
        lastFeed = recorded
        accumulatedDelta = 0
        hardSkinFrame = encodedFrames
        // The shell output, if any, is of particles that no longer stand
        // there: the cloth evaluates this frame's shell on the cores.
        shellInvalidFrame = encodedFrames
        pendingFrame = nil
        fedSinceEncode = true
        active = true
    }

    /// The frame's work, encoded and committed in one command buffer on the
    /// solver's queue: the substeps from the frame's delta, each a predict
    /// and `gpuIterations` gathers, the stats last; the ring slot filled
    /// first with the slerped skin matrices per substep, the hulls' rigid
    /// transforms per substep plus the frame's start, this frame's balls
    /// and the stats slot. Resting it encodes nothing — unless a ball's
    /// swept sphere (its centre backed along its velocity over the frame,
    /// inflated by its radius and the vertex radius) meets the particles'
    /// bounds from the last stats, which wakes the solver as a ball woke
    /// Jolt's resting body; the frame then runs on the last feed, with the
    /// joints where they stood from substep 0 (not swept once more over
    /// the sub-threshold motion of the frame it fell asleep on). Out of
    /// range (the inert layer) nothing wakes it. Awake, a frame with no
    /// feed since the last encode — a game frame without a physics step,
    /// two in five at 100 Hz under the engine's fixed stepping, a frame
    /// under 1/250 s under the hosts' per-frame stepping — encodes nothing
    /// either: the shirt stands on the last frame's positions as the Jolt
    /// arm does on a step-less frame, where an encode would simulate the
    /// last feed's delta twice and replay its joint motion from the pose
    /// before it. The completed handler records the GPU's start-to-end
    /// stamps, which work in release where the engine's frame stats do
    /// not, and the read-back slot the wait-off mode blitted to.
    public func beginFrame(spheres: [ClothSphere]) {
        guard let buffers, count > 0, var feed = lastFeed, feed.jointWorld.count == jointCount, feed.previousJointWorld.count == jointCount else {
            frameStats = ClothSolverStats()
            frameStats.lagFrames = configuration.gpuWait ? 0 : 1
            return
        }
        let started = CACurrentMediaTime()
        let frameDelta = Self.clampedFrameDelta(accumulatedDelta > 0 ? accumulatedDelta : feed.deltaTime)
        func standStill() {
            frameStats.dispatches = 0
            frameStats.substeps = 0
            frameStats.feedMicroseconds = 0
            frameStats.waitMicroseconds = waitAccumulator
            waitAccumulator = 0
        }
        if !active {
            standStill()
            guard case .resting = restLayer, sweptSphereMeetsBounds(spheres, delta: frameDelta) else { return }
            active = true
            feed.previousJointWorld = feed.jointWorld
            lastFeed = feed
        } else if !fedSinceEncode {
            standStill()
            return
        }
        // The frame's slot, free: the buffer that used it four frames ago
        // must be done, which it is unless the CPU ran four frames ahead
        // of the GPU in the wait-off mode. In that mode the three-slot
        // read-back ring and the four-slot stats ring are read with no
        // fence, so at most two frames may stay in flight behind this one:
        // the newest completed frame's read-back slot ((F-3) % 3 is F % 3)
        // and stats slot ((F-4) % 4 is F % 4) are then never a buffer's
        // write target while the CPU reads them. A wait here counts in
        // `wait=`, not in `feed=`.
        let frame = encodedFrames
        let slot = frame % zcRingSlots
        let waitStarted = CACurrentMediaTime()
        for entry in inFlight where entry.slot == slot { entry.buffer.waitUntilCompleted() }
        if !configuration.gpuWait {
            for entry in inFlight where entry.frame <= frame - (zcReadBackRingSlots - 1) { entry.buffer.waitUntilCompleted() }
        }
        let slotWait = (CACurrentMediaTime() - waitStarted) * 1e6
        waitAccumulator += slotWait
        inFlight.removeAll { $0.buffer.status == .completed || $0.buffer.status == .error }

        let substeps = Self.substepCount(frameDelta: frameDelta, substeps: configuration.gpuSubsteps)
        let dt = frameDelta / Float(substeps)
        let iterations = Self.gatherCount(configured: configuration.gpuIterations)
        lastSubstepLength = dt

        // The joints and the hulls per substep into the slot.
        let toGarment = Self.translation(-origin)
        let fromGarment = Self.translation(origin)
        let before = feed.previousJointWorld.map { JointFrame($0) }
        let now = feed.jointWorld.map { JointFrame($0) }
        let hullCount = hullPlaneSets.count
        let skinPointer = buffers.skinMatrices.contents().bindMemory(to: simd_float4x4.self, capacity: zcRingSlots * zcSubstepCap * jointCount)
        let hullPointer = buffers.hullWorld.contents().bindMemory(to: simd_float4x4.self, capacity: max(zcRingSlots * (zcSubstepCap + 1) * hullCount, 1))
        var recorded: [[simd_float4x4]] = []
        recorded.reserveCapacity(substeps)
        let hullBase = slot * (zcSubstepCap + 1) * hullCount
        for (h, set) in hullPlaneSets.enumerated() where set.joint < before.count {
            hullPointer[hullBase + h] = toGarment * before[set.joint].rigidMatrix
        }
        for k in 0 ..< substeps {
            let t = Float(k + 1) / Float(substeps)
            var frames: [JointFrame] = []
            frames.reserveCapacity(jointCount)
            var matrices: [simd_float4x4] = []
            matrices.reserveCapacity(jointCount)
            for j in 0 ..< jointCount {
                let frameJ = JointFrame.between(before[j], now[j], at: t)
                frames.append(frameJ)
                let skin = toGarment * frameJ.matrix * inverseBindWorld[j] * fromGarment
                matrices.append(skin)
                skinPointer[(slot * zcSubstepCap + k) * jointCount + j] = skin
            }
            recorded.append(matrices)
            for (h, set) in hullPlaneSets.enumerated() where set.joint < frames.count {
                hullPointer[hullBase + (k + 1) * hullCount + h] = toGarment * frames[set.joint].rigidMatrix
            }
        }
        lastSkinMatrices = recorded
        let spherePointer = buffers.spheres.contents().bindMemory(to: ZCSphere.self, capacity: zcRingSlots * zcSphereCapacity)
        let sphereCount = min(spheres.count, zcSphereCapacity)
        for s in 0 ..< sphereCount {
            spherePointer[slot * zcSphereCapacity + s] = ZCSphere(spheres[s], origin: origin)
        }

        // The params the frame shares; the dispatch changes the substep and
        // the ring bases.
        var params = ZCParams()
        params.gravityDt = SIMD4(gravity, dt)
        params.compliance = SIMD4(garment?.stretchCompliance ?? configuration.stretchCompliance, garment?.shearCompliance ?? configuration.shearCompliance,
                                  garment?.bendCompliance ?? configuration.bendCompliance, max(configuration.gpuRelaxation, 0))
        let damping = configuration.gpuDamping ?? garment?.linearDamping ?? configuration.linearDamping
        params.material = SIMD4(damping, garment?.maxLinearVelocity ?? configuration.maxLinearVelocity, garment?.vertexRadius ?? configuration.vertexRadius,
                                min(max(configuration.gpuHullFriction, 0), 1))
        params.floor = SIMD4(floorY - origin.y, 0.4, feed.multiplier, frameDelta)
        let pelvis = now[pelvisJoint].translation - origin
        params.pelvis = SIMD4(pelvis, configuration.runawayDistance)
        params.counts = SIMD4(UInt32(count), UInt32(jointCount), UInt32(hullCount), UInt32(sphereCount))
        params.flags = SIMD4(configuration.gpuAveragedJacobi ? 1 : 0, floorEnabled ? 1 : 0, configuration.gpuHullFriction > 0 ? 1 : 0, 0)

        guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            print("CoolZombie: cloth: the GPU solver got no command buffer; the frame is skipped")
            return
        }
        commandBuffer.label = "cloth frame \(frame)"
        encoder.label = "cloth substeps"
        encoder.setBuffer(buffers.previous, offset: 0, index: ZCBufferIndex.previous.rawValue)
        encoder.setBuffer(buffers.velocity, offset: 0, index: ZCBufferIndex.velocity.rawValue)
        encoder.setBuffer(buffers.rest, offset: 0, index: ZCBufferIndex.rest.rawValue)
        encoder.setBuffer(buffers.restNormal, offset: 0, index: ZCBufferIndex.restNormal.rawValue)
        encoder.setBuffer(buffers.influences, offset: 0, index: ZCBufferIndex.influences.rawValue)
        encoder.setBuffer(buffers.slack, offset: 0, index: ZCBufferIndex.slack.rawValue)
        encoder.setBuffer(buffers.target, offset: 0, index: ZCBufferIndex.target.rawValue)
        encoder.setBuffer(buffers.targetNormal, offset: 0, index: ZCBufferIndex.targetNormal.rawValue)
        encoder.setBuffer(buffers.skinMatrices, offset: 0, index: ZCBufferIndex.skinMatrices.rawValue)
        encoder.setBuffer(buffers.csrOffsets, offset: 0, index: ZCBufferIndex.csrOffsets.rawValue)
        encoder.setBuffer(buffers.csrEntries, offset: 0, index: ZCBufferIndex.csrEntries.rawValue)
        encoder.setBuffer(buffers.hullHeaders, offset: 0, index: ZCBufferIndex.hullHeaders.rawValue)
        encoder.setBuffer(buffers.hullPlanes, offset: 0, index: ZCBufferIndex.hullPlanes.rawValue)
        encoder.setBuffer(buffers.hullWorld, offset: 0, index: ZCBufferIndex.hullWorld.rawValue)
        encoder.setBuffer(buffers.spheres, offset: 0, index: ZCBufferIndex.spheres.rawValue)
        encoder.setBuffer(buffers.stats, offset: slot * Self.statsSlotStride, index: ZCBufferIndex.stats.rawValue)

        let grid = MTLSize(width: count, height: 1, depth: 1)
        let group = MTLSize(width: min(zcThreadgroupSize, predictPipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        var dispatches = 0
        func bindPositions() {
            encoder.setBuffer(currentIsA ? buffers.positionA : buffers.positionB, offset: 0, index: ZCBufferIndex.positionIn.rawValue)
            encoder.setBuffer(currentIsA ? buffers.positionB : buffers.positionA, offset: 0, index: ZCBufferIndex.positionOut.rawValue)
        }
        for k in 0 ..< substeps {
            let skinBase = UInt32((slot * zcSubstepCap + k) * jointCount)
            let hullNow = UInt32(hullBase + (k + 1) * hullCount)
            params.rings = SIMD4(skinBase, hullNow, hullNow - UInt32(hullCount), UInt32(slot * zcSphereCapacity))
            params.substep = SIMD4(UInt32(k), UInt32(substeps), 0, UInt32(iterations))
            encoder.setComputePipelineState(predictPipeline)
            encoder.setBytes(&params, length: MemoryLayout<ZCParams>.stride, index: ZCBufferIndex.params.rawValue)
            bindPositions()
            encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
            currentIsA.toggle()
            dispatches += 1
            for it in 0 ..< iterations {
                params.substep.z = UInt32(it)
                encoder.setComputePipelineState(solvePipeline)
                encoder.setBytes(&params, length: MemoryLayout<ZCParams>.stride, index: ZCBufferIndex.params.rawValue)
                bindPositions()
                encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
                currentIsA.toggle()
                dispatches += 1
            }
        }
        encoder.setComputePipelineState(statsPipeline)
        encoder.setBytes(&params, length: MemoryLayout<ZCParams>.stride, index: ZCBufferIndex.params.rawValue)
        bindPositions()
        let statsThreads = min(zcStatsThreadgroupSize, statsPipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: statsThreads, height: 1, depth: 1))
        dispatches += 1
        // The shell (phase 2): the triangle frames and the slots, in mesh
        // space, off the frame's final positions (`bindPositions` left them
        // at `positionIn` for the stats), into this frame's output slot.
        let shellSlot = frame % max(shell?.outputSlots ?? 1, 1)
        if let shell, let toMesh = shellMeshFromWorld {
            var shellParams = ZCShellParams(toMesh: toMesh, origin: origin, slotCount: shell.slotCount, triangleCount: shell.triangleCount)
            encoder.setBytes(&shellParams, length: MemoryLayout<ZCShellParams>.stride, index: ZCBufferIndex.shellParams.rawValue)
            encoder.setBuffer(shell.triangles, offset: 0, index: ZCBufferIndex.triangles.rawValue)
            encoder.setBuffer(shell.frames, offset: 0, index: ZCBufferIndex.triangleFrames.rawValue)
            encoder.setBuffer(shell.bindings, offset: 0, index: ZCBufferIndex.shellBindings.rawValue)
            encoder.setBuffer(shell.output, offset: shellSlot * shell.outputSlotBytes, index: ZCBufferIndex.shellOut.rawValue)
            encoder.setComputePipelineState(triangleFramesPipeline)
            encoder.dispatchThreads(MTLSize(width: shell.triangleCount, height: 1, depth: 1), threadsPerThreadgroup: group)
            encoder.setComputePipelineState(shellPipeline)
            encoder.dispatchThreads(MTLSize(width: shell.slotCount, height: 1, depth: 1), threadsPerThreadgroup: group)
            dispatches += 2
            shellRecords[shellSlot] = ShellRecord(frame: frame, toMesh: toMesh)
        } else if shell != nil {
            shellRecords[shellSlot] = nil
        }
        encoder.endEncoding()

        var readBackSlot: Int?
        if !configuration.gpuWait, let blit = commandBuffer.makeBlitCommandEncoder() {
            let target = frame % zcReadBackRingSlots
            blit.label = "cloth read-back"
            blit.copy(from: currentIsA ? buffers.positionA : buffers.positionB, sourceOffset: 0, to: buffers.readBack,
                      destinationOffset: target * count * MemoryLayout<SIMD4<Float>>.stride, size: count * MemoryLayout<SIMD4<Float>>.stride)
            blit.endEncoding()
            readBackSlot = target
        }
        let record = completion
        let blittedSlot = readBackSlot
        commandBuffer.addCompletedHandler { cb in
            record.record(frame: frame, start: cb.gpuStartTime, end: cb.gpuEndTime, readBackSlot: blittedSlot)
        }
        commandBuffer.commit()
        inFlight.append((frame, slot, commandBuffer))
        pendingFrame = (frame, slot, commandBuffer)
        encodedFrames += 1
        accumulatedDelta = 0
        totalDispatches += dispatches
        ring.encodedFrames = encodedFrames
        ring.slot = slot
        ring.substeps = substeps
        ring.dispatches = dispatches
        ring.currentIsA = currentIsA
        ring.pending = true
        ring.inFlight = inFlight.count
        fedSinceEncode = false
        frameStats.dispatches = dispatches
        frameStats.substeps = substeps
        frameStats.waitMicroseconds = waitAccumulator
        waitAccumulator = 0
        frameStats.lagFrames = configuration.gpuWait ? 0 : 1
        frameStats.feedMicroseconds = (CACurrentMediaTime() - started) * 1e6 - slotWait
    }

    /// The particles now, world space. With the wait on: the first read of
    /// a frame waits for its command buffer (`wait=` is what it took; the
    /// game's step has run meanwhile) and reads the stats slot; later reads
    /// in the frame find it done. With the wait off: the last completed
    /// read-back slot, a frame of lag, without waiting; before any slot
    /// completed since the last hard skin, the shared buffer itself, after
    /// a wait for anything in flight, so a read is never of a buffer being
    /// written.
    public func readPositions(into positions: inout [SIMD3<Float>]) -> Int {
        guard let buffers, count > 0 else { return 0 }
        if positions.count != count { positions = Array(repeating: .zero, count: count) }
        let source: UnsafeMutablePointer<SIMD4<Float>>
        if configuration.gpuWait {
            waitForPendingFrame()
            source = currentPositions(buffers)
            lastReadFrame = encodedFrames - 1
        } else {
            let done = completion.snapshot
            if let slot = done.readBackSlot, done.completedFrame >= hardSkinFrame, done.completedFrame >= 0 {
                source = buffers.readBack.contents().advanced(by: slot * count * MemoryLayout<SIMD4<Float>>.stride).bindMemory(to: SIMD4<Float>.self, capacity: count)
                readStats(slot: done.completedFrame % zcRingSlots)
                ring.readBackSlot = slot
                frameStats.lagFrames = 1
                lastReadFrame = done.completedFrame
            } else {
                waitForAll()
                source = currentPositions(buffers)
                frameStats.lagFrames = 0
                lastReadFrame = encodedFrames - 1
            }
        }
        let origin = origin
        positions.withUnsafeMutableBufferPointer { out in
            for i in 0 ..< count {
                let p = source[i]
                out[i] = SIMD3(p.x, p.y, p.z) + origin
            }
        }
        return count
    }

    /// The positions, and the particles' normals from the faces around
    /// them (area-weighted, on the CPU: a garment drawn as its proxy has no
    /// shell to take them from; the trousers, phase 5).
    public func readPositionsAndNormals(into positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>]) -> Int {
        let read = readPositions(into: &positions)
        guard read == count else { return read }
        let computed = Self.areaWeightedNormals(faces: faces, positions: positions)
        if normals.count != count { normals = computed } else { for i in 0 ..< count { normals[i] = computed[i] } }
        return read
    }

    /// Resting (asleep or out of range) the solver encodes nothing until a
    /// feed wakes it, or — on the resting layer alone, where the balls meet
    /// the Jolt shirt — a ball's swept sphere meets the particles' bounds
    /// (`beginFrame`). Awake it simulates. The layer number itself has no
    /// body to go on here; which kind it is decides the wake.
    public func setResting(_ resting: Bool, layer: ClothRestLayer) {
        restLayer = layer
        if resting {
            active = false
        } else {
            active = true
        }
    }

    /// The frame's figures: the GPU's time on the last completed buffer
    /// (zero on a frame that encoded nothing — asleep, out of range or
    /// without a step — rather than the last buffer's time beside
    /// `sub=0`), what the frame thread waited, the lag, the dispatches and
    /// substeps, the on-clamp share and the bounds from the stats slot
    /// (world space), and the CPU's time at the frame's begin.
    public var stats: ClothSolverStats {
        var out = frameStats
        out.gpuMilliseconds = frameStats.dispatches > 0 ? completion.snapshot.gpuMilliseconds : 0
        if let last = lastStats, last.particlesReduced > 0 {
            out.onClampShare = last.onClampShare
            out.boundsMin = SIMD3(last.boundsMin.x, last.boundsMin.y, last.boundsMin.z) + origin
            out.boundsMax = SIMD3(last.boundsMax.x, last.boundsMax.y, last.boundsMax.z) + origin
        }
        return out
    }

    // MARK: - The GPU shell (phase 2)

    /// Whether the garment was built with a shell for the GPU to evaluate.
    public var hasGPUShell: Bool { shell != nil }
    /// The shell's slots (the driven exported vertices), 0 without one.
    public var shellSlotCount: Int { shell?.slotCount ?? 0 }

    /// The GPU shell's output for the frame the positions were last read
    /// for, into `positions` and `normals` from `offset` on (the garment's
    /// first override slot), mesh space of `meshFromWorld`: the design's
    /// CPU copy of 32,530 x 2 `float4` lanes into the override's SIMD3
    /// arrays, about 100-150 us, in place of a shell to evaluate. The
    /// output was written with the matrix `beginFrame` was given; when the
    /// read's differs — the game's step moved the entity between the
    /// encode and the read, or the frame encoded nothing and the entity
    /// moved since the last one — every slot is re-expressed through the
    /// change of frame (`meshFromWorld` x the inverse of the recorded
    /// matrix: a position through it, a normal through its 3x3's inverse
    /// transpose, unit again), so the shirt is drawn where the body is and
    /// never a frame of motion behind it. False, and nothing written,
    /// when there is nothing valid to copy: no shell, no frame encoded
    /// yet, a hard skin since the output was written (the particles were
    /// rewritten on the CPU), or, in the wait-off mode, no completed frame
    /// since; the cloth then evaluates the shell on the cores. With the
    /// wait on the frame's buffer is waited for here if the positions
    /// were not read first.
    @discardableResult
    public func copyShellOutput(meshFromWorld: simd_float4x4, into positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>], at offset: Int) -> Bool {
        guard let shell, buffers != nil else { return false }
        let slot: Int
        if configuration.gpuWait {
            waitForPendingFrame()
            slot = (encodedFrames - 1) % max(shell.outputSlots, 1)
            guard encodedFrames > 0, let record = shellRecords[slot], record.frame == encodedFrames - 1, record.frame >= shellInvalidFrame else { return false }
        } else {
            // The frame `readPositions` handed the cloth, not a fresh
            // snapshot: its slot is still whole (the ring is three deep and
            // `beginFrame` waits two frames back), and a record that is not
            // that frame's, or none, sends the cloth to the cores.
            let frame = lastReadFrame
            guard frame >= 0, frame >= hardSkinFrame else { return false }
            slot = frame % shell.outputSlots
            guard let record = shellRecords[slot], record.frame == frame, record.frame >= shellInvalidFrame else { return false }
        }
        guard let record = shellRecords[slot] else { return false }
        let slots = shell.slotCount
        guard offset >= 0, offset + slots <= positions.count, offset + slots <= normals.count else { return false }
        let source = shell.output.contents().advanced(by: slot * shell.outputSlotBytes).bindMemory(to: SIMD4<Float>.self, capacity: 2 * slots)
        if record.toMesh == meshFromWorld {
            positions.withUnsafeMutableBufferPointer { pos in
                normals.withUnsafeMutableBufferPointer { nor in
                    for s in 0 ..< slots {
                        let p = source[s], n = source[slots + s]
                        pos[offset + s] = SIMD3(p.x, p.y, p.z)
                        nor[offset + s] = SIMD3(n.x, n.y, n.z)
                    }
                }
            }
        } else {
            // The change of frame since the encode.
            let delta = meshFromWorld * record.toMesh.inverse
            let linear = simd_float3x3(
                SIMD3(delta.columns.0.x, delta.columns.0.y, delta.columns.0.z),
                SIMD3(delta.columns.1.x, delta.columns.1.y, delta.columns.1.z),
                SIMD3(delta.columns.2.x, delta.columns.2.y, delta.columns.2.z)
            )
            let normalMatrix = linear.inverse.transpose
            positions.withUnsafeMutableBufferPointer { pos in
                normals.withUnsafeMutableBufferPointer { nor in
                    for s in 0 ..< slots {
                        let p = delta * SIMD4(source[s].x, source[s].y, source[s].z, 1)
                        let n = normalMatrix * SIMD3(source[slots + s].x, source[slots + s].y, source[slots + s].z)
                        let length = simd_length(n)
                        pos[offset + s] = SIMD3(p.x, p.y, p.z)
                        nor[offset + s] = length > 1e-6 ? n / length : SIMD3(0, 1, 0)
                    }
                }
            }
        }
        return true
    }

    /// The GPU shell's output as arrays, mesh space of `meshFromWorld`
    /// (the tests' GPU-shell-against-CPU-shell comparison, `Docs/GPUCloth.md`
    /// section 6); nil when `copyShellOutput` has nothing valid.
    public func shellOutput(meshFromWorld: simd_float4x4) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>])? {
        guard let shell else { return nil }
        var positions = [SIMD3<Float>](repeating: .zero, count: shell.slotCount)
        var normals = [SIMD3<Float>](repeating: .zero, count: shell.slotCount)
        guard copyShellOutput(meshFromWorld: meshFromWorld, into: &positions, normals: &normals, at: 0) else { return nil }
        return (positions, normals)
    }

    // MARK: - For the tests

    /// Where the rings stand (`RingState`).
    public var ringState: RingState {
        var state = ring
        state.pending = pendingFrame != nil
        state.currentIsA = currentIsA
        return state
    }

    /// The last stats slot read, garment frame; nil before any frame
    /// completed and was read.
    var lastStatsSlot: ZCStats? { lastStats }

    /// The shared buffer holding the positions now (float4, w the inverse
    /// mass), garment frame: the tests write a NaN into it and compare
    /// bytes across sleeping frames and between two solvers. Not to be
    /// read while a frame is in flight; `readPositions` waits.
    public var currentPositionBuffer: MTLBuffer? {
        guard let buffers else { return nil }
        return currentIsA ? buffers.positionA : buffers.positionB
    }

    /// The substep length of the last encode, seconds.
    public var lastSubstepSeconds: Float { lastSubstepLength }

    /// Where the skin put `particle` at `substep` of the last encode, world
    /// space: the CPU blend of the recorded skin matrices, the kernel's
    /// target for that substep.
    public func substepTarget(particle: Int, substep: Int) -> SIMD3<Float>? {
        guard lastSkinMatrices.indices.contains(substep), particle >= 0, particle < count else { return nil }
        var p = SIMD3<Float>.zero
        let rest = SIMD4(restPositions[particle], 1)
        for influence in influences[particle].prefix(zcMaxInfluences) where Int(influence.joint) < jointCount {
            let moved = lastSkinMatrices[substep][Int(influence.joint)] * rest
            p += influence.weight * SIMD3(moved.x, moved.y, moved.z)
        }
        return p + origin
    }

    /// Waits for every command buffer in flight: the tests' bitwise reads.
    public func waitForAll() {
        for entry in inFlight { entry.buffer.waitUntilCompleted() }
        inFlight = []
        if let pending = pendingFrame {
            readStats(slot: pending.slot)
            pendingFrame = nil
        }
    }

    // MARK: - Helpers

    /// The stats ring's pitch per slot: the struct is 64 B, bound at an
    /// offset, and 256 B keeps the offset at any device's alignment for a
    /// constant or device binding.
    static let statsSlotStride = 256

    private func currentPositions(_ buffers: Buffers) -> UnsafeMutablePointer<SIMD4<Float>> {
        (currentIsA ? buffers.positionA : buffers.positionB).contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
    }

    /// The frame's buffer waited for once, the wait timed, its stats read.
    private func waitForPendingFrame() {
        guard let pending = pendingFrame else { return }
        let started = CACurrentMediaTime()
        pending.buffer.waitUntilCompleted()
        frameStats.waitMicroseconds += (CACurrentMediaTime() - started) * 1e6
        if pending.buffer.status == .error, let error = pending.buffer.error {
            print("CoolZombie: cloth: the GPU solver's frame \(pending.frame) failed — \(error)")
        }
        inFlight.removeAll { $0.frame <= pending.frame }
        readStats(slot: pending.slot)
        pendingFrame = nil
        ring.pending = false
    }

    private func readStats(slot: Int) {
        guard let buffers else { return }
        lastStats = buffers.stats.contents().advanced(by: slot * Self.statsSlotStride).bindMemory(to: ZCStats.self, capacity: 1).pointee
    }

    /// Whether any ball, swept over the frame, meets the particles' bounds:
    /// conservatively, the box of the swept sphere against the box of the
    /// last stats (inflated by the vertex radius), or of the rest pose
    /// before any stats.
    private func sweptSphereMeetsBounds(_ spheres: [ClothSphere], delta: Float) -> Bool {
        guard !spheres.isEmpty else { return false }
        var low: SIMD3<Float>, high: SIMD3<Float>
        if let last = lastStats, last.particlesReduced > 0 {
            low = SIMD3(last.boundsMin.x, last.boundsMin.y, last.boundsMin.z)
            high = SIMD3(last.boundsMax.x, last.boundsMax.y, last.boundsMax.z)
        } else {
            guard let buffers else { return false }
            let positions = currentPositions(buffers)
            low = SIMD3(repeating: .greatestFiniteMagnitude)
            high = -low
            for i in 0 ..< count {
                let p = SIMD3(positions[i].x, positions[i].y, positions[i].z)
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
        }
        let radius = garment?.vertexRadius ?? configuration.vertexRadius
        low -= SIMD3(repeating: radius)
        high += SIMD3(repeating: radius)
        for sphere in spheres {
            let end = sphere.center - origin
            let start = end - sphere.velocity * delta
            let r = SIMD3(repeating: sphere.radius)
            let sLow = simd_min(start, end) - r, sHigh = simd_max(start, end) + r
            if simd_reduce_min(high - sLow) >= 0, simd_reduce_min(sHigh - low) >= 0 { return true }
        }
        return false
    }

    /// The skin matrix per joint for `jointWorld`, world space — the joint
    /// world times the inverse bind world, the product `ZombieCloth.
    /// skinnedTargets` takes — so the CPU hard skin lands where the report
    /// and the tests compute the target, to the ulp.
    private func skinMatrices(for jointWorld: [simd_float4x4]) -> [simd_float4x4] {
        (0 ..< jointCount).map { jointWorld[$0] * inverseBindWorld[$0] }
    }

    /// The blend the predict kernel does for one particle, on the CPU:
    /// the influences' world skin matrices over the bind-pose position
    /// (world space, the rest plus the origin), the result back in the
    /// garment frame; their rotations over the rest normal, unit.
    private func skinnedTarget(particle i: Int, skin: [simd_float4x4]) -> (position: SIMD3<Float>, normal: SIMD3<Float>) {
        var p = SIMD3<Float>.zero, n = SIMD3<Float>.zero
        let bind = SIMD4(restPositions[i] + origin, 1)
        let restNormal = SIMD4(restNormals[i], 0)
        for influence in influences[i].prefix(zcMaxInfluences) where Int(influence.joint) < skin.count {
            let m = skin[Int(influence.joint)]
            let moved = m * bind
            p += influence.weight * SIMD3(moved.x, moved.y, moved.z)
            let turned = m * restNormal
            n += influence.weight * SIMD3(turned.x, turned.y, turned.z)
        }
        let length = simd_length(n)
        return (p - origin, length > 1e-9 ? n / length : restNormals[i])
    }

    /// Each particle's normal as the sum of its faces' area-weighted
    /// normals (the cross product's length is twice the area), unit; a
    /// particle on no face takes +y.
    static func areaWeightedNormals(faces: [SIMD3<UInt32>], positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var sums = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for face in faces {
            let a = Int(face.x), b = Int(face.y), c = Int(face.z)
            guard a < positions.count, b < positions.count, c < positions.count else { continue }
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            sums[a] += n
            sums[b] += n
            sums[c] += n
        }
        return sums.map { n in
            let length = simd_length(n)
            return length > 1e-12 ? n / length : SIMD3(0, 1, 0)
        }
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }
}
