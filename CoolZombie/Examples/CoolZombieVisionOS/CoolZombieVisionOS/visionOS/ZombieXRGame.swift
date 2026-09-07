//
//  ZombieXRGame.swift  (visionOS)
//  CoolZombie
//
//  Thin adapter between the XR render loop and the CoolZombieKit package:
//  the package owns the scene and the chase; this file feeds it the head
//  position, forwards frames, and publishes diagnostics for the control
//  window.
//

import CoolZombieKit
import Foundation
import simd
import UntoldEngine

final class ZombieXRGame: @unchecked Sendable {
    let game: ZombieChaseGame
    private let session = ZombieSpatialSession()
    private var started = false
    private var autoProvoked = false

    init() {
        var configuration = ZombieChaseGame.Configuration()
        // The simulator has no floor calibration — its world origin is at
        // the head — so the floor sits about a person's height below it.
        #if targetEnvironment(simulator)
            configuration.floorY = -1.0
        #else
            configuration.floorY = 0
        #endif
        game = ZombieChaseGame(configuration: configuration)
    }

    func start() {
        guard !started else { return }
        started = true
        session.start()
        gameMode = true
    }

    func shutdown() {
        started = false
        gameMode = false
        session.stop()
    }

    /// Called by the engine once per frame on the XR render thread.
    func update(deltaTime: Float) {
        let holder = ZombieXRHolder.shared

        if holder.takeProvokeRequest() {
            game.provoke()
        }
        if holder.takeResetRequest() {
            game.reset()
        }
        if let mode = holder.takeInspectionRequest() {
            game.setInspection(mode)
        }
        // Test hooks: `-autoProvoke` starts the chase as soon as the zombie
        // is loaded, so a simulator run shows the chase without walking;
        // `-autoRoam walk|jog|run` starts roaming, `-autoMode idle|freeze`
        // the other inspection modes.
        if !autoProvoked, game.isReady {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-autoProvoke") {
                autoProvoked = true
                game.provoke()
            } else if let index = arguments.firstIndex(of: "-autoRoam") {
                autoProvoked = true
                let speed = index + 1 < arguments.count ? ZombieChaseGame.RoamSpeed(named: arguments[index + 1]) : nil
                game.setInspection(.roaming(speed ?? .walk))
            } else if let index = arguments.firstIndex(of: "-autoMode"), index + 1 < arguments.count {
                autoProvoked = true
                switch arguments[index + 1] {
                case "idle": game.setInspection(.idling)
                case "freeze": game.setInspection(.frozen)
                default: break
                }
            }
        }

        let head = session.headPosition()
        game.update(deltaTime: deltaTime, playerPosition: head)

        let phase: String = switch game.phase {
        case .waiting: game.isReady ? "waiting" : "loading"
        case .chasing: "chasing"
        case .holding: "holding"
        case .roaming: "roaming"
        case .idling: "idling"
        case .frozen: "frozen"
        }
        holder.setDiagnostics(phase: phase, distance: game.distanceToPlayer, tracked: head != nil)
    }
}
