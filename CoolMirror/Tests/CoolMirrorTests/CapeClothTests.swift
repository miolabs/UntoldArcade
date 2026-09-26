//
//  CapeClothTests.swift
//  CoolMirrorTests
//
//  Batman's cape as Jolt cloth, on this Mac: the cape primitive is read
//  from the shipped asset, built into the cloth topology the app uses,
//  and simulated headless for a few seconds hanging from its collar. What
//  explodes on the headset must explode here first.
//

@testable import CoolMirror
import simd
import UntoldEngine
import UntoldJoltPhysics
import XCTest

final class CapeClothTests: XCTestCase {
    private static var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/CoolMirror/Assets/Models/batman/batman.untold")
    }

    private struct Cape {
        var cloth: CoolMirrorCapeCloth
        var restJoints: [CoolMirrorCapeCloth.JointFrame]
        var jointIndex: (String) -> Int?
    }

    /// The Batman entity's display transform in the mirror: scaled to a
    /// believable height, turned to face the wearer, 1.6 m ahead.
    private static let displayScale: Float = CoolMirrorCharacter.batman.displayScale
    private static let facing = simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0))
    private static let origin = simd_float3(0, 0, -1.6)
    private static var modelToWorld: simd_float4x4 {
        var m = simd_float4x4(facing)
        m.columns.0 *= displayScale
        m.columns.1 *= displayScale
        m.columns.2 *= displayScale
        m.columns.3 = simd_float4(origin, 1)
        return m
    }

    /// The cape primitive of the Batman asset as the app's cloth, in the
    /// rest pose (no animation on this Mac), placed like the mirror does.
    private func loadCape() throws -> Cape? {
        guard FileManager.default.fileExists(atPath: Self.assetURL.path) else { return nil }
        let asset = try NativeFormatLoader().loadAssetSync(from: Self.assetURL)
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first else {
            XCTFail("no skeleton in the asset")
            return nil
        }
        // Rest joint frames in model space, composed through the hierarchy.
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: skeleton.jointPaths.count)
        var restJoints: [CoolMirrorCapeCloth.JointFrame] = []
        for index in 0 ..< skeleton.jointPaths.count {
            let local = skeleton.restTransforms[index]
            if let parent = skeleton.parentIndices[index], parent < index {
                world[index] = world[parent] * local
            } else {
                world[index] = local
            }
            let m = Self.modelToWorld * world[index]
            let rotation = simd_quatf(simd_float3x3(
                simd_normalize(simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                simd_normalize(simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                simd_normalize(simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            ))
            restJoints.append(.init(position: simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z), rotation: rotation))
        }
        func jointIndex(_ name: String) -> Int? {
            skeleton.jointPaths.firstIndex { $0 == name || $0.hasSuffix("/" + name) }
        }
        let rig = try XCTUnwrap(CoolMirrorCapeRig.rig(for: .batman))
        let collarJoints = Set([rig.neck, rig.upperChest, rig.leftClavicle, rig.rightClavicle, rig.head].compactMap(jointIndex))

        for node in asset.nodes {
            for primitive in node.primitives where (primitive.material?.name ?? "").localizedCaseInsensitiveContains("cape") || primitive.name.localizedCaseInsensitiveContains("cape") {
                let geometry = try primitive.decodedGeometry()
                let map = primitive.skin?.skinToSkeletonMap ?? []
                let jointIndices = geometry.jointIndices.map { ids -> simd_ushort4 in
                    func remap(_ id: UInt16) -> UInt16 {
                        map.indices.contains(Int(id)) ? UInt16(clamping: map[Int(id)]) : id
                    }
                    return simd_ushort4(remap(ids.x), remap(ids.y), remap(ids.z), remap(ids.w))
                }
                let toWorld = Self.modelToWorld * primitive.localTransform
                let positions = geometry.positions.map { p -> simd_float3 in
                    let m = toWorld * simd_float4(p, 1)
                    return simd_float3(m.x, m.y, m.z)
                }
                let cloth = CoolMirrorCapeCloth(
                    positions: positions, normals: geometry.normals, triangles: geometry.triangles,
                    jointIndices: jointIndices, jointWeights: geometry.jointWeights,
                    restJoints: restJoints, joints: restJoints, collarJoints: collarJoints, collarWeight: 0.45,
                    particleMass: 0.02
                )
                return Cape(cloth: cloth, restJoints: restJoints, jointIndex: jointIndex)
            }
        }
        XCTFail("no cape primitive in the asset")
        return nil
    }

    func testCapeTopologyIsCleanCloth() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        let stats = cape.cloth.stats
        print("cape cloth: \(stats)")
        XCTAssertGreaterThan(stats.particles, 100)
        XCTAssertGreaterThan(stats.faces, 100)
        XCTAssertGreaterThan(stats.pinned, 10, "the collar must pin to the skeleton")
        XCTAssertLessThan(stats.pinned, stats.particles / 2, "only the collar is pinned")
        XCTAssertEqual(stats.nonManifoldEdges, 0, "an edge shared by more than two faces breaks the bend constraints")
        XCTAssertGreaterThan(stats.minEdge, 5e-5, "an edge under a twentieth of a millimetre is a welding leftover")
    }

    func testCapeHangsFromItsCollarWithoutExploding() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        var settings = JoltWorldSettings()
        settings.workerThreads = 0
        settings.collisionSteps = 3
        let backend = JoltPhysicsBackend(settings: settings)
        backend.configure(PhysicsWorldConfiguration())
        var descriptor = JoltSoftBodyDescriptor(
            vertices: cape.cloth.startWorld, inverseMasses: cape.cloth.inverseMasses, faces: cape.cloth.faces,
            compliance: 2e-6, shearCompliance: 2e-5, bendCompliance: 4e-4
        )
        descriptor.iterations = 8
        descriptor.linearDamping = 0.6
        descriptor.vertexRadius = 0.008
        let body = try XCTUnwrap(backend.addSoftBody(descriptor), "Jolt rejected the cape")
        let targets = cape.cloth.pinTargets(joints: cape.restJoints)
        var positions: [SIMD3<Float>] = []
        var farthestSeen: Float = 0
        for frame in 0 ..< 90 {
            backend.setSoftBodyVertices(body, indices: cape.cloth.pinned, worldPositions: targets)
            backend.step(deltaTime: 1.0 / 30.0)
            backend.readSoftBodyVertices(body, into: &positions)
            let nonFinite = positions.filter { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) }.count
            let farthest = positions.map { simd_length($0 - Self.origin) }.max() ?? 0
            farthestSeen = max(farthestSeen, farthest)
            XCTAssertEqual(nonFinite, 0, "frame \(frame)")
            XCTAssertLessThan(farthest, 3.5, "frame \(frame): the cape flew to \(farthest) m")
            if nonFinite > 0 || farthest > 3.5 { break }
        }
        print("cape cloth: farthest particle over 3 s at 30 fps = \(farthestSeen) m")
        backend.removeSoftBody(body)
    }

    /// What made the cape fly: not the colliders but the bend type. Under
    /// a swaying, turning collar, dihedral bends diverge and distance bends
    /// hold (the cape ships with distance bends).
    func testDistanceBendsHoldWhereDihedralBendsDiverge() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        let rig = try XCTUnwrap(CoolMirrorCapeRig.rig(for: .batman))
        let spine = try XCTUnwrap(CoolMirrorRigProfile.profile(for: .batman)).spine
        _ = spine
        let all = CoolMirrorJoltCape.bones(rig)
        _ = all
        // (name, sway amplitude m, turn amplitude rad, compliance, iterations, damping, bend)
        let variants: [(String, Float, Float, Float, UInt32, Float, JoltSoftBodyDescriptor.BendType)] = [
            ("sway+turn, dihedral, 8 it", 0.08, 0.26, 2e-6, 8, 0.6, .dihedral),
            ("sway+turn, distance, 8 it", 0.08, 0.26, 2e-6, 8, 0.6, .distance),
        ]
        var farthestByName: [String: Float] = [:]
        for (name, swayAmplitude, turnAmplitude, compliance, iterations, damping, bendType) in variants {
            let bones: [(from: String, to: String, radius: Float)] = []
            let setTargets = false
            let sway = true
            var settings = JoltWorldSettings()
            settings.workerThreads = 0
            settings.collisionSteps = 3
            let backend = JoltPhysicsBackend(settings: settings)
            backend.configure(PhysicsWorldConfiguration())
            var cloth = cape.cloth
            let capsules: [CoolMirrorCapeCloth.Capsule] = bones.compactMap { bone in
                guard let a = cape.jointIndex(bone.from), let b = cape.jointIndex(bone.to) else { return nil }
                return .init(start: cape.restJoints[a].position, end: cape.restJoints[b].position, radius: bone.radius)
            }
            cloth.pushStartOut(of: capsules, margin: 0.012)
            // How many pinned particles sit inside a collider?
            var pinnedInside = 0
            for pin in cloth.pinned {
                let p = cloth.startWorld[Int(pin)]
                for c in capsules {
                    let axis = c.end - c.start
                    let t = simd_clamp(simd_dot(p - c.start, axis) / max(simd_length_squared(axis), 1e-8), 0, 1)
                    if simd_length(p - (c.start + axis * t)) < c.radius { pinnedInside += 1; break }
                }
            }
            var descriptor = JoltSoftBodyDescriptor(vertices: cloth.startWorld, inverseMasses: cloth.inverseMasses, faces: cloth.faces, compliance: compliance, shearCompliance: compliance * 10, bendCompliance: name.hasSuffix("4e-3") ? 4e-3 : 4e-4)
            descriptor.iterations = iterations
            descriptor.linearDamping = damping
            descriptor.bendType = bendType
            descriptor.vertexRadius = 0.008
            let body = try XCTUnwrap(backend.addSoftBody(descriptor))
            func capsulePose(_ a: simd_float3, _ b: simd_float3) -> (simd_float3, simd_quatf, Float) {
                let axis = b - a
                let length = simd_length(axis)
                let direction = axis / max(length, 1e-5)
                let up = simd_float3(0, 1, 0)
                let rotation = simd_dot(up, direction) < -0.9999 ? simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0)) : simd_normalize(simd_quatf(from: up, to: direction))
                return ((a + b) * 0.5, rotation, length)
            }
            var bodies: [(JoltKinematicBody, Int, Int)] = []
            for bone in bones {
                guard let a = cape.jointIndex(bone.from), let b = cape.jointIndex(bone.to) else { continue }
                let (position, rotation, length) = capsulePose(cape.restJoints[a].position, cape.restJoints[b].position)
                let capsule = try XCTUnwrap(backend.addKinematicCapsule(radius: bone.radius, height: length + 2 * bone.radius, position: position, rotation: rotation))
                bodies.append((capsule, a, b))
            }
            var positions: [SIMD3<Float>] = []
            var farthest: Float = 0
            var firstFrameFar: Float = 0
            for frame in 0 ..< 30 {
                let t = Float(frame) / 30
                let swayOffset = sway ? simd_float3(swayAmplitude * sin(t * 2.5), 0, 0) : .zero
                let turn = sway ? simd_quatf(angle: turnAmplitude * sin(t * 1.7), axis: simd_float3(0, 1, 0)) : simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
                let joints = cape.restJoints.map { joint -> CoolMirrorCapeCloth.JointFrame in
                    .init(position: Self.origin + turn.act(joint.position - Self.origin) + swayOffset, rotation: simd_normalize(turn * joint.rotation))
                }
                if setTargets {
                    for (capsule, a, b) in bodies {
                        let (position, rotation, _) = capsulePose(joints[a].position, joints[b].position)
                        backend.setKinematicTarget(capsule, position: position, rotation: rotation)
                    }
                }
                backend.setSoftBodyVertices(body, indices: cloth.pinned, worldPositions: cloth.pinTargets(joints: joints))
                backend.step(deltaTime: 1.0 / 30.0)
                backend.readSoftBodyVertices(body, into: &positions)
                let f = positions.map { simd_length($0 - Self.origin) }.max() ?? 0
                if frame == 0 { firstFrameFar = f }
                farthest = max(farthest, f)
            }
            print("cape collider \(name): pinned inside \(pinnedInside), farthest after frame 1 \(firstFrameFar) m, over 1 s \(farthest) m")
            farthestByName[name] = farthest
        }
        XCTAssertLessThan(try XCTUnwrap(farthestByName["sway+turn, distance, 8 it"]), 1.8)
        XCTAssertGreaterThan(try XCTUnwrap(farthestByName["sway+turn, dihedral, 8 it"]), 2.5, "the divergence this test exists for")
    }

    /// The device scenario: the scaled character with capsules on its
    /// bones and a collar that sways, 5 s at 30 fps.
    func testCapeSurvivesCollidersAndASwayingCollar() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        var settings = JoltWorldSettings()
        settings.workerThreads = 0
        settings.collisionSteps = 3
        let backend = JoltPhysicsBackend(settings: settings)
        backend.configure(PhysicsWorldConfiguration())
        let rig = try XCTUnwrap(CoolMirrorCapeRig.rig(for: .batman))
        let bones = CoolMirrorJoltCape.bones(rig)
        // Like the app: the cloth starts outside the colliders, with a speed ceiling.
        var cloth = cape.cloth
        cloth.pushStartOut(of: bones.compactMap { bone in
            guard let a = cape.jointIndex(bone.from), let b = cape.jointIndex(bone.to) else { return nil }
            return .init(start: cape.restJoints[a].position, end: cape.restJoints[b].position, radius: bone.radius)
        }, margin: 0.012)
        var descriptor = JoltSoftBodyDescriptor(
            vertices: cloth.startWorld, inverseMasses: cloth.inverseMasses, faces: cloth.faces,
            compliance: 2e-6, shearCompliance: 2e-5, bendCompliance: 4e-4
        )
        descriptor.iterations = 8
        descriptor.linearDamping = 0.6
        descriptor.vertexRadius = 0.008
        descriptor.maxLinearVelocity = CoolMirrorJoltCape.maxParticleSpeed
        descriptor.bendType = .distance
        let body = try XCTUnwrap(backend.addSoftBody(descriptor))
        func pose(_ a: simd_float3, _ b: simd_float3) -> (simd_float3, simd_quatf, Float) {
            let axis = b - a
            let length = simd_length(axis)
            let up = simd_float3(0, 1, 0)
            let direction = axis / max(length, 1e-5)
            let rotation = simd_dot(up, direction) < -0.9999 ? simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0)) : simd_normalize(simd_quatf(from: up, to: direction))
            return ((a + b) * 0.5, rotation, length)
        }
        var colliders: [(JoltKinematicBody, Int, Int, Float)] = []
        for (from, to, radius) in bones {
            guard let a = cape.jointIndex(from), let b = cape.jointIndex(to) else { continue }
            let (position, rotation, length) = pose(cape.restJoints[a].position, cape.restJoints[b].position)
            let capsule = try XCTUnwrap(backend.addKinematicCapsule(radius: radius, height: max(length + 2 * radius, 2 * radius + 0.01), position: position, rotation: rotation))
            colliders.append((capsule, a, b, radius))
        }
        XCTAssertEqual(colliders.count, bones.count, "every bone found")

        var positions: [SIMD3<Float>] = []
        var farthestSeen: Float = 0
        for frame in 0 ..< 150 {
            // The wearer sways 8 cm sideways and turns ±15°: every joint moves.
            let t = Float(frame) / 30
            let sway = simd_float3(0.08 * sin(t * 2.5), 0, 0)
            let turn = simd_quatf(angle: 0.26 * sin(t * 1.7), axis: simd_float3(0, 1, 0))
            let joints = cape.restJoints.map { joint -> CoolMirrorCapeCloth.JointFrame in
                let relative = joint.position - Self.origin
                return .init(position: Self.origin + turn.act(relative) + sway, rotation: simd_normalize(turn * joint.rotation))
            }
            for (capsule, a, b, _) in colliders {
                let (position, rotation, _) = pose(joints[a].position, joints[b].position)
                backend.setKinematicTarget(capsule, position: position, rotation: rotation)
            }
            backend.setSoftBodyVertices(body, indices: cape.cloth.pinned, worldPositions: cape.cloth.pinTargets(joints: joints))
            backend.step(deltaTime: 1.0 / 30.0)
            backend.readSoftBodyVertices(body, into: &positions)
            let nonFinite = positions.filter { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) }.count
            let farthest = positions.map { simd_length($0 - Self.origin) }.max() ?? 0
            farthestSeen = max(farthestSeen, farthest)
            XCTAssertEqual(nonFinite, 0, "frame \(frame)")
            XCTAssertLessThan(farthest, 2.5, "frame \(frame): the cape flew to \(farthest) m")
            if nonFinite > 0 || farthest > 2.5 { break }
        }
        print("cape cloth: with colliders and a swaying collar, farthest particle over 5 s = \(farthestSeen) m")
        for (capsule, _, _, _) in colliders {
            backend.removeKinematicBody(capsule)
        }
        backend.removeSoftBody(body)
    }
}
