import Foundation
import simd

/// Tunable cleanup applied to scanned meshes before they are cooked.
public struct MeshCleanupOptions: Sendable {
    /// Drop connected components smaller than this fraction of the mesh's
    /// triangles. Photogrammetry leaves floating speckle and floor crumbs;
    /// this removes them without touching real parts (casters, knobs).
    public var islandMinimumFraction: Float = 0.001
    /// Taubin smoothing passes (0 disables). Each pass is one shrink +
    /// one inflate step, so the shape's volume is preserved while the
    /// per-vertex reconstruction noise is averaged out.
    public var smoothingIterations: Int = 4
    public var smoothingLambda: Float = 0.5
    public var smoothingMu: Float = -0.53
    /// Recompute area-weighted vertex normals across UV seams after
    /// smoothing. Scan normals are as noisy as the positions; smooth
    /// normals are what stops flat shading from looking lumpy.
    public var recomputeNormals: Bool = true

    public init() {}

    /// Leaves the mesh exactly as the reconstruction produced it.
    public static let none: MeshCleanupOptions = {
        var options = MeshCleanupOptions()
        options.islandMinimumFraction = 0
        options.smoothingIterations = 0
        options.recomputeNormals = false
        return options
    }()
}

/// Deterministic geometry cleanup for photogrammetry output.
///
/// Photogrammetry meshes split vertices at UV seams, so every step works on
/// *welded* vertices (clustered by position) and writes results back to
/// every duplicate — otherwise smoothing tears seams open and normals show
/// hard lines along texture islands.
enum MeshCleanup {
    static func apply(_ mesh: inout ExtractedMesh, options: MeshCleanupOptions) {
        guard !mesh.positions.isEmpty else { return }
        let weld = weldVertices(mesh.positions)

        if options.islandMinimumFraction > 0 {
            removeIslands(&mesh, weld: weld, minimumFraction: options.islandMinimumFraction)
        }
        if options.smoothingIterations > 0 {
            smooth(
                &mesh, weld: weld,
                iterations: options.smoothingIterations,
                lambda: options.smoothingLambda,
                mu: options.smoothingMu
            )
        }
        if options.recomputeNormals {
            recomputeNormals(&mesh, weld: weld)
        }
    }

    // MARK: - Welding

    struct Weld {
        /// Cluster id per original vertex.
        let cluster: [Int]
        let clusterCount: Int
    }

    static func weldVertices(_ positions: [SIMD3<Float>]) -> Weld {
        // Quantize to a grid far below reconstruction accuracy (0.01 mm at
        // metre scale) so seam duplicates collapse but real neighbours don't.
        let inverseCell: Float = 100_000
        var clusterByKey: [SIMD3<Int32>: Int] = [:]
        var cluster = [Int](repeating: 0, count: positions.count)
        var next = 0
        for (i, p) in positions.enumerated() {
            let key = SIMD3<Int32>(
                Int32((p.x * inverseCell).rounded()),
                Int32((p.y * inverseCell).rounded()),
                Int32((p.z * inverseCell).rounded())
            )
            if let existing = clusterByKey[key] {
                cluster[i] = existing
            } else {
                clusterByKey[key] = next
                cluster[i] = next
                next += 1
            }
        }
        return Weld(cluster: cluster, clusterCount: next)
    }

    // MARK: - Islands

    private static func removeIslands(_ mesh: inout ExtractedMesh, weld: Weld, minimumFraction: Float) {
        // Union-find over welded vertices, joined by triangles.
        var parent = Array(0 ..< weld.clusterCount)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        var totalTriangles = 0
        for submesh in mesh.submeshes {
            let indices = submesh.indices
            totalTriangles += indices.count / 3
            var i = 0
            while i + 2 < indices.count {
                let a = weld.cluster[Int(indices[i])]
                let b = weld.cluster[Int(indices[i + 1])]
                let c = weld.cluster[Int(indices[i + 2])]
                union(a, b)
                union(a, c)
                i += 3
            }
        }
        guard totalTriangles > 0 else { return }

        var trianglesPerComponent: [Int: Int] = [:]
        for submesh in mesh.submeshes {
            let indices = submesh.indices
            var i = 0
            while i + 2 < indices.count {
                let root = find(weld.cluster[Int(indices[i])])
                trianglesPerComponent[root, default: 0] += 1
                i += 3
            }
        }

        let minimum = max(1, Int((Float(totalTriangles) * minimumFraction).rounded()))
        // Never remove the largest component even if the mesh is tiny.
        let largest = trianglesPerComponent.max { $0.value < $1.value }?.key
        let keep = Set(trianglesPerComponent.filter { $0.value >= minimum || $0.key == largest }.map(\.key))

        for s in mesh.submeshes.indices {
            let indices = mesh.submeshes[s].indices
            var kept: [UInt32] = []
            kept.reserveCapacity(indices.count)
            var i = 0
            while i + 2 < indices.count {
                if keep.contains(find(weld.cluster[Int(indices[i])])) {
                    kept.append(indices[i])
                    kept.append(indices[i + 1])
                    kept.append(indices[i + 2])
                }
                i += 3
            }
            mesh.submeshes[s].indices = kept
        }
        mesh.submeshes.removeAll { $0.indices.isEmpty }
    }

