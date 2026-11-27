//
//  LabScene.swift
//  ClothLab
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
import SwiftUI
import UntoldEngine

/// The bench: a wall, a floor, one light, and one piece of cloth hung in
/// front of the wall. Each step of the lab adds one thing to the cloth and
/// nothing else, so what changed between two looks is always one thing.
final class LabScene {
    /// The steps built so far.
    enum Step: String, CaseIterable {
        /// 1a: a plain sheet. If this does not look like fabric, the solver
        /// or the material is wrong and nothing else matters yet.
        case sheet
        /// 1b: the shirt's simulation mesh alone, hung by its collar and
        /// shoulders. No body, no skin targets, no back-stop, no colliders.
        case shirt

        var title: String {
            switch self {
            case .sheet: "1a  Sheet"
            case .shirt: "1b  Shirt alone"
            }
        }
    }

    /// How easily the fabric folds: the bending compliance by name.
    enum Fabric: String, CaseIterable {
        case soft, medium, crisp

        var title: String {
            switch self {
            case .soft: "Soft"
            case .medium: "Medium"
            case .crisp: "Crisp"
            }
        }

        var bendCompliance: Float {
            switch self {
            case .soft: 2e-3
            case .medium: 2e-4
            case .crisp: 2e-5
            }
        }
    }

    private(set) var step = Step.sheet
    private(set) var fabric = Fabric.soft
    /// Cuffs and collar stiffer than the rest, as a real shirt's are.
    var interfacing: Bool { parameters.interfacing > 1 }
    private(set) var hasInterfacedPanels = false
    private static let interfacingFactor: Float = 100
    private(set) var sheetPin = SheetPin.hooks
    private(set) var garmentSource = GarmentSource.proxy4k
    private(set) var garmentPin = GarmentPin.shoulders
    /// What the cloth remembers: the artist's drape, flat bending, or the
    /// flat pattern.
    var restShape: ClothSolver.RestShape { parameters.restShape }
    /// The rest shapes this mesh can take (the pattern only if it has one).
    private(set) var availableRestShapes: [ClothSolver.RestShape] = [.draped, .flat]
    var showWireframe = false
    var showPins = false
    var paused = false
    /// The wall behind the cloth; hidden to look at the cloth's back.
    var showWall = true { didSet { placeWall() } }
    /// The light keeps its place relative to the viewer (high, from the
    /// left), so whichever side of the cloth is looked at is the lit one.
    /// Off, it stays where it was.
    var lightFollowsView = true { didSet { applyCamera() } }
    /// Whether the cloth casts a shadow, on the wall and on itself. Off,
    /// what is left on its surface is the shading of its own shape alone.
    var clothCastsShadow = true {
        didSet { if let drawing { setEntityCastsShadow(entityId: drawing.entity, clothCastsShadow) } }
    }
    /// One line under the menus: what is on the bench and how it is doing.
    private(set) var readout = ""

    private var parameters = ClothSolver.Parameters()
    private var solver: ClothSolver?
    private var drawing: ClothDrawing?
    private var topologyNote = ""
    private var camera: EntityID!
    private var sun: EntityID!
    private var wall: EntityID!
    private var clock: Float = 0
    private var readoutClock: Float = 0
    private var simulatedTime: Float = 0
    private var stepMilliseconds: Double = 0

    // The orbit camera: where it looks and from where.
    private var yaw: Float = 0.4
    private var pitch: Float = 0.1
    private var distance: Float = 2.2
    private var target = SIMD3<Float>(0, 1.3, 0)

    // `-control <file>`: commands read from a text file while running, so
    // a scripted look can change the view without relaunching.
    private var controlURL: URL?
    private var controlText = ""
    private var controlClock: Float = 0

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let raw = value("-step"), let named = Step(rawValue: raw) { step = named }
        if let raw = value("-sheetPin"), let named = SheetPin(rawValue: raw) { sheetPin = named }
        if let raw = value("-mesh"), let named = GarmentSource(rawValue: raw), named.isAvailable { garmentSource = named }
        if let raw = value("-shirtPin"), let named = GarmentPin(rawValue: raw) { garmentPin = named }
        if let raw = value("-substeps"), let n = Int(raw), n > 0 { parameters.substeps = n }
        if let raw = value("-stretch"), let c = Float(raw), c >= 0 { parameters.stretchCompliance = c }
        if let raw = value("-bend"), let c = Float(raw), c >= 0 { parameters.bendCompliance = c }
        if let raw = value("-damping"), let c = Float(raw), c >= 0 { parameters.damping = c }
        if let raw = value("-rest"), let named = ClothSolver.RestShape(rawValue: raw) { parameters.restShape = named }
        if let raw = value("-fabric"), let named = Fabric(rawValue: raw) {
            fabric = named
            parameters.bendCompliance = named.bendCompliance
        }
        if arguments.contains("-interfacing") { parameters.interfacing = Self.interfacingFactor }
        showWireframe = arguments.contains("-wire")
        showPins = arguments.contains("-pins")
        if let path = value("-control") { controlURL = URL(fileURLWithPath: path) }

