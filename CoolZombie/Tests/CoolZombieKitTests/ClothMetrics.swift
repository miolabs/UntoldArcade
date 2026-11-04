//
//  ClothMetrics.swift
//  CoolZombieKitTests
//
//  How the cloth tests read the shirt against the body: the posed skin
//  (`penetration(of:)`, `skinDistances(of:)`), the surface under the shirt
//  at the bind pose (`distanceToBody`), the slack's excess and the depth
//  behind the skinned plane (`ClothHarness.excess`, `worstInward`), the
//  shell rebuilt from the particles in the test's own words, and the
//  interpolated poses the swing tests drive. Hoisted out of ZombieClothTests
//  on 2026-11-03 for the GPU solver's twin; the code is the Jolt tests' of
//  that date, moved and not changed, and the figures it prints are theirs.
//

@testable import CoolZombieKit
import simd
@testable import UntoldEngine
import XCTest

/// The metrics, as statics: the posed-skin reader and its surface, the
/// bind-pose body, the export skinned onto a pose, and the region names.
enum ClothMetrics {
    /// The closest point of a triangle to a point (Ericson, Real-Time
    /// Collision Detection 5.1.5).
    static func closestPoint(on a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, to p: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }

    static let bodyCellSize: Float = 0.01

    static func bodyCell(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32((p.x / bodyCellSize).rounded(.down)), Int32((p.y / bodyCellSize).rounded(.down)), Int32((p.z / bodyCellSize).rounded(.down)))
    }

    /// The surface under the shirt at some positions of the exported
    /// vertices — the export's own (the bind pose) or the body skinned onto
    /// a pose (`posedBody`) — binned by the centimetre cells each triangle's
    /// bounds touch.
    static func bodyCells(over positions: [SIMD3<Float>], triangles: [Int]) -> [SIMD3<Int32>: [Int]]? {
        guard let exported = ClothFixtures.exported, positions.count == exported.positions.count else { return nil }
        var cells: [SIMD3<Int32>: [Int]] = [:]
        for index in triangles {
            let tri = exported.triangles[index]
            let a = positions[Int(tri.x)], b = positions[Int(tri.y)], c = positions[Int(tri.z)]
            let low = bodyCell(simd_min(a, simd_min(b, c))), high = bodyCell(simd_max(a, simd_max(b, c)))
            for x in low.x ... high.x { for y in low.y ... high.y { for z in low.z ... high.z {
                cells[SIMD3(x, y, z), default: []].append(index)
            } } }
        }
        return cells
    }

    /// The sign the metric gives the side of the surface the export's
    /// winding calls the front: +1 when the geometric normals (the cross of
    /// the edges in the index order) point out of the body, which
    /// `testThePosedBodyReadsTheRestShirtAsOutside` holds against the proxy
    /// at rest (every particle 2 mm OUTSIDE after the prep's push-out).
    /// -1 would read an export wound the other way.
    static let bodyWindingSign: Float = 1

    /// A surface of exported triangles (`underShirtTriangles`, or the
    /// `skinTriangles`) in one pose: the exported vertices where that pose
    /// puts them, and the triangles binned over them.
    struct BodySurface {
        let positions: [SIMD3<Float>]
        let cells: [SIMD3<Int32>: [Int]]

        init?(positions: [SIMD3<Float>], triangles: [Int]?) {
            guard let triangles, let cells = ClothMetrics.bodyCells(over: positions, triangles: triangles) else { return nil }
            self.positions = positions
            self.cells = cells
        }

        /// The nearest point of the surface to a mesh-space point among the
        /// triangles binned within `reach` cells of the point's own, with the
        /// triangle it lies on; nil when nothing is binned there, or the
        /// nearest is farther than `reach` centimetres (all the cells looked
        /// at can promise).
        func nearest(to p: SIMD3<Float>, reach: Int32) -> (distance: Float, point: SIMD3<Float>, triangle: Int)? {
            guard let exported = ClothFixtures.exported else { return nil }
            let k = ClothMetrics.bodyCell(p)
            var best: (distance: Float, point: SIMD3<Float>, triangle: Int) = (.greatestFiniteMagnitude, .zero, -1)
            for dx in -reach ... reach { for dy in -reach ... reach { for dz in -reach ... reach {
                for index in cells[k &+ SIMD3<Int32>(dx, dy, dz)] ?? [] {
                    let tri = exported.triangles[index]
                    let q = ClothMetrics.closestPoint(on: positions[Int(tri.x)], positions[Int(tri.y)], positions[Int(tri.z)], to: p)
                    let d = simd_distance(p, q)
                    if d < best.distance { best = (d, q, index) }
                }
            } } }
            return best.distance <= Float(reach) * ClothMetrics.bodyCellSize ? best : nil
        }

        /// How far a mesh-space point is from the surface, signed: positive
        /// outside, negative inside, the side read off the nearest
        /// triangle's geometric normal (`bodyWindingSign`); nil when no
        /// surface is within 5 cm (five cells out: an upper arm is 8 cm
        /// through and in the arms-forward idle the armhole band sank 28 mm
        /// into it before the skin colliders, so a 3 cm window clipped the
        /// depth and dropped the deepest particles from the count; the
        /// particles that hang farther than 5 cm off the skin — the hem over
        /// the culled skin under the trousers, the loose back — read
        /// nothing rather than a far surface; 2026-10-31).
        func signedDistance(to p: SIMD3<Float>) -> Float? {
            guard let exported = ClothFixtures.exported, let near = nearest(to: p, reach: 5) else { return nil }
            let tri = exported.triangles[near.triangle]
            let a = positions[Int(tri.x)], b = positions[Int(tri.y)], c = positions[Int(tri.z)]
            let outward = simd_cross(b - a, c - a) * ClothMetrics.bodyWindingSign
            return simd_dot(p - near.point, outward) < 0 ? -near.distance : near.distance
        }
    }

    /// Everything under the shirt at the bind pose, where the export stands.
    static let restBody: BodySurface? = ClothFixtures.exported.flatMap { BodySurface(positions: $0.positions, triangles: ClothFixtures.underShirtTriangles) }

    /// How far a mesh-space point is from the surface under the shirt at the
    /// bind pose, when that is within a centimetre (the cells around the
    /// point's own), and where the nearest point is; nil when nothing is
    /// that close.
    static func distanceToBody(_ p: SIMD3<Float>) -> (distance: Float, point: SIMD3<Float>)? {
        restBody?.nearest(to: p, reach: 1).map { ($0.distance, $0.point) }
    }

    /// The export's body — its vertices off the shell — skinned onto a pose
    /// (joint model transforms, mesh space, as `Body.pose` holds them) by
    /// linear blend skinning against the skeleton's bind pose: the sum over
    /// the vertex's four influences of w_j (pose[j] bind[j]^-1) p, the
    /// engine's blend as `DeformationCompute.metal` does it (no
    /// normalisation; a vertex with no weight stays where it is). The shell's
    /// vertices are left at rest: no body triangle has a corner on them.
    static func posedBody(_ pose: [simd_float4x4]) -> [SIMD3<Float>]? {
        guard let exported = ClothFixtures.exported, let isShell = ClothFixtures.exportedIsShell, let skin = ClothFixtures.exportedSkin, let joints = ClothFixtures.skeleton,
              pose.count == joints.bindModelTransforms.count, skin.joints.count == exported.positions.count else { return nil }
        let skinMatrices = zip(pose, joints.bindModelTransforms).map { $0 * $1.inverse }
        var positions = exported.positions
        for v in positions.indices where !isShell[v] {
            let w = skin.weights[v]
            guard w.sum() > 1e-4 else { continue }
            let p = SIMD4(exported.positions[v], 1)
            var moved = SIMD3<Float>.zero
            for i in 0 ..< 4 where w[i] != 0 {
                let j = Int(skin.joints[v][i])
                guard skinMatrices.indices.contains(j) else { continue }
                let q = skinMatrices[j] * p
                moved += w[i] * SIMD3(q.x, q.y, q.z)
            }
            positions[v] = moved
        }
        return positions
    }

    /// The schedule's regions by their slack (ZombieClothAssetTests holds the
    /// values distinct), for the readouts.
    static func regionName(slack: Float) -> String {
        let names: [(slack: Float, name: String)] = [(0, "collar and cuffs"), (0.005, "placket"), (0.03, "wrist"), (0.07, "yoke"), (0.09, "chest"), (0.10, "back"), (0.11, "sleeves"), (0.12, "hem"), (0.15, "armhole")]
        return names.first { abs($0.slack - slack) < 1e-4 }?.name ?? String(format: "slack %.3f", slack)
    }

    /// The proxy against the posed skin: how many particles sit more than
    /// 2 mm inside it (the back-stop's millimetre plus the push-out's two is
    /// where the drawn shell's outer layer meets the skin), the deepest and
    /// where that particle is on the shirt, the count per slack region, and
    /// how many of the particles had skin within 5 cm to read against.
    struct Penetration: CustomStringConvertible {
        var inside = 0
        var measured = 0
        var particles = 0
        /// The most negative signed distance (metres; 0 when nothing is inside).
        var deepest: Float = 0
        var worst: Int?
        var worstSlack: Float = 0
        var worstRest = SIMD3<Float>.zero
        var byRegion: [Float: Int] = [:]

        var description: String {
            let regions = byRegion.sorted { $0.key < $1.key }.map { String(format: "%@ %d", ClothMetrics.regionName(slack: $0.key), $0.value) }.joined(separator: ", ")
            guard let worst else { return String(format: "posed skin: %d of %d particles have skin within 5 cm, %d more than 2 mm inside it, none inside at all", measured, particles, inside) }
            return String(format: "posed skin: %d of %d particles have skin within 5 cm, %d more than 2 mm inside it (%@); deepest %.1f mm at particle %d (%@, slack %.3f) at rest (%.2f,%.2f,%.2f)",
                          measured, particles, inside, regions.isEmpty ? "none" : regions, -deepest * 1000, worst, ClothMetrics.regionName(slack: worstSlack), worstSlack, worstRest.x, worstRest.y, worstRest.z)
        }
    }

    /// The harness's particles, mesh space, against the body skinned onto
    /// the pose the harness's body holds now.
    static func penetration(of h: ClothHarness) -> Penetration? {
        guard let posed = posedBody(h.body.pose), let body = BodySurface(positions: posed, triangles: ClothFixtures.skinTriangles) else { return nil }
        var result = Penetration()
        result.particles = h.shirt.particles.count
        for (index, p) in h.meshParticles.enumerated() {
            guard let d = body.signedDistance(to: p) else { continue }
            result.measured += 1
            if d < -0.002 {
                result.inside += 1
                result.byRegion[h.shirt.maxDistance[index], default: 0] += 1
            }
            if d < result.deepest {
                result.deepest = d; result.worst = index; result.worstSlack = h.shirt.maxDistance[index]; result.worstRest = h.shirt.positions[index]
            }
        }
        return result
    }

    /// What `penetration(of:)` aggregates, per particle: the signed distance
    /// (mesh space, metres; negative inside) of every particle to the skin
    /// the harness's pose draws, nil where no skin is within 5 cm.
    static func skinDistances(of h: ClothHarness) -> [Float?]? {
        guard let posed = posedBody(h.body.pose), let body = BodySurface(positions: posed, triangles: ClothFixtures.skinTriangles) else { return nil }
        return h.meshParticles.map { body.signedDistance(to: $0) }
    }

    /// `from` toward `to` (joint model transforms) by `t` in 0...1: each
    /// joint's LOCAL transform interpolated — the rotation slerped, the
    /// translation lerped — and the chain recomposed parents first, so the
    /// bones keep their lengths on the way, where interpolating the model
    /// transforms themselves would stretch and shrink them. With `only`,
    /// the joints whose path it refuses keep `from`'s local transform
    /// (one limb swings, the rest of the body stands).
    static func interpolatedPose(from: [simd_float4x4], to: [simd_float4x4], at t: Float, only: ((String) -> Bool)? = nil) -> [simd_float4x4]? {
        guard let joints = ClothFixtures.skeleton, from.count == to.count, from.count == joints.parentIndices.count else { return nil }
        func local(_ model: [simd_float4x4], _ index: Int) -> (rotation: simd_quatf, translation: SIMD3<Float>) {
            let m = joints.parentIndices[index].map { model[$0].inverse * model[index] } ?? model[index]
            let basis = simd_float3x3(
                simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
            return (simd_normalize(simd_quatf(basis)), SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z))
        }
        var model = [simd_float4x4](repeating: matrix_identity_float4x4, count: from.count)
        for index in from.indices {
            let a = local(from, index), b = local(to, index)
            let share = only.map { $0(joints.jointPaths[index]) ? t : 0 } ?? t
            let rotation = simd_slerp(a.rotation, b.rotation, share), translation = simd_mix(a.translation, b.translation, SIMD3(repeating: share))
            var m = simd_float4x4(rotation)
            m.columns.3 = SIMD4(translation, 1)
            let parent = joints.parentIndices[index].map { model[$0] } ?? matrix_identity_float4x4
            model[index] = parent * m
        }
        return model
    }
}

