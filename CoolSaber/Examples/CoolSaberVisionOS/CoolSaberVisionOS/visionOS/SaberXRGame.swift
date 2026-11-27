//
//  SaberXRGame.swift  (visionOS)
//  CoolSaber
//
//  Per-frame duel logic, driven from the XR render thread:
//    PSVR2 poses → blade segments → plugin slots; trigger edges → ignition;
//    segment-segment distance → clash sparks/haptics/audio; SharePlay mailbox
//    in both directions. Solo practice works with no session at all.
//
//  Coordinates: the engine's XR world frame is ARKit's world origin (on the
//  floor beneath the user at immersive-space open). PSVR2 poses arrive in the
//  same frame. In a shared session the system does NOT move ARKit's frame;
//  it moves the immersive space by `immersiveSpaceDisplacement` so every
//  participant's space shares one origin (nearby: aligned in the real room).
//  So poses cross the wire in that shared frame: the sender strips its own
//  displacement, the receiver applies its own. Without a shared frame (plain
//  remote call) remote blades are re-based onto a fixed opponent anchor 2 m
//  in front, facing us.
//

import CoolSaber
import Foundation
@preconcurrency import GameController
import simd
import UntoldEngine
import UntoldEngineXR

/// Per-wand trigger input read straight from GameController. The engine folds
/// both Sense wands into one merged GameControllerState assuming side-prefixed
/// element names ("Left Trigger"/"Right Trigger"); real wands expose their own
/// unprefixed elements, so per-hand ignite must bind per GCController.
final class SaberWandInput: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingToggles: [SaberHand] = []
    private var assignedHands: [ObjectIdentifier: SaberHand] = [:]
    private var boundElements: Set<ObjectIdentifier> = []
    private var lastToggleUptime: [ObjectIdentifier: TimeInterval] = [:]
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.attach(controller)
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            self.lock.withLock {
                _ = self.assignedHands.removeValue(forKey: ObjectIdentifier(controller))
            }
        })
        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        lock.withLock {
            assignedHands.removeAll()
            pendingToggles.removeAll()
        }
    }

    /// Trigger presses since the last call, as the hand each belongs to.
    func takeToggles() -> [SaberHand] {
        lock.withLock {
            let toggles = pendingToggles
            pendingToggles.removeAll()
            return toggles
        }
    }

    /// Handedness from the vendor name ("...Left...", "(L)") or, failing that,
    /// from side-prefixed element names appearing exclusively.
    static func inferHand(of controller: GCController) -> SaberHand? {
        let vendor = (controller.vendorName ?? "").lowercased()
        if vendor.contains("left") || vendor.hasSuffix("(l)") { return .left }
        if vendor.contains("right") || vendor.hasSuffix("(r)") { return .right }
        let keys = controller.physicalInputProfile.buttons.keys.map { $0.lowercased() }
        let hasLeft = keys.contains { $0.hasPrefix("left") }
        let hasRight = keys.contains { $0.hasPrefix("right") }
        if hasLeft != hasRight { return hasLeft ? .left : .right }
        return nil
    }

    private func attach(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        let alreadyAttached = lock.withLock { assignedHands[key] != nil }
        guard !alreadyAttached else { return }

        let hand = Self.inferHand(of: controller) ?? nextFreeHand()
        lock.withLock { assignedHands[key] = hand }

        let buttons = controller.physicalInputProfile.buttons
        print(
            "CoolSaber: wand '\(controller.vendorName ?? "?")' → \(hand), "
                + "elements: \(buttons.keys.sorted())"
        )

        for (name, button) in buttons {
            let lower = name.lowercased()
            // The wand's trigger may surface as "Trigger", side-prefixed, or
            // via a "Button A"/"Cross" alias depending on firmware — accept
            // any of them; each toggles only this wand's blade.
            let isTrigger = lower.contains("trigger")
            let isPrimary = lower == "button a" || lower == "a" || lower == "cross"
            guard isTrigger || isPrimary,
                  !lower.contains("grip"), !lower.contains("shoulder")
            else { continue }

            // Aliases share the element object: bind each element once.
            let elementKey = ObjectIdentifier(button)
            let alreadyBound = lock.withLock { !boundElements.insert(elementKey).inserted }
            guard !alreadyBound else { continue }

            // If one GCController carries both sides' triggers, the element
            // prefix wins over the controller-level assignment.
            let target: SaberHand
            if lower.hasPrefix("left") {
                target = .left
            } else if lower.hasPrefix("right") {
                target = .right
            } else {
                target = hand
            }
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed, let self else { return }
                self.enqueueToggle(target, controllerKey: key)
            }
        }
    }

    /// One physical press can reach us through several distinct elements
    /// (analog trigger + click + alias); debounce per controller so it
    /// produces exactly one toggle.
    private func enqueueToggle(_ hand: SaberHand, controllerKey: ObjectIdentifier) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if let last = lastToggleUptime[controllerKey], now - last < 0.3 { return }
            lastToggleUptime[controllerKey] = now
            pendingToggles.append(hand)
        }
    }

    private func nextFreeHand() -> SaberHand {
        lock.withLock {
            assignedHands.values.contains(.left) ? .right : .left
        }
    }
}

