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
            .leftToes: p.toe,
        ]
        for (joint, name) in joints where joint.mirrored != joint {
            joints[joint.mirrored] = p.mirror(name)
        }
        return MocapRigMapping(joints: joints, rootJoint: p.pelvis)
    }
}

/// Lock-protected; `update()` runs on the render thread, everything else on
/// the main actor.
final class CoolMirrorMocapController: @unchecked Sendable {
    /// Frames older than this stop driving the character (the phone left).
    private static let staleInterval: TimeInterval = 1.0

    private let receiver = MocapReceiver()
    private let lock = NSLock()
    private var retargeter: MocapRetargeter?
    private var characterId: EntityID?
    private var enabled = false
    private var pendingCalibration = false
    private var lastSequence: UInt32?
    private var lastFrameDate = Date.distantPast
    private var driving = false
    private var storedOptions = MocapRetargetOptions()

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

    /// Setup guidance for the person wearing the headset (the phone's screen
    /// faces away from them): what to do next, in order.
    var status: String {
        let (enabled, calibrated, pending, driving, hasMapping) = lock.withLock {
            (self.enabled, retargeter?.isCalibrated ?? false, pendingCalibration, self.driving, retargeter != nil)
        }
        guard enabled else { return "off" }
        guard hasMapping else { return "This character has no motion-capture mapping; pick Spider-Man or Batman." }
        guard receiver.isPeerConnected else {
            return "1 · Open CoolMirror Capture on the iPhone (same Wi-Fi) and put it on a stand with the back camera facing you, 2–3 m away."
        }
        let sinceLastFrame = receiver.secondsSinceLastFrame
        let tracked = (receiver.latestFrame?.isTracked ?? false) && (sinceLastFrame ?? .infinity) < 1
        guard tracked else {
            return "2 · iPhone connected but it sees no body: step back until you are fully in its view, feet included."
        }
        if pending {
            return "Hold still… capturing your pose as the character's rest pose."
        }
        if !calibrated {
            return "3 · Body tracked (\(receiver.framesPerSecond) Hz). Stand like the character (arms as shown), then tap Calibrate and hold the pose."
        }
        if driving {
            return "Mirroring you at \(receiver.framesPerSecond) Hz. Wrong side? tap Mirror. Facing away? tap Flip. Recalibrate any time."
        }
        return "Body tracked (\(receiver.framesPerSecond) Hz), waiting for the next frame…"
    }

    func setCharacter(_ id: EntityID?, mapping: MocapRigMapping?) {
        lock.withLock {
            characterId = id
            if let mapping {
                let retargeter = MocapRetargeter(mapping: mapping)
                retargeter.options = storedOptions
                self.retargeter = retargeter
            } else {
                retargeter = nil
            }
            driving = false
        }
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
            lock.withLock { driving = false }
        }
    }

    func requestCalibration() {
        lock.withLock { pendingCalibration = true }
    }

    /// Render-thread step: retargets the newest frame onto the character.
    func update() {
        let (enabled, characterId, retargeter) = lock.withLock { (self.enabled, self.characterId, self.retargeter) }
        guard enabled, let characterId, let retargeter else { return }
        guard let frame = receiver.latestFrame else { return }

        let now = Date()
        let isNew = lock.withLock { () -> Bool in
            guard frame.sequence != lastSequence else { return false }
            lastSequence = frame.sequence
            lastFrameDate = now
            return true
        }
        if !isNew {
            // The phone went quiet: release the character after a moment.
            let stale = lock.withLock { now.timeIntervalSince(lastFrameDate) > Self.staleInterval && driving }
            if stale {
                clearEntityExternalPose(entityId: characterId)
                lock.withLock { driving = false }
            }
            return
        }
        guard frame.isTracked else { return }

        let calibrate = lock.withLock { () -> Bool in
            defer { pendingCalibration = false }
            return pendingCalibration
        }
        if calibrate {
            retargeter.calibrate(with: frame)
        }
        guard let result = retargeter.retarget(frame) else { return }
        setEntityExternalPose(
            entityId: characterId,
            worldRotationDeltas: result.worldRotationDeltas,
            rootJoint: result.rootJoint,
            rootTranslationDelta: result.rootTranslationDelta,
            weight: retargeter.options.weight
        )
        lock.withLock { driving = true }
    }
}
