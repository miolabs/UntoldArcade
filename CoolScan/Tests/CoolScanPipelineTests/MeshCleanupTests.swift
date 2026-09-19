@testable import CoolScanPipeline
import simd
import XCTest

final class MeshCleanupTests: XCTestCase {
    /// A flat grid in the XZ plane with per-vertex Y noise, split into two
    /// UV islands (duplicated vertices along the middle column) so the
    /// seam-welding path is exercised.
    private func makeNoisyGrid(size: Int, noise: Float) -> ExtractedMesh {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var generator = SystemRandomNumberGenerator()

        func vertexIndex(_ x: Int, _ z: Int, island: Int) -> UInt32 {
            // Middle column is duplicated per island (a UV seam).
            let column = island == 0 ? x : x + (size + 1)
            return UInt32(z * (2 * (size + 1)) + column)
        }

        for z in 0 ... size {
            for island in 0 ..< 2 {
                for x in 0 ... size {
                    let jitter = Float.random(in: -noise ... noise, using: &generator)
                    positions.append(SIMD3<Float>(Float(x), jitter, Float(z)))
                }
            }
        }

        // Both islands describe the same full grid; use island 0 for the
        // left half and island 1 for the right half so the seam column is
        // referenced by both.
        for z in 0 ..< size {
            for x in 0 ..< size {
                let island = x < size / 2 ? 0 : 1
                let a = vertexIndex(x, z, island: island)
                let b = vertexIndex(x + 1, z, island: island)
                let c = vertexIndex(x, z + 1, island: island)
                let d = vertexIndex(x + 1, z + 1, island: island)
                indices += [a, c, b, b, c, d]
            }
        }
        // Make the seam column share positions across islands.
        let seam = size / 2
        for z in 0 ... size {
            let left = Int(vertexIndex(seam, z, island: 0))
            let right = Int(vertexIndex(seam, z, island: 1))
            positions[right] = positions[left]
        }

        let count = positions.count
        return ExtractedMesh(
            name: "grid",
            positions: positions,
            normals: Array(repeating: SIMD3<Float>(0, 1, 0), count: count),
            uvs: Array(repeating: .zero, count: count),
            tangents: Array(repeating: SIMD4<Float>(1, 0, 0, 1), count: count),
            submeshes: [ExtractedSubmesh(indices: indices, material: ExtractedMaterial())],
            worldTransform: matrix_identity_float4x4
        )
    }

    func testIslandRemovalDropsSpeckleButKeepsSmallRealParts() {
        var mesh = makeNoisyGrid(size: 20, noise: 0)
        let before = mesh.submeshes[0].indices.count / 3

        // One floating triangle far away (speckle) ...
        let base = UInt32(mesh.positions.count)
        mesh.positions += [
            SIMD3<Float>(100, 100, 100), SIMD3<Float>(101, 100, 100), SIMD3<Float>(100, 101, 100),
        ]
        mesh.normals += Array(repeating: SIMD3<Float>(0, 0, 1), count: 3)
        mesh.uvs += Array(repeating: .zero, count: 3)
        mesh.tangents += Array(repeating: SIMD4<Float>(1, 0, 0, 1), count: 3)
        mesh.submeshes[0].indices += [base, base + 1, base + 2]

        var options = MeshCleanupOptions()
        options.smoothingIterations = 0
        options.recomputeNormals = false
        options.islandMinimumFraction = 0.01 // 1% of ~800 triangles = 8
        MeshCleanup.apply(&mesh, options: options)

        XCTAssertEqual(mesh.submeshes[0].indices.count / 3, before, "speckle triangle should be gone, grid intact")
    }

    func testSmoothingReducesNoiseWithoutTearingSeams() {
        var mesh = makeNoisyGrid(size: 20, noise: 0.2)
        // Only referenced vertices take part in smoothing (the test grid
        // carries unreferenced duplicates per UV island).
        let referenced = Array(Set(mesh.submeshes[0].indices.map(Int.init)))
        func yVariance(_ m: ExtractedMesh) -> Float {
            let ys = referenced.map { m.positions[$0].y }
            let mean = ys.reduce(0, +) / Float(ys.count)
            return ys.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(ys.count)
        }
        let before = yVariance(mesh)

        var options = MeshCleanupOptions()
        options.islandMinimumFraction = 0
        options.recomputeNormals = false
        options.smoothingIterations = 6
        MeshCleanup.apply(&mesh, options: options)

        XCTAssertLessThan(yVariance(mesh), before * 0.5, "Taubin passes should average out the jitter")

        // Seam duplicates must still coincide after smoothing.
        let size = 20, seam = 10
        for z in 0 ... size {
            let left = z * (2 * (size + 1)) + seam
            let right = z * (2 * (size + 1)) + seam + (size + 1)
            XCTAssertEqual(mesh.positions[left], mesh.positions[right])
        }
    }

    func testRecomputedNormalsAreUnitAndSeamConsistent() {
        var mesh = makeNoisyGrid(size: 10, noise: 0.05)
        // Scramble the incoming normals; cleanup must not trust them.
        mesh.normals = mesh.normals.map { _ in SIMD3<Float>(1, 0, 0) }

        var options = MeshCleanupOptions()
        options.islandMinimumFraction = 0
        options.smoothingIterations = 0
        options.recomputeNormals = true
        MeshCleanup.apply(&mesh, options: options)

        // The test grid carries unreferenced duplicate vertices (the unused
        // half of each UV island); only referenced vertices get recomputed.
        let referenced = Set(mesh.submeshes[0].indices.map(Int.init))
        XCTAssertFalse(referenced.isEmpty)
        for i in referenced {
            let normal = mesh.normals[i]
            XCTAssertEqual(simd_length(normal), 1, accuracy: 1e-4)
            XCTAssertGreaterThan(normal.y, 0.8, "a near-flat grid should point up")
        }
        let size = 10, seam = 5
        for z in 0 ... size {
            let left = z * (2 * (size + 1)) + seam
            let right = z * (2 * (size + 1)) + seam + (size + 1)
            XCTAssertEqual(mesh.normals[left], mesh.normals[right])
        }
        for i in referenced {
            let tangent = mesh.tangents[i]
            XCTAssertEqual(simd_length(SIMD3<Float>(tangent.x, tangent.y, tangent.z)), 1, accuracy: 1e-4)
            XCTAssertEqual(simd_dot(SIMD3<Float>(tangent.x, tangent.y, tangent.z), mesh.normals[i]), 0, accuracy: 1e-4)
        }
    }

    func testNoneOptionsLeaveMeshUntouched() {
        var mesh = makeNoisyGrid(size: 8, noise: 0.3)
        let positions = mesh.positions, normals = mesh.normals, indices = mesh.submeshes[0].indices
        MeshCleanup.apply(&mesh, options: .none)
        XCTAssertEqual(mesh.positions, positions)
        XCTAssertEqual(mesh.normals, normals)
        XCTAssertEqual(mesh.submeshes[0].indices, indices)
    }
}