/// Everything worth tweaking on hardware lives here.
struct SaberTuning {
    /// Blade start relative to the controller pose (controller-local metres):
    /// just above the fist, at the top of the controller ring.
    func gripOffsetLocal(hand: Int) -> SIMD3<Float> {
        SaberXRHolder.shared.fit(forHand: hand).gripOffset
    }
    /// Blade direction in controller-local space, from the fit angles set in
    /// the control window. Tilt rotates from +Y (out of the fist) toward -Z
    /// (the controller's forward: 0° vertical grip, 90° arm extension); lean
    /// then swings that tilted direction left/right around the controller's
    /// up axis — the sideways correction tilt alone can't express.
    func bladeAxisLocal(hand: Int) -> SIMD3<Float> {
        let fit = SaberXRHolder.shared.fit(forHand: hand)
        let tilt = fit.tiltDegrees * .pi / 180
        let lean = fit.leanDegrees * .pi / 180
        return SIMD3<Float>(
            -sin(tilt) * sin(lean),
            cos(tilt),
            -sin(tilt) * cos(lean)
        )
    }
    var fullLength: Float = 0.95
    var coreRadius: Float = 0.02
    var clashTriggerDistance: Float = 0.05
    var remoteColor = SIMD3<Float>(1.0, 0.22, 0.15)
    var glowIntensity: Float = 4
    /// Keep an untracked blade at its last pose this long before retracting.
    var untrackedGrace: Float = 1.0
}

final class SaberXRGame {
    private struct HandState {
        var ignitedTarget = false
        var ignition = CoolSaberIgnition()
        var hilt = SIMD3<Float>(0, 1.1, -0.4)
        var direction = SIMD3<Float>(0, 1, 0)
        var lastTip = SIMD3<Float>(0, 1.1, -0.4)
        var tipSpeed: Float = 0
        var untrackedTime: Float = 0
        var everTracked = false
    }

    private struct RemoteHandState {
        var ignition = CoolSaberIgnition()
        var hilt = SIMD3<Float>(0, 0, 0)
        var direction = SIMD3<Float>(0, 1, 0)
        var wire = SaberBladeWire()
        var hasPose = false
    }

    var tuning = SaberTuning()

    private let mailbox = SaberDuelMailbox.shared
    private let audio = SaberAudio()
    private let haptics = SaberHaptics()
    private let wandInput = SaberWandInput()

    private var localHands: [HandState] = [HandState(), HandState()] // left, right
    private var remoteHands: [RemoteHandState] = [RemoteHandState(), RemoteHandState()]
    private var clashDetector: CoolSaberClashDetector
    private var sequence: UInt32 = 0
    private var sendAccumulator: Float = 0
    private var lastLocalClashUptime: TimeInterval = 0
    private var loggedControllerState = false
    private var spinnerAccumulator: Float = 0
    private var elapsed: Float = 0
    private var lastFrameLogUptime: TimeInterval = 0
    private var lastLoggedDisplacement = matrix_identity_float4x4
    private var loggedFirstRemotePacket = false
    /// Our shared world anchor (engine handle) and the engine observer id.
    private var ownAnchorHandle: UUID?
    private var anchorObserverID: UUID?
    private var ownAnchorTracked: Bool?
    private var lastOwnAnchorLogUptime: TimeInterval = 0
    private var lastOpponentAnchorLogUptime: TimeInterval = 0

    init() {
        clashDetector = CoolSaberClashDetector(triggerDistance: 0.05)
    }

    func start() {
        clashDetector.triggerDistance = tuning.clashTriggerDistance
        SaberXRHolder.shared.wandsEverTracked = false

        // Without these the engine drops all spatial input events.
        registerXREvents()
        setSceneReady(true)

        audio.start()
        haptics.start()
        wandInput.start()
        startSharedAnchorObserver()

        print(
            "CoolSaber: starting — trigger or Cross ignites that hand's blade. "
                + "PSVR2 connected: \(isPSVR2SenseConnected())"
        )
    }

