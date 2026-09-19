//
//  CoolBasketVisionOSXRApp.swift  (visionOS)
//  CoolBasket
//
//  Mixed-reality basketball. Pinch near the ball to pick it up, throw it
//  with a flick of the hand; your hands also dribble, swat and catch. The
//  ball bounces off your real floor, walls and furniture, and off the hoop
//  standing in your room — put it down through the rim to score.
//

import CompositorServices
import CoolBasket
import simd
import SwiftUI
import UntoldEngine
import UntoldEngineXR

// Retains the XR system + game so they aren't deallocated, and carries
// control-window actions and live diagnostics between the main actor and the
// game thread.
final class BasketXRHolder: @unchecked Sendable {
    static let shared = BasketXRHolder()
    var xr: UntoldEngineXR?
    var game: BasketXRGame?
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
    private var placeHoopPending = false
    private var moveHoopPending = false
    private var placingStorage = true

    // MARK: Game-thread writers

    func setDiagnostics(score: Int, planes: Int, impulse: Float, placing: Bool) {
        lock.withLock {
            scoreStorage = score
            planeStorage = planes
            impulseStorage = impulse
            placingStorage = placing
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

    func requestResetBall() { lock.withLock { resetBallPending = true } }
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

struct BasketLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

@main
struct CoolBasketVisionOSXRApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Cool Basket 🏀").font(.extraLargeTitle).fontWeight(.bold)
                    Text("First, place your hoop: look where you want it — the ghost follows your gaze —\nand pinch (or press Place hoop here). Then pinch near the ball to pick it up\nand throw. Put it down through the rim to score!")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)

                    Button {
                        Task {
                            let result = await openImmersiveSpace(id: "Court")
                            BasketXRHolder.shared.lastOpenResult = String(describing: result)
                            print("CoolBasket: openImmersiveSpace → \(String(describing: result))")
                        }
                    } label: {
                        Label("Step onto the Court", systemImage: "basketball")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    Divider()

                    HStack(spacing: 16) {
                        Button("Place hoop here") {
                            BasketXRHolder.shared.requestPlaceHoop()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Move hoop") {
                            BasketXRHolder.shared.requestMoveHoop()
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 16) {
                        Button("Reset ball") {
                            BasketXRHolder.shared.requestResetBall()
                        }
                        .buttonStyle(.bordered)

                        Button("Reset score") {
                            BasketXRHolder.shared.requestResetScore()
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()

                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let holder = BasketXRHolder.shared
                        VStack(spacing: 8) {
                            Text(holder.isPlacingHoop ? "Placing the hoop…" : "Baskets: \(holder.score)")
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
                          !BasketXRHolder.shared.spaceOpen else { return }
                    Task {
                        let result = await openImmersiveSpace(id: "Court")
                        BasketXRHolder.shared.lastOpenResult = String(describing: result)
                        print("CoolBasket: auto-open → \(String(describing: result))")
                    }
                }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 480)

        ImmersiveSpace(id: "Court") {
            CompositorLayer(configuration: BasketLayerConfiguration()) { layerRenderer in
                guard BasketXRHolder.shared.xr == nil else {
                    print("CoolBasket: immersive space reopened before teardown finished")
                    return
                }

                let game = BasketXRGame()
                // Physics backend must install before the renderer exists.
                guard game.game.installPhysics() else { return }

                guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
                BasketXRHolder.shared.xr = xr
                BasketXRHolder.shared.spaceOpen = true
                xr.setImmersionMode(xrImmersionMode: .mixed)

                // Scene construction is main-actor (the CompositorLayer closure
                // is); per-frame updates run on the XR render thread.
                game.game.setupScene()
                BasketXRHolder.shared.game = game
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
                        BasketXRHolder.shared.spaceOpen = false
                        shutdownUntoldEngineXR(xr) {
                            BasketXRHolder.shared.xr = nil
                            BasketXRHolder.shared.game = nil
                            BasketXRHolder.shared.renderThread = nil
                            print("CoolBasket: immersive space torn down, ready to reopen")
                        }
                    }
                }
                thread.name = "XR Render Thread"
                thread.qualityOfService = .userInteractive
                BasketXRHolder.shared.renderThread = thread
                thread.start()
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
