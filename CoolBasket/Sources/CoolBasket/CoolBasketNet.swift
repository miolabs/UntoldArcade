//
//  CoolBasketNet.swift
//  CoolBasket
//
//  The net swings. The hoop model's net is a static mesh (cords, knots and
//  bottom scallops as bevelled curves); here it is driven by a particle
//  lattice that lives in the Jolt plugin as a soft body — Jolt's own XPBD,
//  colliding both ways with the ball — and the artist's net vertices are
//  skinned to the lattice's cords every frame, written straight into the
//  meshes' vertex buffers. The built-in backend has no soft bodies, so on
//  it the net stays the model's static mesh.
//
//  Three pieces, the first two pure and tested without a GPU or a world:
//  `CoolBasketNetLattice` is the particle graph in hoop-model space, taken
//  from the artist's rest geometry (12 hooks, 5 rows of 12 knots, 12
//  scallop bottoms); `CoolBasketNetSkin` binds a mesh's rest vertices to the
//  nearest cord and poses them from the lattice's current positions;
//  `CoolBasketNet` owns the soft body and the buffer writes.
//

import Foundation
import Metal
import simd
import UntoldEngine
import UntoldJoltPhysics

// MARK: - Lattice

/// The net's particle graph in hoop-model space (metres; local +z toward
/// the player, the rim centre at (0, `CoolBasketScene.rimHeight`, 0.38);
/// heights are measured on the model as offsets from the rim). Indices: hooks first,
/// then the knot rows top to bottom, then the scallop bottoms, then one
/// pinned "ghost" above every free particle (see `shapeCompliance`).
public struct CoolBasketNetLattice: Sendable {
    public static let columns = 12
    /// Knot rows below the hooks: height, radius from the rim axis and the
    /// angular phase (the rows alternate by half a column, making the
    /// diamonds), measured on the model.
    public static let knotRows: [(height: Float, radius: Float, phase: Float)] = [
        (rimHeight - 0.10, 0.2218, 15), (rimHeight - 0.17, 0.1894, 0), (rimHeight - 0.24, 0.155, 15),
        (rimHeight - 0.31, 0.1317, 0), (rimHeight - 0.38, 0.1215, 15),
    ]
    static let rimHeight = CoolBasketScene.rimHeight
    /// The rim hooks: where the top cords tie on (the hook's lowest point).
    public static let hookHeight: Float = rimHeight - 0.0273
    public static let hookRadius: Float = 0.2373
    /// Bottom of the open scallops between the last row's knots.
    public static let scallopHeight: Float = rimHeight - 0.4304
    public static let scallopRadius: Float = 0.1191
    /// The rim's axis, in model space (the model's origin is on the floor
    /// under the glass).
    public static let axis = SIMD2<Float>(0, 0.38)
    /// Mass of a knot; the whole net weighs a few hundred grams.
    public static let particleMass: Float = 0.004
    /// Cords barely stretch.
    public static let cordCompliance: Float = 1e-6
    /// Every free particle hangs from a pinned ghost a little above its rest
    /// position through a soft spring. A lattice of pure distance
    /// constraints has no shape of its own — under gravity it would slump
    /// into a wider, rounder net than the artist tied — and real cords keep
    /// theirs by bending stiffness, which these springs stand in for. Soft
    /// enough for a swish to flare the net a hand's width and for it to
    /// swing back at about a hertz, stiff enough to hold the artist's shape
    /// within two centimetres at rest.
    public static let shapeCompliance: Float = 5.0
    public static let ghostLift: Float = 0.01
    /// The net feels less gravity than the ball: at full weight its own
    /// tension stiffens the diamonds and a swish barely moves it; at a
    /// third it flares and settles like a real one (its knots weigh next to
    /// nothing anyway).
    public static let gravityFactor: Float = 0.3
    /// Collision radius of a particle: the cord's.
    public static let vertexRadius: Float = 0.006

