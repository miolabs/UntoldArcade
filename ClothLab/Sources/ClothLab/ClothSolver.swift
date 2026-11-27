//
//  ClothSolver.swift
//  ClothLab
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

/// XPBD cloth on the CPU, small steps: many substeps a frame, one pass over
/// the constraints in each (Gauss-Seidel, so a correction is seen by the
/// next constraint at once). Two constraint families and nothing else:
///
/// - stretch: every mesh edge keeps its rest length;
/// - bend: across every edge shared by two triangles, the two far vertices
///   keep their rest distance.
///
/// No skin targets, no back-stop, no colliders: those are later steps of
/// the lab, each added alone. Masses are lumped from the triangle areas
/// and scaled to a mean of one, so the compliances read on the same scale
/// as CoolCloth's presets.
final class ClothSolver {
    struct Parameters {
        var substeps = 32
        var gravity = SIMD3<Float>(0, -9.81, 0)
        /// Inverse stiffness of the edges; zero is inextensible.
        var stretchCompliance: Float = 1e-7
        /// Inverse stiffness against folding; higher folds more easily.
        var bendCompliance: Float = 2e-3
        /// Share of the velocity lost per second (air).
        var damping: Float = 0.6
        /// What the edges and the bending pull towards.
        var restShape = RestShape.draped
        /// How many times stiffer against folding the interfaced panels
        /// (cuffs, collar) are than the rest; 1 is no interfacing.
        var interfacing: Float = 1
    }

    /// The shape the cloth remembers: what its edges and its bending pull
    /// towards when nothing else acts.
    enum RestShape: String, CaseIterable {
        /// The mesh as it was given: every wrinkle of the artist's drape is
        /// a shape the cloth springs back to.
        case draped
        /// The edge lengths of the given mesh, but flat bending: across
        /// every edge the two triangles want to lie in one plane.
        case flat
        /// The garment's flat sewing pattern: every edge has the length it
        /// has in the pattern, and the bending is flat. Fabric with no
        /// memory of the drape at all. Needs a mesh that carries its
        /// pattern; without one it is the same as `flat`.
        case pattern

        var title: String {
            switch self {
            case .draped: "As draped"
            case .flat: "Flat bending"
            case .pattern: "Flat pattern"
            }
        }
    }

    var parameters: Parameters
    private(set) var positions: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    private var velocities: [SIMD3<Float>]
    private var inverseMass: [Float]
    private let edges: [SIMD2<Int32>]
    private let edgeRest: [Float]
    private let bends: [SIMD2<Int32>]
    private let bendRest: [Float]
    /// Per bend pair, what its compliance is multiplied by (below one in
    /// the interfaced panels).
    private var bendSoftness: [Float]
    /// Pinned particles and where each is held; the scene may move them.
    private var pinIndices: [Int] = []
    private var pinTargets: [SIMD3<Float>] = []

    var particleCount: Int { positions.count }
    var constraintCount: Int { edges.count + bends.count }

    init(mesh: ClothMesh, topology: ClothTopology, parameters: Parameters = Parameters(), startUnevenness: Float = 0.0005) {
        self.parameters = parameters
        positions = mesh.positions
        previous = mesh.positions
        velocities = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)

        // Lumped masses: a third of every triangle's area to each corner.
        var area = [Float](repeating: 0, count: mesh.positions.count)
        for triangle in mesh.triangles {
            let a = mesh.positions[Int(triangle.x)], b = mesh.positions[Int(triangle.y)], c = mesh.positions[Int(triangle.z)]
            let third = simd_length(simd_cross(b - a, c - a)) / 6
            area[Int(triangle.x)] += third
            area[Int(triangle.y)] += third
            area[Int(triangle.z)] += third
        }
        let mean = max(area.reduce(0, +) / Float(max(area.count, 1)), 1e-12)
        inverseMass = area.map { $0 > 0 ? mean / $0 : 0 }

