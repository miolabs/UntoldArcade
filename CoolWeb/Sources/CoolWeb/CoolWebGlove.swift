//
//  CoolWebGlove.swift
//  CoolWeb
//
//  Procedural Spider-Man glove, rebuilt from the tracked hand skeleton every
//  frame — no asset, no rig retargeting, auto-fits any hand. Geometry is
//  world-space tubes: tapered finger tubes with parallel-transported frames,
//  one flattened elliptical loft from the cuff through the palm to the
//  knuckles, and a small metal web-shooter barrel on the inner wrist. The red
//  fabric + black webbing look is painted procedurally in the fragment shader
//  from the (u around, v along) coordinates emitted here.
//
//  Pure math over `CoolWebHandPose` — deliberately free of ARKit and Metal
//  types so the whole mesh can be built and asserted on in host unit tests.
//

import Foundation
import simd

/// Tunables for the procedural glove. Distances are meters.
public struct CoolWebGloveConfig: Sendable, Equatable {
    /// Radial vertices per tube ring.
    public var radialSides = 12
    /// Base finger radii, ordered thumb, index, middle, ring, little.
    public var fingerRadii: [Float] = [0.0115, 0.0102, 0.0102, 0.0096, 0.0088]
    /// Extra radius so the glove sits over the real finger, not inside it.
    public var fabricPadding: Float = 0.002
    /// Palm half-thickness at the wrist end / at the knuckle end.
    public var palmHalfThicknessWrist: Float = 0.018
    public var palmHalfThicknessKnuckles: Float = 0.0145
    /// How far the cuff extends behind the wrist toward the forearm.
    public var cuffLength: Float = 0.055
    /// Whether the metal web-shooter barrel is added on the inner wrist.
    public var showWebShooter = true
    /// Seconds the suit-up animation takes to sweep from the wrist to the
    /// fingertips (and back when reversing). 0 makes it instant.
    public var buildDuration: Float = 0.9
    /// Seconds the user must keep looking at a hand before its suit-up
    /// starts — gives the eyes time to settle on the hand after flipping
    /// the Suit-Up toggle.
    public var suitUpGazeDelay: Float = 0.35

    public init() {}
}

/// One frame of glove geometry, ready for the GPU.
public struct CoolWebGloveMesh: Sendable, Equatable {
    public var vertices: [CoolWebGloveVertexGPU] = []
    public var indices: [UInt32] = []
    /// Largest per-vertex coverage distance (m) — the suit-up animation's
    /// front sweeps 0 → this value.
    public var coverageExtent: Float = 0

    public init() {}
}

public enum CoolWebGloveMaterial {
    /// Palm/cuff fabric: red with the big radial silver web.
    public static let fabric: Float = 0
    public static let metal: Float = 1
    /// Finger fabric: red with silver rings wrapping the finger.
    public static let fingerFabric: Float = 2
}

/// Orthonormal palm frame derived from the joint cloud (the pose carries no
/// orientation data). Shared by the glove builder and the web-shooter origin
/// so the strand fires exactly out of the drawn barrel.
struct CoolWebHandFrame {
    var wrist: SIMD3<Float>
    var knuckleCenter: SIMD3<Float>
    /// Wrist → knuckle line.
    var forward: SIMD3<Float>
    /// Index → little knuckles, orthogonalized against forward.
    var lateral: SIMD3<Float>
    /// Out of the back of the hand.
    var backNormal: SIMD3<Float>
    var palmNormal: SIMD3<Float> { -backNormal }
    var palmLength: Float { simd_length(knuckleCenter - wrist) }

