//
//  CoolWebGloveRig.swift
//  CoolWeb
//
//  Retargets a tracked hand pose onto the rigged glove skeleton: one skinning
//  matrix per joint per frame, ready for the GPU vertex shader.
//
//  The solver is position-driven. ARKit joint orientations use per-joint axis
//  conventions that don't match the Blender rig's bone axes, so instead of
//  fighting them the solver anchors every joint at its *tracked position* and
//  derives rotations hierarchically as shortest-arc alignments of each bind
//  bone direction onto the measured one. Each bone also stretches ALONG its
//  axis by the tracked/bind length ratio — so the bone's bind tail lands
//  exactly on the next tracked joint (adjacent bones agree where they meet,
//  the skin never tears at a knuckle) while the mesh keeps its thickness (a
//  uniform scale would fatten a longer finger).
//
//  Pure math over CoolWebHandPose — host-testable with no ARKit or Metal.
//

import Foundation
import simd

public enum CoolWebGloveRig {
    /// Computes the per-joint skinning matrices (world-from-bind) for one
    /// hand pose, ordered like `skeleton.names`. Non-deforming marker joints
    /// (fingertips, muzzle) ride with the bone they hang off. `fit` shapes
    /// the cross-sections and fingertip overshoot. Returns nil when the
    /// pose misses joints or the skeleton lacks the hand rig.
    public static func skinningMatrices(
        skeleton: CoolWebGloveSkeleton,
        pose: CoolWebHandPose,
        side: CoolWebHandSide,
        fit: CoolWebGloveFit = CoolWebGloveFit()
    ) -> [simd_float4x4]? {
        guard let targetFrame = CoolWebHandFrame(pose: pose, side: side),
              let wristIndex = skeleton.jointIndex(named: "wrist"),
              let forearmIndex = skeleton.jointIndex(named: "forearmArm"),
              let indexKnuckle = skeleton.jointIndex(named: "indexFingerKnuckle"),
              let littleKnuckle = skeleton.jointIndex(named: "littleFingerKnuckle"),
              let bindFrame = bindHandFrame(skeleton: skeleton, side: side)
        else { return nil }

        let bind = skeleton.bindPositions
        let tipPadding = simd_clamp(fit.fingertipPadding, 0, 0.03)

        // Root: rotation from the two orthonormal hand bases; the palm is
        // fitted along its forward (wrist→knuckles) and lateral (index→little
        // knuckle span) axes independently, thickness is a fit knob.
        let rootRotation = targetFrame.basis * bindFrame.basis.transpose
        let wristTarget = pose.wrist
        let bindKnuckleCenter = (bind[indexKnuckle] + bind[littleKnuckle]) * 0.5
        let forwardScale = lengthRatio(
            target: targetFrame.palmLength,
            bind: simd_length(bindKnuckleCenter - bind[wristIndex])
        )
        let lateralScale = lengthRatio(
            target: simd_length(pose.little.points[1] - pose.index.points[1]),
            bind: simd_length(bind[littleKnuckle] - bind[indexKnuckle])
        )
        // Tracking gives lengths, never thickness — but thickness follows
        // hand size closely, so every cross-section starts from the tracked
        // knuckle-span ratio and the fit knobs are relative corrections.
        // Bigger hand, proportionally thicker glove, no per-person tuning.
        let sizeRatio = lateralScale
        let fingerGirth = simd_clamp(fit.fingerGirth * sizeRatio, 0.5, 2.5)
        let palmThickness = simd_clamp(fit.palmThickness * sizeRatio, 0.5, 2.5)
        let cuffGirth = simd_clamp(fit.cuffGirth * sizeRatio, 0.5, 2.5)
        let f = bindFrame.basis.columns.0
        let l = bindFrame.basis.columns.1
        let b = bindFrame.basis.columns.2
        let palmLinear = rootRotation * (
            outer(f, f) * forwardScale + outer(l, l) * lateralScale
                + outer(b, b) * palmThickness
        )
        // The cuff follows the palm's length fit but has its own girth —
        // a wrist wider than the asset's shows skin past the gauntlet.
        let cuffLinear = rootRotation * (
            outer(f, f) * forwardScale + outer(l, l) * cuffGirth
                + outer(b, b) * cuffGirth
        )

        var matrices = [simd_float4x4](
            repeating: matrix_identity_float4x4, count: bind.count
        )
        func stamp(_ joint: Int, linear: simd_float3x3, head: SIMD3<Float>) {
            matrices[joint] = skinningMatrix(
                linear: linear, bindHead: bind[joint], targetHead: head
            )
        }

        stamp(wristIndex, linear: palmLinear, head: wristTarget)
        // The forearm head keeps its bind offset from the wrist so the cuff
        // trails naturally.
        stamp(
            forearmIndex,
            linear: cuffLinear,
            head: wristTarget + cuffLinear * (bind[forearmIndex] - bind[wristIndex])
        )
        if let muzzle = skeleton.jointIndex(named: CoolWebGloveSkeleton.muzzleJoint) {
            stamp(
                muzzle,
                linear: palmLinear,
                head: wristTarget + palmLinear * (bind[muzzle] - bind[wristIndex])
            )
        }

        // Fingers: hierarchical shortest-arc chains. Pose chains carry
        // [metacarpal, knuckle, intermediateBase, intermediateTip, tip]
        // (the thumb starts at the wrist instead of a metacarpal) — bones
        // Knuckle/IntermediateBase/IntermediateTip head at points 1/2/3 and
        // the last bone aims at point 4.
        let fingers: [(chain: CoolWebFingerChain, prefix: String)] = [
            (pose.thumb, "thumb"),
            (pose.index, "indexFinger"),
            (pose.middle, "middleFinger"),
            (pose.ring, "ringFinger"),
            (pose.little, "littleFinger"),
        ]
        for finger in fingers {
            let points = finger.chain.points
            guard points.count >= 5 else { return nil }
            let boneNames = [
                "\(finger.prefix)Knuckle",
                "\(finger.prefix)IntermediateBase",
                "\(finger.prefix)IntermediateTip",
            ]
            let tipJoint = skeleton.jointIndex(named: "\(finger.prefix)Tip")
            var parentRotation = rootRotation
            for (bone, name) in boneNames.enumerated() {
                guard let joint = skeleton.jointIndex(named: name) else {
                    return nil
                }
                let bindHead = bind[joint]
                // Bind tail: the next bone's head; for the last bone the
                // fingertip marker when the asset has one, else an estimate
                // extending the previous segment.
                let bindTail: SIMD3<Float>
                if bone < 2, let next = skeleton.jointIndex(named: boneNames[bone + 1]) {
                    bindTail = bind[next]
                } else if let tipJoint {
                    bindTail = bind[tipJoint]
                } else {
                    let previous = bone >= 1
                        ? bind[skeleton.jointIndex(named: boneNames[bone - 1]) ?? joint]
                        : bind[wristIndex]
                    bindTail = bindHead + (bindHead - previous)
                }
                let bindDirection = bindTail - bindHead
                var targetDirection = points[bone + 2] - points[bone + 1]
                if bone == 2, simd_length_squared(targetDirection) > 1e-10 {
                    // The glove's tip overshoots the tracked tip so the real
                    // fingertip never pokes out of the fabric.
                    targetDirection += simd_normalize(targetDirection) * tipPadding
                }
                let rotation = shortestArc(
                    from: parentRotation * bindDirection,
                    to: targetDirection
                ) * parentRotation
                // Stretch along the bone only: the bind tail lands exactly on
                // the next tracked joint, the cross-section keeps its girth.
                let stretch = lengthRatio(
                    target: simd_length(targetDirection),
                    bind: simd_length(bindDirection)
                )
                let linear = rotation * axialScale(
                    axis: bindDirection, along: stretch, across: fingerGirth
                )
                stamp(joint, linear: linear, head: points[bone + 1])
                parentRotation = rotation
            }
            // The fingertip marker rides with the distal bone — that bone's
            // matrix already carries the bind tip onto the tracked tip.
            if let tipJoint, let distal = skeleton.jointIndex(named: boneNames[2]) {
                matrices[tipJoint] = matrices[distal]
            }
        }
        return matrices
    }

