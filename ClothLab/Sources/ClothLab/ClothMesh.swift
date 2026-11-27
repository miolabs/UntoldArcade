//
//  ClothMesh.swift
//  ClothLab
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

/// A piece of cloth as the lab simulates and draws it: one triangle mesh,
/// nothing else. The simulated mesh IS the drawn mesh here; there is no
/// render shell, no skin, no collider.
struct ClothMesh {
    var name: String
    /// Rest positions in metres, Y up.
    var positions: [SIMD3<Float>]
    var triangles: [SIMD3<Int32>]
    var uvs: [SIMD2<Float>]
    /// Particles held in place, with where they are held. A pin may sit
    /// away from the particle's rest position (a gathered curtain): the
    /// scene walks it there over the first second.
    var pins: [Int: SIMD3<Float>]
    /// The garment's flat sewing pattern, when the mesh carries one: per
    /// triangle, its three corners laid flat, in metres. The lengths in
    /// it are the fabric's own, before any drape.
    var pattern: [[SIMD2<Float>]]?
    /// Per triangle, whether it belongs to an interfaced panel (a cuff,
    /// the collar): fabric with a stiff layer fused inside.
    var interfaced: [Bool]?

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }
}

// MARK: - The plain sheet

enum SheetPin: String, CaseIterable {
    /// Five hooks along the top edge, drawn in to three quarters of the
    /// width, so the fabric between them has slack to fold with.
    case hooks
    /// The two top corners, drawn in: the classic sag.
    case corners
    /// The whole top edge where it is: a flat sheet, no folds expected.
    case edge

    var title: String {
        switch self {
        case .hooks: "Five hooks"
        case .corners: "Two corners"
        case .edge: "Whole top edge"
        }
    }
}

extension ClothMesh {
    /// A rectangular sheet standing in the XY plane, its top edge at `top`,
    /// facing +Z. `spacing` is the particle spacing; the diagonals alternate
    /// so no direction of the weave is stiffer than the other.
    static func sheet(width: Float, height: Float, spacing: Float, top: Float, pin: SheetPin) -> ClothMesh {
        let columns = max(2, Int((width / spacing).rounded())) + 1
        let rows = max(2, Int((height / spacing).rounded())) + 1
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(columns * rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let u = Float(column) / Float(columns - 1), v = Float(row) / Float(rows - 1)
                positions.append(SIMD3((u - 0.5) * width, top - v * height, 0))
                uvs.append(SIMD2(u, v))
            }
        }
        var triangles: [SIMD3<Int32>] = []
        triangles.reserveCapacity((columns - 1) * (rows - 1) * 2)
        for row in 0 ..< rows - 1 {
            for column in 0 ..< columns - 1 {
                let a = Int32(row * columns + column), b = a + 1
                let c = a + Int32(columns), d = c + 1
                // Counter-clockwise seen from +Z.
                if (row + column) % 2 == 0 {
                    triangles.append(SIMD3(a, c, d))
                    triangles.append(SIMD3(a, d, b))
                } else {
                    triangles.append(SIMD3(a, c, b))
                    triangles.append(SIMD3(b, c, d))
                }
            }
        }
        var pins: [Int: SIMD3<Float>] = [:]
        switch pin {
        case .edge:
            for column in 0 ..< columns {
                pins[column] = positions[column]
            }
        case .hooks, .corners:
            let hooks = pin == .hooks ? 5 : 2
            let gather: Float = pin == .hooks ? 0.75 : 0.8
            // A hook grips a patch of fabric, not one thread: every
            // particle within 2.5 cm of it moves with it.
            let grip: Float = 0.025
            for hook in 0 ..< hooks {
                let column = Int((Float(hook) / Float(hooks - 1) * Float(columns - 1)).rounded())
                let centre = positions[column]
                let shift = SIMD3<Float>(centre.x * (gather - 1), 0, 0)
                for (index, p) in positions.enumerated() where simd_length(p - centre) <= grip {
                    pins[index] = p + shift
                }
            }
        }
        return ClothMesh(
            name: "sheet \(columns)x\(rows)", positions: positions, triangles: triangles, uvs: uvs, pins: pins
        )
    }
}

// MARK: - The garment