    init?(pose: CoolWebHandPose, side: CoolWebHandSide) {
        guard pose.index.points.count >= 5,
              pose.little.points.count >= 5,
              pose.middle.points.count >= 5,
              pose.ring.points.count >= 5,
              pose.thumb.points.count >= 5
        else { return nil }

        wrist = pose.wrist
        let indexKnuckle = pose.index.points[1]
        let littleKnuckle = pose.little.points[1]
        knuckleCenter = (indexKnuckle + littleKnuckle) * 0.5

        forward = safeNormalize(
            knuckleCenter - wrist, fallback: SIMD3<Float>(0, 0, -1)
        )
        var side0 = safeNormalize(
            littleKnuckle - indexKnuckle, fallback: SIMD3<Float>(1, 0, 0)
        )
        side0 = safeNormalize(
            side0 - forward * simd_dot(side0, forward),
            fallback: perpendicular(to: forward)
        )
        lateral = side0
        backNormal = safeNormalize(
            side == .right
                ? simd_cross(lateral, forward)
                : simd_cross(forward, lateral),
            fallback: SIMD3<Float>(0, 1, 0)
        )
    }
}

public enum CoolWebGloveBuild {
    /// params.w front value meaning "fully covered, no animation": far beyond
    /// any real coverage distance, so the shader's front test never trips.
    public static let coveredFront: Float = 1_000_000
}

// MARK: - Builder

public enum CoolWebGloveBuilder {
    /// Where the drawn barrel's muzzle sits — strands should fire from here
    /// so the web visually leaves the gray device on the inner wrist.
    public static func webShooterMuzzle(
        pose: CoolWebHandPose,
        side: CoolWebHandSide,
        config: CoolWebGloveConfig = CoolWebGloveConfig()
    ) -> SIMD3<Float>? {
        guard let frame = CoolWebHandFrame(pose: pose, side: side) else {
            return nil
        }
        return muzzlePosition(frame: frame, config: config)
    }

    static func barrelCenter(
        frame: CoolWebHandFrame,
        config: CoolWebGloveConfig
    ) -> SIMD3<Float> {
        frame.wrist + frame.palmNormal * (config.palmHalfThicknessWrist + 0.006)
    }

    static func muzzlePosition(
        frame: CoolWebHandFrame,
        config: CoolWebGloveConfig
    ) -> SIMD3<Float> {
        barrelCenter(frame: frame, config: config) + frame.forward * 0.026
    }