    public let particles: [SIMD3<Float>]
    public let inverseMasses: [Float]
    public let edges: [SIMD2<UInt32>]
    public let edgeCompliances: [Float]

    public static let hookCount = columns
    public static let knotCount = columns * knotRows.count
    public static let scallopCount = columns
    /// Particles that are part of the net proper (not the shape ghosts).
    public static let cordParticleCount = hookCount + knotCount + scallopCount
    public static let freeParticleCount = knotCount + scallopCount
    public static let particleCount = cordParticleCount + freeParticleCount
    /// Edges that are cords (the ghost springs come after them).
    public static let cordEdgeCount = columns * 2 * knotRows.count + columns * 2

    public static func hook(_ column: Int) -> Int { ((column % columns) + columns) % columns }
    public static func knot(row: Int, column: Int) -> Int { hookCount + row * columns + ((column % columns) + columns) % columns }
    public static func scallop(_ column: Int) -> Int { hookCount + knotCount + ((column % columns) + columns) % columns }
    public static func ghost(of particle: Int) -> Int { cordParticleCount + (particle - hookCount) }

    public static let rest = CoolBasketNetLattice()

    static func ring(radius: Float, height: Float, phaseDegrees: Float, column: Int) -> SIMD3<Float> {
        // Blender's x–y angle, seen from the engine's side: y up, −z where
        // Blender's +y was.
        let angle = (phaseDegrees + 30 * Float(column)) * .pi / 180
        return SIMD3<Float>(axis.x + radius * cosf(angle), height, axis.y - radius * sinf(angle))
    }

    public init() {
        var particles: [SIMD3<Float>] = []
        var inverseMasses: [Float] = []
        for column in 0 ..< Self.columns {
            particles.append(Self.ring(radius: Self.hookRadius, height: Self.hookHeight, phaseDegrees: 0, column: column))
            inverseMasses.append(0)
        }
        for row in Self.knotRows {
            for column in 0 ..< Self.columns {
                particles.append(Self.ring(radius: row.radius, height: row.height, phaseDegrees: row.phase, column: column))
                inverseMasses.append(1 / Self.particleMass)
            }
        }
        for column in 0 ..< Self.columns {
            particles.append(Self.ring(radius: Self.scallopRadius, height: Self.scallopHeight, phaseDegrees: 0, column: column))
            inverseMasses.append(1 / Self.particleMass)
        }
        // Ghosts: pinned copies just above every free particle.
        for index in Self.hookCount ..< Self.cordParticleCount {
            particles.append(particles[index] + SIMD3<Float>(0, Self.ghostLift, 0))
            inverseMasses.append(0)
        }

        var edges: [SIMD2<UInt32>] = []
        var compliances: [Float] = []
        func cord(_ a: Int, _ b: Int) {
            edges.append(SIMD2<UInt32>(UInt32(a), UInt32(b)))
            compliances.append(Self.cordCompliance)
        }
        // Diagonals: a knot at phase 15 hangs from columns k and k+1 of the
        // phase-0 row above it (the hooks are one); a knot at phase 0 from
        // columns k and k−1 of the phase-15 row above.
        for (row, spec) in Self.knotRows.enumerated() {
            func above(_ column: Int) -> Int {
                row == 0 ? Self.hook(column) : Self.knot(row: row - 1, column: column)
            }
            for column in 0 ..< Self.columns {
                let below = Self.knot(row: row, column: column)
                cord(above(column), below)
                cord(above(spec.phase == 15 ? column + 1 : column - 1), below)
            }
        }
        // Scallops: the bottom of loop k hangs between the last row's knots
        // k−1 and k (phase 15, at 30k ∓ 15°).
        let lastRow = Self.knotRows.count - 1
        for column in 0 ..< Self.columns {
            cord(Self.knot(row: lastRow, column: column - 1), Self.scallop(column))
            cord(Self.knot(row: lastRow, column: column), Self.scallop(column))
        }
        // Shape springs.
        for index in Self.hookCount ..< Self.cordParticleCount {
            edges.append(SIMD2<UInt32>(UInt32(Self.ghost(of: index)), UInt32(index)))
            compliances.append(Self.shapeCompliance)
        }

        self.particles = particles
        self.inverseMasses = inverseMasses
        self.edges = edges
        edgeCompliances = compliances
    }

