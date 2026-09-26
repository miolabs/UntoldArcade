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
    private var hiddenCape: (mesh: Int, submesh: Int)?

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
            hiddenCape = nil
        }
        apply()
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            placed = false
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
            // Lay the sheet out at once (behind the character, hanging from
            // shoulder height) so the first drawn frames are a cape, not the
            // uninitialised grid; the first update refines the placement
            // from the skeleton.
            let origin = getPosition(entityId: characterId)
            let facing = getRotationQuaternion(entityId: characterId)
            let back = -simd_normalize(facing.act(simd_float3(0, 0, 1)))
            let translation = Self.translation(origin + back * (Self.backOffset + 0.05) + simd_float3(0, 1.45 - Self.length / 2, 0))
            let yaw = atan2(back.x, back.z)
            setCoolClothModelMatrix(translation * Self.rotationY(yaw) * Self.scale(simd_float3(Self.width / 2, Self.length / 2, 1)))
            setCoolClothPinTargets(worldPositions: nil)
            resetCoolCloth(pinMode: .topEdge)
            hideModelCape(entityId: characterId, hidden: true)
        } else {
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
        setCoolClothPinTargets(worldPositions: [leftEnd, leftMid, center + up * 0.015, rightMid, rightEnd])

        if !placed {
            // First frame: lay the sheet out hanging from the shoulders so it
            // does not start inside the body, then reset the simulation.
            let translation = Self.translation(center + behind * 0.5 - up * (Self.length / 2))
            let yaw = atan2(back.x, back.z)
            let rotation = Self.rotationY(yaw)
            let scale = Self.scale(simd_float3(halfWidth, Self.length / 2, 1))
            setCoolClothModelMatrix(translation * rotation * scale)
            resetCoolCloth(pinMode: .topEdge)
            lock.withLock { self.placed = true }
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

    /// The model's own cape (the submesh textured with the cape map) is
    /// faded out while the cloth stands in for it.
    private func hideModelCape(entityId: EntityID, hidden: Bool) {
        let slot: (mesh: Int, submesh: Int)? = lock.withLock { hiddenCape } ?? Self.capeSlot(entityId: entityId)
        guard let slot else {
            print("CoolMirror cape: no submesh with a cape texture found; material slots: \(Self.describeMaterialSlots(entityId: entityId))")
            return
        }
        lock.withLock { hiddenCape = slot }
        print("CoolMirror cape: model cape is mesh \(slot.mesh) submesh \(slot.submesh), \(hidden ? "hidden" : "shown")")
        // Mask with zero opacity: every fragment falls under the cutoff and is
        // discarded in the main pass (blend would need the transparency pass).
        updateMaterialAlphaMode(entityId: entityId, mode: hidden ? .mask : .opaque, meshIndex: slot.mesh, submeshIndex: slot.submesh)
        updateMaterialAlphaCutoff(entityId: entityId, cutoff: 0.5, meshIndex: slot.mesh, submeshIndex: slot.submesh)
        updateMaterialOpacity(entityId: entityId, opacity: hidden ? 0 : 1, meshIndex: slot.mesh, submeshIndex: slot.submesh)
    }

    /// The submesh whose base colour texture is the cape map (bounded scan
    /// of the material slots: a missing slot answers nil like an untextured one).
    private static func capeSlot(entityId: EntityID) -> (mesh: Int, submesh: Int)? {
        for mesh in 0 ..< 8 {
            for submesh in 0 ..< 32 {
                if let url = getMaterialTextureURL(entityId: entityId, type: .baseColor, meshIndex: mesh, submeshIndex: submesh),
                   url.lastPathComponent.localizedCaseInsensitiveContains("cape")
                {
                    return (mesh, submesh)
                }
            }
        }
        return nil
    }

    private static func describeMaterialSlots(entityId: EntityID) -> String {
        var names: [String] = []
        for mesh in 0 ..< 8 {
            for submesh in 0 ..< 32 {
                if let url = getMaterialTextureURL(entityId: entityId, type: .baseColor, meshIndex: mesh, submeshIndex: submesh) {
                    names.append("\(mesh)/\(submesh)=\(url.lastPathComponent)")
                }
            }
        }
        return names.isEmpty ? "none with a base colour texture" : names.joined(separator: ", ")
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