    /// Builds the world-space glove mesh for one tracked hand pose.
    public static func build(
        pose: CoolWebHandPose,
        side: CoolWebHandSide,
        config: CoolWebGloveConfig = CoolWebGloveConfig()
    ) -> CoolWebGloveMesh {
        var accumulator = GloveMeshAccumulator()

        guard let frame = CoolWebHandFrame(pose: pose, side: side) else {
            return CoolWebGloveMesh()
        }
        let wrist = frame.wrist
        let knuckleCenter = frame.knuckleCenter
        let forward = frame.forward
        let lateral = frame.lateral
        let backNormal = frame.backNormal

        // The big radial web is centered on the back of the hand, a bit past
        // mid-palm (matches the reference glove); web-plane coordinates are
        // planar offsets from it so the pattern is continuous over the loft.
        let webCenter = wrist + forward * (frame.palmLength * 0.45)
        let palmWeb = GloveWebFrame.planar(
            center: webCenter, xAxis: lateral, yAxis: forward
        )

        // MARK: cuff → palm loft (one flattened elliptical tube)
        let knuckleSpan = simd_length(pose.little.points[1] - pose.index.points[1])
        let knuckleHalfWidth = knuckleSpan * 0.5
            + (config.fingerRadii[1] + config.fabricPadding) * 1.55
        let wristHalfWidth = knuckleHalfWidth * 0.86
        let palmLength = simd_length(knuckleCenter - wrist)

        var palmRings: [Int] = []
        let cuffStations = 3
        let palmStations = 5
        var firstRingInfo: (center: SIMD3<Float>, radius: Float) = (wrist, 0)
        var lastRingInfo: (center: SIMD3<Float>, radius: Float) = (wrist, 0)
        for i in 0 ..< (cuffStations + palmStations + 1) {
            let center: SIMD3<Float>
            let halfWidth: Float
            let halfThickness: Float
            let v: Float
            if i < cuffStations {
                // Cuff: behind the wrist, flaring slightly toward the forearm.
                let f = Float(cuffStations - i) / Float(cuffStations)
                center = wrist - forward * (config.cuffLength * f)
                halfWidth = wristHalfWidth * (1 + 0.12 * f)
                halfThickness = config.palmHalfThicknessWrist * (1 + 0.18 * f)
                v = config.cuffLength * (1 - f)
            } else {
                // Palm: wrist toward the knuckle line.
                let f = Float(i - cuffStations) / Float(palmStations)
                center = mix(wrist, knuckleCenter, t: f)
                halfWidth = mix(wristHalfWidth, knuckleHalfWidth, t: f)
                halfThickness = mix(
                    config.palmHalfThicknessWrist,
                    config.palmHalfThicknessKnuckles,
                    t: f
                )
                v = config.cuffLength + palmLength * f
            }
            let ring = accumulator.addRing(
                center: center,
                sAxis: lateral,
                tAxis: backNormal,
                sRadius: halfWidth,
                tRadius: halfThickness,
                v: v,
                coverage: abs(v - config.cuffLength),
                material: CoolWebGloveMaterial.fabric,
                sides: config.radialSides,
                web: palmWeb
            )
            palmRings.append(ring)
            if i == 0 { firstRingInfo = (center, (halfWidth + halfThickness) * 0.5) }
            lastRingInfo = (center, (halfWidth + halfThickness) * 0.5)
        }
        for i in 1 ..< palmRings.count {
            accumulator.stitch(palmRings[i - 1], palmRings[i], sides: config.radialSides)
        }
        // Close both loft ends so the tube never shows its inside.
        accumulator.addFan(
            apex: firstRingInfo.center,
            normal: -forward,
            ring: palmRings[0],
            sides: config.radialSides,
            v: 0,
            coverage: config.cuffLength,
            material: CoolWebGloveMaterial.fabric,
            web: palmWeb
        )
        accumulator.addFan(
            apex: lastRingInfo.center,
            normal: forward,
            ring: palmRings[palmRings.count - 1],
            sides: config.radialSides,
            v: config.cuffLength + palmLength,
            coverage: palmLength,
            material: CoolWebGloveMaterial.fabric,
            web: palmWeb,
            ao: 0.85
        )

        // MARK: fingers
        // Taper multipliers root → tip; the root station sits back along the
        // metacarpal so the tube disappears into the palm loft with no gap.
        // The thumb gets a much fatter root to cover the thenar mound.
        let fingerTaper: [Float] = [1.30, 1.10, 1.0, 0.93, 0.86]
        let thumbTaper: [Float] = [1.65, 1.25, 1.05, 0.95, 0.86]
        let chains = [pose.thumb, pose.index, pose.middle, pose.ring, pose.little]
        for (fingerIndex, chain) in chains.enumerated() {
            let taper = fingerIndex == 0 ? thumbTaper : fingerTaper
            let baseRadius = config.fingerRadii[
                min(fingerIndex, config.fingerRadii.count - 1)
            ] + config.fabricPadding
            let points = chain.points
            // Thumb chain starts at the wrist; sink its root deeper so the
            // fat thumb base blends into the palm side. Finger roots reach
            // well into the palm loft so no knuckle skin peeks through.
            let rootBias: Float = fingerIndex == 0 ? 0.20 : 0.35
            var stations = [mix(points[0], points[1], t: rootBias)]
            stations.append(contentsOf: points[1...4])
            let radii = taper.map { $0 * baseRadius }
            // Roots sit in the crotch between fingers: bake them darker.
            accumulator.addTube(
                stations: stations,
                radii: radii,
                referenceSide: lateral,
                coverageOffset: simd_length(stations[0] - wrist),
                material: CoolWebGloveMaterial.fingerFabric,
                sides: config.radialSides,
                capEnd: true,
                web: .cylindrical,
                stationAO: [0.62, 0.78, 1, 1, 1]
            )
        }

        // MARK: web-shooter barrel (metal, inner wrist — where strands fire)
        if config.showWebShooter {
            // Kept in sync with webShooterMuzzle: strands fire from the
            // front end of this barrel.
            let barrelCenter = Self.barrelCenter(frame: frame, config: config)
            let barrelStations: [(d: Float, a: Float, b: Float)] = [
                (-0.016, 0.013, 0.0075),
                (0.008, 0.014, 0.008),
                (0.026, 0.010, 0.006),
            ]
            var barrelRings: [Int] = []
            for station in barrelStations {
                let ring = accumulator.addRing(
                    center: barrelCenter + forward * station.d,
                    sAxis: lateral,
                    tAxis: frame.palmNormal,
                    sRadius: station.a,
                    tRadius: station.b,
                    v: station.d + 0.016,
                    coverage: abs(station.d),
                    material: CoolWebGloveMaterial.metal,
                    sides: config.radialSides,
                    web: .none
                )
                barrelRings.append(ring)
            }
            for i in 1 ..< barrelRings.count {
                accumulator.stitch(
                    barrelRings[i - 1], barrelRings[i], sides: config.radialSides
                )
            }
            accumulator.addFan(
                apex: barrelCenter + forward * barrelStations[0].d,
                normal: -forward,
                ring: barrelRings[0],
                sides: config.radialSides,
                v: 0,
                coverage: abs(barrelStations[0].d),
                material: CoolWebGloveMaterial.metal
            )
            accumulator.addFan(
                apex: barrelCenter + forward * barrelStations[2].d,
                normal: forward,
                ring: barrelRings[2],
                sides: config.radialSides,
                v: 0.05,
                coverage: abs(barrelStations[2].d),
                material: CoolWebGloveMaterial.metal
            )
        }

        var mesh = CoolWebGloveMesh()
        mesh.vertices = accumulator.vertices
        mesh.indices = accumulator.indices
        mesh.coverageExtent = accumulator.maxCoverage
        return mesh
    }
}

