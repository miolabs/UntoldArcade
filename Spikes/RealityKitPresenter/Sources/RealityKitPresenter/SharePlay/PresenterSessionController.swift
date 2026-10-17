//
//  PresenterSessionController.swift
//  RealityKitPresenter spike
//
//  SharePlay plumbing after Apple's "Implementing SharePlay for immersive spaces in
//  visionOS" and CoolSaber's SaberSessionController: observe sessions, join, configure
//  the system coordinator for a group immersive space with the side-by-side template,
//  and mirror the system's group immersion style so the app opens or closes the space.
//

import Combine
import Foundation
import GroupActivities
import Observation
import SwiftUI // the _GroupActivities_SwiftUI overlay (groupImmersionStyle)

@MainActor
@Observable
final class PresenterSessionController {
    enum Status: Equatable {
        case idle
        case waiting
        case joined(participants: Int)

        var label: String {
            switch self {
            case .idle: return "No session"
            case .waiting: return "Waiting to join"
            case let .joined(participants): return "Joined, \(participants) participant\(participants == 1 ? "" : "s")"
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var statusMessage = "Start SharePlay from a FaceTime call with another Vision Pro."
    /// True while the system reports a group immersion style, false when it reports none,
    /// nil without a session.
    private(set) var groupImmersionActive: Bool?
    private(set) var groupImmersionStyleName = "—"
    private(set) var isSpatial = false
    private(set) var participantCount = 0

    private var session: GroupSession<PresenterActivity>?
    private var tasks: [Task<Void, Never>] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var observing = false

    /// Call once at launch; handles every incoming session for the activity.
    func startSessionObserver() {
        guard !observing else { return }
        observing = true
        Task {
            for await session in PresenterActivity.sessions() {
                configure(session)
            }
        }
    }

    func startSharePlay() {
        statusMessage = "Starting SharePlay…"
        Task {
            let activity = PresenterActivity()
            switch await activity.prepareForActivation() {
            case .activationPreferred:
                do {
                    _ = try await activity.activate()
                } catch {
                    statusMessage = "Could not start SharePlay: \(error.localizedDescription)"
                }
            case .activationDisabled:
                statusMessage = "SharePlay is not available (no FaceTime call?)."
            case .cancelled:
                statusMessage = "SharePlay start cancelled."
            @unknown default:
                statusMessage = "SharePlay start: unknown result."
            }
        }
    }

    func leave() {
        session?.leave()
        cleanup(message: "Left the session.")
    }

    private func configure(_ session: GroupSession<PresenterActivity>) {
        cleanup(message: statusMessage)
        self.session = session
        status = .waiting
        statusMessage = "Session found, joining…"

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
                    self.statusMessage = "Joined. Open the space (or let the system do it) and look for the Persona."
                case .waiting:
                    self.status = .waiting
                case .invalidated:
                    self.cleanup(message: "Session ended.")
                @unknown default:
                    break
                }
            }
            .store(in: &subscriptions)

        session.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self else { return }
                self.participantCount = participants.count
                if case .joined = self.status {
                    self.status = .joined(participants: participants.count)
                }
            }
            .store(in: &subscriptions)

        session.join()
    }

    private func configureSystemCoordinator(for session: GroupSession<PresenterActivity>) async {
        guard let coordinator = await session.systemCoordinator else {
            statusMessage = "No system coordinator for this session."
            return
        }

        var configuration = SystemCoordinator.Configuration()
        configuration.supportsGroupImmersiveSpace = true
        configuration.spatialTemplatePreference = .sideBySide
        coordinator.configuration = configuration

        tasks.append(Task { [weak self] in
            for await state in coordinator.localParticipantStates {
                await MainActor.run { self?.isSpatial = state.isSpatial }
            }
        })
        tasks.append(Task { [weak self] in
            for await style in coordinator.groupImmersionStyle {
                await MainActor.run {
                    self?.groupImmersionActive = style != nil
                    self?.groupImmersionStyleName = style.map { String(describing: type(of: $0)) } ?? "none"
                }
            }
        })
    }

    private func cleanup(message: String) {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        subscriptions.removeAll()
        session = nil
        status = .idle
        statusMessage = message
        groupImmersionActive = nil
        groupImmersionStyleName = "—"
        isSpatial = false
        participantCount = 0
    }
}