/// The harness's own readouts: the shell from the particles, the skin's
/// normals at the targets, the depth behind the skin and the excess past
/// the slack.
extension ClothHarness {
    /// A proxy triangle's frame from its corners: `e1` along the first
    /// edge, `n` the face normal, `t` across.
    static func frame(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> (e1: SIMD3<Float>, n: SIMD3<Float>, t: SIMD3<Float>) {
        let e1 = simd_normalize(b - a), n = simd_normalize(simd_cross(e1, c - a))
        return (e1, n, simd_cross(n, e1))
    }

    /// The shell as the sidecar's binding says, from world-space
    /// particles, in the test's own words: the triangle's frame from its
    /// corners, the vertex its barycentric point plus its rest offset in
    /// that frame, the normal the body's own (the exported one at the
    /// vertex) taken into the triangle's bind-pose frame and out through
    /// the frame now. World space.
    func shell(from particles: [SIMD3<Float>]) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        let render = shirt.render!
        let bary = render.barycentricVectors, offset = render.offsetVectors
        let rest = shirt.positions
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = []
        positions.reserveCapacity(render.vertexCount); normals.reserveCapacity(render.vertexCount)
        for v in 0 ..< render.vertexCount {
            let t = shirt.triangles[render.triangle[v]]
            let a = particles[t[0]], b = particles[t[1]], c = particles[t[2]]
            let now = Self.frame(a, b, c), bind = Self.frame(rest[t[0]], rest[t[1]], rest[t[2]])
            let w = bary[v], o = offset[v], m = body.meshNormals[v]
            let r = SIMD3(simd_dot(m, bind.e1), simd_dot(m, bind.n), simd_dot(m, bind.t))
            positions.append(w.x * a + w.y * b + w.z * c + o.x * now.e1 + o.y * now.n + o.z * now.t)
            normals.append(r.x * now.e1 + r.y * now.n + r.z * now.t)
        }
        return (positions, normals)
    }

