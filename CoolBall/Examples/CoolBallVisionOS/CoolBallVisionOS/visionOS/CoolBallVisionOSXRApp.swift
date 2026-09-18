//
//  CoolBallVisionOSXRApp.swift  (visionOS)
//  CoolBall
//
//  Mixed-reality basketball. Pinch near the ball to pick it up, throw it
//  with a flick of the hand; your hands also dribble, swat and catch. The
//  ball bounces off your real floor, walls and furniture, and off the hoop
//  standing in your room — put it down through the rim to score.
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
    private var engineStorage = "—"
    private var dropBallPending = false
    private var resetScorePending = false
    private var ballStorage = 0
    private var placeHoopPending = false
    private var moveHoopPending = false
    private var placingStorage = true

    // MARK: Game-thread writers

    func setDiagnostics(score: Int, balls: Int, planes: Int, impulse: Float, placing: Bool, engine: String) {
        lock.withLock {
            scoreStorage = score
            ballStorage = balls
            planeStorage = planes
            impulseStorage = impulse
            placingStorage = placing
            engineStorage = engine
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
    var isPlacingHoop: Bool { lock.withLock { placingStorage } }
    var planeCount: Int { lock.withLock { planeStorage } }
    var lastImpulse: Float { lock.withLock { impulseStorage } }
    var engineName: String { lock.withLock { engineStorage } }
    var ballCount: Int { lock.withLock { ballStorage } }

    func requestDropBall() { lock.withLock { dropBallPending = true } }

    func takeDropBallRequest() -> Bool {
        lock.withLock {
            let pending = dropBallPending
            dropBallPending = false
            return pending
        }
    }
    func requestResetScore() { lock.withLock { resetScorePending = true } }
    func requestPlaceHoop() { lock.withLock { placeHoopPending = true } }
    func requestMoveHoop() { lock.withLock { moveHoopPending = true } }

    func takePlaceHoopRequest() -> Bool {
        lock.withLock {
            let pending = placeHoopPending
            placeHoopPending = false
            return pending
        }
    }

    func takeMoveHoopRequest() -> Bool {
        lock.withLock {
            let pending = moveHoopPending
            moveHoopPending = false
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

/// UserDefaults key for the backend choice. Also settable as a launch
/// argument (`-physicsEngine jolt`) for automated simulator runs.
let physicsEngineDefaultsKey = "physicsEngine"

@main
struct CoolBallVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var immersionStyle: ImmersionStyle = .mixed
    @AppStorage(physicsEngineDefaultsKey) private var physicsEngineRaw = CoolBallPhysicsEngine.coolBall.rawValue

    var body: some SwiftUI.Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Cool Ball 🏀").font(.extraLargeTitle).fontWeight(.bold)
                    Text("First, place your hoop: look where you want it — the ghost follows your gaze —\nand pinch (or press Place hoop here). Then pinch near a ball to pick it up\nand throw. Put it down through the rim to score!")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)

                    Button {
                        Task {
                            let result = await openImmersiveSpace(id: "Court")
                            BallXRHolder.shared.lastOpenResult = String(describing: result)
                            print("CoolBall: openImmersiveSpace → \(String(describing: result))")
                        }
                    } label: {
                        Label("Step onto the Court", systemImage: "basketball")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    Divider()

                    VStack(spacing: 6) {
                        Picker("Physics", selection: $physicsEngineRaw) {
                            ForEach(CoolBallPhysicsEngine.allCases, id: \.rawValue) { engine in
                                Text(engine.displayName).tag(engine.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        Text("Applies when the Court opens; restart the app to switch afterwards.")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }

                    Divider()

                    HStack(spacing: 16) {
                        Button("Place hoop here") {
                            BallXRHolder.shared.requestPlaceHoop()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Move hoop") {
                            BallXRHolder.shared.requestMoveHoop()
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 16) {
                        Button("Drop ball") {
                            BallXRHolder.shared.requestDropBall()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Reset score") {
                            BallXRHolder.shared.requestResetScore()
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Drop as many as you like — every ball can be grabbed, thrown and scored with. Balls show the backends apart: the built-in one has no ball-vs-ball contact, Jolt piles them up.")
                        .font(.footnote).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)

                    Divider()

                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let holder = BallXRHolder.shared
                        VStack(spacing: 8) {
                            Text(holder.isPlacingHoop ? "Placing the hoop…" : "Baskets: \(holder.score) · balls: \(holder.ballCount)")
                                .font(.title2.monospacedDigit()).fontWeight(.semibold)
                            Text(
                                "Space \(holder.spaceOpen ? "OPEN" : "closed")"
                                    + " (last open: \(holder.lastOpenResult))"
                                    + " · physics \(holder.engineName)"
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
                        let result = await openImmersiveSpace(id: "Court")
                        BallXRHolder.shared.lastOpenResult = String(describing: result)
                        print("CoolBall: auto-open → \(String(describing: result))")
                    }
                }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 480)

        ImmersiveSpace(id: "Court") {
            CompositorLayer(configuration: BallLayerConfiguration()) { layerRenderer in
                guard BallXRHolder.shared.xr == nil else {
                    print("CoolBall: immersive space reopened before teardown finished")
                    return
                }

                let game = BallXRGame()
                // Physics backend must install before the renderer exists.
                let chosen = CoolBallPhysicsEngine(
                    rawValue: UserDefaults.standard.string(forKey: physicsEngineDefaultsKey) ?? ""
                ) ?? .coolBall
                guard game.game.installPhysics(engine: chosen) else { return }
                print("CoolBall: physics backend \(game.game.activeEngine?.displayName ?? "none")")

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