    func shutdown() {
        audio.stop()
        haptics.stop()
        wandInput.stop()
        stopSharedAnchor()
        clearCoolSaberScene()
    }

    // MARK: - Shared world anchor

    /// Every anchor update the engine's world tracking reports. A shared
    /// anchor that is not ours is the opponent's: they placed it at THEIR
    /// ARKit origin, so its pose here maps their wire frame into ours.
    private func startSharedAnchorObserver() {
        guard let xr = SaberXRHolder.shared.xr else { return }
        anchorObserverID = xr.addWorldAnchorObserver { [weak self] update in
            self?.handleAnchorUpdate(update)
        }
    }

    private func handleAnchorUpdate(_ update: XRWorldAnchorUpdate) {
        let now = ProcessInfo.processInfo.systemUptime
        let t = update.originFromAnchorTransform.columns.3
        if update.isOwn {
            if ownAnchorTracked != update.isTracked || now - lastOwnAnchorLogUptime > 10 {
                ownAnchorTracked = update.isTracked
                lastOwnAnchorLogUptime = now
                print(
                    "CoolSaber[anchor]: own anchor \(update.id) \(update.event) tracked=\(update.isTracked) "
                        + "shared=\(update.isSharedWithNearbyParticipants) at \(Self.fmt(SIMD3(t.x, t.y, t.z)))"
                )
            }
            return
        }
        guard update.isSharedWithNearbyParticipants else { return }

        switch update.event {
        case .removed:
            mailbox.setOpponentAnchor(nil, tracked: false, summary: "opponent anchor removed")
            print("CoolSaber[anchor]: opponent anchor \(update.id) removed")
        case .added, .updated:
            let yaw = atan2(update.originFromAnchorTransform.columns.0.z, update.originFromAnchorTransform.columns.0.x) * 180 / .pi
            let summary = String(
                format: "shared anchor %@ · yaw %.0f° · offset (%.2f, %.2f, %.2f) m",
                update.isTracked ? "tracked" : "NOT tracked", -yaw, t.x, t.y, t.z
            )
            if update.isTracked {
                mailbox.setOpponentAnchor(update.originFromAnchorTransform, tracked: true, summary: summary)
            } else {
                // Keep the last pose; just report the tracking loss.
                mailbox.setOpponentAnchor(
                    mailbox.alignmentSource == .sharedAnchor ? update.originFromAnchorTransform : nil,
                    tracked: false, summary: summary
                )
            }
            if update.event == .added || now - lastOpponentAnchorLogUptime > 5 {
                lastOpponentAnchorLogUptime = now
                print("CoolSaber[anchor]: opponent anchor \(update.id) \(update.event) — \(summary)")
            }
        }
    }

    /// Place our anchor at our ARKit origin, shared, as soon as a nearby
    /// opponent is in the session; drop it when the session ends.
    private func updateSharedAnchor() {
        let wanted = mailbox.sessionActive && mailbox.opponentNearby
        if wanted, ownAnchorHandle == nil, let xr = SaberXRHolder.shared.xr {
            ownAnchorHandle = xr.addWorldAnchor(
                originFromAnchorTransform: matrix_identity_float4x4,
                sharedWithNearbyParticipants: true
            )
            print("CoolSaber[anchor]: placing our shared anchor at the ARKit origin (handle \(String(describing: ownAnchorHandle)))")
        } else if !wanted, ownAnchorHandle != nil {
            stopSharedAnchor(keepObserver: true)
        }
    }

    private func stopSharedAnchor(keepObserver: Bool = false) {
        if let handle = ownAnchorHandle, let xr = SaberXRHolder.shared.xr {
            xr.removeWorldAnchor(handle)
            print("CoolSaber[anchor]: removed our shared anchor")
        }
        ownAnchorHandle = nil
        ownAnchorTracked = nil
        if !keepObserver, let id = anchorObserverID {
            SaberXRHolder.shared.xr?.removeWorldAnchorObserver(id)
            anchorObserverID = nil
        }
    }

    var localColor: SIMD3<Float> {
        SaberXRHolder.shared.localColor
    }

    // MARK: - Per frame

    func update(deltaTime: Float) {
        let dt = min(max(deltaTime, 0), 1.0 / 30.0)
        elapsed += dt

        updateLocalInput(dt: dt)
        updateLoadingSpinner(dt: dt)
        updateSharedAnchor()
        mailbox.setNudgeHeadingIfIdle(localHands[1].direction)
        updateRemote(dt: dt)
        publishBlades()
        detectClashes(dt: dt)
        updateAudio()
        sendPoses(dt: dt)
    }