    /// Where the skin's normal points at each particle for the joints
    /// last fed — the unit normals of the triangles around it summed, from
    /// the skinned targets, as Jolt computes it (`SkinVertices`) — which
    /// is what Jolt places the back-stop behind.
    func targetNormals() -> [SIMD3<Float>] {
        let t = targets
        var sum = [SIMD3<Float>](repeating: .zero, count: t.count)
        for tri in shirt.triangles {
            let c = simd_cross(t[tri[1]] - t[tri[0]], t[tri[2]] - t[tri[0]])
            guard simd_length(c) > 1e-12 else { continue }
            for i in tri { sum[i] += simd_normalize(c) }
        }
        return sum.map { simd_length($0) > 1e-12 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }

    /// The farthest any particle with a back-stop sits BEHIND its skinned
    /// target along the skin's normal there: the skin the prep keeps under
    /// the shirt is 2 mm behind the target (the push-out), so more than
    /// that is the proxy inside the body. The particles whose faces point
    /// at the body have no stop and are left out.
    func inwardExcursion() -> Float { worstInward().depth }

    /// The particle `inwardExcursion` reads: its index and its depth.
    func worstInward() -> (index: Int, depth: Float) {
        let p = particles, t = targets, n = targetNormals()
        let bodyFacing = Set(shirt.bodyFacingParticles)
        var worst = (index: 0, depth: -Float.greatestFiniteMagnitude)
        for index in p.indices where shirt.maxDistance[index] > 0 && !bodyFacing.contains(index) {
            let depth = simd_dot(t[index] - p[index], n[index])
            if depth > worst.depth { worst = (index, depth) }
        }
        return worst
    }

    /// The worst particle: how far beyond its slack it sits from its
    /// skinned target (negative inside), and the worst pin's distance.
    func excess() -> (free: Float, pins: Float, finite: Bool) {
        let p = particles, t = targets
        var free: Float = -.greatestFiniteMagnitude, pins: Float = 0, finite = true
        for index in p.indices {
            let position = p[index]
            if !(position.x.isFinite && position.y.isFinite && position.z.isFinite) { finite = false; continue }
            let d = simd_distance(position, t[index])
            if shirt.maxDistance[index] == 0 { pins = max(pins, d) } else { free = max(free, d - shirt.maxDistance[index]) }
        }
        return (free, pins, finite)
    }
}

// MARK: - The drape figure

/// The drape figure of `Docs/GPUCloth.md` (section 6, `testTheHangReportsItsFolds`):
/// what turns "folds under gravity" from a headset read into a number printed
/// beside it. The design named two figures over the hem band's interior
/// edges — the mean absolute dihedral angle between the two faces of each,
/// and the number of convex-concave alternations around the hem loop — and
/// left both loose; this is their exact form, chosen so a 4k and a 16k proxy
/// of the same shirt read on one scale (2026-11-04). The hem band is the
/// schedule's 0.12 (the lowest 12 cm of the body panels, `HEM_BAND` in the
/// prep); its interior edges are the edges with two faces and both ends in
/// the band. The dihedral of an edge is the angle between its two faces'
/// normals, signed: positive where the fold is convex outward (the far
/// face's opposite corner lies behind the near face's plane), negative where
/// it is concave, read off the geometry and not the winding. The per-edge
/// mean of its magnitude is the design's figure and is printed as it asked,
/// in degrees, but it falls with the edge length for the same shape (the
/// same bend spread over twice the edges is half the angle at each), so the
/// figure that compares across proxies is the band's mean absolute curvature,
/// sum over the band's edges of |dihedral| x edge length divided by the band's
/// area (the discrete integral of the absolute mean curvature, 1/m): a
/// cylinder of radius r reads 1 / r on it at any resolution. The alternations
/// are counted around the hem loop (the boundary loop with the lowest mean
/// height) on the signed fold at each of its vertices — the sum of signed
/// dihedral x length over the band's interior edges at the vertex —
/// resampled along the loop's arc at a fixed 5 mm step (linear between the
/// vertices, so the profile has the same resolution on either proxy),
/// smoothed over an arc-length window of 1 cm each way, and are the sign
/// changes of that profile around the closed loop: a fold of wavelength L
/// alternates every L / 2, so the 3-5 cm folds the 16k cook is for read
/// through a 2 cm window (a box of that width passes a 4 cm wavelength and
/// kills a 2 cm one) and what is shorter than it, a particle's own jitter,
/// does not; divided by the loop's length they are per metre of hem, the
/// figure the design asked to be per unit length and not per particle. The
/// resample is there for a reason the first day's figure taught
/// (2026-11-04): with the window over the vertices themselves the 4k loop,
/// at its 19.7 mm vertex spacing, was read vertex to vertex while the 16k's
/// (9.6 mm) was averaged over three, and the count compared the filters, not
/// the shirts (21.3 against 5.2 per metre at the bind pose, before either
/// solver ran). For the same reason the figure is read AGAINST
/// THE REST POSE (`restDrape`, `Drape.against`): the artist's hem carries
/// folds of its own, which the finer loop resolves and the coarser cannot,
/// so what the solver did to the hem is the change from the sidecar's bind
/// pose, not the absolute count. Taken at the end of the hang (its 200
/// frames; the design says 300, but the cloth is asleep on the still body
/// from about frame 177 on either solver, so the two states are one) and at
/// the sway's last frame, printed for both solvers by `ClothFitScenarios`,
/// pinned once the owner's gate-2 verdict is in.
extension ClothMetrics {
    /// The hem band's slack in the schedule.
    static let hemSlack: Float = 0.12
    /// The arc-length window each way along the hem loop over which the signed
    /// fold is smoothed before the alternations are counted, metres: under
    /// the half-wavelength of the folds the figure is for (1.5-2.5 cm), so
    /// the window does not average them away, with the resample below
    /// seeing to it that both proxies' loops are read the same way.
    static let drapeWindow: Float = 0.01
    /// The arc-length step the fold profile is resampled at along the loop
    /// before the window, metres: under the finer proxy's loop spacing (9.6
    /// mm at 16k), so the two proxies' profiles have one resolution.
    static let drapeStep: Float = 0.005

