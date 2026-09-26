//
//  CoolMirrorMocapController.swift
//  CoolMirror
//
//  Bridges the iPhone body capture to the engine: receives frames, retargets
//  them for the current character's rig and hands the engine world-space
//  rotation deltas every frame through `setEntityExternalPose`.
//

import CoolMirrorMocap
import Foundation
import simd
import UntoldEngine

/// ARKit body joints → rig joints for the demo characters.
enum CoolMirrorMocapMapping {
    static func mapping(for character: CoolMirrorCharacter) -> MocapRigMapping? {
        guard let p = CoolMirrorRigProfile.profile(for: character) else { return nil }
        var joints: [MocapJoint: String] = [
            .hips: p.pelvis,
            .spine2: p.spine,
            .spine5: p.chest,
            .spine7: p.upperChest,
            .neck1: p.neck,
            .head: p.head,
            .leftShoulder: p.clavicle,
            .leftArm: p.upperArm,
            .leftForearm: p.forearm,
            .leftHand: p.hand,
            .leftUpLeg: p.thigh,
            .leftLeg: p.calf,
            .leftFoot: p.foot,
        ]
        // The toes are only a bone end: ARKit infers them from the ankle
        // (never tracked), so their twist would stretch the feet if driven.
        var reference = joints
        reference[.leftToes] = p.toe
        for (joint, name) in joints where joint.mirrored != joint {
            joints[joint.mirrored] = p.mirror(name)
        }
        for (joint, name) in reference where joint.mirrored != joint {
            reference[joint.mirrored] = p.mirror(name)
        }
        return MocapRigMapping(joints: joints, rootJoint: p.pelvis, referenceJoints: reference)
    }
}

/// Lock-protected; `update()` runs on the render thread, everything else on
/// the main actor.
final class CoolMirrorMocapController: @unchecked Sendable {
    /// Frames older than this stop driving the character (the phone left).
    private static let staleInterval: TimeInterval = 1.0
    private static let debugLinesName = "coolmirror.mocap"

    private let receiver = MocapReceiver()
    private let lock = NSLock()
    private var retargeter: MocapRetargeter?
    private var characterId: EntityID?
    private var characterOrigin = simd_float3(0, 0, 0)
    private var enabled = false
    private var pendingCalibration = false
    private var lastSequence: UInt32?
    private var lastFrameDate = Date.distantPast
    private var driving = false
    private var storedOptions = MocapRetargetOptions()
    private var jitter = MocapJitterMeter()
    private var debugOverlay = false
    private var debugLinesShown = false
    private var groundLock = true
    private var groundCorrection: Float = 0
    private var restFootHeight: Float?

    var options: MocapRetargetOptions {
        get { lock.withLock { storedOptions } }
        set {
            lock.withLock {
                storedOptions = newValue
                retargeter?.options = newValue
            }
        }
    }

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    var isCalibrated: Bool {
        lock.withLock { retargeter?.isCalibrated ?? false }
    }

    /// Draws the captured skeleton (orange, red bones where ARKit lost the
    /// joint) and the character's rig bones (cyan) as lines in the world.
    var isDebugOverlayEnabled: Bool {
        get { lock.withLock { debugOverlay } }
        set { lock.withLock { debugOverlay = newValue } }
    }

    /// Keeps the character's lowest foot on the floor: the root translation
    /// is corrected by whatever the lowest ankle has risen above its rest
    /// height (no jumping, no floating).
    var isGroundLockEnabled: Bool {
        get { lock.withLock { groundLock } }
        set {
            lock.withLock {
                groundLock = newValue
                if !newValue { groundCorrection = 0 }
            }
        }
    }

    /// Raw per-frame motion of the capture (see `MocapJitterMeter`).
    var jitterReport: String {
        lock.withLock { jitter.report }
    }