// MARK: - Mesh accumulator

/// How a ring's vertices get their web-pattern coordinates (extra.xy).
enum GloveWebFrame {
    /// Planar projection onto (xAxis, yAxis) relative to `center` — the
    /// radial back-of-hand web.
    case planar(center: SIMD3<Float>, xAxis: SIMD3<Float>, yAxis: SIMD3<Float>)
    /// Unrolled tube coords (m around, m along) — finger ring stripes.
    case cylindrical
    /// No pattern (metal barrel).
    case none
}

private struct GloveMeshAccumulator {
    var vertices: [CoolWebGloveVertexGPU] = []
    var indices: [UInt32] = []
    /// Largest coverage distance written so far (suit-up animation extent).
    var maxCoverage: Float = 0

    /// Adds one elliptical ring in the (sAxis, tAxis) plane. `axialLean`
    /// tilts the normals toward `leanAxis` for hemisphere cap rings.
    /// `coverage` is the vertex's distance from the wrist along the glove —
    /// the suit-up animation front sweeps through it.
    /// Returns the index of the ring's first vertex.
    mutating func addRing(
        center: SIMD3<Float>,
        sAxis: SIMD3<Float>,
        tAxis: SIMD3<Float>,
        sRadius: Float,
        tRadius: Float,
        v: Float,
        coverage: Float,
        material: Float,
        sides: Int,
        web: GloveWebFrame,
        ao: Float = 1,
        leanAxis: SIMD3<Float> = .zero,
        axialLean: Float = 0
    ) -> Int {
        let base = vertices.count
        let meanRadius = (sRadius + tRadius) * 0.5
        maxCoverage = max(maxCoverage, coverage)
        for k in 0 ..< sides {
            let theta = 2 * Float.pi * Float(k) / Float(sides)
            let c = cos(theta)
            let s = sin(theta)
            let position = center + sAxis * (c * sRadius) + tAxis * (s * tRadius)
            // Ellipse normal ∝ (cos/a, sin/b), then optionally leaned axially.
            var normal = safeNormalize(
                sAxis * (c / max(sRadius, 1e-5)) + tAxis * (s / max(tRadius, 1e-5)),
                fallback: sAxis
            )
            if axialLean > 0 {
                normal = safeNormalize(
                    normal * (1 - axialLean) + leanAxis * axialLean,
                    fallback: normal
                )
            }
            var vertex = CoolWebGloveVertexGPU()
            vertex.position = SIMD4<Float>(position, Float(k) / Float(sides))
            vertex.normal = SIMD4<Float>(normal, v)
            vertex.params = SIMD4<Float>(
                material, meanRadius, coverage, CoolWebGloveBuild.coveredFront
            )
            let webCoord = Self.webCoord(
                web, position: position, k: k, sides: sides,
                meanRadius: meanRadius, v: v
            )
            vertex.extra = SIMD4<Float>(webCoord.x, webCoord.y, ao, 0)
            vertices.append(vertex)
        }
        return base
    }