    struct Drape: CustomStringConvertible {
        var particles = 0
        /// The band's particles, its interior edges and the area those edges
        /// account for (a third of each adjacent face per edge), m^2.
        var bandParticles = 0
        var bandEdges = 0
        var bandArea: Float = 0
        /// The design's per-edge figures, degrees.
        var meanDihedralDegrees: Float = 0
        var maxDihedralDegrees: Float = 0
        /// The band's mean absolute curvature, 1/m: sum |dihedral| x length over
        /// the band's area.
        var curvature: Float = 0
        /// How much of the band's signed dihedral x length is convex, 0...1.
        var convexShare: Float = 0
        /// The hem loop: its vertices, its length (m) and the alternations of
        /// the smoothed fold sign around it.
        var loopVertices = 0
        var loopLength: Float = 0
        var alternations = 0

        var alternationsPerMetre: Float { loopLength > 0 ? Float(alternations) / loopLength : 0 }

        var description: String {
            String(format: "hem band %d particles, %d interior edges over %.0f cm^2: mean |dihedral| %.2f deg per edge (max %.1f), mean curvature %.2f 1/m, %.0f%% convex; hem loop %d vertices, %.3f m: %d fold alternations on a %.0f mm resample through a %.0f cm window, %.1f per metre",
                   bandParticles, bandEdges, bandArea * 1e4, meanDihedralDegrees, maxDihedralDegrees, curvature, convexShare * 100, loopVertices, loopLength, alternations, ClothMetrics.drapeStep * 1000, ClothMetrics.drapeWindow * 200, alternationsPerMetre)
        }

