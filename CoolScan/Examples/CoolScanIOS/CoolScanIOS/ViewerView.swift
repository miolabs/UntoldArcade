import CoolScan
import Metal
import MetalKit
import simd
import SwiftUI
import UntoldEngine

/// Renders one cooked scan with the shared engine renderer, drives the orbit
/// camera from touch input, and hosts the style picker.
struct ViewerView: View {
    let scan: ScanRecord
    @StateObject private var model = ViewerModel()
    @State private var style: CoolScanStyle = {
        // Environment hook used by automated UI checks.
        if let name = ProcessInfo.processInfo.environment["COOLSCAN_STYLE"],
           let style = CoolScanStyle(rawValue: name)
        {
            return style
        }
        return .original
    }()

    var body: some View {
        ZStack(alignment: .bottom) {
            if let renderer = SharedRenderer.renderer {
                SceneView(renderer: renderer) { _ in
                    model.tick()
                }
                .ignoresSafeArea()
            } else {
                ContentUnavailableView(
                    "Renderer unavailable",
                    systemImage: "exclamationmark.triangle"
                )
            }

            StylePickerView(style: $style)
                .padding(.bottom, 12)
        }
        .navigationTitle(scan.metadata.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            model.start(scan: scan)
            model.apply(style: style)
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: style) { _, newStyle in
            model.apply(style: newStyle)
        }
    }
}

/// Owns the engine-side state for the viewer screen: entities, camera
/// framing, touch-driven orbit, and style application.
@MainActor
final class ViewerModel: ObservableObject {
    private var scanEntity: EntityID?
    private var lightEntity: EntityID?
    private var cameraEntity: EntityID?
    private var orbitDistance: Float = 2
    private var minDistance: Float = 0.2
    private var maxDistance: Float = 10
    private var currentScan: ScanRecord?

    func start(scan: ScanRecord) {
        guard let renderer = SharedRenderer.renderer else { return }
        currentScan = scan

        InputSystem.shared.registerTouchEvents(view: renderer.metalView)

        // Mac-cooked bundles carry 2K textures; the default streaming
        // profile would cap them at 1K on load.
        TextureStreamingSystem.shared.apply(
            (scan.metadata.textureMax ?? 0) >= 2048 ? .superdetailed : .balanced
        )

        let entity = createEntity()
        scanEntity = entity
        setEntityMeshAsync(
            entityId: entity,
            filename: scan.untoldURL.path,
            withExtension: "untold"
        ) { success in
            print(
                "CoolScan: viewer load \(success ? "ok" : "FAILED") — "
                    + "\(scan.untoldURL.path), bounds \(scan.boundsMin) … \(scan.boundsMax)"
            )
        }

        let light = createEntity()
        lightEntity = light
        createDirLight(entityId: light)
        rotateTo(entityId: light, pitch: -50, yaw: 30, roll: 0)

        frameCamera(on: scan)
    }

    func stop() {
        InputSystem.shared.unregisterTouchEvents()
        setCoolScanStyle(.original)
        setCoolScanToonAlbedo(nil)
        if let scanEntity {
            destroyEntity(entityId: scanEntity)
        }
        if let lightEntity {
            destroyEntity(entityId: lightEntity)
        }
        scanEntity = nil
        lightEntity = nil
        currentScan = nil
    }

    private func frameCamera(on scan: ScanRecord) {
        let center = (scan.boundsMin + scan.boundsMax) * 0.5
        let radius = max(simd_length(scan.boundsMax - scan.boundsMin) * 0.5, 0.05)

        orbitDistance = radius * 2.6
        minDistance = radius * 0.6
        maxDistance = radius * 12

        let camera = findGameCamera()
        cameraEntity = camera
        let eye = center + SIMD3<Float>(0, radius * 0.7, orbitDistance)
        cameraLookAt(entityId: camera, eye: eye, target: center, up: SIMD3<Float>(0, 1, 0))
        setOrbitOffset(entityId: camera, uTargetOffset: simd_length(eye - center))
    }

    /// Called every frame from the SceneView update handler.
    func tick() {
        guard let cameraEntity else { return }
        let touch = getIOSTouchState()

        if touch.isDragging {
            orbitCameraAround(
                entityId: cameraEntity,
                uDelta: SIMD2<Float>(touch.dragDeltaX, touch.dragDeltaY)
            )
        }

        if touch.isPinching, touch.pinchScaleDelta != 0 {
            let dolly = -touch.pinchScaleDelta * orbitDistance
            let newDistance = simd_clamp(orbitDistance + dolly, minDistance, maxDistance)
            let applied = newDistance - orbitDistance
            if applied != 0 {
                moveCameraAlongAxis(
                    entityId: cameraEntity,
                    uDelta: SIMD3<Float>(0, 0, applied)
                )
                orbitDistance = newDistance
                setOrbitOffset(entityId: cameraEntity, uTargetOffset: orbitDistance)
            }
        }
    }

    func apply(style: CoolScanStyle) {
        setCoolScanStyle(style)
        guard let scanEntity else { return }

        if style == .toon {
            // The render extension binds the entity's own material texture,
            // so attaching the component is all the opt-in needed.
            registerComponent(entityId: scanEntity, componentType: CoolScanToonComponent.self)
        } else {
            removeEntityComponent(
                entityId: scanEntity,
                componentType: CoolScanToonComponent.self
            )
        }
    }
}
