//
//  CoolBasketSimulation.swift
//  CoolBasket
//
//  The demo runs on either of two physics backends behind the engine's
//  plugin seam: its own pure-Swift backend, or the Jolt Physics plugin. The
//  engine drives both identically through PhysicsBackend; what the GAME
//  needs beyond that protocol (real-world surfaces in, ball state out, a
//  teleport for resets) is this small side channel, which both provide.
//

import Foundation
import simd
import UntoldEngine
import UntoldJoltPhysics

/// Which backend the demo installs. Chosen before the renderer exists — the
/// engine's registry locks on the first simulated substep, so switching
/// afterwards needs an app restart.
public enum CoolBasketPhysicsEngine: String, CaseIterable, Sendable {
    case coolBasket
    case jolt

    public var displayName: String {
        switch self {
        case .coolBasket: return "Built-in (CoolBasket)"
        case .jolt: return "Jolt Physics"
        }
    }
}

/// The plugin-owned side channel the game logic uses.
public protocol CoolBasketSimulation: AnyObject {
    var engine: CoolBasketPhysicsEngine { get }
    /// Replaces the set of real-world surfaces (any thread).
    func setWorldPlanes(_ planes: [CoolBasketWorldPlane])
    var worldPlaneCount: Int { get }
    /// Position and velocity of a simulated body (game thread).
    func bodyState(for entity: EntityID) -> (position: SIMD3<Float>, velocity: SIMD3<Float>)?
    /// Teleports a simulated body; false when the entity has no body right now.
    @discardableResult
    func resetBody(entity: EntityID, position: SIMD3<Float>, velocity: SIMD3<Float>) -> Bool
}

extension CoolBasketPhysicsBackend: CoolBasketSimulation {
    public var engine: CoolBasketPhysicsEngine { .coolBasket }
}

/// Jolt behind the same side channel. The engine seam handles every entity
/// body; the detected surfaces — which belong to no entity — become Jolt
/// environment boxes: thin static slabs whose top face lies on the plane.
public final class CoolBasketJoltSimulation: CoolBasketSimulation, @unchecked Sendable {
    public let backend: JoltPhysicsBackend
    private let planeCount = CoolBasketLockedBox<Int>(0)

    /// Half thickness of the slab standing in for a (zero-thickness) plane.
    static let slabHalfThickness: Float = 0.02
    /// Cap for the "infinite" safety floor: Jolt wants finite boxes.
    static let maxHalfExtent: Float = 100

    public init(backend: JoltPhysicsBackend) {
        self.backend = backend
    }

    public var engine: CoolBasketPhysicsEngine { .jolt }

    public func setWorldPlanes(_ planes: [CoolBasketWorldPlane]) {
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

    /// A plane as a slab: local X along `tangentU`, local Y along `tangentV`,
    /// local Z along the normal; centred half a thickness below the surface
    /// so the top face is exactly the plane. Restitution 0 leaves the bounce
    /// to the ball's own value (Jolt combines with max), matching the
    /// pure-Swift backend.
    static func environmentBox(for plane: CoolBasketWorldPlane) -> JoltEnvironmentBox {
        let normal = simd_normalize(plane.normal)
        let u = simd_normalize(plane.tangentU)
        var v = simd_normalize(plane.tangentV)
        // A quaternion needs a right-handed basis; the demo's infinite floor
        // (and any anchor whose tangents come out mirrored) is not. The slab
        // is symmetric, so flipping V costs nothing.
        if simd_dot(simd_cross(u, v), normal) < 0 {
            v = -v
        }
        let basis = simd_float3x3(columns: (u, v, normal))
        let orientation = simd_normalize(simd_quatf(basis))
        return JoltEnvironmentBox(
            center: plane.center - normal * slabHalfThickness,
            orientation: orientation,
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
