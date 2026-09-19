//
//  CoolBowlingWorld.swift
//  CoolBowling
//
//  The real room as physics: ARKit planes become Jolt environment slabs, and
//  the game's side channel to the backend (ball/pin state, teleports).
//

import Foundation
import simd
import UntoldEngine
import UntoldJoltPhysics

/// A bounded real-world surface from ARKit plane detection. `center` and
/// `normal` in world space; `extents` are half-sizes along the tangents.
public struct CoolBowlingWorldPlane: Sendable {
    public let id: UUID
    public var center: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var tangentU: SIMD3<Float>
    public var tangentV: SIMD3<Float>
    public var extentU: Float
    public var extentV: Float
    /// ARKit classified this surface as the floor.
    public var isFloor: Bool

    public init(
        id: UUID,
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        tangentU: SIMD3<Float>,
        tangentV: SIMD3<Float>,
        extentU: Float,
        extentV: Float,
        isFloor: Bool = false
    ) {
        self.id = id
        self.center = center
        self.normal = normal
        self.tangentU = tangentU
        self.tangentV = tangentV
        self.extentU = extentU
        self.extentV = extentV
        self.isFloor = isFloor
    }

    /// An unbounded horizontal floor — the simulator fallback and the safety
    /// net under holes in the real scan.
    public static func infiniteFloor(y: Float = 0.0) -> CoolBowlingWorldPlane {
        CoolBowlingWorldPlane(
            id: UUID(),
            center: SIMD3<Float>(0.0, y, 0.0),
            normal: SIMD3<Float>(0.0, 1.0, 0.0),
            tangentU: SIMD3<Float>(1.0, 0.0, 0.0),
            tangentV: SIMD3<Float>(0.0, 0.0, 1.0),
            extentU: .greatestFiniteMagnitude,
            extentV: .greatestFiniteMagnitude
        )
    }
}

/// Jolt behind the game's side channel: detected planes become environment
/// slabs (thin static boxes whose top face lies on the plane).
public final class CoolBowlingSimulation: @unchecked Sendable {
    public let backend: JoltPhysicsBackend
    private let planeCount = CoolBowlingLockedBox<Int>(0)

    /// Half thickness of the slab standing in for a (zero-thickness) plane.
    static let slabHalfThickness: Float = 0.02
    /// Cap for the "infinite" safety floor: Jolt wants finite boxes.
    static let maxHalfExtent: Float = 100

    public init(backend: JoltPhysicsBackend) {
        self.backend = backend
    }

    public func setWorldPlanes(_ planes: [CoolBowlingWorldPlane]) {
        planeCount.value = planes.count
        backend.setEnvironmentBoxes(planes.map(Self.environmentBox(for:)))
    }

    public var worldPlaneCount: Int {
        planeCount.value
    }

    public func bodyState(for entity: EntityID) -> (position: SIMD3<Float>, velocity: SIMD3<Float>)? {
        backend.bodyState(for: entity)
    }

    @discardableResult
    public func resetBody(entity: EntityID, position: SIMD3<Float>, velocity: SIMD3<Float>) -> Bool {
        backend.resetBody(entity: entity, position: position, velocity: velocity)
    }

    public func isBodyActive(entity: EntityID) -> Bool {
        backend.isBodyActive(entity: entity)
    }

    /// A plane as a slab: local X along `tangentU`, local Y along `tangentV`,
    /// local Z along the normal; centred half a thickness below the surface
    /// so the top face is exactly the plane.
    static func environmentBox(for plane: CoolBowlingWorldPlane) -> JoltEnvironmentBox {
        let normal = simd_normalize(plane.normal)
        let u = simd_normalize(plane.tangentU)
        var v = simd_normalize(plane.tangentV)
        // A quaternion needs a right-handed basis; the slab is symmetric, so
        // flipping V costs nothing.
        if simd_dot(simd_cross(u, v), normal) < 0 {
            v = -v
        }
        let basis = simd_float3x3(columns: (u, v, normal))
        return JoltEnvironmentBox(
            center: plane.center - normal * slabHalfThickness,
            orientation: simd_normalize(simd_quatf(basis)),
            halfExtents: SIMD3<Float>(
                min(plane.extentU, maxHalfExtent),
                min(plane.extentV, maxHalfExtent),
                slabHalfThickness
            ),
            friction: 0.5,
            restitution: 0.0
        )
    }
}

/// Minimal lock-guarded box for cross-thread handoff.
final class CoolBowlingLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