        // The rest length of an edge: its length on the body as given, or
        // (rest shape `pattern`) its length in the flat pattern, averaged
        // over the one or two triangles that hold it (the two sides of a
        // seam are cut separately and may differ by a hair).
        var patternLength: [UInt64: (sum: Float, count: Float)] = [:]
        func key(_ i: Int32, _ j: Int32) -> UInt64 { UInt64(min(i, j)) << 32 | UInt64(max(i, j)) }
        if parameters.restShape == .pattern, let pattern = mesh.pattern {
            for (triangle, corners) in zip(mesh.triangles, pattern) {
                let v = [triangle.x, triangle.y, triangle.z]
                for k in 0 ..< 3 {
                    let length = simd_length(corners[k] - corners[(k + 1) % 3])
                    let entry = patternLength[key(v[k], v[(k + 1) % 3])] ?? (0, 0)
                    patternLength[key(v[k], v[(k + 1) % 3])] = (entry.sum + length, entry.count + 1)
                }
            }
        }
        func restLength(_ i: Int32, _ j: Int32) -> Float {
            if let entry = patternLength[key(i, j)] { return entry.sum / entry.count }
            return simd_length(mesh.positions[Int(i)] - mesh.positions[Int(j)])
        }

        edges = topology.edges
        edgeRest = topology.edges.map { restLength($0.x, $0.y) }
        bends = topology.bendPairs
        switch parameters.restShape {
        case .draped:
            bendRest = topology.bendPairs.map { simd_length(mesh.positions[Int($0.x)] - mesh.positions[Int($0.y)]) }
        case .flat, .pattern:
            // The two triangles unfolded into one plane about their shared
            // edge a-b: c on one side, d on the other, each placed by its
            // two rest lengths.
            bendRest = zip(topology.bendPairs, topology.bendEdges).map { pair, edge in
                let ab = restLength(edge.x, edge.y)
                guard ab > 1e-9 else { return restLength(pair.x, pair.y) }
                func place(_ toA: Float, _ toB: Float) -> SIMD2<Float> {
                    let along = (toA * toA - toB * toB + ab * ab) / (2 * ab)
                    return SIMD2(along, max(toA * toA - along * along, 0).squareRoot())
                }
                let c = place(restLength(edge.x, pair.x), restLength(edge.y, pair.x))
                let d = place(restLength(edge.x, pair.y), restLength(edge.y, pair.y))
                return simd_length(SIMD2(c.x - d.x, c.y + d.y))
            }
        }

        // Bending inside an interfaced panel is stiffer by the factor.
        if parameters.interfacing > 1, let interfaced = mesh.interfaced {
            bendSoftness = topology.bendTriangles.map {
                interfaced[Int($0.x)] && interfaced[Int($0.y)] ? 1 / parameters.interfacing : 1
            }
        } else {
            bendSoftness = []
        }