    /// The soft body for this lattice placed in the world: `origin` and
    /// `orientation` are the hoop model's.
    public func softBodyDescriptor(origin: SIMD3<Float>, orientation: simd_quatf) -> JoltSoftBodyDescriptor {
        var descriptor = JoltSoftBodyDescriptor(
            vertices: particles.map { orientation.act($0) },
            inverseMasses: inverseMasses,
            edges: edges
        )
        descriptor.position = origin
        descriptor.edgeCompliances = edgeCompliances
        descriptor.vertexRadius = Self.vertexRadius
        descriptor.iterations = 10
        descriptor.linearDamping = 1.0
        descriptor.friction = 0.5
        descriptor.gravityFactor = Self.gravityFactor
        return descriptor
    }
}

// MARK: - Skin

/// Binds a mesh's rest vertices (in hoop-model space) to the lattice's
/// cords and poses them from the lattice's current particle positions:
/// each vertex keeps its offset from the closest point of its cord, carried
/// along as the cord moves and turns.
public struct CoolBasketNetSkin: Sendable {
    struct Binding {
        var edge: Int32
        var t: Float
        var offset: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    let bindings: [Binding]
    let restEdges: [(a: SIMD3<Float>, direction: SIMD3<Float>)]
    public var vertexCount: Int { bindings.count }

    /// Distance beyond a cord's height range within which it is a
    /// candidate for a vertex.
    static let searchMargin: Float = 0.04

    public init(restPositions: [SIMD3<Float>], restNormals: [SIMD3<Float>], lattice: CoolBasketNetLattice = .rest) {
        let edgeCount = CoolBasketNetLattice.cordEdgeCount
        var rest: [(a: SIMD3<Float>, direction: SIMD3<Float>)] = []
        var bands: [(low: Float, high: Float)] = []
        rest.reserveCapacity(edgeCount)
        for edge in lattice.edges.prefix(edgeCount) {
            let a = lattice.particles[Int(edge.x)], b = lattice.particles[Int(edge.y)]
            rest.append((a, b - a))
            bands.append((min(a.y, b.y) - Self.searchMargin, max(a.y, b.y) + Self.searchMargin))
        }
        restEdges = rest

        var bindings: [Binding] = []
        bindings.reserveCapacity(restPositions.count)
        for (index, p) in restPositions.enumerated() {
            var best = (edge: 0, t: Float(0), distance: Float.greatestFiniteMagnitude)
            for edge in 0 ..< edgeCount {
                guard p.y >= bands[edge].low, p.y <= bands[edge].high else { continue }
                let (a, d) = rest[edge]
                let t = simd_clamp(simd_dot(p - a, d) / simd_length_squared(d), 0, 1)
                let distance = simd_length_squared(p - (a + d * t))
                if distance < best.distance { best = (edge, t, distance) }
            }
            if best.distance == .greatestFiniteMagnitude {
                // Outside every band: search them all.
                for edge in 0 ..< edgeCount {
                    let (a, d) = rest[edge]
                    let t = simd_clamp(simd_dot(p - a, d) / simd_length_squared(d), 0, 1)
                    let distance = simd_length_squared(p - (a + d * t))
                    if distance < best.distance { best = (edge, t, distance) }
                }
            }
            let (a, d) = rest[best.edge]
            let normal = index < restNormals.count ? restNormals[index] : SIMD3<Float>(0, 1, 0)
            bindings.append(Binding(edge: Int32(best.edge), t: best.t, offset: p - (a + d * best.t), normal: normal))
        }
        self.bindings = bindings
    }

