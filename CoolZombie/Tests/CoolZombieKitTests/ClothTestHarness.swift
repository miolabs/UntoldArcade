//
//  ClothTestHarness.swift
//  CoolZombieKitTests
//
//  The cloth tests' recording body, the harness that runs the demo's physics
//  and the cloth on the model's skeleton at the demo's cadence, and the
//  fixtures read off the bundle (the sidecar, the skeleton, the export's
//  vertices, normals, triangles and skin), hoisted out of ZombieClothTests
//  on 2026-11-03 so the GPU solver of `Docs/GPUCloth.md` runs the same fit
//  scenarios on the same harness as the Jolt one: `ClothHarness` takes a
//  `solver:` and a `device:` beside the configuration, and the balls a test
//  adds with `addBall` reach the GPU solver as spheres through the Jolt
//  backend's body state, as the game's do. The code is the Jolt tests' of
//  that date, moved and not changed.
//

@testable import CoolZombieKit
import Metal
import simd
@testable import UntoldEngine
import UntoldJoltPhysics
import XCTest

/// The test's body: the shell's rest positions as the mesh (one exported
/// vertex per shell vertex, in the sidecar's order) with the exported
/// normal at each — or the whole export — the pose the test sets, and
/// what the cloth writes.
final class ClothTestBody: ZombieClothBody {
    var mesh: [SIMD3<Float>]
    var meshNormals: [SIMD3<Float>]
    var pose: [simd_float4x4]
    var world: simd_float4x4
    var overrideWrites = 0
    var clears = 0
    var begins = 0
    var ends = 0
    /// Whether the body takes the deformation component (the entity
    /// path can fail to).
    var acceptsOverride = true
    var indices: [UInt32] = []
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []

    init(mesh: [SIMD3<Float>], normals: [SIMD3<Float>], pose: [simd_float4x4], world: simd_float4x4) {
        self.mesh = mesh
        meshNormals = normals
        self.pose = pose
        self.world = world
    }

    func meshGeometry() -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>], localTransform: simd_float4x4)? { (mesh, meshNormals, matrix_identity_float4x4) }
    func jointModelTransforms() -> [simd_float4x4]? { pose }
    func entityWorld() -> simd_float4x4 { world }
    func beginOverride() -> Bool {
        begins += 1
        return acceptsOverride
    }
    func writeOverride(indices: [UInt32], positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        overrideWrites += 1
        self.indices = indices
        self.positions = positions
        self.normals = normals
    }

    func clearOverride() { clears += 1 }
    func endOverride() { ends += 1 }
}

/// The demo's physics plus the cloth on the model's skeleton, the
/// powered ragdoll placed on the bind pose, the world stepped the way a
/// frame does.
final class ClothHarness {
    let dt: Float
    let physics: ZombiePhysics
    let cloth: ZombieCloth
    let body: ClothTestBody
    let joints: SkeletonJointInfo
    let shirt: ZombieClothAsset.Garment
    let attached: Bool
    /// The sidecar the shirt was built from: the bundled `Zombie.cloth.json`
    /// (3,995 particles) unless the test named another (`sidecar:`), the
    /// phase-2 `Zombie.cloth16k.json` of `Docs/GPUCloth.md`.
    let sidecarName: String
    var time: Float = 0
    /// The balls the test added (`addBall`), which the GPU solver meets as
    /// spheres through `backend.bodyState(for:)` after every step; the Jolt
    /// solver ignores the list, its balls being Jolt bodies on the ball layer.
    private var balls: [(entity: EntityID, radius: Float)] = []