    static func webCoord(
        _ web: GloveWebFrame,
        position: SIMD3<Float>,
        k: Int,
        sides: Int,
        meanRadius: Float,
        v: Float
    ) -> SIMD2<Float> {
        switch web {
        case let .planar(center, xAxis, yAxis):
            let offset = position - center
            return SIMD2<Float>(
                simd_dot(offset, xAxis), simd_dot(offset, yAxis)
            )
        case .cylindrical:
            return SIMD2<Float>(
                Float(k) / Float(sides) * 2 * .pi * meanRadius, v
            )
        case .none:
            return .zero
        }
    }

    /// Quad-stitches two rings of the same side count.
    mutating func stitch(_ ringA: Int, _ ringB: Int, sides: Int) {
        for k in 0 ..< sides {
            let k2 = (k + 1) % sides
            let a0 = UInt32(ringA + k), a1 = UInt32(ringA + k2)
            let b0 = UInt32(ringB + k), b1 = UInt32(ringB + k2)
            indices.append(contentsOf: [a0, b0, b1, a0, b1, a1])
        }
    }

    /// Closes a ring with a triangle fan to an apex point.
    mutating func addFan(
        apex: SIMD3<Float>,
        normal: SIMD3<Float>,
        ring: Int,
        sides: Int,
        v: Float,
        coverage: Float,
        material: Float,
        web: GloveWebFrame = .none,
        ao: Float = 1
    ) {
        var apexVertex = CoolWebGloveVertexGPU()
        apexVertex.position = SIMD4<Float>(apex, 0)
        apexVertex.normal = SIMD4<Float>(normal, v)
        apexVertex.params = SIMD4<Float>(
            material, 0.01, coverage, CoolWebGloveBuild.coveredFront
        )
        let webCoord = Self.webCoord(
            web, position: apex, k: 0, sides: sides, meanRadius: 0.01, v: v
        )
        apexVertex.extra = SIMD4<Float>(webCoord.x, webCoord.y, ao, 0)
        maxCoverage = max(maxCoverage, coverage)
        let apexIndex = UInt32(vertices.count)
        vertices.append(apexVertex)
        for k in 0 ..< sides {
            let k2 = (k + 1) % sides
            indices.append(contentsOf: [apexIndex, UInt32(ring + k), UInt32(ring + k2)])
        }
    }

