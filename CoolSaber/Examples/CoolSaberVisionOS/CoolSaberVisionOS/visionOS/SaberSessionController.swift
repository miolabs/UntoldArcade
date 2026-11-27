//
//  SaberSessionController.swift  (visionOS)
//  CoolSaber
//
//  SharePlay plumbing. The controller lives on the main actor; the XR game
//  loop runs on its own thread and must never touch actor state, so all
//  game-facing traffic goes through the lock-guarded SaberDuelMailbox.
//

import Combine
import CoolSaber
import Foundation
import GroupActivities
import simd
import SwiftUI // pulls in the _GroupActivities_SwiftUI overlay (groupImmersionStyle)

/// Thread-safe bridge between the main-actor SharePlay session and the XR
/// game thread. The game writes outgoing poses/events and reads the latest
/// remote state; the session controller does the opposite.
final class SaberDuelMailbox: @unchecked Sendable {
    static let shared = SaberDuelMailbox()

    private let lock = NSLock()

    private var outgoingPacket: SaberPosePacket?
    private var outgoingEvents: [SaberEvent] = []
    private var remotePacket: SaberPosePacket?
    private var remoteArrivalUptime: TimeInterval = 0
    private var remoteEvents: [SaberEvent] = []
    private var sessionActiveStorage = false
    private var isSpatialStorage = false
    private var opponentNearbyStorage = false
    private var opponentPresentStorage = false
    private var frameSyncBase: simd_float4x4?
    private var frameSyncHeading = SIMD3<Float>(0, 0, -1)
    private var frameSyncNudge = SIMD2<Float>(0, 0) // side, forward (m)
    private var frameSyncNudgeDirtyUptime: TimeInterval?
    private var frameSyncRequested = false
    private var frameSyncSummaryStorage = "not synced"
    /// From the opponent's shared ARKit world anchor (placed at their origin):
    /// its pose in our frame IS local-from-opponent. Preferred over the manual
    /// solution unless the player synced manually afterwards.
    private var anchorBase: simd_float4x4?
    private var anchorTracked = false
    private var anchorUpdateUptime: TimeInterval = 0
    private var anchorSummaryStorage = "no shared anchor yet"
    private var preferManualSync = false
    private var ringFrontStorage: Float = 0.05

    // MARK: Game-thread side

    func publishLocalPoses(_ packet: SaberPosePacket) {
        lock.withLock { outgoingPacket = packet }
    }

    func pushLocalEvent(_ event: SaberEvent) {
        lock.withLock { outgoingEvents.append(event) }
    }

    func remoteSnapshot() -> (packet: SaberPosePacket?, arrivalUptime: TimeInterval) {
        lock.withLock { (remotePacket, remoteArrivalUptime) }
    }

    func takeRemoteEvents() -> [SaberEvent] {
        lock.withLock {
            let events = remoteEvents
            remoteEvents.removeAll()
            return events
        }
    }

    var sessionActive: Bool {
        lock.withLock { sessionActiveStorage }
    }

    /// True when the system coordinates a shared immersive-space origin
    /// (spatial Personas). False means remote poses need the opponent anchor.
    var isSpatial: Bool {
        lock.withLock { isSpatialStorage }
    }

    /// True when an opponent is physically in the same room (visionOS 26
    /// nearby SharePlay). The system aligns nearby participants' immersive
    /// spaces in place, so their frames relate through the displacement.
    var opponentNearby: Bool {
        lock.withLock { opponentNearbyStorage }
    }

    /// Whether wire poses can be mapped between the two headsets through
    /// the immersive-space displacement (spatial or nearby session). False
    /// falls back to the fixed opponent anchor.
    var sharesFrame: Bool {
        lock.withLock { isSpatialStorage || opponentNearbyStorage }
    }

    var opponentPresent: Bool {
        lock.withLock { opponentPresentStorage }
    }

    // MARK: Manual frame sync

    /// Maps the opponent's wire frame into ours, solved by touching the right
    /// controllers together (`CoolSaberMath.yawAlignedFrame`). Set locally by
    /// the player who tapped Sync, or received from the opponent. Takes
    /// precedence over the system displacement, which is identity for nearby
    /// participants in a Metal immersive space.
    var localFromOpponent: simd_float4x4? {
        lock.withLock { composedLocalFromOpponent() }
    }