    /// `sidecar` names a second cook of the same export under
    /// `Models/Zombie/` to build the shirt from in place of `asset` (the
    /// design's `Zombie.cloth16k.json`, 2026-11-04); the caller checks it is
    /// bundled first (`ClothFixtures.sidecar(named:)`), since a name that
    /// does not load falls back to `asset` here and says so once.
    init(dt: Float, asset: ZombieClothAsset, joints: SkeletonJointInfo, configuration: ZombieCloth.Configuration = ZombieCloth.Configuration(),
         world: simd_float4x4 = ClothFixtures.standing, ragdoll: Bool = true, obstacles: [NavObstacle] = [], mesh: [SIMD3<Float>]? = nil,
         normals: [SIMD3<Float>]? = nil, acceptsOverride: Bool = true, pose: [simd_float4x4]? = nil, collisionSteps: Int32 = 3,
         gravity: SIMD3<Float> = SIMD3(0, -9.8, 0), solver: ZombieCloth.Configuration.Solver? = nil, device: MTLDevice? = nil,
         sidecar: String? = nil)
    {
        self.dt = dt
        self.joints = joints
        var asset = asset
        var sidecarName = ClothFixtures.bundledSidecarName
        if let sidecar {
            if let named = ClothFixtures.sidecar(named: sidecar) {
                asset = named
                sidecarName = sidecar
            } else {
                print("CoolZombie tests: the sidecar \(sidecar) is not bundled; the harness runs on \(sidecarName)")
            }
        }
        self.sidecarName = sidecarName
        shirt = asset.garment(named: "shirt")!
        var settings = JoltWorldSettings()
        settings.workerThreads = 0
        // The Mac's three sub-steps unless a test asks for the headset's two.
        settings.collisionSteps = collisionSteps
        settings.maxKinematicStep = 1.0
        settings.maxKinematicSpeed = 6.0
        settings.minContactSpeed = 0.35
        let backend = JoltPhysicsBackend(settings: settings)
        backend.configure(PhysicsWorldConfiguration())
        physics = ZombiePhysics(backend: backend, configuration: ZombiePhysics.Configuration())
        physics.applyLayers()
        if gravity != SIMD3(0, -9.8, 0) {
            // The layers' configuration with another gravity (a control
            // without one): the test backend is told directly, as
            // `applyLayers` tells it.
            var config = PhysicsCoordinator.shared.worldConfiguration()
            config.gravity = gravity
            backend.configure(config)
        }
        physics.setObstacles(obstacles, floor: 0)
        backend.step(deltaTime: dt)
        let positions = mesh ?? shirt.render?.restPositionVectors ?? shirt.positions
        body = ClothTestBody(mesh: positions, normals: normals ?? ClothFixtures.shellNormals ?? Array(repeating: SIMD3(0, 1, 0), count: positions.count),
                    pose: pose ?? joints.bindModelTransforms, world: world)
        body.acceptsOverride = acceptsOverride
        if ragdoll {
            physics.attachRagdoll(entity: 1, joints: joints)
            physics.track(jointModelTransforms: body.pose, entityWorld: body.world)
        }
        var configuration = configuration
        if let solver { configuration.solver = solver }
        cloth = ZombieCloth(asset: asset, configuration: configuration, device: device)
        attached = cloth.attach(body: body, physics: physics, jointInfo: joints)
        // The balls as the game hands them to the GPU solver (`ZombieChaseGame`
        // maps its props' balls the same way); the floor is the harness's slab.
        cloth.floorY = 0
        cloth.sphereProvider = { [weak self] in
            guard let self else { return [] }
            return self.balls.compactMap { ball -> ClothSphere? in
                guard let state = self.physics.backend.bodyState(for: ball.entity) else { return nil }
                return ClothSphere(center: state.position, radius: ball.radius, velocity: state.velocity)
            }
        }
    }