    func handleInput() {}

    // MARK: - Local controllers

    private func updateLocalInput(dt: Float) {
        let sense = getPSVR2SenseState()
        let pad = getGameControllerState()

        if sense.isConnected, !loggedControllerState {
            loggedControllerState = true
            // One-shot dump so the per-hand trigger mapping is verifiable on device.
            print(
                "CoolSaber: PSVR2 connected — LT=\(pad.leftTriggerValue) RT=\(pad.rightTriggerValue) "
                    + "A=\(pad.aPressed) leftTracked=\(sense.left.isTracked) rightTracked=\(sense.right.isTracked)"
            )
        }

        // Per-wand presses, read directly from each GCController so each
        // saber ignites independently. No merged-state fallback: the wand's
        // trigger surfaces as a "Button A" alias on real firmware, so a
        // toggle-both path on aPressed would fire on every trigger pull.
        for hand in wandInput.takeToggles() {
            toggleIgnite(hand: hand == .left ? 0 : 1)
        }

        let poses = [sense.left, sense.right]
        var autoIgnite: [Int] = []
        for hand in 0 ..< 2 {
            var state = localHands[hand]
            if poses[hand].isTracked {
                // First sight of this wand: light it up, so entering the arena
                // gives immediate feedback (mixed immersion shows nothing at
                // all otherwise). The trigger retracts it as usual.
                if !state.everTracked {
                    autoIgnite.append(hand)
                    SaberXRHolder.shared.wandsEverTracked = true
                }
                state.everTracked = true
                state.untrackedTime = 0
                state.hilt = poses[hand].position
                    + poses[hand].orientation.act(tuning.gripOffsetLocal(hand: hand))
                state.direction = simd_normalize(
                    poses[hand].orientation.act(tuning.bladeAxisLocal(hand: hand))
                )
            } else if state.everTracked {
                // Hold the last pose briefly, then retract rather than flicker.
                state.untrackedTime += dt
                if state.untrackedTime > tuning.untrackedGrace {
                    state.ignitedTarget = false
                }
            }
            state.ignition.update(deltaTime: dt, ignited: state.ignitedTarget)

            let length = state.ignition.easedProgress * tuning.fullLength
            let tip = state.hilt + state.direction * length
            state.tipSpeed = dt > 0 ? simd_distance(tip, state.lastTip) / dt : 0
            state.lastTip = tip
            localHands[hand] = state
        }
        for hand in autoIgnite where !localHands[hand].ignitedTarget {
            toggleIgnite(hand: hand)
        }

        #if targetEnvironment(simulator)
        driveSimulatorDebugBlades()
        #endif
    }

    // MARK: - Loading spinner

    /// While the wands exist but neither has delivered a tracked pose yet,
    /// orbit a pair of fading sparks on a small circle ahead of the user: a
    /// "loading" cue for the seconds ARKit needs to bring up world tracking
    /// and accessory anchors. It only renders once head tracking works (the
    /// engine skips frames without a device anchor), so a visible spinner
    /// also means the render path is healthy — it vanishes the moment the
    /// first wand tracks and the blades auto-ignite. Replaces the old
    /// frozen-blades-at-resting-pose fallback, which read as broken.
    private func updateLoadingSpinner(dt: Float) {
        guard !localHands.contains(where: { $0.everTracked }),
              isPSVR2SenseConnected()
        else { return }

        // Spawn cadence tuned to the spark system: 2 sparks every 45 ms fill
        // the 8-spark cap over ~0.18 s — exactly one spark lifetime — so the
        // ring carries a full fading comet trail.
        spinnerAccumulator += dt
        guard spinnerAccumulator >= 0.045 else { return }
        spinnerAccumulator = 0

        // World origin is on the floor beneath the user at space open, -Z is
        // where they were facing: chest height, one metre ahead.
        let center = SIMD3<Float>(0, 1.35, -1.0)
        let radius: Float = 0.12
        let speed: Float = 3.0 // rad/s
        for arm in 0 ..< 2 {
            let angle = elapsed * speed + Float(arm) * .pi
            let position = center + SIMD3<Float>(cos(angle), sin(angle), 0) * radius
            spawnCoolSaberClashSpark(at: position, color: localColor, intensity: 2.5)
        }
    }

    private func toggleIgnite(hand: Int) {
        localHands[hand].ignitedTarget.toggle()
        let ignited = localHands[hand].ignitedTarget
        if ignited {
            audio.playIgnite()
        } else {
            audio.playRetract()
        }
        let saberHand: SaberHand = hand == 0 ? .left : .right
        haptics.ignitePulse(hand: saberHand)
        mailbox.pushLocalEvent(
            .ignite(hand: saberHand, ignited: ignited, color: localColor)
        )
    }