enum GarmentPin: String, CaseIterable {
    /// The collar ring and the ridge of both shoulders: a shirt on a hanger.
    case shoulders
    /// The collar ring only: a shirt on a hook.
    case collar

    var title: String {
        switch self {
        case .shoulders: "Collar and shoulders"
        case .collar: "Collar only"
        }
    }
}

enum GarmentSource: String, CaseIterable {
    case proxy4k = "4k"
    case proxy16k = "16k"
    case artist
    /// The artist's mesh with every triangle cut in four: half the edge
    /// length, four times the particles.
    case artistFine = "artist4"

    var title: String {
        switch self {
        case .proxy4k: "Proxy 3,995"
        case .proxy16k: "Proxy 15,979"
        case .artist: "Artist sim mesh"
        case .artistFine: "Artist sim mesh x4"
        }
    }

    var resource: String {
        switch self {
        case .proxy4k: "shirt4k"
        case .proxy16k: "shirt16k"
        case .artist, .artistFine: "shirtArtist"
        }
    }

    var isAvailable: Bool {
        Bundle.module.url(forResource: resource, withExtension: "json", subdirectory: "Garments") != nil
    }
}

private struct GarmentFile: Decodable {
    var name: String
    var particles: [[Float]]
    var triangles: [[Int32]]
    var cookedPins: [Int]
    var pattern: [[Float]]?
    var panels: [Int]?
    var interfacedPanels: [Int]?
}

