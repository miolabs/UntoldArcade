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
    /// The headset's own orientation (world), read every update: it drives
    /// the character's head, the one joint the phone cannot see under the
    /// Vision Pro.
    private var headPoseProvider: (@Sendable () -> simd_quatf?)?
    private var headReference: simd_quatf?
    private var groundLock = true
    private var groundCorrection: Float = 0
    /// Rest height of every ankle and toe joint, by rig joint name.
    private var restFootHeights: [String: Float] = [:]
    /// Root x/z held while the captured feet are planted, and the blend
    /// out of a hold (start time, held value) so a release never snaps.
    private var heldRootXZ: simd_float2?
    private var rootHoldRelease: (start: TimeInterval, from: simd_float2)?
    private static let rootHoldReleaseBlend: TimeInterval = 0.25
    private var lastFeet: (positions: [MocapJoint: simd_float3], time: TimeInterval)?

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

    /// Supplies the headset's world orientation; the head then follows the
    /// wearer's head (mirrored like the rest) instead of riding on the neck.
    func setHeadPoseProvider(_ provider: (@Sendable () -> simd_quatf?)?) {
        lock.withLock {
            headPoseProvider = provider
            headReference = nil
        }
    }

    /// Keeps the character's lowest foot on the floor: the root translation
    /// is corrected by whatever the lowest ankle has risen above its rest
    /// height (no jumping, no floating).
    var isGroundLockEnabled: Bool {
        get { lock.withLock { groundLock } }
        set {
            lock.withLock {
                groundLock = newValue
                if !newValue {
                    groundCorrection = 0
                    heldRootXZ = nil
                    rootHoldRelease = nil
                }
            }
        }
    }

    /// Joints the phone must actually see before the pose is trustworthy
    /// and calibration makes sense.
    static let framingJoints: [MocapJoint] = [.head, .leftHand, .rightHand, .leftFoot, .rightFoot]

    /// Whether the phone sees the whole body (head, hands and feet tracked,
    /// not inferred) in the newest frame.
    var isFramed: Bool {
        guard let frame = receiver.latestFrame, frame.isTracked, (receiver.secondsSinceLastFrame ?? .infinity) < 1 else { return false }
        return Self.framingJoints.allSatisfy { frame.trackedJoints.contains($0) }
    }

    /// What to change so the whole body is in the picture, or nil when it is.
    var framingHint: String? {
        guard let frame = receiver.latestFrame, frame.isTracked else { return nil }
        let missing = Set(Self.framingJoints.filter { !frame.trackedJoints.contains($0) })
        guard !missing.isEmpty else { return nil }
        let head = missing.contains(.head)
        let feet = !missing.isDisjoint(with: [.leftFoot, .rightFoot])
        let hands = !missing.isDisjoint(with: [.leftHand, .rightHand])
        if head, feet {
            return "Head and feet out of the picture: step back from the phone."
        }
        if head {
            return "Head out of the picture: step back, or tilt the phone up."
        }
        if feet {
            return "Feet out of the picture: step back, or tilt the phone down."
        }
        if hands {
            return "Hands out of the picture: keep them inside the frame."
        }
        return nil
    }

    /// An iPhone is connected and sending (frames within the last second).
    var isConnected: Bool {
        lock.withLock { enabled } && receiver.isPeerConnected && (receiver.secondsSinceLastFrame ?? .infinity) < 1
    }

    /// One line on the link: connected or not, frame rate, body seen.
    var connectionSummary: String {
        guard lock.withLock({ enabled }) else { return "○ iPhone link off" }
        guard receiver.isPeerConnected else { return "○ No iPhone connected — \(receiver.status)" }
        let hz = receiver.framesPerSecond
        guard hz > 0 else { return "◐ iPhone connected, no frames arriving" }
        let tracked = receiver.latestFrame?.isTracked ?? false
        let pictures = receiver.previewCounts.pictures
        return "● iPhone connected · \(hz) frames/s · \(tracked ? "body seen" : "no body in view") · \(pictures) pictures"
    }

    /// Newest camera preview from the phone.
    var preview: MocapPreviewFrame? {
        receiver.latestPreview
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
            let counts = receiver.previewCounts
            return "2 · iPhone connected but it sees no body: keep the phone in landscape and step back until you are fully in its view, feet included. (pictures \(counts.pictures), chunks \(counts.chunks))"
        }
        if pending {
            return "Hold still… capturing your pose as the character's rest pose."
        }
        if let hint = framingHint {
            return "3 · \(hint) The picture above shows what the phone sees; the whole body must be inside it, or the tracker guesses and flips."
        }
        if !calibrated {
            return "4 · Whole body in view (\(receiver.framesPerSecond) Hz). Stand upright facing the phone, look at it, arms relaxed, then tap Calibrate and hold still."
        }
        let counts = receiver.previewCounts
        let seen = (receiver.latestFrame.map { "\($0.trackedJoints.count)/\($0.rotations.count) joints seen" } ?? "")
            + ", pictures \(counts.pictures) of \(counts.chunks) chunks"
        if driving {
            let held = (lock.withLock { retargeter?.isYawHeld } ?? false) ? " · heading held: the tracker turned the body faster than a body can turn" : ""
            return "Mirroring you at \(receiver.framesPerSecond) Hz, \(seen). Wrong side? tap Mirror. Facing away? tap Flip. Recalibrate any time.\n\(jitterReport)\(held) (stand still to read the tracker noise)"
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
                    restFootHeights = Self.restFootHeights(of: retargeter.rigRestPositions, mapping: mapping)
                }
                self.retargeter = retargeter
            } else {
                retargeter = nil
                restFootHeights = [:]
            }
            driving = false
            groundCorrection = 0
            heldRootXZ = nil
            lastFeet = nil
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

    /// Rest heights of the ankles and toes: whichever of them ends lowest
    /// in a pose is the floor contact.
    private static func restFootHeights(of positions: [String: simd_float3], mapping: MocapRigMapping) -> [String: Float] {
        var heights: [String: Float] = [:]
        for joint in [MocapJoint.leftFoot, .rightFoot, .leftToes, .rightToes] {
            if let name = mapping.referenceJoints[joint], let position = positions[name] {
                heights[name] = position.y
            }
        }
        return heights
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
        let headPose = lock.withLock { headPoseProvider }?()
        if calibrate {
            retargeter.calibrate(with: smoothed)
            lock.withLock { headReference = headPose }
        }
        guard var result = retargeter.retarget(smoothed) else { return }
        if let headPose, let reference = lock.withLock({ headReference }),
           let headJoint = retargeter.mapping.joints[.head]
        {
            result.worldRotationDeltas[headJoint] = Self.headDelta(
                pose: headPose, reference: reference, characterId: characterId, options: retargeter.options
            )
        }
        result.rootTranslationDelta = grounded(result, characterId: characterId, origin: origin, time: time)
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

    // MARK: - Head from the headset

    /// The headset's rotation since calibration, mirrored in world space
    /// across the plane between the wearer and the character (a real
    /// mirror reflects the axis and reverses the angle), then brought into
    /// the character's model space (the entity is turned to face the
    /// wearer) and flipped like the captured joints.
    static func headDelta(pose: simd_quatf, reference: simd_quatf, characterId: EntityID, options: MocapRetargetOptions) -> simd_quatf {
        headDelta(pose: pose, reference: reference, entityRotation: getRotationQuaternion(entityId: characterId), options: options)
    }

    static func headDelta(pose: simd_quatf, reference: simd_quatf, entityRotation entity: simd_quatf, options: MocapRetargetOptions) -> simd_quatf {
        var delta = simd_normalize(pose * reference.inverse)
        if options.mirror {
            // Mirror plane normal: the character's facing axis (either sign
            // gives the same reflection).
            let n = simd_normalize(entity.act(simd_float3(0, 0, 1)))
            let v = delta.imag
            let reflected = -v + 2 * simd_dot(v, n) * n
            delta = simd_quatf(ix: reflected.x, iy: reflected.y, iz: reflected.z, r: delta.real)
        }
        delta = simd_normalize(entity.inverse * delta * entity)
        if options.flipFacing {
            let facing = simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0))
            delta = simd_normalize(facing * delta * facing.inverse)
        }
        return delta
    }

    // MARK: - Ground lock

    /// The root translation with the feet kept on the floor: vertically,
    /// the lowest ankle or toe is held at its rest height (reading the pose
    /// the engine composed last frame, which already holds the previous
    /// correction, and closing the remaining error); horizontally, the root
    /// stays put while both captured feet are planted, so tracker noise
    /// cannot slide the character.
    private func grounded(_ result: MocapRetargetResult, characterId: EntityID, origin: simd_float3, time: TimeInterval) -> simd_float3 {
        var translation = result.rootTranslationDelta
        let (enabled, restHeights, previous, held, lastFeet, release) = lock.withLock {
            (groundLock, restFootHeights, groundCorrection, heldRootXZ, self.lastFeet, rootHoldRelease)
        }
        guard enabled else { return translation }

        if !restHeights.isEmpty {
            let joints = entitySkeletonJointPoses(entityId: characterId)
            var lowest: Float?
            for joint in joints {
                guard let name = joint.path.split(separator: "/").last.map(String.init), let rest = restHeights[name] else { continue }
                let rise = joint.worldPosition.y - origin.y - rest
                lowest = min(lowest ?? rise, rise)
            }
            var correction = previous
            if let lowest {
                correction = previous - 0.8 * lowest
            }
            lock.withLock { groundCorrection = correction }
            translation.y += correction
        }

        // Planted: both feet below 0.15 m/s since the last check.
        let feet = [MocapJoint.leftFoot, .rightFoot].reduce(into: [MocapJoint: simd_float3]()) { $0[$1] = result.capturedJointPositions[$1] }
        var planted = false
        if feet.count == 2, let lastFeet, time > lastFeet.time {
            let dt = Float(time - lastFeet.time)
            planted = feet.allSatisfy { joint, position in
                guard let last = lastFeet.positions[joint] else { return false }
                return simd_length(position - last) / dt < 0.15
            }
        }
        var newHeld = held
        var newRelease = release
        let tracked = simd_float2(translation.x, translation.z)
        if planted {
            if newHeld == nil {
                newHeld = tracked
                newRelease = nil
            }
            translation.x = newHeld!.x
            translation.z = newHeld!.y
        } else {
            if let held {
                // Leaving a hold: ease from the held spot to the tracked one.
                newRelease = (time, held)
            }
            newHeld = nil
            if let newRelease {
                let s = Float(min(max((time - newRelease.start) / Self.rootHoldReleaseBlend, 0), 1))
                if s < 1 {
                    let eased = newRelease.from + s * (tracked - newRelease.from)
                    translation.x = eased.x
                    translation.z = eased.y
                }
            }
        }
        lock.withLock {
            heldRootXZ = newHeld
            rootHoldRelease = newRelease
            self.lastFeet = (feet, time)
        }
        return translation
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