        // A sheet that starts perfectly flat can never leave its plane:
        // every correction lies in it, so compressed cloth folds over
        // itself inside the plane instead of wrinkling out of it. Real
        // fabric is never that flat; the start gets a fraction of a
        // millimetre of unevenness along the normals (the rest lengths
        // stay those of the flat mesh).
        if startUnevenness > 0 {
            var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
            for triangle in mesh.triangles {
                let a = Int(triangle.x), b = Int(triangle.y), c = Int(triangle.z)
                let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
                normals[a] += face
                normals[b] += face
                normals[c] += face
            }
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for i in positions.indices where simd_length(normals[i]) > 0 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Float(state >> 40) / Float(1 << 24) * 2 - 1
                positions[i] += simd_normalize(normals[i]) * (unit * startUnevenness)
            }
            previous = positions
        }

        // A pin held away from its rest position (a gathered curtain) is
        // walked there by the substeps, not teleported.
        for (index, target) in mesh.pins.sorted(by: { $0.key < $1.key }) {
            pinIndices.append(index)
            pinTargets.append(target)
            inverseMass[index] = 0
        }
    }

    var pinnedParticles: [Int] { pinIndices }

    func step(deltaTime: Float) {
        let substeps = max(parameters.substeps, 1)
        let h = deltaTime / Float(substeps)
        let gravityStep = parameters.gravity * h
        let keep = max(0, 1 - parameters.damping * h)
        let stretchAlpha = parameters.stretchCompliance / (h * h)
        let bendAlpha = parameters.bendCompliance / (h * h)
        let count = positions.count

        positions.withUnsafeMutableBufferPointer { x in
            previous.withUnsafeMutableBufferPointer { p in
                velocities.withUnsafeMutableBufferPointer { v in
                    inverseMass.withUnsafeBufferPointer { w in
                        for _ in 0 ..< substeps {
                            // Predict.
                            for i in 0 ..< count where w[i] > 0 {
                                v[i] = (v[i] + gravityStep) * keep
                                p[i] = x[i]
                                x[i] += v[i] * h
                            }
                            // Pins are moved towards their targets a little
                            // each substep, never teleported.
                            for (slot, i) in pinIndices.enumerated() {
                                p[i] = x[i]
                                let toTarget = pinTargets[slot] - x[i]
                                let reach = simd_length(toTarget)
                                let stride: Float = 0.4 * h // 0.4 m/s
                                x[i] = reach <= stride ? pinTargets[slot] : x[i] + toTarget * (stride / reach)
                            }
                            // Solve, always in the same order. (Alternating
                            // the sweep direction was tried and is wrong
                            // here: the two orders settle a hair apart, and
                            // a velocity taken from the position change
                            // turns that hair into speed every substep.)
                            Self.solve(edges, rest: edgeRest, alpha: stretchAlpha, softness: [], x: x, w: w)
                            Self.solve(bends, rest: bendRest, alpha: bendAlpha, softness: bendSoftness, x: x, w: w)
                            // Velocities from the motion that survived.
                            let inverseH = 1 / h
                            for i in 0 ..< count where w[i] > 0 {
                                v[i] = (x[i] - p[i]) * inverseH
                            }
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    private static func solve(
        _ pairs: [SIMD2<Int32>], rest: [Float], alpha: Float, softness: [Float],
        x: UnsafeMutableBufferPointer<SIMD3<Float>>, w: UnsafeBufferPointer<Float>
    ) {
        pairs.withUnsafeBufferPointer { pairs in
            rest.withUnsafeBufferPointer { rest in
                let uniform = softness.isEmpty
                for k in 0 ..< pairs.count {
                    let i = Int(pairs[k].x), j = Int(pairs[k].y)
                    let wSum = w[i] + w[j]
                    if wSum == 0 { continue }
                    let d = x[i] - x[j]
                    let length = simd_length(d)
                    if length < 1e-9 { continue }
                    let lambda = -(length - rest[k]) / (wSum + (uniform ? alpha : alpha * softness[k]))
                    let correction = d * (lambda / length)
                    x[i] += correction * w[i]
                    x[j] -= correction * w[j]
                }
            }
        }
    }

    // MARK: - Readouts

    /// How far the edges are from their rest length right now: the mean
    /// and the worst, as a ratio (0.03 = three per cent long).
    func stretch() -> (mean: Float, worst: Float) {
        var sum: Float = 0, worst: Float = 0
        for (k, edge) in edges.enumerated() where edgeRest[k] > 0 {
            let ratio = simd_length(positions[Int(edge.x)] - positions[Int(edge.y)]) / edgeRest[k] - 1
            sum += abs(ratio)
            worst = max(worst, abs(ratio))
        }
        return (edges.isEmpty ? 0 : sum / Float(edges.count), worst)
    }

    /// Mean particle speed, to tell a settled cloth from a moving one.
    func meanSpeed() -> Float {
        guard !velocities.isEmpty else { return 0 }
        return velocities.reduce(0) { $0 + simd_length($1) } / Float(velocities.count)
    }
}
