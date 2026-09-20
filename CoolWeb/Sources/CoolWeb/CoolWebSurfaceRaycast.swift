import Foundation
import simd

/// A real-world surface point a web can attach to.
public struct CoolWebSurfaceHit: Sendable, Equatable {
    public var position: SIMD3<Float>
    /// Unit normal facing the shooter (flipped if the triangle faces away).
    public var normal: SIMD3<Float>
    public var distance: Float

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, distance: Float) {
        self.position = position
        self.normal = normal
        self.distance = distance
    }
}

/// CPU copies of the ARKit scene-reconstruction meshes, in world space, so a
/// fired web can raycast against arbitrary room geometry (not just detected
/// planes). Updated per mesh anchor by `CoolWebSpatialSession`; queried only on
/// fire events, so a linear triangle sweep is plenty.
public final class CoolWebSurfaceStore: @unchecked Sendable {
    public static let shared = CoolWebSurfaceStore()

    struct Mesh {
        var vertices: [SIMD3<Float>]
        var indices: [UInt32]
    }

    private let lock = NSLock()
    private var meshesByID: [UUID: Mesh] = [:]

    public init() {}

    public func update(id: UUID, worldVertices: [SIMD3<Float>], indices: [UInt32]) {
        lock.withLock {
            meshesByID[id] = Mesh(vertices: worldVertices, indices: indices)
        }
    }

    public func remove(id: UUID) {
        lock.withLock { _ = meshesByID.removeValue(forKey: id) }
    }

    public func clear() {
        lock.withLock { meshesByID.removeAll() }
    }

    public var triangleCount: Int {
        lock.withLock { meshesByID.values.reduce(0) { $0 + $1.indices.count / 3 } }
    }

    /// Möller–Trumbore over every stored triangle; returns the nearest hit.
    public func raycast(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDistance: Float = .greatestFiniteMagnitude
    ) -> CoolWebSurfaceHit? {
        let lengthSquared = simd_length_squared(direction)
        guard lengthSquared.isFinite, lengthSquared > 1e-12 else { return nil }
        let dir = direction / sqrt(lengthSquared)

        let meshes = lock.withLock { Array(meshesByID.values) }
        var bestT = maxDistance
        var bestNormal: SIMD3<Float>?

        for mesh in meshes {
            let vertices = mesh.vertices
            let indices = mesh.indices
            var i = 0
            while i + 2 < indices.count {
                let a = vertices[Int(indices[i])]
                let b = vertices[Int(indices[i + 1])]
                let c = vertices[Int(indices[i + 2])]
                i += 3

                let edge1 = b - a
                let edge2 = c - a
                let pvec = simd_cross(dir, edge2)
                let det = simd_dot(edge1, pvec)
                if abs(det) < 1e-9 { continue }
                let invDet = 1 / det
                let tvec = origin - a
                let u = simd_dot(tvec, pvec) * invDet
                if u < 0 || u > 1 { continue }
                let qvec = simd_cross(tvec, edge1)
                let v = simd_dot(dir, qvec) * invDet
                if v < 0 || u + v > 1 { continue }
                let t = simd_dot(edge2, qvec) * invDet
                if t > 1e-4, t < bestT {
                    bestT = t
                    bestNormal = simd_cross(edge1, edge2)
                }
            }
        }

        guard var normal = bestNormal else { return nil }
        let normalLength = simd_length(normal)
        normal = normalLength > 1e-9 ? normal / normalLength : SIMD3<Float>(0, 1, 0)
        if simd_dot(normal, dir) > 0 { normal = -normal }
        return CoolWebSurfaceHit(
            position: origin + dir * bestT,
            normal: normal,
            distance: bestT
        )
    }
}

/// Convenience wrapper over the shared store.
public func raycastCoolWebSurface(
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    maxDistance: Float = .greatestFiniteMagnitude
) -> CoolWebSurfaceHit? {
    CoolWebSurfaceStore.shared.raycast(
        origin: origin,
        direction: direction,
        maxDistance: maxDistance
    )
}