    #if targetEnvironment(simulator)
    /// The simulator has no PSVR2: swing two auto-ignited debug blades so the
    /// full render/clash path is verifiable without hardware.
    private func driveSimulatorDebugBlades() {
        for hand in 0 ..< 2 {
            var state = localHands[hand]
            if elapsed > 1.5 { state.ignitedTarget = true }
            let side: Float = hand == 0 ? -1 : 1
            let swing = sin(elapsed * 1.6 + (hand == 0 ? 0 : 0.9))
            state.hilt = SIMD3<Float>(side * 0.28, 1.05, -0.85)
            state.direction = simd_normalize(
                SIMD3<Float>(-side * (0.45 + 0.35 * swing), 1.0, 0.15 * swing)
            )
            localHands[hand] = state
        }
    }
    #endif

    // MARK: - Remote opponent

    /// How a point in the opponent's wire frame lands in our ARKit frame.
    /// Manual sync wins; then the system displacement (identity for nearby
    /// players in a Metal space, so raw); then the fixed opponent anchor.
    private enum RemoteMapping {
        case matrix(simd_float4x4)
        case anchor

        func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
            switch self {
            case .matrix(let m): SaberXRGame.transformPoint(m, p)
            case .anchor: SaberXRGame.opponentAnchor(p)
            }
        }