        configureEngine()
        makeCamera()
        makeRoom()
        makeSun()
        rebuild()
        setSceneReady(true)
    }

    // MARK: - Setup

    private func configureEngine() {
        gameMode = true
        setSceneReady(false)
        if let resources = Bundle.module.resourceURL {
            setEngine(.assetBasePath(resources))
        }
        setRendering(.postProcessing(.enabled))
        setRendering(.antiAliasing(.fxaa))
        setEngine(.simulationStepping(.perFrame))
        // A uniform white environment (a 64x32 Radiance file of radiance
        // 1.0), so the ambient term has no tint and the folds are shaped
        // by the one light alone.
        setRendering(.environment(.asset("neutral")))
        setRendering(.environment(.ibl(true)))
        setRendering(.environment(.intensity(0.35)))
        setRendering(.environment(.visible(false)))
    }

    private func makeCamera() {
        camera = createEntity()
        setEntityName(entityId: camera, name: "Main Camera")
        createGameCamera(entityId: camera)
        setCamera(.active(camera))
        applyCamera()
    }

    private func makeRoom() {
        let ground = createEntity()
        setEntityName(entityId: ground, name: "Ground")
        setEntityMeshDirect(entityId: ground, meshes: BasicPrimitives.createPlane(width: 8, depth: 8), assetName: "ground")
        updateMaterialColor(entityId: ground, color: Color(red: 0.42, green: 0.42, blue: 0.40))
        updateMaterialRoughness(entityId: ground, roughness: 0.9)

        wall = createEntity()
        setEntityName(entityId: wall, name: "Wall")
        setEntityMeshDirect(entityId: wall, meshes: BasicPrimitives.createCube(extent: 1), assetName: "wall")
        scaleTo(entityId: wall, scale: SIMD3(4, 3, 0.04))
        updateMaterialColor(entityId: wall, color: Color(red: 0.58, green: 0.60, blue: 0.62))
        updateMaterialRoughness(entityId: wall, roughness: 0.95)
    }

    private func makeSun() {
        sun = createEntity()
        setEntityName(entityId: sun, name: "Sun")
        createDirLight(entityId: sun)
        // High and from the side, so it rakes across the folds; aimed
        // by `applyCamera`.
        setLight(entityId: sun, .color(simd_float3(1.0, 0.96, 0.90)))
        setLight(entityId: sun, .intensity(1.6))
        setLight(entityId: sun, .directional(.active))
        applyCamera()
    }

    // MARK: - What is on the bench

    func setStep(_ value: Step) {
        guard value != step else { return }
        step = value
        rebuild()
        frame()
    }

    func setSheetPin(_ value: SheetPin) {
        guard value != sheetPin else { return }
        sheetPin = value
        if step == .sheet { rebuild() }
    }

    func setGarmentSource(_ value: GarmentSource) {
        guard value != garmentSource, value.isAvailable else { return }
        garmentSource = value
        if step == .shirt { rebuild() }
    }

    func setGarmentPin(_ value: GarmentPin) {
        guard value != garmentPin else { return }
        garmentPin = value
        if step == .shirt { rebuild() }
    }

    func setRestShape(_ value: ClothSolver.RestShape) {
        guard value != parameters.restShape else { return }
        parameters.restShape = value
        rebuild()
    }

    func setFabric(_ value: Fabric) {
        guard value != fabric else { return }
        fabric = value
        parameters.bendCompliance = value.bendCompliance
        rebuild()
    }

    func setInterfacing(_ on: Bool) {
        guard on != interfacing else { return }
        parameters.interfacing = on ? Self.interfacingFactor : 1
        rebuild()
    }

    /// Hangs the cloth again from its rest shape.
    func reset() {
        rebuild()
    }

    private func rebuild() {
        drawing?.destroy()
        drawing = nil
        solver = nil
        simulatedTime = 0

        let mesh: ClothMesh?
        let color: Color
        switch step {
        case .sheet:
            // The shirt proxy's median edge is 17.5 mm; the sheet matches it.
            mesh = .sheet(width: 1.0, height: 1.2, spacing: 0.0175, top: 1.95, pin: sheetPin)
            color = Color(red: 0.74, green: 0.30, blue: 0.24)
        case .shirt:
            mesh = .garment(garmentSource, pin: garmentPin)
            // A mid tone: a white shirt washes its own folds out.
            color = Color(red: 0.45, green: 0.55, blue: 0.66)
        }
        guard let mesh else {
            readout = "could not load \(garmentSource.title)"
            return
        }
        availableRestShapes = mesh.pattern != nil ? [.draped, .flat, .pattern] : [.draped, .flat]
        hasInterfacedPanels = mesh.interfaced != nil
        let topology = ClothTopology(triangles: mesh.triangles)
        let (lo, hi) = mesh.bounds
        wallZ = lo.z - 0.12 - 0.02
        placeWall()
        solver = ClothSolver(mesh: mesh, topology: topology, parameters: parameters)
        drawing = ClothDrawing(mesh: mesh, topology: topology, color: color)
        if let drawing { setEntityCastsShadow(entityId: drawing.entity, clothCastsShadow) }
        topologyNote = "\(mesh.positions.count) particles, \(mesh.triangles.count) triangles, \(mesh.pins.count) pinned"
            + (topology.nonManifoldEdgeCount > 0 ? ", \(topology.nonManifoldEdgeCount) non-manifold edges" : "")
        restTarget = (lo + hi) / 2
        restSize = simd_length(hi - lo)
        if !cameraSetByHand { frame() }
        print("ClothLab: \(step.title): \(mesh.name), \(topologyNote), \(topology.edges.count) edges, \(topology.bendPairs.count) bend pairs")
    }

    private var wallZ: Float = -0.14

    /// The wall stands 12 cm behind the cloth, or far out of sight.
    private func placeWall() {
        guard wall != nil else { return }
        translateTo(entityId: wall, position: SIMD3(0, showWall ? 1.5 : -50, wallZ))
    }

    private var restTarget = SIMD3<Float>(0, 1.3, 0)
    private var restSize: Float = 1.5
    private var cameraSetByHand = false

    /// Points the camera at the cloth as it hangs now, close enough that
    /// it fills most of the view, and lets the camera follow it again
    /// until it is next moved by hand.
    func frame() {
        cameraSetByHand = false
        fitToCloth(blend: 1)
    }

    /// Moves the camera a share of the way towards the view that fits the
    /// cloth's present bounds. Until the camera is moved by hand this runs
    /// every frame, so the view closes in as the cloth settles: a cloth
    /// that is small in the window hides exactly what is being judged.
    private func fitToCloth(blend: Float) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        if let solver {
            for p in solver.positions {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        } else {
            lo = restTarget - SIMD3(repeating: restSize / 2)
            hi = restTarget + SIMD3(repeating: restSize / 2)
        }
        let size = hi - lo
        // The engine's field of view is the vertical one; the window is
        // wider than tall, so the height decides unless the cloth is wide.
        let halfField = tan(fov * .pi / 180 / 2)
        let halfHeight = max(size.y, max(size.x, size.z) / 1.3) / 2
        let wanted = max(0.3, halfHeight / halfField / 1.1 + max(size.x, size.z) / 2)
        target += ((lo + hi) / 2 - target) * blend
        distance += (wanted - distance) * blend
        applyCamera()
    }

    // MARK: - Per frame

    func update(deltaTime: Float) {
        readControl(deltaTime: deltaTime)
        guard let solver, let drawing else { return }
        if !paused {
            // Fixed 60 Hz steps whatever the display's rate, at most two a
            // frame so a hitch does not turn into a jump.
            clock += min(deltaTime, 1.0 / 20.0)
            let fixed: Float = 1.0 / 60.0
            var steps = 0
            while clock >= fixed, steps < 2 {
                let start = DispatchTime.now().uptimeNanoseconds
                solver.step(deltaTime: fixed)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                stepMilliseconds += (elapsed - stepMilliseconds) * 0.1
                clock -= fixed
                simulatedTime += fixed
                steps += 1
            }
            if clock >= fixed { clock = 0 }
        }
        if !cameraSetByHand { fitToCloth(blend: min(1, deltaTime * 3)) }
        drawing.write(positions: solver.positions)
        drawing.showWireframe(showWireframe, positions: solver.positions)
        drawing.showPins(showPins, pinned: solver.pinnedParticles, positions: solver.positions)

        readoutClock += deltaTime
        if readoutClock >= 0.25 {
            readoutClock = 0
            let stretch = solver.stretch()
            readout = String(
                format: "%@   |   %d substeps, %.1f ms a step   |   stretch mean %.1f%% worst %.1f%%   |   speed %.3f m/s   |   t %.1f s",
                topologyNote, parameters.substeps, stepMilliseconds,
                stretch.mean * 100, stretch.worst * 100, solver.meanSpeed(), simulatedTime
            )
        }
    }

    // MARK: - Camera

    func orbit(deltaX: Float, deltaY: Float) {
        yaw -= deltaX * 0.008
        pitch = min(max(pitch + deltaY * 0.008, -1.45), 1.45)
        cameraSetByHand = true
        applyCamera()
    }

    func zoom(delta: Float) {
        distance = min(max(distance * exp(-delta * 0.01), 0.08), 12)
        cameraSetByHand = true
        applyCamera()
    }

    /// Slides the point the camera looks at across the view.
    func pan(deltaX: Float, deltaY: Float) {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let scale = distance * 0.0012
        target += (-right * deltaX + up * deltaY) * scale
        cameraSetByHand = true
        applyCamera()
    }

    private var eye: SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }

    private func applyCamera() {
        guard camera != nil else { return }
        cameraLookAt(entityId: camera, eye: eye, target: target, up: SIMD3(0, 1, 0))
        if lightFollowsView, sun != nil {
            // The sun's azimuth is measured like the camera's yaw; 50 degrees
            // to the viewer's left.
            setSunElevationAzimuth(entityId: sun, elevation: 45, azimuth: yaw * 180 / .pi - 50)
        }
    }

    // MARK: - Scripted control

    /// One command per line: `cam <yaw°> <pitch°> <distance>`,
    /// `target <x> <y> <z>`, `frame`, `wire on|off`, `pins on|off`,
    /// `pause on|off`, `wall on|off`, `shadow on|off`, `light follow|fixed`, `step sheet|shirt`, `mesh 4k|16k|artist|artist4`,
    /// `sheetPin hooks|corners|edge`, `shirtPin shoulders|collar`, `rest draped|flat|pattern`, `fabric soft|medium|crisp`, `interfacing on|off`, `bend <compliance>`, `substeps <n>`, `reset`.
    /// The file is applied whenever its text changes.
    private func readControl(deltaTime: Float) {
        guard let controlURL else { return }
        controlClock += deltaTime
        guard controlClock >= 0.2 else { return }
        controlClock = 0
        guard let text = try? String(contentsOf: controlURL, encoding: .utf8), text != controlText else { return }
        controlText = text
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            guard let command = words.first else { continue }
            let numbers = words.dropFirst().compactMap(Float.init)
            switch command {
            case "cam" where numbers.count == 3:
                yaw = numbers[0] * .pi / 180
                pitch = numbers[1] * .pi / 180
                distance = numbers[2]
                cameraSetByHand = true
                applyCamera()
            case "target" where numbers.count == 3:
                target = SIMD3(numbers[0], numbers[1], numbers[2])
                cameraSetByHand = true
                applyCamera()
            case "frame": frame()
            case "wire": showWireframe = words.last == "on"
            case "pins": showPins = words.last == "on"
            case "pause": paused = words.last == "on"
            case "wall": showWall = words.last == "on"
            case "shadow": clothCastsShadow = words.last == "on"
            case "light": lightFollowsView = words.last == "follow"
            case "step": if let named = Step(rawValue: words.last ?? "") { setStep(named) }
            case "mesh": if let named = GarmentSource(rawValue: words.last ?? "") { setGarmentSource(named) }
            case "sheetPin": if let named = SheetPin(rawValue: words.last ?? "") { setSheetPin(named) }
            case "shirtPin": if let named = GarmentPin(rawValue: words.last ?? "") { setGarmentPin(named) }
            case "rest": if let named = ClothSolver.RestShape(rawValue: words.last ?? "") { setRestShape(named) }
            case "bend" where numbers.count == 1:
                if parameters.bendCompliance != numbers[0] {
                    parameters.bendCompliance = numbers[0]
                    rebuild()
                }
            case "substeps" where numbers.count == 1:
                if parameters.substeps != max(1, Int(numbers[0])) {
                    parameters.substeps = max(1, Int(numbers[0]))
                    rebuild()
                }
            case "fabric": if let named = Fabric(rawValue: words.last ?? "") { setFabric(named) }
            case "interfacing": setInterfacing(words.last == "on")
            case "reset": reset()
            default: print("ClothLab: unknown control line: \(line)")
            }
        }
    }
}