    /// Solution plus the player's fine-tune nudge, expressed along the
    /// heading captured at sync time (forward) and its horizontal right.
    private func composedLocalFromOpponent() -> simd_float4x4? {
        guard let base = activeBase() else { return nil }
        guard frameSyncNudge != .zero else { return base }
        let forward = frameSyncHeading
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let shift = right * frameSyncNudge.x + forward * frameSyncNudge.y
        var nudge = matrix_identity_float4x4
        nudge.columns.3 = SIMD4<Float>(shift, 1)
        return nudge * base
    }

    var frameSyncSummary: String {
        lock.withLock { frameSyncSummaryStorage }
    }

    var isFrameSynced: Bool {
        lock.withLock { activeBase() != nil }
    }

    enum AlignmentSource: Equatable {
        case none
        case sharedAnchor
        case manual
    }

    /// Shared anchor when it exists and the player has not overridden it
    /// manually; the manual solution otherwise.
    private func activeBase() -> simd_float4x4? {
        if !preferManualSync, let anchorBase { return anchorBase }
        return frameSyncBase
    }

    var alignmentSource: AlignmentSource {
        lock.withLock {
            if !preferManualSync, anchorBase != nil { return .sharedAnchor }
            return frameSyncBase != nil ? .manual : .none
        }
    }

    var anchorSummary: String {
        lock.withLock { anchorSummaryStorage }
    }

    /// Game thread, from the engine's anchor observer: the opponent's shared
    /// anchor moved or changed tracking. `nil` forgets it (anchor removed).
    func setOpponentAnchor(_ matrix: simd_float4x4?, tracked: Bool, summary: String) {
        lock.withLock {
            anchorBase = matrix
            anchorTracked = tracked
            anchorUpdateUptime = ProcessInfo.processInfo.systemUptime
            anchorSummaryStorage = summary
        }
    }

    /// Nudge axes follow the player's heading until they start nudging.
    func setNudgeHeadingIfIdle(_ heading: SIMD3<Float>) {
        lock.withLock {
            guard frameSyncNudge == .zero else { return }
            let flat = SIMD3<Float>(heading.x, 0, heading.z)
            if simd_length(flat) > 1e-4 { frameSyncHeading = simd_normalize(flat) }
        }
    }

    /// Installs a solution (ours or the opponent's). `heading` is our
    /// horizontal heading at sync time, the axis the nudges run along.
    func setLocalFromOpponent(_ matrix: simd_float4x4?, heading: SIMD3<Float>, summary: String) {
        lock.withLock {
            frameSyncBase = matrix
            // An explicit manual sync (or one received from the opponent)
            // overrides the shared anchor until the opponent changes.
            preferManualSync = matrix != nil
            let flat = SIMD3<Float>(heading.x, 0, heading.z)
            frameSyncHeading = simd_length(flat) > 1e-4 ? simd_normalize(flat) : SIMD3<Float>(0, 0, -1)
            frameSyncNudge = .zero
            frameSyncNudgeDirtyUptime = nil
            frameSyncSummaryStorage = summary
        }
    }

    /// Distance from the hilt to the physical front of the controller ring
    /// along the blade axis, in metres: the tip-to-tip contact point.
    var ringFront: Float {
        get { lock.withLock { ringFrontStorage } }
        set { lock.withLock { ringFrontStorage = newValue } }
    }

