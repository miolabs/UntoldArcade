//
//  CoolBallVisionOSXRApp.swift  (visionOS)
//  CoolBall
//
//  Mixed-reality football. Kick the ball with your foot — step into it or
//  swing your leg through it (legs aren't tracked, so an invisible boot at
//  floor level follows your body's motion). Pinch near the ball to pick it
//  up and throw it; your hands also catch and make goalkeeper saves. The
//  ball bounces off your real floor, walls and furniture, and off the goal
//  standing in your room — put it between the posts to score.
//

import CompositorServices
import CoolBall
import simd
import SwiftUI
import UntoldEngine
import UntoldEngineXR

// Retains the XR system + game so they aren't deallocated, and carries
// control-window actions and live diagnostics between the main actor and the
// game thread.
final class BallXRHolder: @unchecked Sendable {
    static let shared = BallXRHolder()
    var xr: UntoldEngineXR?
    var game: BallXRGame?
    var renderThread: Thread?
    /// Main-actor flag: the immersive space is currently open and rendering.
    var spaceOpen = false
    var lastOpenResult = "—"

    private let lock = NSLock()
    private var scoreStorage = 0
    private var planeStorage = 0
    private var impulseStorage: Float = 0
    private var resetBallPending = false
    private var resetScorePending = false

    // MARK: Game-thread writers

    func setDiagnostics(score: Int, planes: Int, impulse: Float) {
        lock.withLock {
            scoreStorage = score
            planeStorage = planes
            impulseStorage = impulse
        }
    }

    func resetDiagnostics() {
        lock.withLock {
            scoreStorage = 0
            planeStorage = 0
            impulseStorage = 0
        }
    }

    // MARK: Control-window API

    var score: Int { lock.withLock { scoreStorage } }
    var planeCount: Int { lock.withLock { planeStorage } }
    var lastImpulse: Float { lock.withLock { impulseStorage } }

    func requestResetBall() { lock.withLock { resetBallPending = true } }
    func requestResetScore() { lock.withLock { resetScorePending = true } }

    func takeResetBallRequest() -> Bool {
        lock.withLock {
            let pending = resetBallPending
            resetBallPending = false
            return pending
        }
    }

    func takeResetScoreRequest() -> Bool {
        lock.withLock {
            let pending = resetScorePending
            resetScorePending = false
            return pending
        }
    }
}

struct BallLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

@main
struct CoolBallVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Cool Ball ⚽️").font(.extraLargeTitle).fontWeight(.bold)
                    Text("Kick the ball with your foot — step into it or swing your leg through it.\nPinch near it to pick it up, move and let go to throw.\nIt bounces off your real floor, walls and furniture.\nPut it between the posts to score!")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)

                    Button {
                        Task {
                            let result = await openImmersiveSpace(id: "Pitch")
                            BallXRHolder.shared.lastOpenResult = String(describing: result)
                            print("CoolBall: openImmersiveSpace → \(String(describing: result))")
                        }
                    } label: {
                        Label("Step onto the Pitch", systemImage: "soccerball")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    Divider()

                    HStack(spacing: 16) {
                        Button("Reset ball") {
                            BallXRHolder.shared.requestResetBall()
                        }
                        .buttonStyle(.bordered)

                        Button("Reset score") {
                            BallXRHolder.shared.requestResetScore()
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()

                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let holder = BallXRHolder.shared
                        VStack(spacing: 8) {
                            Text("Goals: \(holder.score)")
                                .font(.title2.monospacedDigit()).fontWeight(.semibold)
                            Text(
                                "Space \(holder.spaceOpen ? "OPEN" : "closed")"
                                    + " (last open: \(holder.lastOpenResult))"
                                    + " · surfaces \(holder.planeCount)"
                                    + String(format: " · last impact %.2f N·s", holder.lastImpulse)
                            )
                            .font(.footnote.monospaced())
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(48)
                .onAppear {
                    // Test hook: `-autoOpenSpace` opens the immersive space
                    // immediately, so automated simulator runs don't depend
                    // on synthesizing a gaze-and-pinch on the button.
                    guard ProcessInfo.processInfo.arguments.contains("-autoOpenSpace"),
                          !BallXRHolder.shared.spaceOpen else { return }
                    Task {
                        let result = await openImmersiveSpace(id: "Pitch")
                        BallXRHolder.shared.lastOpenResult = String(describing: result)
                        print("CoolBall: auto-open → \(String(describing: result))")
                    }
                }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 480)

        ImmersiveSpace(id: "Pitch") {
            CompositorLayer(configuration: BallLayerConfiguration()) { layerRenderer in
                guard BallXRHolder.shared.xr == nil else {
                    print("CoolBall: immersive space reopened before teardown finished")
                    return
                }

                let game = BallXRGame()
                // Physics backend must install before the renderer exists.
                guard game.game.installPhysics() else { return }

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                BallXRHolder.shared.xr = xr
                BallXRHolder.shared.spaceOpen = true
                xr.setImmersionMode(xrImmersionMode: .mixed)

                // Scene construction is main-actor (the CompositorLayer closure
                // is); per-frame updates run on the XR render thread.
                game.game.setupScene()
                BallXRHolder.shared.game = game
                game.start()
                xr.setupCallbacks(
                    gameUpdate: { dt in game.update(deltaTime: dt) },
                    handleInput: { game.handleInput() }
                )

                let thread = Thread {
                    xr.start()
                    xr.runLoop()
                    // The layer was invalidated: the space closed (crown press,
                    // system dismiss). Tear down so the next open rebuilds
                    // cleanly instead of hitting a dead renderer.
                    game.shutdown()
                    Task { @MainActor in
                        BallXRHolder.shared.spaceOpen = false
                        shutdownUntoldEngineXR(xr) {
                            BallXRHolder.shared.xr = nil
                            BallXRHolder.shared.game = nil
                            BallXRHolder.shared.renderThread = nil
                            print("CoolBall: immersive space torn down, ready to reopen")
                        }
                    }
                }
                thread.name = "XR Render Thread"
                thread.qualityOfService = .userInteractive
                BallXRHolder.shared.renderThread = thread
                thread.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