        func direction(_ d: SIMD3<Float>) -> SIMD3<Float> {
            switch self {
            case .matrix(let m): SaberXRGame.transformDirection(m, d)
            case .anchor: SaberXRGame.opponentAnchorRotation(d)
            }
        }
    }

    private func currentRemoteMapping(localFromShared: simd_float4x4) -> RemoteMapping {
        if let localFromOpponent = mailbox.localFromOpponent {
            return .matrix(localFromShared * localFromOpponent)
        }
        return mailbox.sharesFrame ? .matrix(localFromShared) : .anchor
    }

    private func updateRemote(dt: Float) {
        // ARKit-from-shared for THIS device; the sender already removed its own.
        let localFromShared = SaberXRHolder.shared.spaceDisplacement

        for event in mailbox.takeRemoteEvents() {
            switch event {
            case .ignite(_, let ignited, _):
                if ignited { audio.playIgnite() } else { audio.playRetract() }
            case .clash(let position, let intensity):
                // Dedupe: our own detector probably saw the same contact.
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastLocalClashUptime > 0.15 {
                    let local = currentRemoteMapping(localFromShared: localFromShared).point(position)
                    spawnCoolSaberClashSpark(at: local, intensity: intensity)
                    audio.playClash(intensity: intensity)
                }
            case .frameSync(let transform):
                let t = transform.matrix.columns.3
                mailbox.setLocalFromOpponent(
                    transform.matrix,
                    heading: localHands[1].direction,
                    summary: String(format: "synced by opponent · offset (%.2f, %.2f, %.2f) m", t.x, t.y, t.z)
                )
                print("CoolSaber[sync]: received frame sync from opponent — \(mailbox.frameSyncSummary)")
                for hand in 0 ..< 2 { remoteHands[hand].hasPose = false } // snap, don't glide
            }
        }

        let snapshot = mailbox.remoteSnapshot()
        let now = ProcessInfo.processInfo.systemUptime
        logFrameDiagnostics(now: now, snapshot: snapshot, localFromShared: localFromShared)

        if mailbox.takeFrameSyncRequest() {
            solveFrameSync(snapshot: snapshot, now: now, localFromShared: localFromShared)
        }
        if let nudged = mailbox.takeSettledNudge(now: now) {
            let t = nudged.columns.3
            print(String(format: "CoolSaber[sync]: fine-tune settled — offset (%.2f, %.2f, %.2f) m, sending", t.x, t.y, t.z))
            mailbox.pushLocalEvent(.frameSync(receiverFromSender: SaberFrameTransform(simd_inverse(nudged))))
            for hand in 0 ..< 2 { remoteHands[hand].hasPose = false }
        }
        let mapping = currentRemoteMapping(localFromShared: localFromShared)
        guard mailbox.sessionActive, mailbox.opponentPresent,
              let packet = snapshot.packet,
              now - snapshot.arrivalUptime < 2.0
        else {
            for hand in 0 ..< 2 {
                remoteHands[hand].hasPose = false
                remoteHands[hand].ignition.update(deltaTime: dt, ignited: false)
            }
            return
        }

        let stale = now - snapshot.arrivalUptime > 0.5
        let wires = [packet.left, packet.right]
        for hand in 0 ..< 2 {
            var state = remoteHands[hand]
            var wire = wires[hand]

            wire.hilt = mapping.point(wire.hilt)
            wire.direction = mapping.direction(wire.direction)

            if !state.hasPose {
                state.hilt = wire.hilt
                state.direction = wire.direction
                state.hasPose = true
            } else if !stale {
                // Exponential smoothing toward the newest packet.
                let alpha = 1 - exp(-20 * dt)
                state.hilt += (wire.hilt - state.hilt) * alpha
                let blended = simd_mix(state.direction, wire.direction, SIMD3(repeating: alpha))
                state.direction = simd_length_squared(blended) > 1e-8
                    ? simd_normalize(blended)
                    : wire.direction
            }
            state.wire = wire
            state.ignition.update(deltaTime: dt, ignited: wire.ignited)
            remoteHands[hand] = state
        }
    }

    /// translate(0, 0, -2) · rotateY(π) applied to a point.
    private static func opponentAnchor(_ point: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(-point.x, point.y, -point.z - 2)
    }

    private static func opponentAnchorRotation(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(-vector.x, vector.y, -vector.z)
    }

    private static func transformPoint(_ m: simd_float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4<Float>(point, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }

    private static func transformDirection(_ m: simd_float4x4, _ direction: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4<Float>(direction, 0)
        let rotated = SIMD3<Float>(v.x, v.y, v.z)
        return simd_length_squared(rotated) > 1e-8 ? simd_normalize(rotated) : direction
    }

    /// The Sync tap: the players face each other and touch the fronts of
    /// their right controller rings together, level, pointing at each other.
    /// The contact point is `ringFront` metres along each blade axis from its
    /// hilt — the same physical point seen from both frames — and the two
    /// headings are opposite, which fixes the yaw. Unlike holding the
    /// controllers side by side, nothing depends on hand or controller
    /// width: only the hilt-to-ring-front distance, a hardware constant.
    private func solveFrameSync(
        snapshot: (packet: SaberPosePacket?, arrivalUptime: TimeInterval),
        now: TimeInterval,
        localFromShared: simd_float4x4
    ) {
        let heading = localHands[1].direction
        guard let packet = snapshot.packet, now - snapshot.arrivalUptime < 0.5 else {
            mailbox.setLocalFromOpponent(nil, heading: heading, summary: "sync failed: no fresh opponent pose")
            print("CoolSaber[sync]: no fresh remote packet — is the opponent's right wand tracked?")
            return
        }
        guard localHands[1].everTracked, localHands[1].untrackedTime == 0 else {
            mailbox.setLocalFromOpponent(nil, heading: heading, summary: "sync failed: our right wand is not tracked")
            print("CoolSaber[sync]: local right wand not tracked")
            return
        }
        // Solve in our wire frame so the result composes with the sender's
        // and our displacement exactly like a packet does.
        let ringFront = mailbox.ringFront
        let sharedFromLocal = simd_inverse(localFromShared)
        let localHeading = Self.transformDirection(sharedFromLocal, heading)
        let localContact = Self.transformPoint(sharedFromLocal, localHands[1].hilt) + localHeading * ringFront
        let remoteContact = packet.right.hilt + packet.right.direction * ringFront
        // Tip to tip means the opponent's blade points back at us: align
        // their heading reversed onto ours.
        guard let solved = CoolSaberMath.yawAlignedFrame(
            localPoint: localContact,
            localHeading: localHeading,
            remotePoint: remoteContact,
            remoteHeading: -packet.right.direction
        ) else {
            mailbox.setLocalFromOpponent(nil, heading: heading, summary: "sync failed: hold the controllers level")
            print("CoolSaber[sync]: headings too vertical — local \(Self.fmt(localHeading)) remote \(Self.fmt(packet.right.direction))")
            return
        }
        // Residual between the two blade axes after alignment: a large
        // value means the controllers were not pointing at each other.
        let mappedRemoteHeading = Self.transformDirection(solved.localFromRemote, packet.right.direction)
        let axisErrorDegrees = acos(max(-1, min(1, simd_dot(-mappedRemoteHeading, localHeading)))) * 180 / .pi
        let t = solved.localFromRemote.columns.3
        let summary = String(
            format: "synced · yaw %.0f° · offset (%.2f, %.2f, %.2f) m · axis error %.0f°",
            solved.yawDegrees, t.x, t.y, t.z, axisErrorDegrees
        )
        mailbox.setLocalFromOpponent(solved.localFromRemote, heading: heading, summary: summary)
        for hand in 0 ..< 2 { remoteHands[hand].hasPose = false }
        print(
            "CoolSaber[sync]: \(summary) — ring front \(String(format: "%.3f", ringFront)) m; "
                + "local contact \(Self.fmt(localContact)) heading \(Self.fmt(localHeading)); "
                + "remote contact \(Self.fmt(remoteContact)) heading \(Self.fmt(packet.right.direction)) "
                + "→ mapped \(Self.fmt(Self.transformPoint(solved.localFromRemote, remoteContact)))"
        )
        // The opponent needs the inverse for OUR packets.
        mailbox.pushLocalEvent(.frameSync(
            receiverFromSender: SaberFrameTransform(simd_inverse(solved.localFromRemote))
        ))
    }

    private static func fmt(_ v: SIMD3<Float>) -> String {
        String(format: "(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
    }

    /// Every 2 s during a duel: the frames on both ends of the wire, so a
    /// misplaced opponent blade can be traced to the displacement (identity
    /// when the system never aligned the spaces) or to the session flags.
    private func logFrameDiagnostics(
        now: TimeInterval,
        snapshot: (packet: SaberPosePacket?, arrivalUptime: TimeInterval),
        localFromShared: simd_float4x4
    ) {
        guard mailbox.sessionActive else { return }

        let displacementChanged = localFromShared != lastLoggedDisplacement
        if displacementChanged {
            lastLoggedDisplacement = localFromShared
            print(
                "CoolSaber[frame]: displacement now \(SaberXRHolder.shared.displacementSummary) "
                    + "— shared origin sits at \(Self.fmt(Self.transformPoint(localFromShared, .zero))) in our ARKit frame"
            )
        }
        if let packet = snapshot.packet, !loggedFirstRemotePacket {
            loggedFirstRemotePacket = true
            print(
                "CoolSaber[frame]: first remote packet #\(packet.sequence) — "
                    + "R hilt (shared) \(Self.fmt(packet.right.hilt)) → (ours) "
                    + "\(Self.fmt(Self.transformPoint(localFromShared, packet.right.hilt)))"
            )
        }

        guard now - lastFrameLogUptime >= 2 else { return }
        lastFrameLogUptime = now

        let sharedFromLocal = simd_inverse(localFromShared)
        let localHilt = localHands[1].hilt
        var line = "CoolSaber[frame]: spatial \(mailbox.isSpatial) nearby \(mailbox.opponentNearby) "
            + "sharesFrame \(mailbox.sharesFrame) displacement \(SaberXRHolder.shared.displacementSummary)"
            + " align \(mailbox.alignmentSource) [anchor: \(mailbox.anchorSummary)] [manual: \(mailbox.frameSyncSummary)]"
            + " | local R hilt ARKit \(Self.fmt(localHilt)) → shared \(Self.fmt(Self.transformPoint(sharedFromLocal, localHilt)))"
        if let packet = snapshot.packet {
            let age = now - snapshot.arrivalUptime
            line += String(format: " | remote #%u age %.2fs R hilt shared ", packet.sequence, age)
                + Self.fmt(packet.right.hilt)
                + " → ours \(Self.fmt(remoteHands[1].hilt)) ignited \(packet.right.ignited)"
        } else {
            line += " | no remote packet (opponentPresent \(mailbox.opponentPresent))"
        }
        print(line)
    }

    // MARK: - Feeding the renderer

    private func localBladeLength(_ hand: Int) -> Float {
        localHands[hand].ignition.easedProgress * tuning.fullLength
    }

    private func remoteBladeLength(_ hand: Int) -> Float {
        remoteHands[hand].ignition.easedProgress * tuning.fullLength
    }

    private func publishBlades() {
        let localSlots: [CoolSaberBladeSlot] = [.localLeft, .localRight]
        let remoteSlots: [CoolSaberBladeSlot] = [.remoteLeft, .remoteRight]

        for hand in 0 ..< 2 {
            let state = localHands[hand]
            let length = localBladeLength(hand)
            setCoolSaberBlade(
                localSlots[hand],
                length > 0.01
                    ? CoolSaberBladeDesc(
                        hilt: state.hilt,
                        direction: state.direction,
                        length: length,
                        radius: tuning.coreRadius,
                        color: localColor,
                        glowIntensity: tuning.glowIntensity
                    )
                    : nil
            )

            let remote = remoteHands[hand]
            let remoteLength = remoteBladeLength(hand)
            setCoolSaberBlade(
                remoteSlots[hand],
                remote.hasPose && remoteLength > 0.01
                    ? CoolSaberBladeDesc(
                        hilt: remote.hilt,
                        direction: remote.direction,
                        length: remoteLength,
                        radius: tuning.coreRadius,
                        color: tuning.remoteColor,
                        glowIntensity: tuning.glowIntensity
                    )
                    : nil
            )
        }
    }

    // MARK: - Clash detection

    private struct BladeSegment {
        var slot: CoolSaberBladeSlot
        var start: SIMD3<Float>
        var end: SIMD3<Float>
        var tipVelocityRef: SIMD3<Float>
        var isLocal: Bool
        var hand: Int
    }

    private func detectClashes(dt: Float) {
        var segments: [BladeSegment] = []
        for hand in 0 ..< 2 {
            let length = localBladeLength(hand)
            if length > 0.05 {
                let state = localHands[hand]
                segments.append(BladeSegment(
                    slot: hand == 0 ? .localLeft : .localRight,
                    start: state.hilt,
                    end: state.hilt + state.direction * length,
                    tipVelocityRef: state.lastTip,
                    isLocal: true,
                    hand: hand
                ))
            }
            let remoteLength = remoteBladeLength(hand)
            if remoteHands[hand].hasPose, remoteLength > 0.05 {
                let state = remoteHands[hand]
                segments.append(BladeSegment(
                    slot: hand == 0 ? .remoteLeft : .remoteRight,
                    start: state.hilt,
                    end: state.hilt + state.direction * remoteLength,
                    tipVelocityRef: .zero,
                    isLocal: false,
                    hand: hand
                ))
            }
        }

        guard segments.count >= 2 else { return }
        for i in 0 ..< segments.count - 1 {
            for j in (i + 1) ..< segments.count {
                let a = segments[i]
                let b = segments[j]
                guard a.isLocal || b.isLocal else { continue }
                let result = CoolSaberMath.segmentSegmentClosest(
                    a.start, a.end, b.start, b.end
                )
                let pairKey = a.slot.rawValue * 4 + b.slot.rawValue
                guard clashDetector.update(
                    pairKey: pairKey,
                    distance: result.distance,
                    deltaTime: dt
                ) else { continue }

                let contact = (result.pointA + result.pointB) * 0.5
                // Faster combined tip motion → brighter spark, harder kick.
                let speed = max(localHands[0].tipSpeed, localHands[1].tipSpeed)
                let intensity = 6 + min(speed, 6) * 1.5

                lastLocalClashUptime = ProcessInfo.processInfo.systemUptime
                spawnCoolSaberClashSpark(at: contact, intensity: intensity)
                audio.playClash(intensity: intensity)
                for segment in [a, b] where segment.isLocal {
                    haptics.clashPulse(
                        hand: segment.hand == 0 ? .left : .right,
                        intensity: min(0.5 + speed * 0.12, 1)
                    )
                }
                if mailbox.sessionActive {
                    // Events travel in the shared frame like the poses.
                    let sharedFromLocal = simd_inverse(SaberXRHolder.shared.spaceDisplacement)
                    mailbox.pushLocalEvent(.clash(
                        position: Self.transformPoint(sharedFromLocal, contact),
                        intensity: intensity
                    ))
                }
            }
        }
    }

    // MARK: - Audio + network

    private func updateAudio() {
        for hand in 0 ..< 2 {
            audio.setHum(
                slot: hand,
                ignited: localBladeLength(hand) > 0.05,
                tipSpeed: localHands[hand].tipSpeed
            )
            audio.setHum(
                slot: 2 + hand,
                ignited: remoteHands[hand].hasPose && remoteBladeLength(hand) > 0.05,
                tipSpeed: 2
            )
        }
    }

    private func sendPoses(dt: Float) {
        guard mailbox.sessionActive else { return }
        sendAccumulator += dt
        guard sendAccumulator >= 1.0 / 45.0 else { return }
        sendAccumulator = 0

        sequence &+= 1
        // Strip our own immersive-space displacement so the packet is in the
        // group's shared frame (a no-op while the displacement is identity).
        let sharedFromLocal = simd_inverse(SaberXRHolder.shared.spaceDisplacement)
        func wire(_ hand: Int) -> SaberBladeWire {
            SaberBladeWire(
                hilt: Self.transformPoint(sharedFromLocal, localHands[hand].hilt),
                direction: Self.transformDirection(sharedFromLocal, localHands[hand].direction),
                length: localBladeLength(hand),
                ignited: localHands[hand].ignitedTarget
            )
        }
        mailbox.publishLocalPoses(SaberPosePacket(
            sequence: sequence,
            timestamp: ProcessInfo.processInfo.systemUptime,
            left: wire(0),
            right: wire(1)
        ))
    }
}
