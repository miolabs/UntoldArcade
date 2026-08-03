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
    public var fingerRadii: [Float] = [0.0105, 0.0095, 0.0095, 0.009, 0.0082]
    /// Extra radius so the glove sits over the real finger, not inside it.
    public var fabricPadding: Float = 0.0015
    /// Palm half-thickness at the wrist end / at the knuckle end.
    public var palmHalfThicknessWrist: Float = 0.015
    public var palmHalfThicknessKnuckles: Float = 0.012
    /// How far the cuff extends behind the wrist toward the forearm.
    public var cuffLength: Float = 0.055
    /// Whether the metal web-shooter barrel is added on the inner wrist.
    public var showWebShooter = true

    public init() {}
}

/// One frame of glove geometry, ready for the GPU.
public struct CoolWebGloveMesh: Sendable, Equatable {
    public var vertices: [CoolWebGloveVertexGPU] = []
    public var indices: [UInt32] = []

    public init() {}
}

public enum CoolWebGloveMaterial {
    public static let fabric: Float = 0
    public static let metal: Float = 1
}

// MARK: - Builder

public enum CoolWebGloveBuilder {
    /// Builds the world-space glove mesh for one tracked hand pose.
    public static func build(
        pose: CoolWebHandPose,
        side: CoolWebHandSide,
        config: CoolWebGloveConfig = CoolWebGloveConfig()
    ) -> CoolWebGloveMesh {
        var accumulator = GloveMeshAccumulator()

        // Palm frame from the joint cloud (no orientation data in the pose):
        // forward = wrist → knuckle line, lateral = index → little knuckles,
        // back-of-hand normal = their cross product, flipped per chirality.
        guard pose.index.points.count >= 5,
              pose.little.points.count >= 5,
              pose.middle.points.count >= 5,
              pose.ring.points.count >= 5,
              pose.thumb.points.count >= 5
        else { return CoolWebGloveMesh() }

        let wrist = pose.wrist
        let indexKnuckle = pose.index.points[1]
        let littleKnuckle = pose.little.points[1]
        let knuckleCenter = (indexKnuckle + littleKnuckle) * 0.5

        let forward = safeNormalize(
            knuckleCenter - wrist, fallback: SIMD3<Float>(0, 0, -1)
        )
        var lateral = safeNormalize(
            littleKnuckle - indexKnuckle, fallback: SIMD3<Float>(1, 0, 0)
        )
        // Ring planes must be perpendicular to the palm axis.
        lateral = safeNormalize(
            lateral - forward * simd_dot(lateral, forward),
            fallback: perpendicular(to: forward)
        )
        let backNormal = safeNormalize(
            side == .right
                ? simd_cross(lateral, forward)
                : simd_cross(forward, lateral),
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let palmNormal = -backNormal

        // MARK: cuff → palm loft (one flattened elliptical tube)
        let knuckleHalfWidth = simd_length(littleKnuckle - indexKnuckle) * 0.5
            + (config.fingerRadii[1] + config.fabricPadding) * 1.35
        let wristHalfWidth = knuckleHalfWidth * 0.80
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
                material: CoolWebGloveMaterial.fabric,
                sides: config.radialSides
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
            material: CoolWebGloveMaterial.fabric
        )
        accumulator.addFan(
            apex: lastRingInfo.center,
            normal: forward,
            ring: palmRings[palmRings.count - 1],
            sides: config.radialSides,
            v: config.cuffLength + palmLength,
            material: CoolWebGloveMaterial.fabric
        )

        // MARK: fingers
        // Taper multipliers root → tip; the root station sits back along the
        // metacarpal so the tube disappears into the palm loft with no gap.
        let taper: [Float] = [1.18, 1.08, 1.0, 0.93, 0.85]
        let chains = [pose.thumb, pose.index, pose.middle, pose.ring, pose.little]
        for (fingerIndex, chain) in chains.enumerated() {
            let baseRadius = config.fingerRadii[
                min(fingerIndex, config.fingerRadii.count - 1)
            ] + config.fabricPadding
            let points = chain.points
            // Thumb chain starts at the wrist; sink its root deeper so the
            // fat thumb base blends into the palm side.
            let rootBias: Float = fingerIndex == 0 ? 0.30 : 0.55
            var stations = [mix(points[0], points[1], t: rootBias)]
            stations.append(contentsOf: points[1...4])
            let radii = taper.map { $0 * baseRadius }
            accumulator.addTube(
                stations: stations,
                radii: radii,
                referenceSide: lateral,
                material: CoolWebGloveMaterial.fabric,
                sides: config.radialSides,
                capEnd: true
            )
        }

        // MARK: web-shooter barrel (metal, inner wrist — where strands fire)
        if config.showWebShooter {
            let barrelCenter = wrist
                + palmNormal * (config.palmHalfThicknessWrist + 0.006)
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
                    tAxis: palmNormal,
                    sRadius: station.a,
                    tRadius: station.b,
                    v: station.d + 0.016,
                    material: CoolWebGloveMaterial.metal,
                    sides: config.radialSides
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
                material: CoolWebGloveMaterial.metal
            )
            accumulator.addFan(
                apex: barrelCenter + forward * barrelStations[2].d,
                normal: forward,
                ring: barrelRings[2],
                sides: config.radialSides,
                v: 0.05,
                material: CoolWebGloveMaterial.metal
            )
        }