    /// World position of the web-shooter muzzle marker for a solved palette,
    /// or nil when the asset carries no marker.
    public static func muzzlePosition(
        skeleton: CoolWebGloveSkeleton,
        matrices: [simd_float4x4]
    ) -> SIMD3<Float>? {
        guard let joint = skeleton.jointIndex(named: CoolWebGloveSkeleton.muzzleJoint),
              joint < matrices.count
        else { return nil }
        let bindHead = skeleton.bindPositions[joint]
        let world = matrices[joint] * SIMD4<Float>(bindHead, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    // MARK: - Frames

    struct Basis {
        var basis: simd_float3x3
    }

    /// The bind-pose analogue of `CoolWebHandFrame`: same construction from
    /// the same three anchors, so the root alignment is apples-to-apples.
    static func bindHandFrame(
        skeleton: CoolWebGloveSkeleton,
        side: CoolWebHandSide
    ) -> Basis? {
        guard let wrist = skeleton.jointIndex(named: "wrist"),
              let indexKnuckle = skeleton.jointIndex(named: "indexFingerKnuckle"),
              let littleKnuckle = skeleton.jointIndex(named: "littleFingerKnuckle")
        else { return nil }
        let bind = skeleton.bindPositions
        return handBasis(
            wrist: bind[wrist],
            indexKnuckle: bind[indexKnuckle],
            littleKnuckle: bind[littleKnuckle],
            side: side
        )
    }

    static func handBasis(
        wrist: SIMD3<Float>,
        indexKnuckle: SIMD3<Float>,
        littleKnuckle: SIMD3<Float>,
        side: CoolWebHandSide
    ) -> Basis? {
        let knuckleCenter = (indexKnuckle + littleKnuckle) * 0.5
        let forward = knuckleCenter - wrist
        guard simd_length_squared(forward) > 1e-10 else { return nil }
        let f = simd_normalize(forward)
        var lateral = littleKnuckle - indexKnuckle
        lateral -= f * simd_dot(lateral, f)
        guard simd_length_squared(lateral) > 1e-10 else { return nil }
        let l = simd_normalize(lateral)
        let back = side == .right ? simd_cross(l, f) : simd_cross(f, l)
        return Basis(basis: simd_float3x3(f, l, simd_normalize(back)))
    }

    // MARK: - Matrix helpers

    /// T(target) · L · T(−bind): applies the linear part around the joint
    /// head and re-anchors it at the tracked head. Fed straight to the GPU —
    /// the rig's bind orientations cancel, no inverse-bind multiply needed.
    static func skinningMatrix(
        linear: simd_float3x3,
        bindHead: SIMD3<Float>,
        targetHead: SIMD3<Float>
    ) -> simd_float4x4 {
        let translation = targetHead - linear * bindHead
        return simd_float4x4(
            SIMD4<Float>(linear.columns.0, 0),
            SIMD4<Float>(linear.columns.1, 0),
            SIMD4<Float>(linear.columns.2, 0),
            SIMD4<Float>(translation, 1)
        )
    }

    /// Scale `along` the unit direction of `axis` and `across` everything
    /// perpendicular to it: across·I + (along − across)·a·aᵀ.
    static func axialScale(
        axis: SIMD3<Float>,
        along: Float,
        across: Float
    ) -> simd_float3x3 {
        let length = simd_length(axis)
        guard length > 1e-7 else { return matrix_identity_float3x3 * along }
        let a = axis / length
        return matrix_identity_float3x3 * across + outer(a, a) * (along - across)
    }

    static func outer(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> simd_float3x3 {
        simd_float3x3(u * v.x, u * v.y, u * v.z)
    }

    /// Segment-length ratio, clamped so a tracking glitch can't balloon or
    /// collapse the mesh.
    private static func lengthRatio(target: Float, bind: Float) -> Float {
        guard bind > 1e-6, target.isFinite, target > 1e-6 else { return 1 }
        return simd_clamp(target / bind, 0.25, 4)
    }

    /// Shortest rotation carrying `from` onto `to` (both need not be unit).
    static func shortestArc(
        from: SIMD3<Float>,
        to: SIMD3<Float>
    ) -> simd_float3x3 {
        let lf = simd_length(from)
        let lt = simd_length(to)
        guard lf > 1e-7, lt > 1e-7 else { return matrix_identity_float3x3 }
        let f = from / lf
        let t = to / lt
        let dot = simd_clamp(simd_dot(f, t), -1, 1)
        if dot > 0.99999 { return matrix_identity_float3x3 }
        if dot < -0.99999 {
            // Opposite: rotate π around any perpendicular axis.
            let axis = simd_normalize(perpendicularAxis(to: f))
            return simd_float3x3(simd_quatf(angle: .pi, axis: axis))
        }
        let axis = simd_normalize(simd_cross(f, t))
        return simd_float3x3(simd_quatf(angle: acos(dot), axis: axis))
    }

    private static func perpendicularAxis(to v: SIMD3<Float>) -> SIMD3<Float> {
        let reference = abs(v.y) < 0.9
            ? SIMD3<Float>(0, 1, 0)
            : SIMD3<Float>(1, 0, 0)
        return simd_cross(v, reference)
    }
}

extension CoolWebHandFrame {
    /// Orthonormal (forward, lateral, backNormal) basis of this frame.
    var basis: simd_float3x3 {
        simd_float3x3(forward, lateral, backNormal)
    }
}