    /// Per-cord pose for the current particle positions: the cord's start,
    /// its vector, and the rotation carrying its rest direction to the
    /// current one.
    static func cordPoses(
        particles: [SIMD3<Float>], edges: ArraySlice<SIMD2<UInt32>>,
        restEdges: [(a: SIMD3<Float>, direction: SIMD3<Float>)]
    ) -> [(a: SIMD3<Float>, direction: SIMD3<Float>, rotation: simd_quatf)] {
        var poses: [(a: SIMD3<Float>, direction: SIMD3<Float>, rotation: simd_quatf)] = []
        poses.reserveCapacity(restEdges.count)
        for (index, edge) in edges.enumerated() {
            let a = particles[Int(edge.x)], b = particles[Int(edge.y)]
            let from = simd_normalize(restEdges[index].direction)
            let d = b - a
            let length = simd_length(d)
            var rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            if length > 1e-6 {
                let to = d / length
                // A cord folded back on itself has no shortest rotation;
                // keep the rest frame for that frame.
                if simd_dot(from, to) > -0.999 {
                    rotation = simd_quatf(from: from, to: to)
                }
            }
            poses.append((a, d, rotation))
        }
        return poses
    }

    /// Writes the posed positions (w = 1) and normals (w = 0) for the
    /// lattice's current `particles` (hoop-model space).
    public func pose(
        particles: [SIMD3<Float>], lattice: CoolBasketNetLattice = .rest,
        positions: UnsafeMutablePointer<SIMD4<Float>>, normals: UnsafeMutablePointer<SIMD4<Float>>?
    ) {
        let poses = Self.cordPoses(
            particles: particles,
            edges: lattice.edges.prefix(CoolBasketNetLattice.cordEdgeCount),
            restEdges: restEdges
        )
        for (index, binding) in bindings.enumerated() {
            let cord = poses[Int(binding.edge)]
            let p = cord.a + cord.direction * binding.t + cord.rotation.act(binding.offset)
            positions[index] = SIMD4<Float>(p.x, p.y, p.z, 1)
            if let normals {
                let n = cord.rotation.act(binding.normal)
                normals[index] = SIMD4<Float>(n.x, n.y, n.z, 0)
            }
        }
    }

    /// Convenience for tests: posed positions as an array.
    public func posedPositions(particles: [SIMD3<Float>], lattice: CoolBasketNetLattice = .rest) -> [SIMD3<Float>] {
        var positions = [SIMD4<Float>](repeating: .zero, count: bindings.count)
        var normals = [SIMD4<Float>](repeating: .zero, count: bindings.count)
        positions.withUnsafeMutableBufferPointer { p in
            normals.withUnsafeMutableBufferPointer { n in
                pose(particles: particles, lattice: lattice, positions: p.baseAddress!, normals: n.baseAddress!)
            }
        }
        return positions.map { SIMD3<Float>($0.x, $0.y, $0.z) }
    }
}

// MARK: - Net

/// The simulated net: a Jolt soft body for the lattice, and the artist's
/// net meshes skinned to it every frame. Frame thread only (between
/// physics steps), like the rest of the game's update.
public final class CoolBasketNet {
    /// Names of the hoop model's parts the net drives; the rim hooks and
    /// the loops tying them to the rim stay with the rim.
    public static let drivenPartNames = ["Net_Knots", "Net_Clockwise_Cords", "Net_Counterclockwise_Cords", "Net_Open_Bottom_Scallops"]

    private struct BoundMesh {
        let entity: EntityID
        let meshIndex: Int
        let metalKitMesh: ObjectIdentifier
        let skin: CoolBasketNetSkin
        /// Hoop-model space → the mesh's own space, for the write-back.
        let modelToMesh: simd_float4x4
    }

