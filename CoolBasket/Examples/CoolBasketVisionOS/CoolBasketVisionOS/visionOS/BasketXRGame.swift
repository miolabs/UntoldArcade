//
//  BasketXRGame.swift  (visionOS)
//  CoolBasket
//
//  Thin adapter between the XR render loop and the CoolBasket package: the
//  package owns the physics backend, the scene, the grab/throw logic and the
//  score; this file forwards frames and publishes diagnostics for the
//  control window.
//

import CoolBasket
import Foundation
import simd

final class BasketXRGame: @unchecked Sendable {
    let game = CoolBasketGame()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        game.start()
        BasketXRHolder.shared.resetDiagnostics()
    }

    func shutdown() {
        started = false
        game.shutdown()
    }

    /// Called by the engine once per frame on the XR render thread.
    func update(deltaTime: Float) {
        let holder = BasketXRHolder.shared

        if holder.takePlaceHoopRequest() {
            game.requestHoopPlacement()
        }
        if holder.takeMoveHoopRequest() {
            game.requestHoopMove()
        }
        if holder.takeDropBallRequest() {
            game.requestDropBall()
        }
        if holder.takeResetScoreRequest() {
            game.resetScore()
        }

        game.update(deltaTime: deltaTime)

        holder.setDiagnostics(
            score: game.currentScore,
            balls: game.ballCount,
            planes: game.worldPlaneCount,
            impulse: game.lastImpulse,
            placing: game.currentPhase == .placingHoop,
            engine: game.activeEngine?.displayName ?? "none",
            hold: game.currentHold
        )
    }

    func handleInput() {}
}