    /// A tapered tube along `stations` with parallel-transported ring frames
    /// (no twist), optionally closed with a hemisphere cap at the last station.
    /// `coverageOffset` is the first station's distance from the wrist; each
    /// ring's coverage grows with arc length from there.
    mutating func addTube(
        stations: [SIMD3<Float>],
        radii: [Float],
        referenceSide: SIMD3<Float>,
        coverageOffset: Float,
        material: Float,
        sides: Int,
        capEnd: Bool,
        web: GloveWebFrame = .cylindrical,
        stationAO: [Float] = []
    ) {
        guard stations.count >= 2 else { return }
        var rings: [Int] = []
        var v: Float = 0
        var sideAxis = referenceSide
        var lastAxis = SIMD3<Float>(0, 0, 1)
        for i in 0 ..< stations.count {
            let prev = stations[max(i - 1, 0)]
            let next = stations[min(i + 1, stations.count - 1)]
            let axis = safeNormalize(next - prev, fallback: lastAxis)
            lastAxis = axis
            // Parallel transport: keep the previous side vector, minus its
            // component along the new axis.
            sideAxis = safeNormalize(
                sideAxis - axis * simd_dot(sideAxis, axis),
                fallback: perpendicular(to: axis)
            )
            let tAxis = simd_cross(axis, sideAxis)
            if i > 0 { v += simd_length(stations[i] - stations[i - 1]) }
            let radius = radii[min(i, radii.count - 1)]
            let ring = addRing(
                center: stations[i],
                sAxis: sideAxis,
                tAxis: tAxis,
                sRadius: radius,
                tRadius: radius,
                v: v,
                coverage: coverageOffset + v,
                material: material,
                sides: sides,
                web: web,
                ao: stationAO.isEmpty
                    ? 1
                    : stationAO[min(i, stationAO.count - 1)]
            )
            rings.append(ring)
        }
        for i in 1 ..< rings.count {
            stitch(rings[i - 1], rings[i], sides: sides)
        }
        guard capEnd, let tip = stations.last else { return }
        let tipRadius = radii[min(stations.count - 1, radii.count - 1)]
        let axis = lastAxis
        let tAxis = simd_cross(axis, sideAxis)
        var previousRing = rings[rings.count - 1]
        // Two lat rings + apex make a rounded fingertip.
        for phi in [Float.pi * 0.22, Float.pi * 0.38] {
            let ring = addRing(
                center: tip + axis * (tipRadius * sin(phi)),
                sAxis: sideAxis,
                tAxis: tAxis,
                sRadius: tipRadius * cos(phi),
                tRadius: tipRadius * cos(phi),
                v: v + tipRadius * sin(phi),
                coverage: coverageOffset + v + tipRadius * sin(phi),
                material: material,
                sides: sides,
                web: web,
                leanAxis: axis,
                axialLean: sin(phi)
            )
            stitch(previousRing, ring, sides: sides)
            previousRing = ring
        }
        addFan(
            apex: tip + axis * tipRadius,
            normal: axis,
            ring: previousRing,
            sides: sides,
            v: v + tipRadius,
            coverage: coverageOffset + v + tipRadius,
            material: material,
            web: web
        )
    }
}

// MARK: - Small math helpers

private func safeNormalize(
    _ vector: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let lengthSq = simd_length_squared(vector)
    guard lengthSq.isFinite, lengthSq > 1e-10 else { return fallback }
    return vector / sqrt(lengthSq)
}

private func perpendicular(to axis: SIMD3<Float>) -> SIMD3<Float> {
    let reference = abs(axis.y) < 0.9
        ? SIMD3<Float>(0, 1, 0)
        : SIMD3<Float>(1, 0, 0)
    return safeNormalize(
        simd_cross(axis, reference), fallback: SIMD3<Float>(1, 0, 0)
    )
}

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

private func mix(_ a: Float, _ b: Float, t: Float) -> Float {
    a + (b - a) * t
}

// MARK: - Shared state (game thread writes, render thread reads)

final class CoolWebGloveState: @unchecked Sendable {
    static let shared = CoolWebGloveState()

    /// A tracking blip shorter than this keeps the hand's suit-up progress.
    private static let reappearGrace: TimeInterval = 0.5
    /// The front sweeps a little past the extent so the glow band and the
    /// ragged-edge jitter fully clear the fingertips.
    private static let frontOverscan: Float = 0.015