    public let lattice: CoolBasketNetLattice
    public let body: JoltSoftBody
    private let backend: JoltPhysicsBackend
    private let origin: SIMD3<Float>
    private let orientation: simd_quatf
    private let modelWorld: simd_float4x4
    private var worldParticles: [SIMD3<Float>] = []
    /// Particle positions in hoop-model space after the last `update`.
    public private(set) var particles: [SIMD3<Float>]
    /// The farthest any cord particle has been from its rest position since
    /// the last `takePeakDisplacement` (diagnostics).
    private var peakDisplacement: Float = 0
    private var bound: [BoundMesh] = []
    private var removed = false

    /// Adds the soft body to the Jolt world at the hoop's pose; nil when the
    /// world refuses it.
    public init?(backend: JoltPhysicsBackend, origin: SIMD3<Float>, orientation: simd_quatf, lattice: CoolBasketNetLattice = .rest) {
        guard let body = backend.addSoftBody(lattice.softBodyDescriptor(origin: origin, orientation: orientation)) else { return nil }
        self.backend = backend
        self.body = body
        self.lattice = lattice
        self.origin = origin
        self.orientation = orientation
        modelWorld = simd_float4x4(translation: origin) * simd_float4x4(orientation)
        particles = lattice.particles
    }

    public var boundMeshCount: Int { bound.count }

    /// Reads the particles back and writes the driven meshes' vertices.
    /// `partEntities` are the model's net parts; their meshes stream in
    /// after the model, so binding happens whenever a mesh appears (or is
    /// replaced) and the frame's write covers the rest.
    public func update(partEntities: [EntityID]) {
        guard !removed else { return }
        let read = backend.readSoftBodyVertices(body, into: &worldParticles)
        guard read == lattice.particles.count else { return }
        let inverse = orientation.inverse
        for index in 0 ..< read {
            particles[index] = inverse.act(worldParticles[index] - origin)
        }
        for index in CoolBasketNetLattice.hookCount ..< CoolBasketNetLattice.cordParticleCount {
            peakDisplacement = max(peakDisplacement, simd_distance(particles[index], lattice.particles[index]))
        }
        bindNewMeshes(partEntities)
        for mesh in bound {
            guard let render = scene.get(component: RenderComponent.self, for: mesh.entity),
                  mesh.meshIndex < render.mesh.count
            else { continue }
            let mtk = render.mesh[mesh.meshIndex].metalKitMesh
            guard ObjectIdentifier(mtk) == mesh.metalKitMesh, mtk.vertexBuffers.count >= 2,
                  mtk.vertexCount == mesh.skin.vertexCount
            else { continue }
            let positionBuffer = mtk.vertexBuffers[0]
            let normalBuffer = mtk.vertexBuffers[1]
            let positions = positionBuffer.buffer.contents().advanced(by: positionBuffer.offset)
                .assumingMemoryBound(to: SIMD4<Float>.self)
            let normals = normalBuffer.buffer.contents().advanced(by: normalBuffer.offset)
                .assumingMemoryBound(to: SIMD4<Float>.self)
            mesh.skin.pose(particles: particles, lattice: lattice, positions: positions, normals: normals)
            if mesh.modelToMesh != matrix_identity_float4x4 {
                // The mesh carries its own transform: the pose is in model
                // space, bring it back into the mesh's space.
                let rotation = simd_float3x3(
                    SIMD3<Float>(mesh.modelToMesh.columns.0.x, mesh.modelToMesh.columns.0.y, mesh.modelToMesh.columns.0.z),
                    SIMD3<Float>(mesh.modelToMesh.columns.1.x, mesh.modelToMesh.columns.1.y, mesh.modelToMesh.columns.1.z),
                    SIMD3<Float>(mesh.modelToMesh.columns.2.x, mesh.modelToMesh.columns.2.y, mesh.modelToMesh.columns.2.z)
                )
                for index in 0 ..< mesh.skin.vertexCount {
                    positions[index] = mesh.modelToMesh * positions[index]
                    let n = rotation * SIMD3<Float>(normals[index].x, normals[index].y, normals[index].z)
                    normals[index] = SIMD4<Float>(n.x, n.y, n.z, 0)
                }
            }
        }
    }