    /// A ball into the world on the ball layer, as the tests throw one (0.2 kg,
    /// 6 cm, friction 0.4, restitution 0.1), and onto the sphere list the
    /// GPU solver reads.
    func addBall(entity: EntityID, radius: Float, mass: Float, position: SIMD3<Float>, velocity: SIMD3<Float>) {
        physics.backend.didAddBody(entity: entity, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(shape: .sphere(radius: radius), friction: 0.4, restitution: 0.1),
            mass: mass, layer: physics.configuration.ballLayer,
            position: position, linearVelocity: velocity
        ))
        balls.append((entity, radius))
    }

    /// The bind pose with every joint but the root moved by `offset`: the
    /// whole body sways, as it does when the pelvis does.
    func pose(offset: SIMD3<Float>) -> [simd_float4x4] {
        joints.bindModelTransforms.enumerated().map { index, m in
            guard joints.parentIndices[index] != nil else { return m }
            var moved = m
            moved.columns.3 += SIMD4(offset, 0)
            return moved
        }
    }

    /// One frame as the demo runs it: the world steps (the cloth feeds
    /// this frame's pose inside; a long frame as `subSteps` shares of
    /// the delta on the one pose, as the engine's per-frame stepping
    /// does), then the game update — `beforeUpdate` is where the game
    /// moves the entity, the ragdoll tracks the pose — and last the
    /// cloth reads back.
    func frame(playerPosition: SIMD3<Float>? = nil, subSteps: Int = 1, beforeUpdate: (() -> Void)? = nil) {
        time += dt
        for _ in 0 ..< subSteps {
            physics.backend.step(deltaTime: dt / Float(subSteps))
        }
        cloth.beginUpdate()
        beforeUpdate?()
        physics.track(jointModelTransforms: body.pose, entityWorld: body.world)
        cloth.readBack(deltaTime: dt, playerPosition: playerPosition)
    }

    func frames(_ count: Int, playerPosition: SIMD3<Float>? = nil, each: ((Float) -> Void)? = nil) {
        for _ in 0 ..< count {
            each?(time + dt)
            frame(playerPosition: playerPosition)
        }
    }

    var particles: [SIMD3<Float>] { cloth.particleWorldPositions(ofGarment: 0) }
    var targets: [SIMD3<Float>] { cloth.skinnedTargets(ofGarment: 0) }

    /// The particles in mesh space: the world ones through the inverse of
    /// the entity's world, as the cloth takes them for the shell.
    var meshParticles: [SIMD3<Float>] {
        let toMesh = body.world.inverse
        return particles.map { q in let m = toMesh * SIMD4(q, 1); return SIMD3(m.x, m.y, m.z) }
    }

    /// The override's slot for an exported vertex (here, a shell vertex).
    var slotOfVertex: [Int: Int] {
        Dictionary(uniqueKeysWithValues: body.indices.enumerated().map { (Int($1), $0) })
    }
}