    private struct Entry {
        var mesh: CoolWebGloveMesh
        /// 0 = bare hand … 1 = fully covered. Advances toward the suit-up
        /// target each game-thread update, so a mid-flight toggle simply
        /// reverses from wherever the front currently is.
        var progress: Float
        var lastNow: TimeInterval
        /// When the user started looking at this hand (progress 0, waiting
        /// to begin building).
        var gazeSince: TimeInterval?
        var buildDuration: Float
    }

    private let lock = NSLock()
    private var enabled = false
    /// Target state: true → gloves build on (gaze-gated), false → they
    /// retract in reverse.
    private var suitUp = false
    private var entries: [CoolWebHandSide: Entry] = [:]
    private var removedAt: [CoolWebHandSide: (time: TimeInterval, progress: Float)] = [:]

    func setEnabled(_ newValue: Bool) {
        lock.withLock {
            enabled = newValue
            if !newValue {
                entries.removeAll()
                removedAt.removeAll()
            }
        }
    }

    func setSuitUp(_ up: Bool) {
        lock.withLock {
            guard suitUp != up else { return }
            suitUp = up
            if up {
                // Each hand re-arms its own gaze trigger.
                for side in entries.keys {
                    entries[side]?.gazeSince = nil
                }
            }
        }
    }

    var isSuitUp: Bool {
        lock.withLock { suitUp }
    }

    /// Largest suit-up progress across hands — the app uses this to decide
    /// when to hide the real passthrough hands.
    func maxProgress() -> Float {
        lock.withLock { entries.values.map(\.progress).max() ?? 0 }
    }

    func update(
        side: CoolWebHandSide,
        mesh: CoolWebGloveMesh,
        lookedAt: Bool,
        buildDuration: Float,
        gazeDelay: Float,
        now: TimeInterval
    ) {
        lock.withLock {
            guard enabled else { return }
            let target: Float = suitUp ? 1 : 0
            guard var entry = entries[side] else {
                // Newly appeared. A short tracking blip resumes the previous
                // progress; otherwise the hand starts bare and waits for gaze.
                var progress: Float = 0
                if let removed = removedAt[side],
                   now - removed.time < Self.reappearGrace {
                    progress = removed.progress
                }
                removedAt[side] = nil
                entries[side] = Entry(
                    mesh: mesh,
                    progress: progress,
                    lastNow: now,
                    // The gaze timer arms from the very first looked-at frame.
                    gazeSince: (suitUp && lookedAt && progress == 0) ? now : nil,
                    buildDuration: buildDuration
                )
                return
            }
            entry.mesh = mesh
            entry.buildDuration = buildDuration
            let dt = Float(max(0, now - entry.lastNow))
            entry.lastNow = now

            if entry.progress == 0, target == 1 {
                // Bare hand waiting to build: only start once the user has
                // been looking at it for the focus delay.
                if lookedAt {
                    let since = entry.gazeSince ?? now
                    entry.gazeSince = since
                    if now - since >= TimeInterval(gazeDelay) {
                        entry.progress = 0.0001
                        entry.gazeSince = nil
                    }
                } else {
                    entry.gazeSince = nil
                }
            } else if entry.progress != target {
                let step = buildDuration > 0 ? dt / buildDuration : 1
                entry.progress = target > entry.progress
                    ? min(target, entry.progress + step)
                    : max(target, entry.progress - step)
            }
            entries[side] = entry
        }
    }

    func remove(side: CoolWebHandSide, now: TimeInterval) {
        lock.withLock {
            guard let entry = entries.removeValue(forKey: side) else { return }
            removedAt[side] = (now, entry.progress)
        }
    }

    func clear() {
        lock.withLock {
            entries.removeAll()
            removedAt.removeAll()
        }
    }

    /// Rewinds every hand to bare and re-arms the gaze triggers.
    func replayBuild(now _: TimeInterval) {
        lock.withLock {
            for side in entries.keys {
                entries[side]?.progress = 0
                entries[side]?.gazeSince = nil
            }
            removedAt.removeAll()
        }
    }