extension ClothMesh {
    /// The shirt's simulation mesh as cooked (`Tools/extract_garment.py`),
    /// in the character's bind pose, pinned for hanging. The cook's own
    /// pins (collar and cuffs) are used only to find the collar: the cuffs
    /// hang free here.
    static func garment(_ source: GarmentSource, pin: GarmentPin) -> ClothMesh? {
        if source == .artistFine {
            guard var fine = garment(.artist, pin: pin)?.subdivided() else { return nil }
            fine.name = "shirt \(source.title)"
            return fine
        }
        guard let url = Bundle.module.url(forResource: source.resource, withExtension: "json", subdirectory: "Garments"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(GarmentFile.self, from: data)
        else { return nil }
        let positions = file.particles.map { SIMD3<Float>($0[0], $0[1], $0[2]) }
        let triangles = file.triangles.map { SIMD3<Int32>($0[0], $0[1], $0[2]) }
        var mesh = ClothMesh(name: "\(file.name) \(source.title)", positions: positions, triangles: triangles, uvs: [], pins: [:])
        let (lo, hi) = mesh.bounds
        let size = hi - lo
        mesh.uvs = positions.map { SIMD2(($0.x - lo.x) / size.x, (hi.y - $0.y) / size.y) }
        if let pattern = file.pattern, pattern.count == triangles.count {
            mesh.pattern = pattern.map { [SIMD2($0[0], $0[1]), SIMD2($0[2], $0[3]), SIMD2($0[4], $0[5])] }
        }
        if let panels = file.panels, let stiff = file.interfacedPanels, panels.count == triangles.count {
            mesh.interfaced = panels.map { stiff.contains($0) }
        }

        // The collar: the cook's pins near the neck (the cuffs are the
        // cook's pins far out along the arms).
        let centreX = (lo.x + hi.x) / 2
        let collarHalfWidth: Float = 0.14
        for index in file.cookedPins where abs(positions[index].x - centreX) < collarHalfWidth {
            mesh.pins[index] = positions[index]
        }
        if pin == .shoulders {
            // The ridge of the shoulders: in every centimetre of width out
            // to the shoulder tip, the particles within a centimetre of
            // the highest one.
            let shoulderHalfWidth: Float = 0.20
            let binWidth: Float = 0.01
            var ridgeHeight: [Int: Float] = [:]
            for p in positions where abs(p.x - centreX) < shoulderHalfWidth {
                let bin = Int(((p.x - centreX) / binWidth).rounded(.down))
                ridgeHeight[bin] = max(ridgeHeight[bin] ?? -.infinity, p.y)
            }
            for (index, p) in positions.enumerated() where abs(p.x - centreX) < shoulderHalfWidth {
                let bin = Int(((p.x - centreX) / binWidth).rounded(.down))
                if let top = ridgeHeight[bin], p.y > top - 0.01 {
                    mesh.pins[index] = p
                }
            }
        }
        return mesh
    }
}

// MARK: - Finer

extension ClothMesh {
    /// Every triangle cut in four at the midpoints of its edges. The new
    /// particles sit on the old triangles (nothing is smoothed), the
    /// pattern is cut the same way, an interfaced triangle's four pieces
    /// are interfaced, and a new particle is pinned when both ends of its
    /// edge were.
    func subdivided() -> ClothMesh {
        var result = self
        var midpoints: [UInt64: Int32] = [:]
        func midpoint(_ a: Int32, _ b: Int32) -> Int32 {
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if let existing = midpoints[key] { return existing }
            let index = Int32(result.positions.count)
            result.positions.append((positions[Int(a)] + positions[Int(b)]) / 2)
            if uvs.count == positions.count { result.uvs.append((uvs[Int(a)] + uvs[Int(b)]) / 2) }
            if let pinA = pins[Int(a)], let pinB = pins[Int(b)] { result.pins[Int(index)] = (pinA + pinB) / 2 }
            midpoints[key] = index
            return index
        }
        result.triangles = []
        result.triangles.reserveCapacity(triangles.count * 4)
        var finePattern: [[SIMD2<Float>]] = []
        var fineInterfaced: [Bool] = []
        for (t, triangle) in triangles.enumerated() {
            let a = triangle.x, b = triangle.y, c = triangle.z
            let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
            result.triangles.append(contentsOf: [SIMD3(a, ab, ca), SIMD3(ab, b, bc), SIMD3(ca, bc, c), SIMD3(ab, bc, ca)])
            if let pattern {
                let pa = pattern[t][0], pb = pattern[t][1], pc = pattern[t][2]
                let pab = (pa + pb) / 2, pbc = (pb + pc) / 2, pca = (pc + pa) / 2
                finePattern.append(contentsOf: [[pa, pab, pca], [pab, pb, pbc], [pca, pbc, pc], [pab, pbc, pca]])
            }
            if let interfaced {
                fineInterfaced.append(contentsOf: [Bool](repeating: interfaced[t], count: 4))
            }
        }
        if pattern != nil { result.pattern = finePattern }
        if interfaced != nil { result.interfaced = fineInterfaced }
        return result
    }
}

// MARK: - Topology

/// The mesh's edges, and for every edge shared by two triangles the two
/// vertices across it (the pair a bending constraint holds apart).
struct ClothTopology {
    var edges: [SIMD2<Int32>] = []
    var bendPairs: [SIMD2<Int32>] = []
    /// The shared edge of each bend pair, in the same order.
    var bendEdges: [SIMD2<Int32>] = []
    /// The two triangles of each bend pair, in the same order.
    var bendTriangles: [SIMD2<Int32>] = []
    /// Edges with only one triangle: the cloth's rim.
    var boundaryEdgeCount = 0
    /// Edges with more than two triangles: a mesh fault for cloth.
    var nonManifoldEdgeCount = 0

    init(triangles: [SIMD3<Int32>]) {
        struct Key: Hashable { var a: Int32, b: Int32 }
        var opposite: [Key: [Int32]] = [:]
        var holders: [Key: [Int32]] = [:]
        var order: [Key] = []
        for (index, triangle) in triangles.enumerated() {
            let v = [triangle.x, triangle.y, triangle.z]
            for corner in 0 ..< 3 {
                let a = v[corner], b = v[(corner + 1) % 3], c = v[(corner + 2) % 3]
                let key = Key(a: min(a, b), b: max(a, b))
                if opposite[key] == nil { order.append(key) }
                opposite[key, default: []].append(c)
                holders[key, default: []].append(Int32(index))
            }
        }
        for key in order {
            edges.append(SIMD2(key.a, key.b))
            let across = opposite[key]!
            switch across.count {
            case 1: boundaryEdgeCount += 1
            case 2:
                bendPairs.append(SIMD2(across[0], across[1]))
                bendEdges.append(SIMD2(key.a, key.b))
                bendTriangles.append(SIMD2(holders[key]![0], holders[key]![1]))
            default: nonManifoldEdgeCount += 1
            }
        }
    }
}
