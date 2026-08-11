//
//  BallXRGame.swift  (visionOS)
//  CoolBall
//
//  Thin adapter between the XR render loop and the CoolBall package: the
//  package owns the physics backend, the scene, the grab/throw/kick logic and
//  the score; this file forwards frames and publishes diagnostics for the
//  control window.
//

import CoolBall
import Foundation
import simd

final class BallXRGame: @unchecked Sendable {
    let game = CoolBallGame()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        game.start()
        BallXRHolder.shared.resetDiagnostics()
    }

    func shutdown() {
        started = false
        game.shutdown()
    }

    /// Called by the engine once per frame on the XR render thread.
    func update(deltaTime: Float) {
        let holder = BallXRHolder.shared

        if holder.takeResetBallRequest() {
            game.scene.respawnBall(at: game.ballSpawnPosition)
        }
        if holder.takeResetScoreRequest() {
            game.resetScore()
        }

        game.update(deltaTime: deltaTime)

        holder.setDiagnostics(
            score: game.currentScore,
            planes: game.worldPlaneCount,
            impulse: game.lastImpulse
        )
    }

    func handleInput() {}
}