    // MARK: - Smoothing

    private static func neighbours(of mesh: ExtractedMesh, weld: Weld) -> [Set<Int>] {
        var neighbours = [Set<Int>](repeating: [], count: weld.clusterCount)
        for submesh in mesh.submeshes {
            let indices = submesh.indices
            var i = 0
            while i + 2 < indices.count {
                let a = weld.cluster[Int(indices[i])]
                let b = weld.cluster[Int(indices[i + 1])]
                let c = weld.cluster[Int(indices[i + 2])]
                neighbours[a].insert(b); neighbours[a].insert(c)
                neighbours[b].insert(a); neighbours[b].insert(c)
                neighbours[c].insert(a); neighbours[c].insert(b)
                i += 3
            }
        }
        return neighbours
    }

    private static func smooth(
        _ mesh: inout ExtractedMesh, weld: Weld,
        iterations: Int, lambda: Float, mu: Float
    ) {
        let neighbours = neighbours(of: mesh, weld: weld)

        // One representative position per cluster.
        var clusterPosition = [SIMD3<Float>](repeating: .zero, count: weld.clusterCount)
        for (i, c) in weld.cluster.enumerated() {
            clusterPosition[c] = mesh.positions[i]
        }

        func step(_ factor: Float) {
            var next = clusterPosition
            for c in 0 ..< weld.clusterCount {
                let n = neighbours[c]
                guard !n.isEmpty else { continue }
                var centroid = SIMD3<Float>.zero
                for other in n { centroid += clusterPosition[other] }
                centroid /= Float(n.count)
                next[c] = clusterPosition[c] + factor * (centroid - clusterPosition[c])
            }
            clusterPosition = next
        }

        for _ in 0 ..< iterations {
            step(lambda)
            step(mu)
        }

        for i in mesh.positions.indices {
            mesh.positions[i] = clusterPosition[weld.cluster[i]]
        }
    }

    // MARK: - Normals

    private static func recomputeNormals(_ mesh: inout ExtractedMesh, weld: Weld) {
        var accumulated = [SIMD3<Float>](repeating: .zero, count: weld.clusterCount)
        for submesh in mesh.submeshes {
            let indices = submesh.indices
            var i = 0
            while i + 2 < indices.count {
                let ia = Int(indices[i]), ib = Int(indices[i + 1]), ic = Int(indices[i + 2])
                let a = mesh.positions[ia], b = mesh.positions[ib], c = mesh.positions[ic]
                // Cross product magnitude = 2 × area: area weighting for free.
                let faceNormal = simd_cross(b - a, c - a)
                accumulated[weld.cluster[ia]] += faceNormal
                accumulated[weld.cluster[ib]] += faceNormal
                accumulated[weld.cluster[ic]] += faceNormal
                i += 3
            }
        }

        for i in mesh.positions.indices {
            let n = accumulated[weld.cluster[i]]
            let length = simd_length(n)
            let normal = length > 1e-12 ? n / length : mesh.normals[i]
            mesh.normals[i] = normal

            // Keep the tangent orthogonal to the new normal.
            let t = mesh.tangents[i]
            var tangent = SIMD3<Float>(t.x, t.y, t.z)
            tangent -= normal * simd_dot(normal, tangent)
            let tLength = simd_length(tangent)
            if tLength > 1e-6 {
                tangent /= tLength
                mesh.tangents[i] = SIMD4<Float>(tangent, t.w)
            }
        }
    }
}
