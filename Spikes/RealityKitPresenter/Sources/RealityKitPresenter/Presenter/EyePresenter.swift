//
//  EyePresenter.swift
//  RealityKitPresenter spike
//
//  The main-thread side of the presenter: owns the grids, the texture route, the two
//  grid entities and their materials, the origin markers, the mailbox and the render
//  thread. Once per RealityKit frame (SceneEvents.Update) it makes a command buffer,
//  calls the replace APIs and posts a ticket.
//

import Foundation
import Metal
import QuartzCore
import RealityKit

@MainActor
final class EyePresenter {
    let root = Entity()
    private let model: SpikeModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let grids: [EyeGrid]
    private var route: EyeTextureRoute
    /// Routes replaced at runtime, kept a little while for command buffers still in flight.
    private var retiredRoutes: [(route: EyeTextureRoute, retiredAt: TimeInterval)] = []
    private let gridEntities: [ModelEntity]
    private var usesShaderGraph: Bool
    private let anchorCube: ModelEntity
    private let noseMarker: ModelEntity
    private let originDisc: ModelEntity
    private let mailbox = TicketMailbox()
    private let head = HeadTracker()
    private let renderer: PresenterRenderer
    private var thread: Thread?
    private var serial: UInt64 = 0
    private var lastStatsTime = CACurrentMediaTime()
    private var lastNumbersLogTime = CACurrentMediaTime()
    private var lastTrackingLog = ""

    init(model: SpikeModel) async throws {
        self.model = model
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw EyeTextureError.noDevice
        }
        self.device = device
        self.queue = queue
        queue.label = "presenter spike"

        grids = [try EyeGrid(), try EyeGrid()]
        route = try Self.makeRoute(model.route, device: device, model: model)

        var materials: [any Material] = []
        var usesShaderGraph = true
        do {
            let graph = try await EyeMaterialLoader.load()
            for eye in 0 ..< 2 {
                var material = graph
                try EyeMaterialLoader.configure(&material, eye: eye + 1, texture: route.resources[eye])
                materials.append(material)
            }
            model.stats.materialInUse = "ShaderGraphMaterial (EyeMaterial.usda)"
            model.stats.log("Eye material loaded; parameters: \(graph.parameterNames.sorted().joined(separator: ", "))")
        } catch {
            usesShaderGraph = false
            model.stats.materialInUse = "UnlitMaterial fallback (no eye switch)"
            model.stats.log("Eye material failed to load, using the fallback: \(error)")
            materials = route.resources.map { EyeMaterialLoader.fallback(texture: $0) }
        }
        self.usesShaderGraph = usesShaderGraph

        var entities: [ModelEntity] = []
        for eye in 0 ..< 2 {
            let entity = ModelEntity(mesh: try await MeshResource(from: grids[eye].mesh), materials: [materials[eye]])
            entity.name = eye == 0 ? "left grid" : "right grid"
            root.addChild(entity)
            entities.append(entity)
        }
        gridEntities = entities

