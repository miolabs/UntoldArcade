//
//  CoolMirrorCape.swift
//  CoolMirror
//
//  Batman's cape on the CoolCloth XPBD sheet: the sheet's pinned top row
//  rides on the character's shoulders (attachment targets computed from
//  the driven skeleton every frame), the body pushes the cloth away
//  through capsules on the torso, head, arms and legs, and the model's own
//  rigid cape is faded out.
//

import CoolCloth
import Foundation
import simd
import UntoldEngine

/// Joint names the cape hangs from and collides with, per rig.
struct CoolMirrorCapeRig {
    var neck: String
    var upperChest: String
    var chest: String
    var pelvis: String
    var head: String
    var leftClavicle: String
    var rightClavicle: String
    var leftUpperArm: String
    var rightUpperArm: String
    var leftForearm: String
    var rightForearm: String
    var leftThigh: String
    var rightThigh: String
    var leftCalf: String
    var rightCalf: String

    static func rig(for character: CoolMirrorCharacter) -> CoolMirrorCapeRig? {
        guard character == .batman, let p = CoolMirrorRigProfile.profile(for: character) else { return nil }
        return CoolMirrorCapeRig(
            neck: p.neck, upperChest: p.upperChest, chest: p.chest, pelvis: p.pelvis, head: p.head,
            leftClavicle: p.clavicle, rightClavicle: p.mirror(p.clavicle),
            leftUpperArm: p.upperArm, rightUpperArm: p.mirror(p.upperArm),
            leftForearm: p.forearm, rightForearm: p.mirror(p.forearm),
            leftThigh: p.thigh, rightThigh: p.mirror(p.thigh),
            leftCalf: p.calf, rightCalf: p.mirror(p.calf)
        )
    }
}

/// Lock-protected; `update()` runs on the render thread.
final class CoolMirrorCape: @unchecked Sendable {
    /// Cloth sheet: 128 particles per side over `width` × `length` metres.
    private static let width: Float = 0.62
    private static let length: Float = 1.15
    /// How far behind the shoulder line the top row hangs.
    private static let backOffset: Float = 0.10
    private static let shoulderDrop: Float = 0.02

    private let lock = NSLock()
    private var characterId: EntityID?
    private var rig: CoolMirrorCapeRig?
    private var enabled = false
    private var placed = false
    /// Centre of the attachment line when the sheet was last laid out.
    private var placedTop: simd_float3?
    private var hiddenCape: [(mesh: Int, submesh: Int)]?

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    /// Registers the cloth plugin once, before the renderer is created.
    static func registerPlugin() {
        _ = registerCoolClothPlugin()
    }