    /// Both hands combined into one vertex/index list (indices rebased), or
    /// empty arrays when disabled/bare. While a glove is partway on, the
    /// per-vertex front distance (params.w) is stamped from the eased
    /// progress; covered gloves keep the builder's sentinel untouched.
    func snapshot(
        now _: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> (vertices: [CoolWebGloveVertexGPU], indices: [UInt32]) {
        lock.withLock {
            guard enabled, !entries.isEmpty else { return ([], []) }
            var vertices: [CoolWebGloveVertexGPU] = []
            var indices: [UInt32] = []
            for side in CoolWebHandSide.allCases {
                guard let entry = entries[side], entry.progress > 0 else {
                    continue
                }
                let mesh = entry.mesh
                guard vertices.count + mesh.vertices.count
                    <= CoolWebShaderLimits.maxGloveVertices,
                    indices.count + mesh.indices.count
                    <= CoolWebShaderLimits.maxGloveIndices
                else { continue }
                let base = UInt32(vertices.count)
                if entry.progress < 1 {
                    // smoothstep easing: the front accelerates off the wrist
                    // and settles at the fingertips (mirrored on reverse).
                    let t = entry.progress
                    let eased = t * t * (3 - 2 * t)
                    let front = eased * (mesh.coverageExtent + Self.frontOverscan)
                    vertices.append(contentsOf: mesh.vertices.map {
                        var vertex = $0
                        vertex.params.w = front
                        return vertex
                    })
                } else {
                    vertices.append(contentsOf: mesh.vertices)
                }
                indices.append(contentsOf: mesh.indices.map { $0 + base })
            }
            return (vertices, indices)
        }
    }
}

// MARK: - Public API

/// Master switch for the glove system (rendering + state). Keep it on while
/// the immersive space lives; use `setCoolWebGloveSuitUp` to animate the
/// gloves on and off.
public func setCoolWebGloveEnabled(_ enabled: Bool) {
    CoolWebGloveState.shared.setEnabled(enabled)
}

/// Suit-Up target. `true`: each hand builds its glove wrist→fingertips as
/// soon as the user has looked at it for `config.suitUpGazeDelay` seconds
/// (the `lookedAt` flag passed to `updateCoolWebGlove`). `false`: gloves
/// retract with the same animation in reverse — from wherever they are, so
/// a mid-build flip just turns the front around.
public func setCoolWebGloveSuitUp(_ up: Bool) {
    CoolWebGloveState.shared.setSuitUp(up)
}

/// Largest suit-up progress across both hands (0 bare … 1 covered). The app
/// uses it to decide when to hide the real passthrough hands.
public func coolWebGloveMaxProgress() -> Float {
    CoolWebGloveState.shared.maxProgress()
}

/// Rebuilds one hand's glove from the latest pose. Call every frame from the
/// game update; pass nil (or an untracked pose) to hide that hand's glove.
/// `lookedAt` reports whether the user's gaze is on this hand — it gates
/// when a bare hand starts building.
public func updateCoolWebGlove(
    side: CoolWebHandSide,
    pose: CoolWebHandPose?,
    config: CoolWebGloveConfig = CoolWebGloveConfig(),
    lookedAt: Bool = true,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
) {
    guard let pose, pose.isTracked else {
        CoolWebGloveState.shared.remove(side: side, now: now)
        return
    }
    let mesh = CoolWebGloveBuilder.build(pose: pose, side: side, config: config)
    CoolWebGloveState.shared.update(
        side: side,
        mesh: mesh,
        lookedAt: lookedAt,
        buildDuration: config.buildDuration,
        gazeDelay: config.suitUpGazeDelay,
        now: now
    )
}

/// Rewinds both gloves to bare hands; they build again on the next gaze.
public func replayCoolWebGloveBuild(
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
) {
    CoolWebGloveState.shared.replayBuild(now: now)
}

/// Hides both gloves (e.g. on session teardown) without toggling the option.
public func clearCoolWebGloves() {
    CoolWebGloveState.shared.clear()
}