    /// Setup guidance for the person wearing the headset (the phone's screen
    /// faces away from them): what to do next, in order.
    var status: String {
        let (enabled, calibrated, pending, driving, hasMapping) = lock.withLock {
            (self.enabled, retargeter?.isCalibrated ?? false, pendingCalibration, self.driving, retargeter != nil)
        }
        guard enabled else { return "off" }
        guard hasMapping else { return "This character has no motion-capture mapping; pick Spider-Man or Batman." }
        guard receiver.isPeerConnected else {
            return "1 · Open CoolMirror Capture on the iPhone (same Wi-Fi) and stand it sideways (landscape) with the back camera facing you, 3–4 m away."
        }
        let sinceLastFrame = receiver.secondsSinceLastFrame
        let tracked = (receiver.latestFrame?.isTracked ?? false) && (sinceLastFrame ?? .infinity) < 1
        guard tracked else {
            return "2 · iPhone connected but it sees no body: keep the phone in landscape and step back until you are fully in its view, feet included."
        }
        if pending {
            return "Hold still… capturing your pose as the character's rest pose."
        }
        if !calibrated {
            return "3 · Body tracked (\(receiver.framesPerSecond) Hz). Stand upright facing the phone, look at it, arms relaxed, then tap Calibrate and hold still."
        }
        let seen = receiver.latestFrame.map { "\($0.trackedJoints.count)/\($0.rotations.count) joints seen" } ?? ""
        if driving {
            return "Mirroring you at \(receiver.framesPerSecond) Hz, \(seen). Wrong side? tap Mirror. Facing away? tap Flip. Recalibrate any time.\n\(jitterReport) (stand still to read the tracker noise)"
        }
        return "Body tracked (\(receiver.framesPerSecond) Hz), waiting for the next frame…"
    }

    /// `origin` is where the character's rest pose stands in the world (the
    /// captured skeleton is drawn relative to it).
    func setCharacter(_ id: EntityID?, mapping: MocapRigMapping?, origin: simd_float3 = .zero) {
        lock.withLock {
            characterId = id
            characterOrigin = origin
            if let mapping {
                let retargeter = MocapRetargeter(mapping: mapping)
                retargeter.options = storedOptions
                if let id {
                    retargeter.rigRestPositions = Self.restPositions(of: id)
                    restFootHeight = Self.restFootHeight(of: retargeter.rigRestPositions, mapping: mapping)
                }
                self.retargeter = retargeter
            } else {
                retargeter = nil
                restFootHeight = nil
            }
            driving = false
            groundCorrection = 0
            jitter.reset()
        }
        hideDebugLines()
    }

    /// The rig's rest joint positions keyed by full path and by last path
    /// component (the names the mappings use).
    private static func restPositions(of entityId: EntityID) -> [String: simd_float3] {
        var positions: [String: simd_float3] = [:]
        for joint in entitySkeletonRestJointPoses(entityId: entityId) {
            positions[joint.path] = joint.modelPosition
            if let name = joint.path.split(separator: "/").last {
                positions[String(name)] = joint.modelPosition
            }
        }
        return positions
    }

    /// Height of the lower ankle in the rest pose: the floor contact.
    private static func restFootHeight(of positions: [String: simd_float3], mapping: MocapRigMapping) -> Float? {
        let heights = [MocapJoint.leftFoot, .rightFoot].compactMap { mapping.joints[$0].flatMap { positions[$0]?.y } }
        return heights.min()
    }

    func setEnabled(_ enabled: Bool) {
        let (wasEnabled, characterId) = lock.withLock {
            let was = self.enabled
            self.enabled = enabled
            return (was, self.characterId)
        }
        if enabled, !wasEnabled {
            receiver.start()
        } else if !enabled, wasEnabled {
            receiver.stop()
            if let characterId {
                clearEntityExternalPose(entityId: characterId)
            }
            lock.withLock {
                driving = false
                retargeter?.resetSmoothing()
                jitter.reset()
            }
            hideDebugLines()
        }
    }

    func requestCalibration() {
        lock.withLock { pendingCalibration = true }
    }