    func setCharacter(_ id: EntityID?, character: CoolMirrorCharacter?) {
        let rig = character.flatMap { CoolMirrorCapeRig.rig(for: $0) }
        lock.withLock {
            characterId = id
            self.rig = rig
            placed = false
            placedTop = nil
            hiddenCape = nil
        }
        apply()
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            placed = false
            placedTop = nil
        }
        apply()
    }

    /// Turns the simulation on or off to match the state (and restores the
    /// model's own cape when off).
    private func apply() {
        let (enabled, characterId, rig) = lock.withLock { (self.enabled && self.rig != nil, self.characterId, self.rig) }
        if enabled, let characterId, rig != nil {
            setCoolClothPaused(false)
            setCoolClothBallVisible(false)
            setCoolClothGravity(simd_float3(0, -9.81, 0))
            setCoolClothLightDirection(simd_float3(0.3, 1.0, 0.6))
            // Heavier than silk, lighter than denim: a leather-like cape.
            setCoolClothMaterial(CoolClothMaterialParameters(
                stretchCompliance: 3e-7, shearCompliance: 3e-6, bendCompliance: 2e-5, damping: 1.4
            ))
            setCoolClothWind(directionWorld: simd_float3(0, 0, 1), strength: 0.15, gustiness: 0.6)
            setCoolClothColors(
                front: simd_float3(0.02, 0.02, 0.03), back: simd_float3(0.035, 0.035, 0.045),
                sheen: simd_float3(0.12, 0.12, 0.16), sheenIntensity: 0.35
            )
            setCoolClothFloor(worldY: 0)
            // Hidden until the first placement from a live skeleton (see
            // update): the sheet must never be seen before it hangs from
            // the shoulders.
            setCoolClothVisible(false)
            setCoolClothPinTargets(worldPositions: nil)
            hideModelCape(entityId: characterId, hidden: true)
        } else {
            setCoolClothVisible(false)
            setCoolClothPaused(true)
            setCoolClothPinTargets(worldPositions: nil)
            setCoolClothCapsules([])
            if let characterId {
                hideModelCape(entityId: characterId, hidden: false)
            }
        }
    }

    /// Render-thread step: hangs the top row from the shoulders and moves
    /// the body colliders.
    func update(deltaTime: Float) {
        let (enabled, characterId, rig, placed) = lock.withLock { (self.enabled, self.characterId, self.rig, self.placed) }
        guard enabled, let characterId, let rig else { return }
        let joints = entitySkeletonJointPoses(entityId: characterId)
        guard !joints.isEmpty else { return }
        func position(_ name: String) -> simd_float3? {
            joints.first { Self.jointPath($0.path, matches: name) }?.worldPosition
        }
        guard let neck = position(rig.neck), let upperChest = position(rig.upperChest),
              let pelvis = position(rig.pelvis), let leftArm = position(rig.leftUpperArm),
              let rightArm = position(rig.rightUpperArm)
        else { return }

        // Before the first animation update the skeleton query returns the
        // rest transforms, not a pose in the world: wait for joints that sit
        // on the character.
        let origin = getPosition(entityId: characterId)
        let neckHeight = neck.y - origin.y
        guard simd_length(simd_float2(neck.x - origin.x, neck.z - origin.z)) < 2.5, neckHeight > 0.6, neckHeight < 2.3,
              simd_length(neck - pelvis) > 0.2
        else { return }

        // Torso frame from the joints: up the spine, lateral across the
        // shoulders, back = lateral × up (right-handed, right minus left).
        let up = simd_normalize(neck - pelvis)
        var lateral = rightArm - leftArm
        lateral -= simd_dot(lateral, up) * up
        guard simd_length_squared(lateral) > 1e-6 else { return }
        lateral = simd_normalize(lateral)
        let back = simd_normalize(simd_cross(lateral, up))

        // Attachment line: from behind one shoulder, over the base of the
        // neck, to behind the other shoulder.
        let drop = -up * Self.shoulderDrop
        let behind = back * Self.backOffset
        let halfWidth = Self.width / 2
        let center = upperChest + behind * 0.9 + up * simd_dot(neck - upperChest, up) * 0.6
        let leftEnd = center - lateral * halfWidth + drop
        let rightEnd = center + lateral * halfWidth + drop
        let leftMid = center - lateral * halfWidth * 0.5 + up * 0.01
        let rightMid = center + lateral * halfWidth * 0.5 + up * 0.01

        // Lay the sheet out hanging from the attachment line and reset the
        // simulation when it has not been placed yet, or when the line has
        // moved far from the sheet's top row (a teleport, a reload): the
        // pins would otherwise drag the cloth across the room.
        let sheetTop = lock.withLock { placedTop }
        if !placed || sheetTop.map({ simd_length($0 - center) > 0.6 }) ?? true {
            let translation = Self.translation(center + behind * 0.5 - up * (Self.length / 2))
            let yaw = atan2(back.x, back.z)
            let rotation = Self.rotationY(yaw)
            let scale = Self.scale(simd_float3(halfWidth, Self.length / 2, 1))
            setCoolClothModelMatrix(translation * rotation * scale)
            setCoolClothPinTargets(worldPositions: [leftEnd, leftMid, center + up * 0.015, rightMid, rightEnd])
            resetCoolCloth(pinMode: .topEdge)
            setCoolClothVisible(true)
            lock.withLock {
                self.placed = true
                placedTop = center
            }
            print(String(format: "CoolMirror cape: sheet placed at (%.2f, %.2f, %.2f), back (%.2f, %.2f, %.2f)", center.x, center.y, center.z, back.x, back.y, back.z))
        } else {
            setCoolClothPinTargets(worldPositions: [leftEnd, leftMid, center + up * 0.015, rightMid, rightEnd])
        }

        var capsules: [CoolClothSimulation.Capsule] = [
            .init(start: pelvis - up * 0.05, end: neck, radius: 0.17),
        ]
        if let head = position(rig.head) {
            capsules.append(.init(start: neck, end: head + up * 0.08, radius: 0.11))
        }
        for (arm, forearm) in [(rig.leftUpperArm, rig.leftForearm), (rig.rightUpperArm, rig.rightForearm)] {
            if let a = position(arm), let b = position(forearm) {
                capsules.append(.init(start: a, end: b, radius: 0.065))
            }
        }
        for (thigh, calf) in [(rig.leftThigh, rig.leftCalf), (rig.rightThigh, rig.rightCalf)] {
            if let a = position(thigh), let b = position(calf) {
                capsules.append(.init(start: a, end: b, radius: 0.09))
            }
        }
        setCoolClothCapsules(capsules)
        advanceCoolCloth(deltaTime: deltaTime)
    }

    /// The model's own cape is faded out while the cloth stands in for it:
    /// every material slot whose mesh name or base colour texture name
    /// mentions the cape.
    private func hideModelCape(entityId: EntityID, hidden: Bool) {
        let slots = lock.withLock { hiddenCape } ?? Self.capeSlots(entityId: entityId)
        guard !slots.isEmpty else {
            print("CoolMirror cape: no cape material slot found; slots: \(Self.describeMaterialSlots(entityId: entityId))")
            return
        }
        lock.withLock { hiddenCape = slots }
        print("CoolMirror cape: model cape slots \(slots.map { "\($0.mesh)/\($0.submesh)" }.joined(separator: ", ")) \(hidden ? "hidden" : "shown")")
        for slot in slots {
            // Mask with zero opacity: every fragment falls under the cutoff
            // and is discarded in the main pass (blend would need the
            // transparency pass).
            updateMaterialAlphaMode(entityId: entityId, mode: hidden ? .mask : .opaque, meshIndex: slot.mesh, submeshIndex: slot.submesh)
            updateMaterialAlphaCutoff(entityId: entityId, cutoff: 0.5, meshIndex: slot.mesh, submeshIndex: slot.submesh)
            updateMaterialOpacity(entityId: entityId, opacity: hidden ? 0 : 1, meshIndex: slot.mesh, submeshIndex: slot.submesh)
        }
    }

    private static func capeSlots(entityId: EntityID) -> [(mesh: Int, submesh: Int)] {
        var slots: [(mesh: Int, submesh: Int)] = []
        for (mesh, meshName) in getEntityMeshNames(entityId: entityId).enumerated() {
            let meshIsCape = meshName.localizedCaseInsensitiveContains("cape")
            for submesh in 0 ..< getEntitySubmeshCount(entityId: entityId, meshIndex: mesh) {
                let texture = getMaterialBaseColorTextureName(entityId: entityId, meshIndex: mesh, submeshIndex: submesh) ?? ""
                if meshIsCape || texture.localizedCaseInsensitiveContains("cape") {
                    slots.append((mesh, submesh))
                }
            }
        }
        return slots
    }

    private static func describeMaterialSlots(entityId: EntityID) -> String {
        var names: [String] = []
        for (mesh, meshName) in getEntityMeshNames(entityId: entityId).enumerated() {
            for submesh in 0 ..< getEntitySubmeshCount(entityId: entityId, meshIndex: mesh) {
                let texture = getMaterialBaseColorTextureName(entityId: entityId, meshIndex: mesh, submeshIndex: submesh) ?? "-"
                names.append("\(mesh)/\(submesh) \(meshName) [\(texture)]")
            }
        }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private static func translation(_ t: simd_float3) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = simd_float4(t, 1)
        return m
    }

    private static func rotationY(_ angle: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: angle, axis: simd_float3(0, 1, 0)))
    }

    private static func scale(_ s: simd_float3) -> simd_float4x4 {
        simd_float4x4(diagonal: simd_float4(s, 1))
    }

    private static func jointPath(_ path: String, matches name: String) -> Bool {
        path == name || path.hasSuffix("/" + name) || path.split(separator: "/").last.map(String.init) == name
    }
}