    private func bindNewMeshes(_ partEntities: [EntityID]) {
        for entity in partEntities {
            guard let render = scene.get(component: RenderComponent.self, for: entity) else { continue }
            for (index, mesh) in render.mesh.enumerated() {
                let identity = ObjectIdentifier(mesh.metalKitMesh)
                if let existing = bound.firstIndex(where: { $0.entity == entity && $0.meshIndex == index }) {
                    if bound[existing].metalKitMesh == identity { continue }
                    bound.remove(at: existing)
                }
                guard let skinned = bind(entity: entity, meshIndex: index, mesh: mesh) else { continue }
                bound.append(skinned)
            }
        }
    }

    /// Reads the mesh's rest vertices (they are in the mesh's own space;
    /// the model's parts carry their node transforms) into hoop-model
    /// space and binds them to the cords.
    private func bind(entity: EntityID, meshIndex: Int, mesh: Mesh) -> BoundMesh? {
        let mtk = mesh.metalKitMesh
        guard mtk.vertexBuffers.count >= 2, mtk.vertexCount > 0 else { return nil }
        let positionBuffer = mtk.vertexBuffers[0]
        let normalBuffer = mtk.vertexBuffers[1]
        guard positionBuffer.buffer.storageMode == .shared, normalBuffer.buffer.storageMode == .shared else {
            coolBasketLog.error("net part \(getEntityName(entityId: entity), privacy: .public) has GPU-private vertex buffers; the net cannot drive it")
            return nil
        }
        let entityWorld = scene.get(component: WorldTransformComponent.self, for: entity)?.space ?? matrix_identity_float4x4
        let meshToModel = modelWorld.inverse * entityWorld * mesh.localSpace
        let count = mtk.vertexCount
        let positions = positionBuffer.buffer.contents().advanced(by: positionBuffer.offset)
            .assumingMemoryBound(to: SIMD4<Float>.self)
        let normals = normalBuffer.buffer.contents().advanced(by: normalBuffer.offset)
            .assumingMemoryBound(to: SIMD4<Float>.self)
        let rotation = simd_float3x3(
            SIMD3<Float>(meshToModel.columns.0.x, meshToModel.columns.0.y, meshToModel.columns.0.z),
            SIMD3<Float>(meshToModel.columns.1.x, meshToModel.columns.1.y, meshToModel.columns.1.z),
            SIMD3<Float>(meshToModel.columns.2.x, meshToModel.columns.2.y, meshToModel.columns.2.z)
        )
        var restPositions: [SIMD3<Float>] = []
        var restNormals: [SIMD3<Float>] = []
        restPositions.reserveCapacity(count)
        restNormals.reserveCapacity(count)
        for index in 0 ..< count {
            let p = meshToModel * positions[index]
            restPositions.append(SIMD3<Float>(p.x, p.y, p.z))
            restNormals.append(rotation * SIMD3<Float>(normals[index].x, normals[index].y, normals[index].z))
        }
        let skin = CoolBasketNetSkin(restPositions: restPositions, restNormals: restNormals, lattice: lattice)
        coolBasketLog.log("net drives \(getEntityName(entityId: entity), privacy: .public): \(count) vertices")
        return BoundMesh(entity: entity, meshIndex: meshIndex, metalKitMesh: ObjectIdentifier(mtk), skin: skin, modelToMesh: meshToModel.inverse)
    }

    /// Returns the peak particle displacement since the last call, and
    /// resets it.
    public func takePeakDisplacement() -> Float {
        defer { peakDisplacement = 0 }
        return peakDisplacement
    }

    /// Takes the soft body out of the world. The meshes keep their last pose.
    public func remove() {
        guard !removed else { return }
        removed = true
        backend.removeSoftBody(body)
    }
}

private extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
    }
}