/// What the cloth tests read off the bundle, once per process: the model's
/// skeleton, the sidecar (or the one `COOLZOMBIE_CLOTH_SIDECAR` names), the
/// export's vertices, normals and triangles, which of them are the shell's
/// and the trousers', the body under the shirt, the export's own skin, the
/// shell's normals, the standing world and the bundled clips' poses.
enum ClothFixtures {
    /// The model's skeleton as the engine reports it: joint paths, parents
    /// and the model-space bind pose.
    static let skeleton: SkeletonJointInfo? = {
        guard let url = ZombieResources.baseURL?.appendingPathComponent("Models/Zombie/Zombie.untold"),
              FileManager.default.fileExists(atPath: url.path),
              let asset = try? NativeFormatLoader().loadAssetSync(from: url),
              let skeleton = asset.nodes.compactMap(\.skeleton).first
        else { return nil }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: skeleton.jointPaths.count)
        for index in skeleton.jointPaths.indices {
            let parent = skeleton.parentIndices[index].map { world[$0] } ?? matrix_identity_float4x4
            world[index] = parent * skeleton.restTransforms[index]
        }
        return SkeletonJointInfo(jointPaths: skeleton.jointPaths, parentIndices: skeleton.parentIndices, bindModelTransforms: world)
    }()

    /// The bundled sidecar, or the one `COOLZOMBIE_CLOTH_SIDECAR` names: another
    /// cook of the same export (its particles must still sit on the vertices),
    /// for an A/B of the weights or the slack in these tests.
    static let asset: ZombieClothAsset? = {
        if let path = ProcessInfo.processInfo.environment["COOLZOMBIE_CLOTH_SIDECAR"] {
            return try? ZombieClothAsset.load(from: URL(fileURLWithPath: path))
        }
        return try? ZombieClothAsset.loadBundled()
    }()

    /// The bundled sidecar's file name, and the design's name for the
    /// phase-2 cook at 16,000 particles (`Docs/GPUCloth.md`, "The sim mesh
    /// and the shell"): a second file beside the first, the same shell bound
    /// to a four-times-finer proxy, the same colliders and trousers.
    static let bundledSidecarName = "Zombie.cloth.json"
    static let sidecar16kName = "Zombie.cloth16k.json"

    /// Another sidecar under `Models/Zombie/` by file name, decoded once per
    /// process (the 16k file is about 4 MB of JSON); nil when it is not
    /// bundled or does not decode, which the tests turn into a skip.
    static func sidecar(named name: String) -> ZombieClothAsset? {
        sidecars.asset(named: name)
    }

    /// The URL a named sidecar would have beside the model.
    static func sidecarURL(named name: String) -> URL? {
        ZombieResources.baseURL?.appendingPathComponent("Models/Zombie/\(name)")
    }

    /// The decoded sidecars by name, under a lock (the tests run on one
    /// thread, the fixtures are statics all the same).
    private final class SidecarCache: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded: [String: ZombieClothAsset?] = [:]

        func asset(named name: String) -> ZombieClothAsset? {
            lock.lock(); defer { lock.unlock() }
            if let cached = loaded[name] { return cached }
            var asset: ZombieClothAsset?
            if let url = ClothFixtures.sidecarURL(named: name), FileManager.default.fileExists(atPath: url.path) {
                asset = try? ZombieClothAsset.load(from: url)
            }
            loaded[name] = asset
            return asset
        }
    }

    private static let sidecars = SidecarCache()

    /// The exported mesh's vertices and normals, read off the asset's vertex
    /// data the way the model tests read it (pbrStaticV1: the position's three
    /// floats, then the packed normal), and its triangles off the index data.
    static let exported: (positions: [SIMD3<Float>], normals: [SIMD3<Float>], triangles: [SIMD3<Int32>])? = {
        guard let url = ZombieResources.baseURL?.appendingPathComponent("Models/Zombie/Zombie.untold"),
              FileManager.default.fileExists(atPath: url.path),
              let asset = try? NativeFormatLoader().loadAssetSync(from: url),
              let primitive = asset.nodes.flatMap(\.primitives).first
        else { return nil }
        let stride = primitive.vertexLayout.stride
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = []
        positions.reserveCapacity(primitive.vertexCount); normals.reserveCapacity(primitive.vertexCount)
        primitive.vertexData.withUnsafeBytes { raw in
            for v in 0 ..< primitive.vertexCount {
                let base = raw.baseAddress!.advanced(by: v * stride)
                let p = base.assumingMemoryBound(to: Float.self)
                positions.append(SIMD3(p[0], p[1], p[2]))
                normals.append(UntoldVertexPacking.unpackNormal(base.load(fromByteOffset: 12, as: UInt32.self)))
            }
        }
        var indices: [Int32] = []
        indices.reserveCapacity(primitive.indexCount)
        primitive.indexData.withUnsafeBytes { raw in
            for i in 0 ..< primitive.indexCount {
                switch primitive.indexFormat {
                case .uint16: indices.append(Int32(raw.load(fromByteOffset: i * 2, as: UInt16.self)))
                case .uint32: indices.append(Int32(raw.load(fromByteOffset: i * 4, as: UInt32.self)))
                }
            }
        }
        let triangles = (0 ..< indices.count / 3).map { SIMD3(indices[3 * $0], indices[3 * $0 + 1], indices[3 * $0 + 2]) }
        return (positions, normals, triangles)
    }()

    /// Whether each exported vertex is one of the shell's (within the bind
    /// tolerance of a shell rest position): the rest of the export is the
    /// body, the trousers and the shoes, the surface the shirt must stay off.
    static let exportedIsShell: [Bool]? = {
        guard let shell = asset?.garment(named: "shirt")?.render?.restPositionVectors, let exported else { return nil }
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (index, p) in shell.enumerated() {
            grid[SIMD3<Int32>(Int32((p.x / 0.001).rounded(.down)), Int32((p.y / 0.001).rounded(.down)), Int32((p.z / 0.001).rounded(.down))), default: []].append(index)
        }
        return exported.positions.map { exportedIndex(near: $0, within: ZombieCloth.bindTolerance, grid: grid, positions: shell) != nil }
    }()

    /// Whether each exported vertex is one of the trousers proxy's (the
    /// sidecar's second garment, drawn as it is, so its particles are in the
    /// export; 3,176 exported vertices for its 2,999 particles, the split
    /// copies included). The trousers stand outside the body, and the
    /// shirt's proxy, pushed 2 mm off the BODY, sits inside their waistband
    /// by up to 14 mm at the flanks at rest (2026-10-31): skin they are not.
    static let exportedIsTrousers: [Bool]? = {
        guard let trousers = asset?.garment(named: "trousers")?.positions, let exported else { return nil }
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (index, p) in trousers.enumerated() {
            grid[SIMD3<Int32>(Int32((p.x / 0.001).rounded(.down)), Int32((p.y / 0.001).rounded(.down)), Int32((p.z / 0.001).rounded(.down))), default: []].append(index)
        }
        return exported.positions.map { exportedIndex(near: $0, within: ZombieCloth.bindTolerance, grid: grid, positions: trousers) != nil }
    }()

    /// The exported triangles with no corner on the shell: the body, the
    /// trousers, the shoes and the belt loops — everything under the shirt
    /// at the bind pose, what the hang test's clearance is read against.
    static let underShirtTriangles: [Int]? = {
        guard let exported, let isShell = exportedIsShell else { return nil }
        return exported.triangles.indices.filter { let t = exported.triangles[$0]; return !isShell[Int(t.x)] && !isShell[Int(t.y)] && !isShell[Int(t.z)] }
    }()

    /// The pieces of the export off the shell and the trousers, each a list
    /// of triangles, largest first: connected across shared corners and
    /// across the exporter's split copies (one position, two normals; welded
    /// here by the bind tolerance, since a UV seam would otherwise cut the
    /// body in two). The body — torso, arms, hands, neck and head, one piece
    /// since the prep culls its faces under the trousers and the shoes but
    /// keeps the skin under the shirt — is the largest; the rest are the
    /// shoes, the eyes, the calves between the trousers' hems and the shoes,
    /// and the five belt loops.
    static let offShellPieces: [[Int]]? = {
        guard let exported, let isShell = exportedIsShell, let isTrousers = exportedIsTrousers else { return nil }
        let count = exported.positions.count
        var parent = Array(0 ..< count)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { let ra = root(a), rb = root(b); if ra != rb { parent[ra] = rb } }
        var grid: [SIMD3<Int32>: [Int]] = [:]
        let triangles = exported.triangles.indices.filter { let t = exported.triangles[$0]; return ![t.x, t.y, t.z].contains { isShell[Int($0)] || isTrousers[Int($0)] } }
        var vertices = Set<Int>()
        for index in triangles { let t = exported.triangles[index]; vertices.insert(Int(t.x)); vertices.insert(Int(t.y)); vertices.insert(Int(t.z)) }
        for v in vertices {
            let p = exported.positions[v]
            grid[SIMD3<Int32>(Int32((p.x / 0.001).rounded(.down)), Int32((p.y / 0.001).rounded(.down)), Int32((p.z / 0.001).rounded(.down))), default: []].append(v)
        }
        for v in vertices {
            let p = exported.positions[v]
            let k = SIMD3<Int32>(Int32((p.x / 0.001).rounded(.down)), Int32((p.y / 0.001).rounded(.down)), Int32((p.z / 0.001).rounded(.down)))
            for dx in -1 ... 1 { for dy in -1 ... 1 { for dz in -1 ... 1 {
                for other in grid[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? [] where simd_distance(exported.positions[other], p) <= ZombieCloth.bindTolerance { union(v, other) }
            } } }
        }
        for index in triangles { let t = exported.triangles[index]; union(Int(t.x), Int(t.y)); union(Int(t.x), Int(t.z)) }
        var pieces: [Int: [Int]] = [:]
        for index in triangles { pieces[root(Int(exported.triangles[index].x)), default: []].append(index) }
        return pieces.values.sorted { $0.count > $1.count }
    }()

    /// The SKIN: the export's largest piece off the shell and the trousers —
    /// the body, 27,010 triangles from the shirt's hem (y 0.835, below which
    /// the prep culls the skin under the trousers) to the top of the head,
    /// against 9,320 for the next piece (an eye) and 192-288 for a belt
    /// loop (50 pieces in all, 2026-10-31). What the headset shows through
    /// the shirt is this surface, posed. The belt loops are left out on
    /// purpose: they ride the waist outside the trousers in 1 cm slivers
    /// wound every which way, and against them the proxy's flanks at the
    /// waist read 8-20 mm "inside" at rest, where they are 2 mm off the
    /// body; and the trousers the same, 14 mm at the flanks.
    static let skinTriangles: [Int]? = offShellPieces?.first

    /// The export's skin on its vertices, read the way ZombieSkinTests reads
    /// it — the per-vertex byte widths from the data's length (the loader
    /// slices four UInt16 joint indices and four Float weights per vertex),
    /// the skin's joints mapped onto the skeleton's through
    /// `skinToSkeletonMap` — and the skeleton's own bind transforms, model
    /// space, which the engine's skin matrices invert (`Skeleton.swift`).
    static let exportedSkin: (joints: [SIMD4<Int32>], weights: [SIMD4<Float>], bindTransforms: [simd_float4x4])? = {
        guard let url = ZombieResources.baseURL?.appendingPathComponent("Models/Zombie/Zombie.untold"),
              FileManager.default.fileExists(atPath: url.path),
              let asset = try? NativeFormatLoader().loadAssetSync(from: url),
              let skeleton = asset.nodes.compactMap(\.skeleton).first,
              let primitive = asset.nodes.flatMap(\.primitives).first, let skin = primitive.skin, primitive.vertexCount > 0
        else { return nil }
        let count = primitive.vertexCount
        let indexBytes = skin.jointIndexData.count / count, weightBytes = skin.jointWeightData.count / count
        let map = skin.skinToSkeletonMap
        var joints: [SIMD4<Int32>] = [], weights: [SIMD4<Float>] = []
        joints.reserveCapacity(count); weights.reserveCapacity(count)
        skin.jointIndexData.withUnsafeBytes { raw in
            for v in 0 ..< count {
                let b = raw.baseAddress!.advanced(by: v * indexBytes)
                var j = SIMD4<Int32>(repeating: 0)
                for i in 0 ..< 4 {
                    let skinJoint: Int
                    switch indexBytes {
                    case 4: skinJoint = Int(b.loadUnaligned(fromByteOffset: i, as: UInt8.self))
                    case 8: skinJoint = Int(b.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                    default: skinJoint = Int(b.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                    }
                    j[i] = Int32(map.indices.contains(skinJoint) ? map[skinJoint] : skinJoint)
                }
                joints.append(j)
            }
        }
        skin.jointWeightData.withUnsafeBytes { raw in
            for v in 0 ..< count {
                let b = raw.baseAddress!.advanced(by: v * weightBytes)
                var w = SIMD4<Float>(repeating: 0)
                for i in 0 ..< 4 {
                    switch weightBytes {
                    case 16: w[i] = b.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
                    case 8: w[i] = Float(b.loadUnaligned(fromByteOffset: i * 2, as: Float16.self))
                    default: w[i] = Float(b.loadUnaligned(fromByteOffset: i, as: UInt8.self)) / 255
                    }
                }
                weights.append(w)
            }
        }
        return (joints, weights, skeleton.bindTransforms)
    }()

    /// The exported normal at each shell vertex's rest position (the first
    /// exported copy within the bind tolerance; on a sharp edge the copies
    /// differ, and one of them stands for the vertex here), so the recording
    /// body gives the cloth what the entity gives it: positions and normals.
    static let shellNormals: [SIMD3<Float>]? = {
        guard let shell = asset?.garment(named: "shirt")?.render?.restPositionVectors, let exported else { return nil }
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (index, p) in exported.positions.enumerated() {
            grid[SIMD3<Int32>(Int32((p.x / 0.001).rounded(.down)), Int32((p.y / 0.001).rounded(.down)), Int32((p.z / 0.001).rounded(.down))), default: []].append(index)
        }
        return shell.map { p in
            exportedIndex(near: p, within: ZombieCloth.bindTolerance, grid: grid, positions: exported.positions).map { exported.normals[$0] } ?? SIMD3(0, 1, 0)
        }
    }()

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// The zombie stands a little off the origin and turned, so the model
    /// and world frames differ and the read-back's transform shows.
    static let standing = translation(SIMD3(1, 0, 2)) * simd_float4x4(simd_quatf(angle: 0.5, axis: SIMD3(0, 1, 0)))

    /// The exported vertices hashed into millimetre cells: the index of one
    /// within `distance` of a point, if any.
    static func exportedIndex(near p: SIMD3<Float>, within distance: Float, grid: [SIMD3<Int32>: [Int]], positions: [SIMD3<Float>]) -> Int? {
        let k = SIMD3<Int32>(Int32((p.x / 0.001).rounded(.down)), Int32((p.y / 0.001).rounded(.down)), Int32((p.z / 0.001).rounded(.down)))
        for dx in -1 ... 1 { for dy in -1 ... 1 { for dz in -1 ... 1 {
            for index in grid[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? [] where simd_distance(positions[index], p) <= distance { return index }
        } } }
        return nil
    }

    /// The pose of a bundled clip at a time, model space, sampled the way the
    /// clip-ground test samples it (translation and rotation keys interpolated
    /// on the rest transforms, parents first).
    static func clipPose(_ name: String, at time: Float) throws -> [simd_float4x4]? {
        guard let base = ZombieResources.baseURL, let joints = ClothFixtures.skeleton else { return nil }
        let url = base.appendingPathComponent("Animations/\(name)/\(name).untold")
        guard FileManager.default.fileExists(atPath: url.path),
              let skeleton = try NativeFormatLoader().loadAssetSync(from: base.appendingPathComponent("Models/Zombie/Zombie.untold")).nodes.compactMap(\.skeleton).first,
              let clip = try NativeFormatLoader().loadAssetSync(from: url).animationClips.first else { return nil }
        let channels = Dictionary(uniqueKeysWithValues: clip.channels.map { ($0.jointPath, $0) })
        func value(_ keys: [RuntimeTranslationKeyframe]) -> SIMD3<Float>? {
            guard let first = keys.first else { return nil }
            if time <= first.time { return first.value }
            for (a, b) in zip(keys, keys.dropFirst()) where time <= b.time {
                return simd_mix(a.value, b.value, SIMD3(repeating: (time - a.time) / max(b.time - a.time, 1e-6)))
            }
            return keys.last!.value
        }
        func rotation(_ keys: [RuntimeRotationKeyframe]) -> simd_quatf? {
            guard let first = keys.first else { return nil }
            if time <= first.time { return simd_normalize(simd_quatf(vector: first.value)) }
            for (a, b) in zip(keys, keys.dropFirst()) where time <= b.time {
                return simd_slerp(simd_normalize(simd_quatf(vector: a.value)), simd_normalize(simd_quatf(vector: b.value)), (time - a.time) / max(b.time - a.time, 1e-6))
            }
            return simd_normalize(simd_quatf(vector: keys.last!.value))
        }
        var locals = skeleton.restTransforms
        for index in joints.jointPaths.indices {
            guard let channel = channels[joints.jointPaths[index]] else { continue }
            let rest = skeleton.restTransforms[index]
            var translation = simd_float3(rest.columns.3.x, rest.columns.3.y, rest.columns.3.z)
            var basis = simd_float3x3(
                simd_float3(rest.columns.0.x, rest.columns.0.y, rest.columns.0.z),
                simd_float3(rest.columns.1.x, rest.columns.1.y, rest.columns.1.z),
                simd_float3(rest.columns.2.x, rest.columns.2.y, rest.columns.2.z))
            if let t = value(channel.translations) { translation = t }
            if let q = rotation(channel.rotations) { basis = simd_float3x3(q) }
            locals[index] = simd_float4x4(simd_float4(basis.columns.0, 0), simd_float4(basis.columns.1, 0), simd_float4(basis.columns.2, 0), simd_float4(translation, 1))
        }
        var model = [simd_float4x4](repeating: matrix_identity_float4x4, count: locals.count)
        for index in locals.indices {
            let parent = joints.parentIndices[index].map { model[$0] } ?? matrix_identity_float4x4
            model[index] = parent * locals[index]
        }
        return model
    }
}