    /// Render-thread step: smooths the newest frame toward the current time
    /// and retargets it onto the character. Runs every render tick, so the
    /// filter also interpolates between the phone's frames.
    func update() {
        let (enabled, characterId, retargeter, origin) = lock.withLock {
            (self.enabled, self.characterId, self.retargeter, characterOrigin)
        }
        guard enabled, let characterId, let retargeter else { return }
        guard let frame = receiver.latestFrame else { return }

        let now = Date()
        let time = now.timeIntervalSinceReferenceDate
        let isNew = lock.withLock { () -> Bool in
            guard frame.sequence != lastSequence else { return false }
            lastSequence = frame.sequence
            lastFrameDate = now
            jitter.add(frame, at: time)
            return true
        }
        if !isNew {
            // The phone went quiet: release the character after a moment.
            let stale = lock.withLock { now.timeIntervalSince(lastFrameDate) > Self.staleInterval }
            if stale {
                let wasDriving = lock.withLock { driving }
                if wasDriving {
                    clearEntityExternalPose(entityId: characterId)
                    lock.withLock { driving = false }
                }
                hideDebugLines()
                return
            }
        }
        guard frame.isTracked else { return }

        let smoothed = retargeter.smoothed(frame, at: time)
        let calibrate = lock.withLock { () -> Bool in
            defer { pendingCalibration = false }
            return pendingCalibration
        }
        if calibrate {
            retargeter.calibrate(with: smoothed)
        }
        guard var result = retargeter.retarget(smoothed) else { return }
        result.rootTranslationDelta.y += groundCorrection(characterId: characterId, origin: origin, mapping: retargeter.mapping)
        setEntityExternalPose(
            entityId: characterId,
            worldRotationDeltas: result.worldRotationDeltas,
            rootJoint: result.rootJoint,
            rootTranslationDelta: result.rootTranslationDelta,
            weight: retargeter.options.weight
        )
        lock.withLock { driving = true }

        if lock.withLock({ debugOverlay }) {
            showDebugLines(result: result, characterId: characterId, origin: origin)
        } else {
            hideDebugLines()
        }
    }

    // MARK: - Ground lock

    /// Vertical root correction keeping the lower ankle at its rest height.
    /// Reads the pose the engine composed last frame (which already holds
    /// the previous correction) and closes the remaining error gradually.
    private func groundCorrection(characterId: EntityID, origin: simd_float3, mapping: MocapRigMapping) -> Float {
        let (enabled, restHeight, previous) = lock.withLock { (groundLock, restFootHeight, groundCorrection) }
        guard enabled, let restHeight else { return 0 }
        let feet = [MocapJoint.leftFoot, .rightFoot].compactMap { mapping.joints[$0] }
        let joints = entitySkeletonJointPoses(entityId: characterId)
        let heights = joints.compactMap { joint -> Float? in
            feet.contains { Self.jointPath(joint.path, matches: $0) } ? joint.worldPosition.y - origin.y : nil
        }
        guard let lowest = heights.min() else { return previous }
        let error = lowest - restHeight
        let correction = previous - 0.5 * error
        lock.withLock { groundCorrection = correction }
        return correction
    }

    // MARK: - Debug overlay

    private func showDebugLines(result: MocapRetargetResult, characterId: EntityID, origin: simd_float3) {
        var segments: [DebugLineSegment] = []
        let rig = simd_float4(0.2, 0.9, 1.0, 1)
        let joints = entitySkeletonJointPoses(entityId: characterId)
        for joint in joints {
            guard let parentIndex = joint.parentIndex, parentIndex < joints.count else { continue }
            segments.append(DebugLineSegment(from: joints[parentIndex].worldPosition, to: joint.worldPosition, color: rig))
        }

        // ARKit's anchor sits at the hips, not on the floor, so the captured
        // figure is placed with its hips on the rig's pelvis (both carry the
        // same root translation); limbs then show the retargeting error.
        var anchor = origin
        if let capturedHips = result.capturedJointPositions[.hips],
           let pelvis = joints.first(where: { Self.jointPath($0.path, matches: result.rootJoint) })
        {
            anchor = pelvis.worldPosition - capturedHips
        }
        let captured = simd_float4(1.0, 0.6, 0.1, 1)
        let lost = simd_float4(1.0, 0.15, 0.15, 1)
        for (joint, position) in result.capturedJointPositions.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let parent = joint.parent, let parentPosition = result.capturedJointPositions[parent] else { continue }
            let color = result.capturedTrackedJoints.isEmpty || result.capturedTrackedJoints.contains(joint) ? captured : lost
            segments.append(DebugLineSegment(from: anchor + parentPosition, to: anchor + position, color: color))
        }
        setDebugLines(segments, named: Self.debugLinesName)
        lock.withLock { debugLinesShown = true }
    }

    /// Same resolution as the engine's joint lookup: exact path, `/name`
    /// suffix or last path component.
    private static func jointPath(_ path: String, matches name: String) -> Bool {
        path == name || path.hasSuffix("/" + name) || path.split(separator: "/").last.map(String.init) == name
    }

    private func hideDebugLines() {
        let shown = lock.withLock { () -> Bool in
            defer { debugLinesShown = false }
            return debugLinesShown
        }
        if shown {
            clearDebugLines(named: Self.debugLinesName)
        }
    }
}
