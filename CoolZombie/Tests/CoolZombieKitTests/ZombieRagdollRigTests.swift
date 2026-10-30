//
//  ZombieRagdollRigTests.swift
//  CoolZombieKitTests
//
//  The ragdoll rig built from a skeleton laid out like the zombie's bind
//  pose (the mannequin, Mannequin.swift), without an engine; and its
//  capsules, fitted to the exported body, held to the export itself.
//

@testable import CoolZombieKit
import simd
import UntoldEngine
import UntoldJoltPhysics
import XCTest

final class ZombieRagdollRigTests: XCTestCase {
    func testBuildsTwentyPartsOnTheJointsParentsFirst() throws {
        let joints = mannequin()
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: joints, entity: 42, layer: 1))
        XCTAssertEqual(rig.partCount, 20)
        XCTAssertEqual(rig.descriptor.parts.count, 20)
        XCTAssertEqual(rig.descriptor.entity, 42)
        XCTAssertEqual(rig.descriptor.layer, 1)
        XCTAssertEqual(Set(rig.jointIndices).count, 20, "one joint per part")
        for (index, parent) in rig.parentIndices.enumerated() {
            if let parent {
                XCTAssertLessThan(parent, index)
                // Every part hangs from the part on its joint's own parent
                // joint: no bind-pose offset is frozen into a constraint.
                XCTAssertEqual(joints.parentIndices[rig.jointIndices[index]], rig.jointIndices[parent], "\(rig.partNames[index]) hangs from its parent joint")
            } else {
                XCTAssertEqual(index, 0, "only the pelvis has no parent")
            }
        }
        // Parts sit on their joints and run along their bones.
        let thigh = try XCTUnwrap(rig.partIndex(named: "thigh_l"))
        let thighJoint = try XCTUnwrap(joints.jointPaths.firstIndex(of: "/root/pelvis/thigh_l"))
        XCTAssertEqual(rig.jointIndices[thigh], thighJoint)
        XCTAssertEqual(rig.lengths[thigh], 0.414, accuracy: 0.01)
        let calfJoint = joints.bindModelTransforms[thighJoint + 1].columns.3
        let along = rig.descriptor.parts[thigh].twistAxis
        let expected = simd_normalize(simd_float3(calfJoint.x, calfJoint.y, calfJoint.z) - rig.descriptor.parts[thigh].position)
        XCTAssertEqual(simd_dot(along, expected), 1, accuracy: 1e-4)
        XCTAssertEqual(simd_dot(along, rig.descriptor.parts[thigh].planeAxis), 0, accuracy: 1e-4)
        // The capsule is the spec's, fitted to the body in model space, carried
        // into the part's frame: out through the part's bind transform it is
        // the spec's line again, its Y axis along it, the caps inside the tips.
        let part = rig.descriptor.parts[thigh]
        let spec = ZombieRagdollRig.specs[thigh]
        let centre = part.position + part.rotation.act(part.shapeOffset)
        XCTAssertEqual(simd_distance(centre, (spec.capsule.from + spec.capsule.to) / 2), 0, accuracy: 1e-4)
        let capsuleAxis = part.rotation.act(part.shapeRotation.act(simd_float3(0, 1, 0)))
        XCTAssertEqual(simd_dot(capsuleAxis, simd_normalize(spec.capsule.to - spec.capsule.from)), 1, accuracy: 1e-4)
        XCTAssertGreaterThan(simd_dot(capsuleAxis, along), 0.98, "the thigh's capsule runs along its bone, within a few degrees")
        guard case let .capsule(radius, height) = part.shape else { return XCTFail("capsule") }
        XCTAssertEqual(radius, spec.capsule.radius)
        XCTAssertEqual(height, simd_length(spec.capsule.to - spec.capsule.from) - 2 * radius, accuracy: 1e-5)
        XCTAssertEqual(rig.descriptor.parts.map(\.mass).reduce(0, +), 76.4, accuracy: 0.1)
    }

    func testSubtreeAndNearestPart() throws {
        let joints = mannequin()
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: joints, entity: 1, layer: 1))
        let upperArm = try XCTUnwrap(rig.partIndex(named: "upperarm_l"))
        let subtree = rig.subtree(of: upperArm).map { rig.partNames[$0] }
        XCTAssertEqual(subtree, ["upperarm_l", "lowerarm_l", "hand_l"])
        let spine1 = try XCTUnwrap(rig.partIndex(named: "spine_01"))
        XCTAssertEqual(rig.subtree(of: spine1).count, 13, "the spine, the neck, the head and both arms hang from the first spine link")

        let pose = rig.partWorldTransforms(jointModelTransforms: joints.bindModelTransforms, entityWorld: matrix_identity_float4x4)
        XCTAssertEqual(rig.partNames[rig.nearestPart(to: simd_float3(0.62, 1.02, 0.05), partWorldTransforms: pose)], "hand_l")
        XCTAssertEqual(rig.partNames[rig.nearestPart(to: simd_float3(-0.15, 0.25, -0.05), partWorldTransforms: pose)], "calf_r")
        XCTAssertEqual(rig.partNames[rig.nearestPart(to: simd_float3(0, 1.65, 0.05), partWorldTransforms: pose)], "head")
    }

    func testPhysicsPoseMapsPartsBackOntoTheirJoints() throws {
        let joints = mannequin()
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: joints, entity: 1, layer: 1))
        var entity = matrix_identity_float4x4
        entity.columns.3 = simd_float4(2, 0, -1, 1)
        let world = rig.partWorldTransforms(jointModelTransforms: joints.bindModelTransforms, entityWorld: entity)
        var weights = Array(repeating: Float(0), count: rig.partCount)
        weights[0] = 1
        let pose = rig.physicsPose(partWorldTransforms: world, entityWorld: entity, partWeights: weights)
        XCTAssertEqual(pose.transforms.count, joints.jointPaths.count)
        XCTAssertEqual(pose.weights.count, joints.jointPaths.count)
        let pelvisJoint = rig.jointIndices[0]
        XCTAssertEqual(pose.weights[pelvisJoint], 1)
        XCTAssertEqual(pose.weights.reduce(0, +), 1, "only the pelvis is weighted")
        let back = pose.transforms[pelvisJoint].columns.3
        XCTAssertEqual(back.x, 0, accuracy: 1e-4)
        XCTAssertEqual(back.y, 0.891, accuracy: 1e-4)
        XCTAssertEqual(back.z, 0.007, accuracy: 1e-4)
    }

    func testAHitOnThePelvisReactsThroughTheTorso() throws {
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: mannequin(), entity: 7, layer: 1))
        let pelvis = try XCTUnwrap(rig.partIndex(named: "pelvis"))
        let spine = try XCTUnwrap(rig.partIndex(named: "spine_01"))
        let reaction = rig.reactionSubtree(for: pelvis)
        XCTAssertEqual(reaction.anchor, spine, "the root has no joint to hold it")
        XCTAssertEqual(reaction.parts, rig.subtree(of: spine))
        XCTAssertFalse(reaction.parts.contains(pelvis))
        XCTAssertFalse(reaction.parts.contains(try XCTUnwrap(rig.partIndex(named: "thigh_l"))))

        let calf = try XCTUnwrap(rig.partIndex(named: "calf_r"))
        let leg = rig.reactionSubtree(for: calf)
        XCTAssertEqual(leg.anchor, calf)
        XCTAssertEqual(leg.parts, [calf, try XCTUnwrap(rig.partIndex(named: "foot_r"))])
    }

    func testAHardHitStaggersTheWholeChainUnderThePelvis() throws {
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: mannequin(), entity: 7, layer: 1))
        let head = try XCTUnwrap(rig.partIndex(named: "head"))
        let spine1 = try XCTUnwrap(rig.partIndex(named: "spine_01"))
        let upper = rig.staggerSubtree(for: head)
        XCTAssertEqual(upper.anchor, head, "the hit lands on the head")
        XCTAssertEqual(upper.parts, rig.subtree(of: spine1), "and the whole upper body staggers")
        let hand = try XCTUnwrap(rig.partIndex(named: "hand_r"))
        XCTAssertEqual(rig.staggerSubtree(for: hand).parts, rig.subtree(of: spine1), "a hit on a hand too")
        let calf = try XCTUnwrap(rig.partIndex(named: "calf_l"))
        let thigh = try XCTUnwrap(rig.partIndex(named: "thigh_l"))
        XCTAssertEqual(rig.staggerSubtree(for: calf).parts, rig.subtree(of: thigh), "a hit on a leg takes that leg")
        XCTAssertEqual(rig.staggerSubtree(for: 0).parts, rig.subtree(of: spine1), "a hit on the pelvis goes through the torso")
    }

    func testFootCapsulesRestOnTheFloor() throws {
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: mannequin(), entity: 7, layer: 1))
        for side in ["l", "r"] {
            let index = try XCTUnwrap(rig.partIndex(named: "foot_\(side)"))
            let part = rig.descriptor.parts[index]
            guard case let .capsule(radius, height) = part.shape else { return XCTFail("capsule") }
            // The capsule's axis is its local Y, turned by shapeRotation
            // about the shape's centre at shapeOffset, all in the part's
            // frame, which the bind pose places at the ankle.
            let axis = part.shapeRotation.act(simd_float3(0, height / 2, 0))
            for end in [part.shapeOffset + axis, part.shapeOffset - axis] {
                let world = part.position + part.rotation.act(end)
                XCTAssertGreaterThan(world.y - radius, -0.01, "foot_\(side) end at \(world)")
                XCTAssertLessThan(world.y - radius, 0.06, "foot_\(side) end floats at \(world)")
            }
        }
    }

    func testHingesLieAcrossTheBody() throws {
        let joints = mannequin()
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: joints, entity: 7, layer: 1))
        // Spine and legs bend about the sideways axis; every hinge is square
        // to its bone and to the body's front.
        for name in ["spine_02", "neck_01", "head", "thigh_l", "calf_l", "foot_l"] {
            let index = try XCTUnwrap(rig.partIndex(named: name))
            let part = rig.descriptor.parts[index]
            XCTAssertGreaterThan(abs(part.planeAxis.x), 0.8, "\(name)'s hinge is sideways")
            XCTAssertEqual(simd_dot(part.planeAxis, part.twistAxis), 0, accuracy: 1e-4, "\(name)'s hinge is square to the bone")
        }
        for name in ["upperarm_l", "lowerarm_r", "clavicle_l"] {
            let index = try XCTUnwrap(rig.partIndex(named: name))
            let part = rig.descriptor.parts[index]
            XCTAssertEqual(simd_dot(part.planeAxis, rig.forward), 0, accuracy: 0.05, "\(name)'s hinge lies in the arm plane")
            XCTAssertEqual(simd_dot(part.planeAxis, part.twistAxis), 0, accuracy: 1e-4, "\(name)'s hinge is square to the bone")
        }
    }

    func testConesAreCentredIntoTheBend() throws {
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: mannequin(), entity: 7, layer: 1))
        XCTAssertEqual(simd_dot(rig.forward, simd_float3(0, 0, 1)), 1, accuracy: 1e-3, "the toes point +Z on the mannequin")
        func centring(_ name: String) -> (bone: simd_float3, parent: simd_float3?, plane: simd_float3?) {
            let part = rig.descriptor.parts[rig.partIndex(named: name)!]
            return (part.twistAxis, part.parentTwistAxis, part.parentPlaneAxis)
        }
        // The knee's cone is centred behind the thigh's line, the hip's,
        // elbow's and spine's ahead of it, by the spec's angle.
        for (name, toward, degrees) in [("calf_l", -rig.forward, Float(72)), ("calf_r", -rig.forward, 72), ("thigh_l", rig.forward, 50),
                                        ("lowerarm_l", rig.forward, 70), ("lowerarm_r", rig.forward, 70), ("spine_02", rig.forward, 10)]
        {
            let c = centring(name)
            let parent = try XCTUnwrap(c.parent, name)
            XCTAssertGreaterThan(simd_dot(parent, toward), simd_dot(c.bone, toward), "\(name)'s centre leans into the bend")
            XCTAssertEqual(acos(min(max(simd_dot(parent, c.bone), -1), 1)) * 180 / .pi, degrees, accuracy: 0.5, "\(name) centred by the spec's angle")
            XCTAssertEqual(simd_dot(parent, try XCTUnwrap(c.plane)), 0, accuracy: 1e-4, "\(name)'s plane axis stays perpendicular")
        }
        // Wrists, ankles, the neck and the clavicles stay centred on the bind pose.
        for name in ["hand_l", "foot_r", "neck_01", "clavicle_l"] {
            XCTAssertNil(centring(name).parent, name)
        }
        // A hinge bends toward the normal axis (Jolt's normal half cone)
        // and gets a sliver across it.
        let knee = rig.descriptor.parts[try XCTUnwrap(rig.partIndex(named: "calf_l"))]
        XCTAssertEqual(knee.normalHalfConeAngle, 75 * .pi / 180, accuracy: 1e-4)
        XCTAssertLessThan(knee.planeHalfConeAngle, 15 * .pi / 180)
        // And the centring turns the parent's twist axis toward the normal.
        let normal = simd_cross(knee.twistAxis, knee.planeAxis)
        let parentTwist = try XCTUnwrap(knee.parentTwistAxis)
        XCTAssertGreaterThan(abs(simd_dot(parentTwist, normal)), 0.9, "the knee's centre lies in its bending plane")
    }

    func testTorsoAndLegsNeverCollide() throws {
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: mannequin(), entity: 7, layer: 1))
        let pairs = Set(rig.descriptor.disabledCollisionPairs.map { "\(rig.partNames[$0.0])-\(rig.partNames[$0.1])" })
        for pair in ["spine_01-thigh_l", "spine_02-thigh_r", "spine_03-thigh_l", "pelvis-calf_l", "pelvis-calf_r", "spine_01-calf_r"] {
            XCTAssertTrue(pairs.contains(pair), pair)
        }
        XCTAssertFalse(pairs.contains("pelvis-thigh_l"), "parent/child pairs are Jolt's to disable")
        for pair in ["spine_03-lowerarm_l", "head-hand_r", "spine_02-upperarm_l", "clavicle_r-hand_r"] {
            XCTAssertTrue(pairs.contains(pair), pair)
        }
        XCTAssertFalse(pairs.contains("clavicle_l-upperarm_l"), "parent/child")
        XCTAssertFalse(pairs.contains("thigh_l-hand_l"), "arms still meet legs")
        for pair in ["pelvis-spine_02", "spine_01-spine_03", "pelvis-head", "spine_02-neck_01"] {
            XCTAssertTrue(pairs.contains(pair), "\(pair): the torso chain never collides with itself")
        }
        XCTAssertFalse(pairs.contains("pelvis-spine_01"), "parent/child")
        XCTAssertEqual(pairs.count, 14 + 8 * 6 - 2 + 10)
    }

    func testAMissingJointMeansNoRig() {
        // Without the last joint (ball_r) the right foot has nothing to aim at.
        let full = mannequin()
        let joints = SkeletonJointInfo(
            jointPaths: Array(full.jointPaths.dropLast()),
            parentIndices: Array(full.parentIndices.dropLast()),
            bindModelTransforms: Array(full.bindModelTransforms.dropLast())
        )
        XCTAssertNil(ZombieRagdollRig(joints: joints, entity: 1, layer: 1))
    }

    // MARK: - The capsules against the exported body

    /// The exported model as the fit needs it: the mesh's vertices, each
    /// with the joint that moves it most (the skin's heaviest weight), the
    /// skeleton's bind pose, and the cloth sidecar.
    private struct Export {
        let positions: [simd_float3]
        /// Per vertex, the name of its dominant joint (`spine_03`, `hand_l`).
        let dominantJoint: [String]
        let joints: SkeletonJointInfo
        let cloth: ZombieClothAsset
    }

    private func loadExport() throws -> Export? {
        guard let base = ZombieResources.baseURL else { return nil }
        let url = base.appendingPathComponent("Models/Zombie/Zombie.untold")
        guard FileManager.default.fileExists(atPath: url.path), let clothURL = ZombieClothAsset.bundledURL,
              FileManager.default.fileExists(atPath: clothURL.path) else { return nil }
        let asset = try NativeFormatLoader().loadAssetSync(from: url)
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first,
              let primitive = asset.nodes.flatMap(\.primitives).first, let skin = primitive.skin else { return nil }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: skeleton.jointPaths.count)
        for index in skeleton.jointPaths.indices {
            let parent = skeleton.parentIndices[index].map { world[$0] } ?? matrix_identity_float4x4
            world[index] = parent * skeleton.restTransforms[index]
        }
        // The skin's joint indices and weights, four per vertex, in whichever
        // width the exporter chose (ZombieSkinTests reads them the same way).
        let count = primitive.vertexCount
        let indexBytes = skin.jointIndexData.count / count, weightBytes = skin.jointWeightData.count / count
        let names = skeleton.jointPaths.map { String($0.split(separator: "/").last ?? "") }
        var dominant: [String] = []
        dominant.reserveCapacity(count)
        skin.jointIndexData.withUnsafeBytes { indexRaw in
            skin.jointWeightData.withUnsafeBytes { weightRaw in
                for v in 0 ..< count {
                    let ib = indexRaw.baseAddress!.advanced(by: v * indexBytes), wb = weightRaw.baseAddress!.advanced(by: v * weightBytes)
                    var best = -1, bestWeight: Float = -1
                    for k in 0 ..< 4 {
                        let joint: Int
                        switch indexBytes {
                        case 4: joint = Int(ib.load(fromByteOffset: k, as: UInt8.self))
                        case 8: joint = Int(ib.load(fromByteOffset: k * 2, as: UInt16.self))
                        default: joint = Int(ib.load(fromByteOffset: k * 4, as: UInt32.self))
                        }
                        let weight: Float
                        switch weightBytes {
                        case 16: weight = wb.load(fromByteOffset: k * 4, as: Float.self)
                        case 8: weight = Float(wb.load(fromByteOffset: k * 2, as: Float16.self))
                        default: weight = Float(wb.load(fromByteOffset: k, as: UInt8.self)) / 255
                        }
                        if weight > bestWeight { bestWeight = weight; best = joint }
                    }
                    let skeletonIndex = best >= 0 && best < skin.skinToSkeletonMap.count ? skin.skinToSkeletonMap[best] : best
                    dominant.append(names.indices.contains(skeletonIndex) ? names[skeletonIndex] : "")
                }
            }
        }
        return Export(
            positions: try primitive.decodedGeometry().positions,
            dominantJoint: dominant,
            joints: SkeletonJointInfo(jointPaths: skeleton.jointPaths, parentIndices: skeleton.parentIndices, bindModelTransforms: world),
            cloth: try ZombieClothAsset.load(from: clothURL)
        )
    }

    /// A garment proxy's surface as points: every triangle of the sidecar
    /// sampled on the barycentric lattice with six steps along each edge — 28
    /// points a triangle, the particles among them — as `fit_capsules` samples
    /// it. The particles alone put the surface 0.3-2.6 mm farther than it is.
    private func surfacePoints(_ garment: ZombieClothAsset.Garment, steps n: Int = 6) -> [simd_float3] {
        let p = garment.positions
        var points: [simd_float3] = []
        points.reserveCapacity(garment.triangles.count * (n + 1) * (n + 2) / 2)
        for t in garment.triangles {
            let a = p[t[0]], b = p[t[1]], c = p[t[2]]
            for i in 0 ... n {
                for j in 0 ... (n - i) {
                    points.append((a * Float(i) + b * Float(j) + c * Float(n - i - j)) / Float(n))
                }
            }
        }
        return points
    }

    /// Every capsule sits inside the body and under the clothes, on the model
    /// as exported, and on its own bone. Around each capsule's own axis, in
    /// bins of a centimetre along it and 15° around it, the skin's reach is
    /// the farthest exported vertex in the bin among those the part's own
    /// bones move (`fit_capsules` uses the same sets: the upper torso takes
    /// the clavicles' skin, a foot its ball's), so the teeth and the eyes
    /// inside the head are never the farthest and another limb in the same
    /// bin — a hand beside the hips, the other thigh — never stands in for
    /// the skin; a bin without own skin takes the skin of the parts the
    /// capsule's caps enter (its parent's and children's bones), since the
    /// caps lie inside those by design; a bin with no skin at all takes the
    /// mean reach of the bins around it, since the shoes and the palms are
    /// meshed coarser than the bins and the scalp has a gap under the hair.
    /// No point of the capsule's surface reaches more than 5 mm past that
    /// reach. Every point of the shirt's
    /// and the trousers' surfaces (`surfacePoints`) stays 2 mm clear of every
    /// capsule — under the clothes the export keeps no skin (the prep culls
    /// it), so there the garment is the bound, and the trousers bound the
    /// legs and the hips as the shirt the torso and the arms. Each sample is
    /// told which bound it had — own skin, neighbour skin, a garment, or
    /// none — and the shares are printed; a sample with no bound is a cap
    /// deep inside the next link (the top of the chest inside the neck) or a
    /// sliver past a seam, so at least 95 % of a capsule's samples carry one,
    /// which is what a capsule put on the wrong bone or left too long
    /// fails. `fit_capsules` fits by the same measure on the full body before
    /// the cull (to 3 mm); this holds the pasted numbers to the export. And
    /// every joint lies within a tenth of a metre of its capsule's line: the
    /// capsules are the zombie export's and the rig carries them into
    /// whichever skeleton it is given, so another export fails here instead
    /// of placing capsules off the bones.
    func testCapsulesStayInsideTheBodyAndUnderTheClothes() throws {
        guard let export = try loadExport() else { throw XCTSkip("Models/Zombie is not bundled") }
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: export.joints, entity: 1, layer: 1))
        // The body is the export less the garment proxies' vertices: the
        // sidecar's particles, matched by position the way the cloth binds them.
        let cell: Float = 0.001
        func key(_ p: simd_float3) -> SIMD3<Int32> { SIMD3<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down))) }
        var garmentCells: [SIMD3<Int32>: [simd_float3]] = [:]
        for g in export.cloth.garments {
            for p in g.positions { garmentCells[key(p), default: []].append(p) }
        }
        func isGarment(_ p: simd_float3) -> Bool {
            let k = key(p)
            for dx in -1 ... 1 { for dy in -1 ... 1 { for dz in -1 ... 1 {
                for q in garmentCells[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? [] where simd_distance(p, q) <= 0.0002 { return true }
            } } }
            return false
        }
        var body: [simd_float3] = [], bodyJoint: [String] = []
        for (p, joint) in zip(export.positions, export.dominantJoint) where !isGarment(p) {
            body.append(p); bodyJoint.append(joint)
        }
        XCTAssertGreaterThan(body.count, 20000, "the body is in the export")
        let garments = export.cloth.garments.map { ($0.name, surfacePoints($0)) }
        XCTAssertEqual(garments.map(\.0), ["shirt", "trousers"])

        // The bones whose skin is a part's, as the fit takes them.
        func ownBones(_ part: Int) -> Set<String> {
            let name = rig.partNames[part]
            var bones: Set<String> = [name]
            if name == "spine_03" { bones.formUnion(["clavicle_l", "clavicle_r"]) }
            if name.hasPrefix("foot_") { bones.insert("ball_" + name.suffix(1)) }
            return bones
        }
        func neighbourBones(_ part: Int) -> Set<String> {
            var bones = Set<String>()
            if let parent = rig.parentIndices[part] { bones.formUnion(ownBones(parent)) }
            for child in rig.parentIndices.indices where rig.parentIndices[child] == part { bones.formUnion(ownBones(child)) }
            // The palm's skin is the finger roots' as much as the hand's.
            let name = rig.partNames[part]
            if name.hasPrefix("hand_") { bones.formUnion(["thumb_01_", "index_01_", "middle_01_", "ring_01_", "pinky_01_"].map { $0 + name.suffix(1) }) }
            return bones.subtracting(ownBones(part))
        }

        let tBin: Float = 0.01, sectors = 24
        func frame(_ d: simd_float3) -> (simd_float3, simd_float3) {
            let up = abs(d.y) < 0.9 ? simd_float3(0, 1, 0) : simd_float3(1, 0, 0)
            let u = simd_normalize(simd_cross(d, up))
            return (u, simd_cross(d, u))
        }
        var worstBody: Float = -1, worstClearance: Float = 1, worstUnbounded: Float = 0, worstJoint: Float = 0
        for (part, spec) in ZombieRagdollRig.specs.enumerated() {
            let capsule = spec.capsule
            let d = simd_normalize(capsule.to - capsule.from)
            let (u, v) = frame(d)
            func bin(_ p: simd_float3) -> (t: Float, r: Float, key: SIMD2<Int32>) {
                let w = p - capsule.from
                let t = simd_dot(w, d)
                let perp = w - d * t
                let sector = Int32(((atan2(simd_dot(perp, v), simd_dot(perp, u)) + .pi) / (2 * .pi) * Float(sectors)).rounded(.down)) % Int32(sectors)
                return (t, simd_length(perp), SIMD2(Int32((t / tBin).rounded(.down)), sector))
            }
            let own = ownBones(part), neighbours = neighbourBones(part)
            var ownReach: [SIMD2<Int32>: Float] = [:], neighbourReach: [SIMD2<Int32>: Float] = [:]
            var ownCount = 0
            for (p, joint) in zip(body, bodyJoint) {
                if own.contains(joint) {
                    let b = bin(p); ownReach[b.key] = max(ownReach[b.key] ?? 0, b.r); ownCount += 1
                } else if neighbours.contains(joint) {
                    let b = bin(p); neighbourReach[b.key] = max(neighbourReach[b.key] ?? 0, b.r)
                }
            }
            var garmentBins = Set<SIMD2<Int32>>()
            for (_, points) in garments {
                for p in points { garmentBins.insert(bin(p).key) }
            }
            // The capsule's surface: rings every 5 mm along the cylinder and
            // over both caps, as the fit samples it.
            let span = simd_length(capsule.to - capsule.from)
            var a = capsule.from + d * capsule.radius, b = capsule.to - d * capsule.radius
            if span < 2 * capsule.radius + 0.005 {
                let m = (capsule.from + capsule.to) / 2
                a = m - d * 0.0025; b = m + d * 0.0025
            }
            var samples: [simd_float3] = []
            let rings = max(Int(simd_distance(a, b) / 0.005) + 1, 2)
            for ring in 0 ..< rings {
                let centre = a + (b - a) * (Float(ring) / Float(rings - 1))
                for k in 0 ..< 48 {
                    let angle = (Float(k) + 0.5) / 48 * 2 * .pi
                    samples.append(centre + (u * cos(angle) + v * sin(angle)) * capsule.radius)
                }
            }
            for lat in 0 ..< 6 {
                let theta = (0.15 + 0.85 * Float(lat) / 5) * .pi / 2
                for k in 0 ..< 48 {
                    let angle = (Float(k) + 0.5) / 48 * 2 * .pi
                    let ring = (u * cos(angle) + v * sin(angle)) * (capsule.radius * cos(theta))
                    samples.append(a - d * (capsule.radius * sin(theta)) + ring)
                    samples.append(b + d * (capsule.radius * sin(theta)) + ring)
                }
            }
            // A sample whose own bin holds no skin takes the mean reach of the
            // skin in the bins around it (a centimetre either way along, a
            // sector either way around): the shoes and the palms are meshed
            // coarser than the bins, and the scalp has a gap under the hair.
            func nearbyReach(_ key: SIMD2<Int32>) -> Float? {
                var sum: Float = 0, count = 0
                for dt in -1 ... 1 {
                    for ds in -1 ... 1 where dt != 0 || ds != 0 {
                        let k = SIMD2(key.x + Int32(dt), (key.y + Int32(ds) + Int32(sectors)) % Int32(sectors))
                        if let r = ownReach[k] ?? neighbourReach[k] { sum += r; count += 1 }
                    }
                }
                return count > 0 ? sum / Float(count) : nil
            }
            var excess: Float = -1, excessAt = simd_float3.zero
            var byOwn = 0, byNeighbour = 0, byNearby = 0, byGarment = 0, unbounded = 0
            for s in samples {
                let sb = bin(s)
                var skin: Float?
                if let r = ownReach[sb.key] { skin = r; byOwn += 1 }
                else if let r = neighbourReach[sb.key] { skin = r; byNeighbour += 1 }
                else if let r = nearbyReach(sb.key) { skin = r; byNearby += 1 }
                if let skin {
                    if sb.r - skin > excess { excess = sb.r - skin; excessAt = s }
                } else if garmentBins.contains(sb.key) {
                    byGarment += 1
                } else {
                    unbounded += 1
                }
            }
            var clearances: [(String, Float, simd_float3)] = []
            let axis = b - a
            for (name, points) in garments {
                var clearance = Float.greatestFiniteMagnitude, clearanceAt = simd_float3.zero
                for p in points {
                    let t = min(max(simd_dot(p - a, axis) / max(simd_length_squared(axis), 1e-9), 0), 1)
                    let c = simd_distance(p, a + axis * t) - capsule.radius
                    if c < clearance { clearance = c; clearanceAt = p }
                }
                clearances.append((name, clearance, clearanceAt))
            }
            // The joint against its capsule's line.
            let origin = export.joints.bindModelTransforms[rig.jointIndices[part]].columns.3
            let joint = simd_float3(origin.x, origin.y, origin.z)
            let along = min(max(simd_dot(joint - capsule.from, d) / span, 0), 1)
            let jointDistance = simd_distance(joint, capsule.from + (capsule.to - capsule.from) * along)
            let unboundedShare = Float(unbounded) / Float(samples.count)
            print(String(format: "capsule fit %@: radius %.3f, span %.3f, joint %.3f m off its line; skin excess %+.1f mm at (%.3f,%.3f,%.3f) over %d own-skin vertices; samples bounded by own skin %d, neighbour skin %d, nearby skin %d, a garment %d, none %d of %d; %@",
                         rig.partNames[part], capsule.radius, span, jointDistance, excess * 1000, excessAt.x, excessAt.y, excessAt.z, ownCount, byOwn, byNeighbour, byNearby, byGarment, unbounded, samples.count,
                         clearances.map { String(format: "%@ clearance %+.1f mm at (%.3f,%.3f,%.3f)", $0.0, $0.1 * 1000, $0.2.x, $0.2.y, $0.2.z) }.joined(separator: ", ")))
            XCTAssertLessThanOrEqual(excess, 0.005, "\(rig.partNames[part]) reaches \(excess * 1000) mm out of the body at \(excessAt)")
            for (name, clearance, at) in clearances {
                XCTAssertGreaterThanOrEqual(clearance, 0.002, "\(rig.partNames[part]) comes within \(clearance * 1000) mm of the \(name) at \(at)")
            }
            XCTAssertLessThanOrEqual(unboundedShare, 0.05, "\(rig.partNames[part]): \(unbounded) of \(samples.count) surface samples have neither skin nor a garment around them")
            XCTAssertLessThan(jointDistance, 0.10, "\(rig.partNames[part])'s joint is \(jointDistance) m from its capsule: the capsules are another skeleton's")
            worstBody = max(worstBody, excess); worstClearance = min(worstClearance, clearances.map(\.1).min() ?? 1)
            worstUnbounded = max(worstUnbounded, unboundedShare); worstJoint = max(worstJoint, jointDistance)
        }
        print(String(format: "capsule fit: worst skin excess %+.1f mm, smallest garment clearance %+.1f mm, most samples without a bound %.1f %%, joint farthest off its line %.3f m",
                     worstBody * 1000, worstClearance * 1000, worstUnbounded * 100, worstJoint))
        // The torso links are thick enough to be a body: a ball at the chest
        // meets them, not the spine.
        for name in ["pelvis", "spine_01", "spine_02", "spine_03"] {
            XCTAssertGreaterThan(ZombieRagdollRig.specs[try XCTUnwrap(rig.partIndex(named: name))].capsule.radius, 0.06, name)
        }
    }
}