    /// Fine tune after a sync: x = side (right +), y = forward, metres.
    var frameSyncNudgeValue: SIMD2<Float> {
        get { lock.withLock { frameSyncNudge } }
        set {
            lock.withLock {
                guard frameSyncBase != nil else { return }
                frameSyncNudge = newValue
                frameSyncNudgeDirtyUptime = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    /// Game thread: once the sliders have rested 0.3 s, the composed matrix
    /// is re-sent so the opponent sees the same alignment.
    func takeSettledNudge(now: TimeInterval) -> simd_float4x4? {
        lock.withLock {
            guard let dirty = frameSyncNudgeDirtyUptime, now - dirty > 0.3 else { return nil }
            frameSyncNudgeDirtyUptime = nil
            return composedLocalFromOpponent()
        }
    }

    /// Window → game thread: solve the alignment on the next frame.
    func requestFrameSync() {
        lock.withLock {
            frameSyncRequested = true
            frameSyncSummaryStorage = "syncing…"
        }
    }

    func takeFrameSyncRequest() -> Bool {
        lock.withLock {
            let requested = frameSyncRequested
            frameSyncRequested = false
            return requested
        }
    }

    // MARK: Session-controller side

    func takeOutgoing() -> (packet: SaberPosePacket?, events: [SaberEvent]) {
        lock.withLock {
            let packet = outgoingPacket
            let events = outgoingEvents
            outgoingPacket = nil
            outgoingEvents.removeAll()
            return (packet, events)
        }
    }

    func storeRemote(_ packet: SaberPosePacket) {
        lock.withLock {
            if let existing = remotePacket, packet.sequence <= existing.sequence,
               existing.sequence - packet.sequence < UInt32.max / 2 {
                return // stale or out of order
            }
            remotePacket = packet
            remoteArrivalUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    func pushRemoteEvent(_ event: SaberEvent) {
        lock.withLock { remoteEvents.append(event) }
    }

    func setSessionActive(_ active: Bool) {
        lock.withLock {
            sessionActiveStorage = active
            if !active {
                remotePacket = nil
                remoteEvents.removeAll()
                outgoingPacket = nil
                outgoingEvents.removeAll()
                opponentPresentStorage = false
                opponentNearbyStorage = false
                isSpatialStorage = false
                frameSyncBase = nil
                frameSyncNudge = .zero
                frameSyncNudgeDirtyUptime = nil
                frameSyncRequested = false
                frameSyncSummaryStorage = "not synced"
                anchorBase = nil
                anchorTracked = false
                anchorSummaryStorage = "no shared anchor yet"
                preferManualSync = false
            }
        }
    }

    func setIsSpatial(_ spatial: Bool) {
        lock.withLock { isSpatialStorage = spatial }
    }

    func setOpponentNearby(_ nearby: Bool) {
        lock.withLock { opponentNearbyStorage = nearby }
    }

    func setOpponentPresent(_ present: Bool) {
        lock.withLock {
            opponentPresentStorage = present
            if !present {
                remotePacket = nil
                // A new opponent has a new frame; the old solution is void.
                frameSyncBase = nil
                frameSyncNudge = .zero
                frameSyncNudgeDirtyUptime = nil
                frameSyncSummaryStorage = "not synced"
                anchorBase = nil
                anchorTracked = false
                anchorSummaryStorage = "no shared anchor yet"
                preferManualSync = false
            }
        }
    }
}

@MainActor
@Observable
final class SaberSessionController {
    enum Status: Equatable {
        case idle
        case waiting
        case joined(participants: Int)
    }

    private(set) var status: Status = .idle
    private(set) var statusMessage = "Solo practice — start a duel from a FaceTime call."
    /// Mirrors the system's group-immersion request: true → open the immersive
    /// space, false → dismiss it, nil → no opinion (manual control).
    private(set) var groupImmersionActive: Bool?
    /// Bumps once per successful join; the app cycles an already-open arena
    /// on it so the space becomes the group's shared space.
    private(set) var joinCount = 0

    let mailbox = SaberDuelMailbox.shared

    private var session: GroupSession<SaberActivity>?
    private var poseMessenger: GroupSessionMessenger?
    private var eventMessenger: GroupSessionMessenger?
    private var tasks: [Task<Void, Never>] = []
    private var subscriptions: Set<AnyCancellable> = []

    /// Call once at app launch; handles every incoming session for the activity.
    func startSessionObserver() {
        Task {
            for await session in SaberActivity.sessions() {
                configure(session)
            }
        }
    }

    func startDuel() {
        statusMessage = "Starting duel…"
        Task {
            do {
                _ = try await SaberActivity().activate()
            } catch {
                statusMessage = "Could not start SharePlay: \(error.localizedDescription)"
            }
        }
    }

    func leaveDuel() {
        session?.leave()
        cleanup(message: "Left the duel. Solo practice.")
    }

    private func configure(_ session: GroupSession<SaberActivity>) {
        cleanup(message: statusMessage)
        self.session = session
        status = .waiting
        statusMessage = "Duel session found — joining…"

        // Messengers and receive loops must exist before join() so no early
        // message is dropped.
        let poses = GroupSessionMessenger(session: session, deliveryMode: .unreliable)
        let events = GroupSessionMessenger(session: session, deliveryMode: .reliable)
        poseMessenger = poses
        eventMessenger = events

        tasks.append(Task { [mailbox] in
            for await (packet, _) in poses.messages(of: SaberPosePacket.self) {
                mailbox.storeRemote(packet)
            }
        })
        tasks.append(Task { [mailbox] in
            for await (event, _) in events.messages(of: SaberEvent.self) {
                mailbox.pushRemoteEvent(event)
            }
        })

        // Outgoing pump: drain the mailbox at ~45 Hz. Unreliable sends are
        // fire-and-forget; a dropped pose packet is superseded 22 ms later.
        tasks.append(Task { [mailbox, weak self] in
            while !Task.isCancelled {
                let outgoing = mailbox.takeOutgoing()
                if let packet = outgoing.packet {
                    try? await poses.send(packet)
                }
                for event in outgoing.events {
                    try? await events.send(event)
                }
                guard self != nil else { return }
                try? await Task.sleep(nanoseconds: 22_000_000)
            }
        })

        tasks.append(Task { [weak self] in
            await self?.configureSystemCoordinator(for: session)
        })

        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .joined:
                    self.status = .joined(participants: session.activeParticipants.count)
                    self.statusMessage = "Duel joined — waiting for your opponent's blades."
                    self.mailbox.setSessionActive(true)
                    self.joinCount += 1
                case .waiting:
                    self.status = .waiting
                case .invalidated:
                    self.cleanup(message: "Duel ended. Solo practice.")
                @unknown default:
                    break
                }
            }
            .store(in: &subscriptions)

        session.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self, let session = self.session else { return }
                let opponents = participants.subtracting([session.localParticipant])
                self.mailbox.setOpponentPresent(!opponents.isEmpty)
                let nearby = opponents.contains { $0.isNearbyWithLocalParticipant }
                self.mailbox.setOpponentNearby(nearby)
                for participant in opponents {
                    print(
                        "CoolSaber: participant \(participant.id) — nearby: "
                            + "\(participant.isNearbyWithLocalParticipant)"
                    )
                }
                print(
                    "CoolSaber: \(opponents.count) opponent(s), nearby: \(nearby), "
                        + "spatial: \(self.mailbox.isSpatial)"
                )
                if case .joined = self.status {
                    self.status = .joined(participants: participants.count)
                    self.statusMessage = opponents.isEmpty
                        ? "Waiting for an opponent to join…"
                        : "Opponent connected — fight!"
                }
            }
            .store(in: &subscriptions)

        session.join()
    }

    private func configureSystemCoordinator(for session: GroupSession<SaberActivity>) async {
        guard let coordinator = await session.systemCoordinator else {
            print("CoolSaber: no systemCoordinator for this session — no shared frame possible")
            return
        }
        print("CoolSaber: systemCoordinator acquired — requesting group immersive space")

        var configuration = SystemCoordinator.Configuration()
        configuration.supportsGroupImmersiveSpace = true
        // A duel wants the participants facing each other with room between.
        configuration.spatialTemplatePreference = .conversational
        coordinator.configuration = configuration

        tasks.append(Task { [mailbox] in
            for await state in coordinator.localParticipantStates {
                mailbox.setIsSpatial(state.isSpatial)
                // `pose` (visionOS 26) is our own position in the shared
                // frame — a second, independent handle on the alignment.
                let pose = state.pose.map { pose -> String in
                    let p = pose.position.vector
                    return String(
                        format: "(%.2f, %.2f, %.2f) m, yaw-ish %.1f°",
                        p.x, p.y, p.z, pose.rotation.angle.degrees
                    )
                } ?? "nil"
                print(
                    "CoolSaber: localParticipantState — spatial: \(state.isSpatial), "
                        + "seat: \(String(describing: state.seat)), pose: \(pose), "
                        + "displacement: \(SaberXRHolder.shared.displacementSummary)"
                )
            }
        })
        tasks.append(Task { [weak self] in
            for await immersionStyle in coordinator.groupImmersionStyle {
                print(
                    "CoolSaber: groupImmersionStyle → "
                        + "\(immersionStyle.map { String(describing: $0) } ?? "nil (windowed)")"
                )
                await MainActor.run {
                    self?.groupImmersionActive = immersionStyle != nil
                }
            }
        })
    }

    private func cleanup(message: String) {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        subscriptions.removeAll()
        poseMessenger = nil
        eventMessenger = nil
        session = nil
        status = .idle
        statusMessage = message
        groupImmersionActive = nil
        mailbox.setSessionActive(false)
    }
}