        // Origin markers (question 3): a cube on the device anchor, a marker 60 cm ahead of
        // it and a disc on the RealityKit origin. The disc must sit on the yellow dot the
        // test pattern draws on the ARKit origin.
        anchorCube = ModelEntity(mesh: .generateBox(size: 0.08), materials: [SimpleMaterial(color: .orange, isMetallic: false)])
        anchorCube.name = "device anchor cube"
        noseMarker = ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [SimpleMaterial(color: .cyan, isMetallic: false)])
        noseMarker.name = "nose marker"
        originDisc = ModelEntity(mesh: .generatePlane(width: 0.3, depth: 0.3, cornerRadius: 0.15), materials: [SimpleMaterial(color: .yellow, isMetallic: false)])
        originDisc.name = "scene origin disc"
        originDisc.position = [0, 0.002, 0]
        for marker in [anchorCube, noseMarker, originDisc] {
            marker.isEnabled = false
            root.addChild(marker)
        }

        renderer = try PresenterRenderer(
            device: device, queue: queue, mailbox: mailbox, head: head, counters: model.counters,
            gridColumns: EyeGrid.columns, gridRows: EyeGrid.rows,
            textureWidth: model.textureWidth, textureHeight: model.textureHeight
        )
        model.stats.routeInUse = route.route.label
        model.stats.log("Presenter ready: grids \(EyeGrid.columns) x \(EyeGrid.rows), textures \(model.textureWidth) x \(model.textureHeight), route \(route.route.label)")
    }

    func start() {
        let stats = model.stats
        if head.isSupported {
            head.start { message in
                Task { @MainActor in stats.log(message) }
            }
        } else {
            stats.log("WorldTrackingProvider is not supported here; poses stay at the origin")
        }
        let renderer = self.renderer
        let thread = Thread {
            renderer.run()
        }
        thread.name = "Presenter Render Thread"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        mailbox.close()
        head.stop()
        model.stats.log("Presenter stopped after \(serial) tickets")
    }

    /// Called from SceneEvents.Update on the main thread, once per RealityKit frame.
    func onUpdate(deltaTime: TimeInterval) {
        let now = CACurrentMediaTime()
        updateMarkers(now: now)
        if model.route != route.route || model.textureWidth != route.width {
            switchRoute(to: model.route)
        }
        retiredRoutes.removeAll { now - $0.retiredAt > 2 }

        guard !mailbox.hasPending else {
            model.counters.noteUpdate(textureReplace: nil, meshReplace: nil)
            model.counters.noteDropped()
            publishStats(now: now)
            return
        }
        guard let commandBuffer = queue.makeCommandBuffer() else { return }

        let replaceStart = CACurrentMediaTime()
        let textures = route.beginFrame(commandBuffer: commandBuffer)
        let texturesDone = CACurrentMediaTime()
        let buffers = model.updateGrids ? grids.map { $0.mesh.replace(bufferIndex: 0, using: commandBuffer) } : []
        let posted = CACurrentMediaTime()
        model.counters.noteUpdate(textureReplace: texturesDone - replaceStart, meshReplace: posted - texturesDone)

        serial += 1
        let lead = model.leadSeconds
        let ticket = FrameTicket(
            serial: serial,
            commandBuffer: commandBuffer,
            eyeTextures: textures,
            gridBuffers: buffers,
            postedAt: posted,
            targetTime: posted + lead,
            leadSeconds: lead,
            settings: model.snapshot()
        )
        if !mailbox.post(ticket) {
            // Closed or raced: never leave a replaced texture waiting on an uncommitted buffer.
            commandBuffer.commit()
        }
        publishStats(now: now)
    }

    private func publishStats(now: TimeInterval) {
        guard now - lastStatsTime >= 0.5 else { return }
        lastStatsTime = now
        model.stats.latest = model.counters.snapshot(leadSeconds: model.leadSeconds)
        if now - lastNumbersLogTime >= 5 {
            lastNumbersLogTime = now
            model.stats.logNumbers(model.stats.latest, route: route.route.label)
        }
        let tracking = head.stateDescription
        if tracking != lastTrackingLog {
            lastTrackingLog = tracking
            model.stats.trackingState = tracking
        }
    }

    private func updateMarkers(now: TimeInterval) {
        let show = model.showAnchorMarkers
        anchorCube.isEnabled = show
        noseMarker.isEnabled = show
        originDisc.isEnabled = show
        guard show, let pose = head.originFromDevice(at: now).pose else { return }
        anchorCube.transform = Transform(matrix: pose)
        noseMarker.transform = Transform(matrix: pose * PresenterRenderer.translation(SIMD3<Float>(0, 0, -0.6)))
    }

    private func switchRoute(to newRoute: TextureRoute) {
        do {
            let replacement = try Self.makeRoute(newRoute, device: device, model: model)
            for eye in 0 ..< 2 {
                guard var modelComponent = gridEntities[eye].model else { continue }
                if usesShaderGraph, var material = modelComponent.materials.first as? ShaderGraphMaterial {
                    try EyeMaterialLoader.configure(&material, eye: eye + 1, texture: replacement.resources[eye])
                    modelComponent.materials = [material]
                } else {
                    modelComponent.materials = [EyeMaterialLoader.fallback(texture: replacement.resources[eye])]
                }
                gridEntities[eye].model = modelComponent
            }
            retiredRoutes.append((route, CACurrentMediaTime()))
            route = replacement
            model.stats.routeInUse = replacement.route.label
            model.stats.log("Textures rebuilt: \(replacement.route.label), \(replacement.width) x \(replacement.height)")
        } catch {
            model.stats.log("Could not switch to \(newRoute.label): \(error); staying on \(route.route.label)")
            model.route = route.route
        }
    }

    private static func makeRoute(_ route: TextureRoute, device: MTLDevice, model: SpikeModel) throws -> EyeTextureRoute {
        switch route {
        case .replace:
            return try ReplaceTextureRoute(width: model.textureWidth, height: model.textureHeight)
        case .deviceResource:
            if #available(visionOS 27, *) {
                return try DeviceResourceTextureRoute(device: device, width: model.textureWidth, height: model.textureHeight)
            }
            throw EyeTextureError.deviceResourcesUnavailable
        case .sharedHandle:
            #if targetEnvironment(simulator)
            throw EyeTextureError.sharedTexturesSimulator
            #else
            if #available(visionOS 27, *) {
                return try SharedHandleTextureRoute(device: device, width: model.textureWidth, height: model.textureHeight)
            }
            throw EyeTextureError.deviceResourcesUnavailable
            #endif
        }
    }
}