        var mesh = CoolWebGloveMesh()
        mesh.vertices = accumulator.vertices
        mesh.indices = accumulator.indices
        return mesh
    }
}

// MARK: - Mesh accumulator

private struct GloveMeshAccumulator {
    var vertices: [CoolWebGloveVertexGPU] = []
    var indices: [UInt32] = []

    /// Adds one elliptical ring in the (sAxis, tAxis) plane. `axialLean`
    /// tilts the normals toward `leanAxis` for hemisphere cap rings.
    /// Returns the index of the ring's first vertex.
    mutating func addRing(
        center: SIMD3<Float>,
        sAxis: SIMD3<Float>,
        tAxis: SIMD3<Float>,
        sRadius: Float,
        tRadius: Float,
        v: Float,
        material: Float,
        sides: Int,
        leanAxis: SIMD3<Float> = .zero,
        axialLean: Float = 0
    ) -> Int {
        let base = vertices.count
        let meanRadius = (sRadius + tRadius) * 0.5
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
            vertex.params = SIMD4<Float>(material, meanRadius, 0, 0)
            vertices.append(vertex)
        }
        return base
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
        material: Float
    ) {
        var apexVertex = CoolWebGloveVertexGPU()
        apexVertex.position = SIMD4<Float>(apex, 0)
        apexVertex.normal = SIMD4<Float>(normal, v)
        apexVertex.params = SIMD4<Float>(material, 0.01, 0, 0)
        let apexIndex = UInt32(vertices.count)
        vertices.append(apexVertex)
        for k in 0 ..< sides {
            let k2 = (k + 1) % sides
            indices.append(contentsOf: [apexIndex, UInt32(ring + k), UInt32(ring + k2)])
        }
    }

    /// A tapered tube along `stations` with parallel-transported ring frames
    /// (no twist), optionally closed with a hemisphere cap at the last station.
    mutating func addTube(
        stations: [SIMD3<Float>],
        radii: [Float],
        referenceSide: SIMD3<Float>,
        material: Float,
        sides: Int,
        capEnd: Bool
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
                material: material,
                sides: sides
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
                material: material,
                sides: sides,
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
            material: material
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

    private let lock = NSLock()
    private var enabled = false
    private var meshes: [CoolWebHandSide: CoolWebGloveMesh] = [:]

    func setEnabled(_ newValue: Bool) {
        lock.withLock {
            enabled = newValue
            if !newValue { meshes.removeAll() }
        }
    }

    func update(side: CoolWebHandSide, mesh: CoolWebGloveMesh) {
        lock.withLock {
            guard enabled else { return }
            meshes[side] = mesh
        }
    }

    func remove(side: CoolWebHandSide) {
        lock.withLock { _ = meshes.removeValue(forKey: side) }
    }

    func clear() {
        lock.withLock { meshes.removeAll() }
    }

    /// Both hands combined into one vertex/index list (indices rebased), or
    /// empty arrays when disabled/untracked. Respects the shader limits.
    func snapshot() -> (vertices: [CoolWebGloveVertexGPU], indices: [UInt32]) {
        lock.withLock {
            guard enabled, !meshes.isEmpty else { return ([], []) }
            var vertices: [CoolWebGloveVertexGPU] = []
            var indices: [UInt32] = []
            for side in CoolWebHandSide.allCases {
                guard let mesh = meshes[side] else { continue }
                guard vertices.count + mesh.vertices.count
                    <= CoolWebShaderLimits.maxGloveVertices,
                    indices.count + mesh.indices.count
                    <= CoolWebShaderLimits.maxGloveIndices
                else { continue }
                let base = UInt32(vertices.count)
                vertices.append(contentsOf: mesh.vertices)
                indices.append(contentsOf: mesh.indices.map { $0 + base })
            }
            return (vertices, indices)
        }
    }
}

// MARK: - Public API

/// Shows/hides the Spider-Man glove over the tracked hands. When enabled the
/// example app should also hide the passthrough hands
/// (`.upperLimbVisibility(.hidden)`) so the glove replaces them.
public func setCoolWebGloveEnabled(_ enabled: Bool) {
    CoolWebGloveState.shared.setEnabled(enabled)
}

/// Rebuilds one hand's glove from the latest pose. Call every frame from the
/// game update; pass nil (or an untracked pose) to hide that hand's glove.
public func updateCoolWebGlove(
    side: CoolWebHandSide,
    pose: CoolWebHandPose?,
    config: CoolWebGloveConfig = CoolWebGloveConfig()
) {
    guard let pose, pose.isTracked else {
        CoolWebGloveState.shared.remove(side: side)
        return
    }
    let mesh = CoolWebGloveBuilder.build(pose: pose, side: side, config: config)
    CoolWebGloveState.shared.update(side: side, mesh: mesh)
}

/// Hides both gloves (e.g. on session teardown) without toggling the option.
public func clearCoolWebGloves() {
    CoolWebGloveState.shared.clear()
}