        /// The figure as a change from `rest` (the same shirt's bind pose):
        /// what the solver did to the hem, the artist's own folds taken out.
        func against(_ rest: Drape) -> String {
            String(format: "against the rest pose's %.2f 1/m and %.1f per metre (%d alternations): curvature %+.2f 1/m (%+.0f%%), alternations %+.1f per metre",
                   rest.curvature, rest.alternationsPerMetre, rest.alternations, curvature - rest.curvature,
                   rest.curvature > 0 ? (curvature / rest.curvature - 1) * 100 : 0, alternationsPerMetre - rest.alternationsPerMetre)
        }
    }

    /// The drape figure of `shirt`'s proxy at `positions` (any rigid frame:
    /// angles and lengths); nil when the hem loop is torn or pinched (a
    /// boundary vertex with other than two boundary edges) or the band is
    /// empty.
    static func drape(positions p: [SIMD3<Float>], shirt: ZombieClothAsset.Garment) -> Drape? {
        guard p.count == shirt.particles.count, p.count == shirt.maxDistance.count else { return nil }
        var band = [Bool](repeating: false, count: p.count)
        var bandCount = 0
        for (index, slack) in shirt.maxDistance.enumerated() where abs(slack - hemSlack) < 1e-5 { band[index] = true; bandCount += 1 }
        guard bandCount > 0 else { return nil }
        // Each edge's faces, with the corner opposite the edge in each.
        struct Side { let face: Int; let opposite: Int }
        var sides: [UInt64: [Side]] = [:]
        var normals: [SIMD3<Float>] = [], areas: [Float] = []
        normals.reserveCapacity(shirt.triangles.count); areas.reserveCapacity(shirt.triangles.count)
        for (f, t) in shirt.triangles.enumerated() {
            let cross = simd_cross(p[t[1]] - p[t[0]], p[t[2]] - p[t[0]])
            let length = simd_length(cross)
            normals.append(length > 1e-12 ? cross / length : SIMD3(0, 1, 0))
            areas.append(length / 2)
            for i in 0 ..< 3 {
                let a = t[i], b = t[(i + 1) % 3], o = t[(i + 2) % 3]
                sides[UInt64(min(a, b)) << 32 | UInt64(max(a, b)), default: []].append(Side(face: f, opposite: o))
            }
        }
        var out = Drape()
        out.particles = p.count
        out.bandParticles = bandCount
        // The signed fold at each particle: the sum of signed dihedral x length
        // over the band's interior edges at it.
        var fold = [Float](repeating: 0, count: p.count)
        var sumAbs: Float = 0, sumAbsLength: Float = 0, sumConvexLength: Float = 0, area: Float = 0
        var maxAbs: Float = 0
        for (key, faces) in sides where faces.count == 2 {
            let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
            guard band[a], band[b] else { continue }
            let n1 = normals[faces[0].face], n2 = normals[faces[1].face]
            let magnitude = acos(min(1, max(-1, simd_dot(n1, n2))))
            let midpoint = (p[a] + p[b]) / 2
            let convex = simd_dot(n1, p[faces[1].opposite] - midpoint) < 0
            let theta = convex ? magnitude : -magnitude
            let length = simd_distance(p[a], p[b])
            out.bandEdges += 1
            sumAbs += magnitude
            maxAbs = max(maxAbs, magnitude)
            sumAbsLength += magnitude * length
            if convex { sumConvexLength += magnitude * length }
            area += (areas[faces[0].face] + areas[faces[1].face]) / 3
            fold[a] += theta * length
            fold[b] += theta * length
        }
        guard out.bandEdges > 0 else { return nil }
        out.bandArea = area
        out.meanDihedralDegrees = sumAbs / Float(out.bandEdges) * 180 / .pi
        out.maxDihedralDegrees = maxAbs * 180 / .pi
        out.curvature = area > 0 ? sumAbsLength / area : 0
        out.convexShare = sumAbsLength > 0 ? sumConvexLength / sumAbsLength : 0
        // The hem loop: the boundary loop with the lowest mean height, walked
        // from its lowest-indexed vertex.
        var next: [Int: [Int]] = [:]
        for (key, faces) in sides where faces.count == 1 {
            let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
            next[a, default: []].append(b); next[b, default: []].append(a)
        }
        guard next.values.allSatisfy({ $0.count == 2 }) else { return nil }
        var seen = Set<Int>(), loops: [[Int]] = []
        for start in next.keys.sorted() where !seen.contains(start) {
            var loop: [Int] = [], previous = -1, v = start
            repeat {
                seen.insert(v); loop.append(v)
                let around = next[v]!
                let step = around[0] != previous ? around[0] : around[1]
                previous = v; v = step
            } while v != start && !seen.contains(v)
            loops.append(loop)
        }
        guard let hem = loops.min(by: { l, r in l.reduce(Float(0)) { $0 + p[$1].y } / Float(l.count) < r.reduce(Float(0)) { $0 + p[$1].y } / Float(r.count) }), hem.count > 2 else { return nil }
        // Arc length along the loop; the fold resampled at `drapeStep` along
        // it (linear between the vertices, cyclic), smoothed over the window
        // each way (cyclic), the sign changes around the loop.
        var arc: [Float] = [0]
        for i in 1 ..< hem.count { arc.append(arc[i - 1] + simd_distance(p[hem[i - 1]], p[hem[i]])) }
        let total = arc.last! + simd_distance(p[hem[hem.count - 1]], p[hem[0]])
        out.loopVertices = hem.count
        out.loopLength = total
        guard total > 0 else { return nil }
        let samples = max(Int((total / drapeStep).rounded()), hem.count)
        var resampled = [Float](repeating: 0, count: samples)
        var vertex = 0
        for k in 0 ..< samples {
            let s = Float(k) / Float(samples) * total
            while vertex + 1 < hem.count, arc[vertex + 1] <= s { vertex += 1 }
            let a = arc[vertex], b = vertex + 1 < hem.count ? arc[vertex + 1] : total
            let fa = fold[hem[vertex]], fb = fold[hem[(vertex + 1) % hem.count]]
            let t = b > a ? (s - a) / (b - a) : 0
            resampled[k] = fa + (fb - fa) * t
        }
        let reach = Int((drapeWindow / (total / Float(samples))).rounded())
        var profile = [Float](repeating: 0, count: samples)
        for k in 0 ..< samples {
            var sum: Float = 0
            for j in -reach ... reach { sum += resampled[((k + j) % samples + samples) % samples] }
            profile[k] = sum
        }
        var lastSign = 0, alternations = 0, firstSign = 0
        for value in profile {
            let sign = value > 0 ? 1 : (value < 0 ? -1 : 0)
            guard sign != 0 else { continue }
            if firstSign == 0 { firstSign = sign }
            if lastSign != 0, sign != lastSign { alternations += 1 }
            lastSign = sign
        }
        // The loop closes: the last sign against the first.
        if lastSign != 0, firstSign != 0, lastSign != firstSign { alternations += 1 }
        out.alternations = alternations
        return out
    }

    /// The drape of the harness's shirt as the solver has it now.
    static func drape(of h: ClothHarness) -> Drape? {
        drape(positions: h.particles, shirt: h.shirt)
    }

    /// The drape of the harness's shirt at the sidecar's bind pose: the
    /// artist's folds, which a frame's figure is read against.
    static func restDrape(of h: ClothHarness) -> Drape? {
        drape(positions: h.shirt.positions, shirt: h.shirt)
    }
}
