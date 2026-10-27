//
//  RealityKitPresenterExampleApp.swift
//  RealityKitPresenterExample
//
//  The engine's XR frame presented by RealityKit: the immersive space holds an
//  `UntoldXRPresenterView` where the other visionOS examples hold a `CompositorLayer`. A
//  control window opens and closes the space, picks the immersion, and shows the presenter's
//  numbers once a second: each frame split into its stages from the ticket's pickup (the CPU
//  frame to the commit, the wait for the GPU to start, the GPU span, which on the headset's
//  shared GPU also holds the compositor's and RealityKit's own work in between and stretches
//  on a warm device) with each stage's maximum, the frames that overran the refresh measured
//  from the update rate (a late frame lands a refresh late and RealityKit shows the previous
//  one twice), the worst frame's split ("worst 16.6 = cpu 3.1 + wait 9.2 + gpu 4.3" says where
//  it spent its time), the engine's own GPU time (the union of its passes' stage spans, timed
//  by the GPU) and the device's thermal state beside it.
//
//  Launch arguments: `--open-space` opens the space at start, `--hide-window` then closes the
//  window (simulator screenshots), `--turning` turns the cubes (still by default, so that
//  screenshots of one build compare with the next), `--swim-probe` shows the swim probe (a
//  cross locked to the room, a dot locked to the head; `SwimProbe`), `--control-cube` stands
//  a plain RealityKit cube beside the engine's cubes (`ControlCube`: the control for the edge
//  measurements on the headset's captures). The presenter's settings, for comparisons from
//  the command line: `--grid 64x60`, `--skirt 0` (texels),
//  `--adaptive-diagonal` or `--fixed-diagonal`, `--no-edge-band`, `--lead 22` (ms, the fixed
//  lead), `--adaptive-lead` or `--fixed-lead`, `--display-latency 16` (ms, the adaptive lead's
//  constant), `--tear 0.5` (metres; `--tear 1000`, past the shell, turns the placement off:
//  every vertex on its own centre texel, no rims), `--no-tears` (the tear mask left zero: no
//  cell across a depth jump is discarded, the placement unchanged; the test of the tear
//  decision as the shimmer's mechanism), `--silhouette-cells alpha` (or `skirt`, the default:
//  each rim vertex on the texture's alpha crossing at the surface's own depth with no cell
//  stretched to the shell, against the shipped skirt past the edge texel; the stage 3 depth
//  item for the limb's segments that breathed with the gaze), the presenter's own rasterization rate map with
//  `--foveation equiangular` (or `none`); the engine's anti-aliasing with
//  `--aa fxaa|smaa|msaa|taa|msaataa`; the pipeline's depth with `--pipeline-depth 2` (the
//  default: the engine's frame starts a refresh earlier, so a frame stretched by up to a
//  refresh still lands on time, at the price of a refresh more lead) or `1`; the render scale
//  with `--render-scale 1.5` (each eye rendered at 1.5 times the drawable size, 2880 × 2736,
//  for more texels per degree than the display's pixels; `1`, the default, is the drawable
//  size); the silhouette with `--blended-core` (the default since 2026-10-27: the grids drawn
//  blended with their depth kept and no band, so there is no alpha test along a silhouette
//  and no band choosing cells on a curved one) or `--cut-and-band` (the chain as first shipped,
//  the alpha-tested core with the band over the cells along silhouettes); the eyes
//  the engine renders from with `--ipd 63` (millimetres between the nominal eyes) and
//  `--view-offset x,y,z` (centimetres, decimals allowed; both eyes moved on the device: x right, y up, z back),
//  the eye test for the kinks and waves along edges; `--measure-eyes` measures the device's
//  TRACKED eyes at start (the `EyeCalibration` space, a bare compositor layer for 60 frames;
//  `EyeCalibration.swift`), keeps them for this device and opens the presenter's space
//  rendering from them, `--measured-eyes` (or `--nominal-eyes`) says whether a kept
//  measurement is used; `--mipmapped` (or `--no-mipmaps`) gives
//  the eye textures a mip chain for the device's gaze-foveated raster to sample at its own
//  rate. All but the grid, the rate map, the pipeline's depth, the render scale, the
//  silhouette, the mip chain and the eyes change from the window
//  while the space is open too (the presenter's `settings`), for comparisons on the headset
//  without a relaunch; those are chosen in the window for the next space opened (the
//  presenter is made with them).
//

import CompositorServices
import os
import RealityKit
import SwiftUI
import UntoldEngine
import UntoldEngineXR
import UntoldEngineXRRealityKit

@main
struct RealityKitPresenterExampleApp: App {
    @State private var model = ExampleModel()

    var body: some SwiftUI.Scene {
        WindowGroup(id: "control") {
            ControlView(model: model)
        }
        .defaultSize(width: 560, height: 560)

        ImmersiveSpace(id: "presenter") {
            UntoldXRPresenterView(
                configuration: model.configurationForNextSpace(),
                immersionMode: model.immersion == .full ? .full : .mixed,
                onReady: { xr, presenter in
                    model.spaceOpened(xr: xr, presenter: presenter)
                },
                onShutdown: {
                    model.spaceClosed()
                }
            )
        }
        .immersionStyle(selection: $model.immersionSelection, in: .mixed, .full)

        // The eye calibration: a bare compositor layer the engine's `XREyeMeasurement` runs on
        // for a moment, drawing nothing (the room shows through), to read the device's tracked
        // eyes; the window opens it, waits for the measurement, closes it and opens the
        // presenter's space with the eyes (`EyeCalibration.swift`).
        ImmersiveSpace(id: "eyeCalibration") {
            CompositorLayer(configuration: EyeCalibrationLayerConfiguration()) { layerRenderer in
                model.startEyeMeasurement(on: layerRenderer)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

enum Immersion: String, CaseIterable, Identifiable {
    case mixed
    case full

    var id: String { rawValue }
    var label: String { self == .mixed ? "Mixed" : "Full" }
    var style: ImmersionStyle { self == .mixed ? .mixed : .full }
}

/// What the window and the space share: the immersion choice, the scene, the presenter's
/// numbers.
@Observable
@MainActor
final class ExampleModel {
    var immersion: Immersion = .mixed {
        didSet { immersionSelection = immersion.style }
    }
    var immersionSelection: ImmersionStyle = .mixed
    var spaceOpen = false
    var statusLine = "The space is closed."
    var materialLine = ""
    /// The presenter's settings as the window shows them, at any time: written through to the
    /// presenter while a space is open, applied to the next one when it opens, and remembered
    /// across launches (a launch argument wins over the remembered value for its setting).
    var settings = ExampleModel.rememberedSettings() {
        didSet {
            presenter?.settings = settings
            Self.remember(settings)
        }
    }
    /// The engine's anti-aliasing as the window shows it, at any time; asked of the scene when
    /// it changes, which applies it on the engine's thread before the next frame; remembered.
    /// The engine sphere's roughness, live: 0.2 as the scene makes it, or rougher, the test of
    /// the specks along its lower edge on the headset as reflections of the room's lights at a
    /// glossy limb. Not remembered: 0.2 at each launch.
    var sphereRoughness: Float = 0.2 {
        didSet { scene.setSphereRoughness(sphereRoughness) }
    }

    /// The room's light estimate on the engine's scene (the XR path's environment lighting),
    /// live; off, the scene is lit by its own sun and sky alone, as on the Mac. The specks along
    /// the sphere's lower edge survived every presenter setting and the roughness: if they go
    /// with the estimate off, they are its reflection at the limb.
    var roomLighting = true {
        didSet { scene.setRoomLighting(roomLighting) }
    }

    /// The sun's strength, live: 3 as the scene makes it, or 0.5 so the sphere's shadowed bottom
    /// is lit by the room as RealityKit's sphere is, which takes away the contrast the rim's
    /// reflection stands out against.
    var sunStrength: Float = 3 {
        didSet { scene.setSunStrength(sunStrength) }
    }

    var antiAliasing = ExampleModel.rememberedAntiAliasing() {
        didSet {
            if spaceOpen, antiAliasing != oldValue { scene.setAntiAliasing(antiAliasing) }
            UserDefaults.standard.set(antiAliasing.rawValue, forKey: "antiAliasing")
        }
    }

    /// The settings to start with: the launch arguments' where given, else the remembered ones,
    /// else the configuration's defaults.
    static func rememberedSettings() -> XRPresenterSettings {
        var settings = XRPresenterSettings(configuration: configurationFromArguments())
        let arguments = CommandLine.arguments
        let defaults = UserDefaults.standard
        if !arguments.contains("--skirt"), let skirt = defaults.object(forKey: "skirtTexels") as? Float { settings.skirtTexels = skirt }
        if !arguments.contains("--tear"), let tear = defaults.object(forKey: "tearThresholdMetres") as? Float { settings.tearThresholdMetres = tear }
        if !arguments.contains("--no-tears"), let tears = defaults.object(forKey: "tears") as? Bool { settings.tears = tears }
        if !arguments.contains("--silhouette-cells"), let cells = defaults.string(forKey: "silhouetteCells").flatMap(XRPresenterSilhouetteCells.init(rawValue:)) { settings.silhouetteCells = cells }
        if !arguments.contains("--lead"), let lead = defaults.object(forKey: "leadSeconds") as? Double { settings.leadSeconds = lead }
        if !arguments.contains("--adaptive-lead"), !arguments.contains("--fixed-lead"), let adaptive = defaults.object(forKey: "adaptiveLead") as? Bool { settings.adaptiveLead = adaptive }
        if !arguments.contains("--display-latency"), let latency = defaults.object(forKey: "displayLatencySeconds") as? Double { settings.displayLatencySeconds = latency }
        if !arguments.contains("--adaptive-diagonal"), !arguments.contains("--fixed-diagonal"), let adaptive = defaults.object(forKey: "adaptiveDiagonal") as? Bool { settings.adaptiveDiagonal = adaptive }
        if !arguments.contains("--no-edge-band"), let band = defaults.object(forKey: "edgeBlending") as? Bool { settings.edgeBlending = band }
        return settings
    }

    static func remember(_ settings: XRPresenterSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.skirtTexels, forKey: "skirtTexels")
        defaults.set(settings.tearThresholdMetres, forKey: "tearThresholdMetres")
        defaults.set(settings.tears, forKey: "tears")
        defaults.set(settings.silhouetteCells.rawValue, forKey: "silhouetteCells")
        defaults.set(settings.leadSeconds, forKey: "leadSeconds")
        defaults.set(settings.adaptiveLead, forKey: "adaptiveLead")
        defaults.set(settings.displayLatencySeconds, forKey: "displayLatencySeconds")
        defaults.set(settings.adaptiveDiagonal, forKey: "adaptiveDiagonal")
        defaults.set(settings.edgeBlending, forKey: "edgeBlending")
    }

    static func rememberedAntiAliasing() -> ExampleAntiAliasing {
        if CommandLine.arguments.contains("--aa") { return ExampleAntiAliasing.fromArguments() }
        return ExampleAntiAliasing(rawValue: UserDefaults.standard.string(forKey: "antiAliasing") ?? "") ?? ExampleAntiAliasing.fromArguments()
    }
    /// The grid each eye is shown on, for the next space opened (the grids are made with the
    /// space); remembered across launches.
    var grid = ExampleGrid.remembered() {
        didSet { grid.remember() }
    }
    /// Whether the far shell stands at 50 m instead of 100 (the 512 grid's hairlines are
    /// RealityKit's interpolation across the stretched triangles, which a nearer shell removes);
    /// for the next space opened.
    var nearShell = UserDefaults.standard.bool(forKey: "nearShell") {
        didSet { UserDefaults.standard.set(nearShell, forKey: "nearShell") }
    }
    /// The distance between the nominal eyes the engine renders from, millimetres, for the
    /// next space opened. RealityKit tells the presenter nothing of the device's real eye
    /// transforms: the engine renders each eye, and the kernel lays the grid along that eye's
    /// rays, from a nominal eye this far to its side of the device anchor, and RealityKit then
    /// shows the grids from the real eyes. A grid cell whose one depth plane is wrong (an
    /// edge-on sliver, a curved limb; the rim rule puts a sliver's texels on the nearest depth)
    /// shows the difference as parallax: the kinks on the cubes' top edges at rest and the
    /// waves under head motion, if the eyes are their cause, must change with this. 63 by
    /// default, as the presenter's configuration; `--ipd 63` at a launch; remembered across
    /// launches otherwise.
    var interpupillaryMillimetres = ExampleModel.interpupillaryFromArgumentsOrRemembered() {
        didSet { UserDefaults.standard.set(interpupillaryMillimetres, forKey: "interpupillaryMillimetres") }
    }

    /// An offset of both nominal eyes on the device, millimetres along each axis of the device
    /// anchor's frame (x to the right, y up, z back: forward is negative z), for the next
    /// space opened; zero in use. The headset settled it (2026-10-27): the kinks and the
    /// shimmer along the engine cubes' edges are the parallax of cells at a wrong depth seen
    /// from the device's TRACKED eyes, which sit off the anchor and move with the gaze, while
    /// the engine renders from nominal eyes at the anchor; 5 cm down lessened them, 5 cm up
    /// made them worse. The numbers to set here are the eyes line of ProceduralGeometry's
    /// stats window (the Compositor path's per-view transforms, which RealityKit never gives
    /// the presenter). `--view-offset x,y,z` (centimetres, decimals allowed) at a launch;
    /// remembered across launches otherwise.
    var viewOffsetMillimetres = ExampleModel.viewOffsetFromArgumentsOrRemembered() {
        didSet {
            let defaults = UserDefaults.standard
            defaults.set(viewOffsetMillimetres.x, forKey: "viewOffsetMillimetresX")
            defaults.set(viewOffsetMillimetres.y, forKey: "viewOffsetMillimetresY")
            defaults.set(viewOffsetMillimetres.z, forKey: "viewOffsetMillimetresZ")
        }
    }

    /// The view offset steppers' step, millimetres: 1 or 10.
    var viewOffsetStep = 10

    /// The device's tracked eyes as measured on it (`EyeCalibration.swift`: the calibration
    /// space's compositor layer, 60 frames of its view transforms averaged), kept across
    /// launches for this device only; nil until measured. In force for the next space opened
    /// while `useMeasuredEyes` is on: the presenter renders each eye from its measured
    /// transform (`configuration.eyeTransforms`) instead of the nominal pair the IPD and view
    /// offset steppers describe, which then show the measured numbers greyed.
    var measuredEyes = MeasuredEyes.remembered()

    /// Whether a kept measurement is used for the next space opened (on by default once there
    /// is one; off, the steppers' nominal pair renders, the manual way). `--measured-eyes` or
    /// `--nominal-eyes` at a launch; remembered across launches otherwise.
    var useMeasuredEyes = ExampleModel.useMeasuredEyesFromArgumentsOrRemembered() {
        didSet { UserDefaults.standard.set(useMeasuredEyes, forKey: "useMeasuredEyes") }
    }

    static func useMeasuredEyesFromArgumentsOrRemembered() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--measured-eyes") || arguments.contains("--measure-eyes") { return true }
        if arguments.contains("--nominal-eyes") { return false }
        return (UserDefaults.standard.object(forKey: "useMeasuredEyes") as? Bool) ?? true
    }

    /// The measurement under way, if one, or the last one's result until it is kept.
    var eyeMeasurement: EyeMeasurementState = .idle
    /// What the last measurement did, under the eye row (`eyeMeasurementNote`, which logs it).
    var eyeMeasurementNoteStorage = ""
    /// The window's flow waiting for the measurement in the calibration space to finish.
    var eyeMeasurementWaiter: CheckedContinuation<XREyeMeasurement.Result?, Never>?

    /// The IPD's range, millimetres: the headset's own fitting range, about.
    static let interpupillaryRange = 50 ... 75
    /// The view offset's range along each axis, millimetres.
    static let viewOffsetRange = -80 ... 80

    static func interpupillaryFromArgumentsOrRemembered() -> Int {
        if let ipd = argument(after: "--ipd").flatMap(Double.init) {
            return clamp(Int(ipd.rounded()), to: interpupillaryRange)
        }
        return (UserDefaults.standard.object(forKey: "interpupillaryMillimetres") as? Int) ?? 63
    }

    static func viewOffsetFromArgumentsOrRemembered() -> SIMD3<Int> {
        if let offset = argument(after: "--view-offset") {
            let parts = offset.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 3 {
                let mm = parts.map { clamp(Int(($0 * 10).rounded()), to: viewOffsetRange) }
                return SIMD3<Int>(mm[0], mm[1], mm[2])
            }
        }
        let defaults = UserDefaults.standard
        // Remembered in millimetres; a value remembered in centimetres by an earlier build is
        // taken over once.
        func remembered(_ axis: String) -> Int {
            if let mm = defaults.object(forKey: "viewOffsetMillimetres" + axis) as? Int { return mm }
            if let cm = defaults.object(forKey: "viewOffsetCentimetres" + axis) as? Int { return clamp(cm * 10, to: viewOffsetRange) }
            return 0
        }
        return SIMD3<Int>(remembered("X"), remembered("Y"), remembered("Z"))
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The value after a launch argument, if the argument is there and has one.
    static func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// A number with its sign, for the eye settings: "+3", "0", "−2".
    static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : value < 0 ? "−\(-value)" : "0"
    }

    /// The view offset as the row and the settings line name it: "none", or the three
    /// millimetres with the axes' sense.
    static func viewOffsetDescription(_ mm: SIMD3<Int>) -> String {
        mm == .zero ? "none" : "(\(signed(mm.x)), \(signed(mm.y)), \(signed(mm.z))) mm (x right, y up, z back)"
    }
    /// Whether the next space opened draws each eye through the presenter's own equi-angular
    /// rasterization rate map: the same 1920 × 1824 physical pixels per eye spread evenly in
    /// angle, so the centre of view is about 1.36 times denser than the uniform frame (the grid
    /// is then the map's, a vertex every 8 texels: 241 × 229). The launch argument
    /// `--foveation equiangular|none` sets where the toggle starts; remembered across launches
    /// otherwise.
    var rateMap = ExampleModel.rateMapFromArgumentsOrRemembered() {
        didSet { UserDefaults.standard.set(rateMap, forKey: "rateMap") }
    }

    /// Whether the swim probe is shown: a cross locked to the room 1.5 m ahead of where the
    /// head was when it came on and a dot locked to the head (`SwimProbe`), for judging the
    /// lead by turning the head; at any time, remembered across launches, `--swim-probe` at
    /// a launch.
    var swimProbe = CommandLine.arguments.contains("--swim-probe") || UserDefaults.standard.bool(forKey: "swimProbe") {
        didSet {
            scene.swimProbe.setEnabled(swimProbe)
            UserDefaults.standard.set(swimProbe, forKey: "swimProbe")
        }
    }

    /// Whether a plain RealityKit cube stands beside the engine's cubes (`ControlCube`): the
    /// control for the edge measurements on the headset's captures, drawn by the device's own
    /// render with no presenter between; at any time, remembered across launches,
    /// `--control-cube` at a launch.
    var controlCube = CommandLine.arguments.contains("--control-cube") || UserDefaults.standard.bool(forKey: "controlCube") {
        didSet {
            controlCubeEntity?.isEnabled = controlCube
            controlSphereEntity?.isEnabled = controlCube
            UserDefaults.standard.set(controlCube, forKey: "controlCube")
        }
    }

    /// The control cube's entity while a space is open: a child of the presenter's root beside
    /// the grid entities, world-locked like them, nothing the presenter manages.
    private var controlCubeEntity: ModelEntity?
    /// The control sphere beside the engine's, under the same toggle (`ControlCube.makeSphereEntity`).
    private var controlSphereEntity: ModelEntity?

    static func rateMapFromArgumentsOrRemembered() -> Bool {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--foveation"), index + 1 < arguments.count {
            return arguments[index + 1].lowercased() == "equiangular"
        }
        return UserDefaults.standard.bool(forKey: "rateMap")
    }

    /// Whether the next space opened runs the pipeline two refreshes deep: the presenter is made
    /// with a second set of textures and grids and alternates them, a frame posted at a
    /// RealityKit update shows at the render two updates on instead of the next, so a frame
    /// whose GPU span is stretched by up to a refresh (the shared GPU during quick head turns)
    /// still lands on time, and the engine poses each frame a refresh further ahead. The
    /// launch argument `--pipeline-depth 2|1` sets where the toggle starts; remembered across
    /// launches otherwise. On by default, as the presenter's configuration: on the headset it
    /// took the late count during quick turns to none and the swim probe's dot held still.
    var twoRefreshPipeline = ExampleModel.twoRefreshPipelineFromArgumentsOrRemembered() {
        didSet { UserDefaults.standard.set(twoRefreshPipeline, forKey: "twoRefreshPipeline") }
    }

    static func twoRefreshPipelineFromArgumentsOrRemembered() -> Bool {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--pipeline-depth"), index + 1 < arguments.count {
            return (Int(arguments[index + 1]) ?? 1) >= 2
        }
        return (UserDefaults.standard.object(forKey: "twoRefreshPipeline") as? Bool) ?? true
    }

    /// The render scale of the next space opened: how many times the drawable size each eye is
    /// rendered at (the presenter's textures are made at it). 1 is the drawable size, 1920 ×
    /// 1824, which gives 12.9 texels per degree at the centre of view (17.6 through the rate
    /// map) against the display's some 34 pixels, so RealityKit's sampler shows each texel 2.6
    /// display pixels wide and magnifies the engine's one-texel edge steps with it; 1.5 renders
    /// 2880 × 2736 (19.4 texels per degree, 26.4 through the map) for 2.25 times the engine's
    /// pixels, which the two-refresh pipeline has the budget for. The window's toggle switches
    /// between 1 and 1.5; the launch argument `--render-scale 1.5` sets where it starts;
    /// remembered across launches otherwise.
    var renderScale = ExampleModel.renderScaleFromArgumentsOrRemembered() {
        didSet { UserDefaults.standard.set(renderScale, forKey: "renderScale") }
    }

    /// The render scale toggle: on above 1 (1.5 when turned on).
    var renderScaleRaised: Bool {
        get { renderScale > 1 }
        set { renderScale = newValue ? 1.5 : 1 }
    }

    static func renderScaleFromArgumentsOrRemembered() -> Float {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-scale"), index + 1 < arguments.count, let scale = Float(arguments[index + 1]) {
            return scale
        }
        return (UserDefaults.standard.object(forKey: "renderScale") as? Float) ?? 1
    }

    /// Whether the next space opened gives the eye textures a mip chain, generated after each
    /// frame, with the graphs filtering between levels: the test of 2026-10-27, after the
    /// shimmer along the edges was found to follow the gaze. The device rasterizes RealityKit
    /// content at a rate that follows the gaze, coarse away from it, and with the base level
    /// alone it samples our texels above that rate, so the silhouettes alias; the chain lets the
    /// sampler filter the texture down to the rate. `--mipmapped` sets where it starts;
    /// remembered across launches otherwise.
    var mipmapped = ExampleModel.mipmappedFromArgumentsOrRemembered() {
        didSet { UserDefaults.standard.set(mipmapped, forKey: "mipmapped") }
    }

    static func mipmappedFromArgumentsOrRemembered() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--mipmapped") { return true }
        if arguments.contains("--no-mipmaps") { return false }
        return UserDefaults.standard.bool(forKey: "mipmapped")
    }

    /// Whether the next space opened draws the grids as a blended core: each eye's grid
    /// through the band's blended graph itself, its depth write kept (the grid still occludes
    /// RealityKit's content and the Personas the system composites by depth), and no band
    /// meshes, so that no alpha test lies anywhere along a silhouette. The experiment the
    /// control cube called for: on the headset the engine's cubes shimmer beside a plain
    /// RealityKit cube that does not, through the same device render, and the shipped core's
    /// hard cut, rasterized by the device without anti-aliasing, is the suspect; on the Mac
    /// the two chains give the same picture. Off by default (the shipped cut and band); the
    /// launch argument `--blended-core` (or `--cut-and-band`) sets where the toggle starts;
    /// remembered across launches otherwise.
    var blendedCore = ExampleModel.blendedCoreFromArgumentsOrRemembered() {
        didSet { UserDefaults.standard.set(blendedCore, forKey: "blendedCore") }
    }

    static func blendedCoreFromArgumentsOrRemembered() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--blended-core") { return true }
        if arguments.contains("--cut-and-band") { return false }
        return (UserDefaults.standard.object(forKey: "blendedCore") as? Bool) ?? true
    }

    /// The configuration of the next space opened: the launch arguments', then the window's
    /// choices for what the presenter fixes when it is made.
    func configurationForNextSpace() -> XRRealityKitPresenterConfiguration {
        var configuration = Self.configurationFromArguments()
        if !CommandLine.arguments.contains("--grid") {
            configuration.gridColumns = grid.columns
            configuration.gridRows = grid.rows
        }
        if nearShell { configuration.farShellMetres = 50 }
        configuration.interpupillaryDistance = Float(interpupillaryMillimetres) / 1000
        configuration.viewOffsetMetres = SIMD3<Float>(Float(viewOffsetMillimetres.x), Float(viewOffsetMillimetres.y), Float(viewOffsetMillimetres.z)) / 1000
        // The measured eyes override the nominal pair when in force (the configuration then
        // reports their distance and midpoint as the IPD and the view offset).
        if useMeasuredEyes, let measured = measuredEyes {
            configuration.eyeTransforms = measured.eyeTransforms
        }
        configuration.foveation = rateMap ? .equiAngular : .none
        configuration.pipelineDepth = twoRefreshPipeline ? 2 : 1
        configuration.renderScale = renderScale
        configuration.silhouette = blendedCore ? .blendedCore : .cutAndBand
        configuration.mipmapped = mipmapped
        return configuration
    }
    let scene = ExampleScene()
    private(set) var presenter: XRRealityKitPresenter?
    /// The numbers go to the unified log too (subsystem `com.untoldengine.realitykitpresenterexample`,
    /// category `numbers`), so a simulator or headset run can be read back afterwards.
    let log = os.Logger(subsystem: "com.untoldengine.realitykitpresenterexample", category: "numbers")
    private var refreshTask: Task<Void, Never>?

    /// The presenter's configuration with the launch arguments' overrides applied.
    static func configurationFromArguments() -> XRRealityKitPresenterConfiguration {
        var configuration = XRRealityKitPresenterConfiguration()
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let grid = value(after: "--grid") {
            let parts = grid.lowercased().split(separator: "x").compactMap { Int($0) }
            if parts.count == 2, parts[0] >= 2, parts[1] >= 2 {
                configuration.gridColumns = parts[0]
                configuration.gridRows = parts[1]
            }
        }
        if let skirt = value(after: "--skirt").flatMap(Float.init) { configuration.skirtTexels = skirt }
        if let lead = value(after: "--lead").flatMap(Double.init) { configuration.leadSeconds = lead / 1000 }
        if arguments.contains("--fixed-lead") { configuration.adaptiveLead = false }
        if arguments.contains("--adaptive-lead") { configuration.adaptiveLead = true }
        if let latency = value(after: "--display-latency").flatMap(Double.init) { configuration.displayLatencySeconds = latency / 1000 }
        if let tear = value(after: "--tear").flatMap(Float.init) { configuration.tearThresholdMetres = tear }
        if arguments.contains("--no-tears") { configuration.tears = false }
        if let cells = value(after: "--silhouette-cells") { configuration.silhouetteCells = Self.silhouetteCells(named: cells) ?? configuration.silhouetteCells }
        if arguments.contains("--fixed-diagonal") { configuration.adaptiveDiagonal = false }
        if arguments.contains("--adaptive-diagonal") { configuration.adaptiveDiagonal = true }
        if arguments.contains("--no-edge-band") { configuration.edgeBlending = false }
        if let scale = value(after: "--render-scale").flatMap(Float.init) { configuration.renderScale = scale }
        if arguments.contains("--blended-core") { configuration.silhouette = .blendedCore }
        if arguments.contains("--mipmapped") { configuration.mipmapped = true }
        if arguments.contains("--cut-and-band") { configuration.silhouette = .cutAndBand }
        if arguments.contains("--ipd") { configuration.interpupillaryDistance = Float(interpupillaryFromArgumentsOrRemembered()) / 1000 }
        if arguments.contains("--view-offset") {
            let mm = viewOffsetFromArgumentsOrRemembered()
            configuration.viewOffsetMetres = SIMD3<Float>(Float(mm.x), Float(mm.y), Float(mm.z)) / 1000
        }
        return configuration
    }

    /// `--silhouette-cells alpha|skirt`: the crossing by its name or the case's, the skirt by its.
    static func silhouetteCells(named name: String) -> XRPresenterSilhouetteCells? {
        switch name.lowercased() {
        case "alpha", "crossing", "alpha-crossing", "alphacrossing": return .alphaCrossing
        case "skirt": return .skirt
        default: return nil
        }
    }

    func spaceOpened(xr: UntoldEngineXR, presenter: XRRealityKitPresenter) {
        self.presenter = presenter
        // The window reads the numbers; the presenter's own log line would reset them.
        presenter.reportInterval = 0
        // The window's settings, not the new presenter's defaults: what was chosen stays
        // chosen across a close and an open. The pipeline's depth is the presenter's own: it
        // was made with the sets for it.
        settings.pipelineDepth = presenter.configuration.pipelineDepth
        presenter.settings = settings
        scene.start(xr)
        scene.setAntiAliasing(antiAliasing)
        scene.swimProbe.setEnabled(swimProbe)
        // The control cube beside the grids, in the presenter's root (so in the space's world,
        // like them), shown when the toggle says so.
        let control = ControlCube.makeEntity()
        control.isEnabled = controlCube
        presenter.root.addChild(control)
        controlCubeEntity = control
        // And the control sphere above it, beside the engine's sphere, for the limb.
        let controlSphere = ControlCube.makeSphereEntity()
        controlSphere.isEnabled = controlCube
        presenter.root.addChild(controlSphere)
        controlSphereEntity = controlSphere
        // The engine's passes timed by the GPU, so the numbers line can show the engine's own
        // GPU time beside the ticket's span (which also holds whatever else the shared GPU ran).
        setRendering(.gpuPassTiming(.enabled))
        spaceOpen = true
        describeSettings()
        log.notice("\(self.materialLine, privacy: .public)")
        // Once a second while the space is open, whether or not the window is (a hidden window
        // ends its own tasks).
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refresh()
            }
        }
    }

    func spaceClosed() {
        refreshTask?.cancel()
        refreshTask = nil
        scene.stop()
        controlCubeEntity?.removeFromParent()
        controlCubeEntity = nil
        controlSphereEntity?.removeFromParent()
        controlSphereEntity = nil
        presenter = nil
        spaceOpen = false
        statusLine = "The space is closed."
    }

    /// The material and settings line, from the presenter: what is in force.
    private func describeSettings() {
        guard let presenter else { return }
        let c = presenter.configuration
        let s = presenter.settings
        materialLine = (presenter.usesShaderGraphMaterial
            ? "Eye material: the shader graph (each eye sees its own grid). "
            : "Eye material: the FALLBACK (both eyes see both grids). ")
            + (presenter.foveation.map { "Rate map: screen \($0.screenSize.x)×\($0.screenSize.y) over \(presenter.textureSize.x)×\(presenter.textureSize.y) texels, cells of \($0.cellTexels)" } ?? "No rate map: \(presenter.textureSize.x)×\(presenter.textureSize.y) uniform texels")
            + String(format: " (render scale %.2g, %.1f texels/° at the centre of view; %@). ", presenter.renderScale, presenter.centreTexelsPerDegree, presenter.mipmapped ? "MIP CHAIN, filtered to the device's rate" : "base level only")
            + "Grid \(presenter.grid.columns)×\(presenter.grid.rows), shell \(Int(c.farShellMetres)) m, \(Self.eyesDescription(c)), \(s.silhouetteCells == .alphaCrossing ? "silhouette cells on the ALPHA CROSSING (skirt \(s.skirtTexels) texels where no crossing)" : "silhouette cells skirt \(s.skirtTexels) texels"), \(s.adaptiveDiagonal ? "adaptive" : "fixed") diagonal, silhouette \(silhouetteDescription(presenter)), "
            + (s.adaptiveLead
                ? "adaptive lead (display latency \(Int((s.displayLatencySeconds * 1000).rounded())) ms; fixed \(Int((s.leadSeconds * 1000).rounded())) ms until a frame completes), "
                : "fixed lead \(Int((s.leadSeconds * 1000).rounded())) ms, ")
            + (s.tears ? "tear \(s.tearThresholdMetres) m, " : "NO TEARS (threshold \(s.tearThresholdMetres) m places the vertices only), ") + "pipeline \(presenter.pipelineDepth == 2 ? "two refreshes deep" : "one refresh deep"), \(scene.antiAliasing.label)\(scene.swimProbe.isEnabled ? ", swim probe on" : "")\(controlCubeEntity?.isEnabled == true ? ", control cube and sphere on" : "")."
    }

    /// The silhouette in force, for the settings line: the shipped cut with its band's state,
    /// or the blended core; and when the blended core was asked for but its graph did not
    /// load, that the shipped one stands in.
    private func silhouetteDescription(_ presenter: XRRealityKitPresenter) -> String {
        switch presenter.silhouette {
        case .cutAndBand:
            let band = "edge band \(presenter.drawsEdgeBand ? "on" : presenter.hasEdgeBand ? "off" : "unavailable")"
            let fallback = presenter.configuration.silhouette == .blendedCore ? "; the blended core's graph did not load" : ""
            return "cut and band (\(band)\(fallback))"
        case .blendedCore:
            return "blended core (depth written, no band)"
        }
    }

    /// Once a second from the window.
    func refresh() {
        guard let presenter else { return }
        describeSettings()
        let numbers = presenter.statistics.snapshot()
        // Each frame's stages (pickup to commit, commit to GPU start, the GPU span) with their
        // maxima, the frames that overran the refreshes planned for them (one, or two with the
        // pipeline two refreshes deep, which the late count then says), and the worst frame's
        // split; the replace call's maximum is left out (the main thread's microseconds), the
        // lead's kept for calibrating the adaptive lead.
        statusLine = String(
            format: "%.0f updates/s (refresh %.1f ms) · %.0f frames/s · %d dropped (%d in all) · %d late%@ · replace %.2f ms · pickup age %.1f ms · cpu %.1f ms (max %.1f) · wait %.1f ms (max %.1f) · gpu %.1f ms (max %.1f) · completion %.1f ms (max %.1f) · worst %@ · engine GPU %.1f ms · lead %.1f ms (max %.1f) · thermal %@ · %d taps",
            numbers.updatesPerSecond, numbers.refreshMs, numbers.framesPerSecond, numbers.ticketsDropped, numbers.ticketsDroppedTotal,
            numbers.lateFrames, numbers.plannedRefreshesDescription, numbers.replaceMsAverage, numbers.pickupAgeMsAverage,
            numbers.frameMsAverage, numbers.frameMsMax, numbers.waitMsAverage, numbers.waitMsMax,
            numbers.gpuMsAverage, numbers.gpuMsMax, numbers.completionMsAverage, numbers.completionMsMax,
            numbers.worstFrame.splitDescription, numbers.engineGPUMsAverage,
            numbers.leadMsAverage, numbers.leadMsMax, numbers.thermalStateName, scene.tapCount
        )
        log.notice("\(self.statusLine, privacy: .public)")
    }
}

struct ControlView: View {
    @Bindable var model: ExampleModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("RealityKit Presenter")
                .font(.extraLargeTitle)
                .fontWeight(.bold)
            Text("The Untold Engine renders every frame; RealityKit shows it on two depth-displaced grids, one per eye, so the system owns the space.")
                .foregroundStyle(.secondary)

            Picker("Immersion", selection: $model.immersion) {
                ForEach(Immersion.allCases) { immersion in
                    Text(immersion.label).tag(immersion)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.spaceOpen)

            HStack {
                Button {
                    Task { await openImmersiveSpace(id: "presenter") }
                } label: {
                    Label("Open the space", systemImage: "visionpro.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.spaceOpen)

                Button {
                    Task { await dismissImmersiveSpace() }
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .disabled(!model.spaceOpen)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Settings (at any time; they stay across a close and an open)")
                    .font(.headline)
                HStack(spacing: 24) {
                    Toggle("Edge band", isOn: $model.settings.edgeBlending)
                        .disabled(!(model.presenter?.hasEdgeBand ?? true))
                    Toggle("Adaptive diagonal", isOn: $model.settings.adaptiveDiagonal)
                }
                HStack(spacing: 24) {
                    Stepper("Skirt \(Int(model.settings.skirtTexels)) texels", value: $model.settings.skirtTexels, in: 0 ... 8, step: 1)
                    Stepper(model.settings.tearThresholdMetres > 3 ? "Tear past the shell" : String(format: "Tear %.1f m", model.settings.tearThresholdMetres), value: $model.settings.tearThresholdMetres, in: 0.1 ... 3, step: 0.1)
                    Stepper("Lead \(Int((model.settings.leadSeconds * 1000).rounded())) ms", value: $model.settings.leadSeconds, in: 0 ... 0.06, step: 0.0055)
                }
                Toggle("Tears (the cells stretched across a depth jump discarded; off, the grid stays one surface and only the alpha test cuts the silhouette)", isOn: $model.settings.tears)
                // The silhouette cells, live: the shipped skirt (a rim vertex on its edge texel
                // pushed outward, the cells from there to the shell stretched across the jump),
                // or each rim vertex on the texture's alpha crossing at the surface's own depth
                // with no triangle from there to the shell, so the mesh boundary is the
                // silhouette itself and the device's multisampling resolves it as it resolves
                // the control sphere's.
                Toggle("Silhouette cells on the alpha crossing (live: each rim vertex on the texture's edge at the surface's own depth, no cell stretched to the shell; off is the shipped skirt past the edge texel)", isOn: Binding(
                    get: { model.settings.silhouetteCells == .alphaCrossing },
                    set: { model.settings.silhouetteCells = $0 ? .alphaCrossing : .skirt }
                ))
                // The threshold's other job is the placement: a vertex lands on the texel nearest its
                // centre among those within the threshold of its footprint's nearest depth, and is a
                // rim (pushed by the skirt) when its own centre texel fails that limit. Past the shell
                // every texel passes: each vertex on its own centre texel, no rims, no skirt; with the
                // tears off too, a regular grid with no per-frame decision, the silhouette left to the
                // alpha test on the stretched cells (`--tear 1000` from the command line).
                Toggle("Placement off (threshold past the shell: every vertex on its own texel, no rims; with Tears off, no per-frame decision at all)", isOn: Binding(
                    get: { model.settings.tearThresholdMetres > 3 },
                    set: { model.settings.tearThresholdMetres = $0 ? 1000 : 0.5 }
                ))
                HStack(spacing: 24) {
                    Toggle("Adaptive lead", isOn: $model.settings.adaptiveLead)
                    Stepper("Display latency \(Int((model.settings.displayLatencySeconds * 1000).rounded())) ms", value: $model.settings.displayLatencySeconds, in: 0 ... 0.06, step: 0.001)
                        .disabled(!model.settings.adaptiveLead)
                }
                HStack(spacing: 24) {
                    Toggle("Swim probe", isOn: $model.swimProbe)
                    Toggle("Control cube and sphere (a plain RealityKit cube beside the engine's cubes and a sphere beside the engine's sphere, for the captures and the limb)", isOn: $model.controlCube)
                }
                HStack(spacing: 24) {
                    Toggle("Room light estimate (live; off, the engine's scene is lit by its sun and sky alone)", isOn: $model.roomLighting)
                    Picker("Sun", selection: $model.sunStrength) {
                        Text("Sun 3").tag(Float(3))
                        Text("Sun 0.5").tag(Float(0.5))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
                HStack(spacing: 12) {
                    Text("Sphere roughness (live; the specks along its lower edge soften if they are the room's lights reflected at the glossy limb)")
                    Picker("Sphere roughness", selection: $model.sphereRoughness) {
                        Text("0.2").tag(Float(0.2))
                        Text("0.6").tag(Float(0.6))
                        Text("0.9").tag(Float(0.9))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Picker("Anti-aliasing", selection: $model.antiAliasing) {
                    ForEach(ExampleAntiAliasing.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("For the next space opened (close and open the space)")
                    .font(.headline)
                HStack(spacing: 24) {
                    Picker("Grid", selection: $model.grid) {
                        ForEach(ExampleGrid.allCases) { grid in
                            Text(grid.label).tag(grid)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Shell 50 m", isOn: $model.nearShell)
                    // The steppers are the manual way; with a measurement in force they show
                    // its numbers (the distance between the measured eyes, their midpoint)
                    // greyed, and the measured transforms themselves are what renders.
                    Stepper("IPD \(measuredEyesShown?.interpupillaryMillimetres ?? model.interpupillaryMillimetres) mm", value: $model.interpupillaryMillimetres, in: ExampleModel.interpupillaryRange, step: 1)
                        .disabled(measuredEyesShown != nil)
                }
                HStack(spacing: 24) {
                    Stepper("View x \(ExampleModel.signed(measuredEyesShown?.midpointMillimetres.x ?? model.viewOffsetMillimetres.x)) mm", value: $model.viewOffsetMillimetres.x, in: ExampleModel.viewOffsetRange, step: model.viewOffsetStep)
                    Stepper("View y \(ExampleModel.signed(measuredEyesShown?.midpointMillimetres.y ?? model.viewOffsetMillimetres.y)) mm", value: $model.viewOffsetMillimetres.y, in: ExampleModel.viewOffsetRange, step: model.viewOffsetStep)
                    Stepper("View z \(ExampleModel.signed(measuredEyesShown?.midpointMillimetres.z ?? model.viewOffsetMillimetres.z)) mm", value: $model.viewOffsetMillimetres.z, in: ExampleModel.viewOffsetRange, step: model.viewOffsetStep)
                    Picker("Step", selection: $model.viewOffsetStep) {
                        Text("10 mm").tag(10)
                        Text("1 mm").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
                .disabled(measuredEyesShown != nil)
                HStack(spacing: 24) {
                    Button {
                        Task { await measureEyes() }
                    } label: {
                        Label(model.eyeMeasurement == .running ? "Measuring the eyes…" : "Measure the eyes", systemImage: "eye")
                    }
                    .disabled(model.eyeMeasurement == .running)
                    Toggle(model.measuredEyes.map { "Measured eyes (\($0.positionsDescription), \($0.frames) frames)" } ?? "Measured eyes (none kept for this device: measure them)", isOn: $model.useMeasuredEyes)
                        .disabled(model.measuredEyes == nil)
                }
                if !model.eyeMeasurementNote.isEmpty {
                    Text(model.eyeMeasurementNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("The eyes the engine renders from: a nominal pair, the IPD apart at the device anchor plus the view offset, while RealityKit shows the grids from the device's TRACKED eyes it never tells the presenter about: 25 mm below the anchor on the headset of 2026-10-27, moving by half a millimetre with the gaze. The difference is the kinks and the shimmer along the cubes' edges (parallax of cells at a wrong depth). Measure the eyes: the calibration space opens for a moment (a bare compositor layer, nothing drawn), reads the device's eye transforms for 60 frames, closes, and the presenter's space opens rendering from the measured pair, kept for this device; the toggle puts a kept measurement in force or leaves the steppers' pair in charge (the manual way: the IPD is the distance between the two measured eyes, the offset their midpoint; x right, y up, z back).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Equi-angular rate map (the same pixels, denser at the centre of view; the grid becomes the map's)", isOn: $model.rateMap)
                Toggle("Two-refresh pipeline (the engine's frame starts a refresh earlier, so a frame stretched by up to a refresh still lands on time; one refresh more lead)", isOn: $model.twoRefreshPipeline)
                // The render scale as a picker: 0.5 (960 × 912, 6.5 texels per degree at the
                // centre) through 2 (3840 × 3648). The undersampling test of 2026-10-27: if the
                // device's gaze-foveated raster undersamples the eye texture away from the gaze,
                // 0.5 shimmers less (and blurs) and 2 shimmers more.
                Toggle("Mip chain on the eye textures (next space: generated after each frame, the graphs filtering between levels, so the device's gaze-foveated raster samples the texture at its own rate instead of aliasing the silhouettes away from the gaze)", isOn: $model.mipmapped)
                HStack(spacing: 12) {
                    Text("Render scale (next space; 1 is the drawable size, 1920×1824)")
                    Picker("Render scale", selection: $model.renderScale) {
                        Text("0.5×").tag(Float(0.5))
                        Text("1×").tag(Float(1))
                        Text("1.5×").tag(Float(1.5))
                        Text("2×").tag(Float(2))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Toggle("Blended core (the default: the grids drawn blended with their depth kept and no band, no alpha test anywhere along a silhouette and no band choosing cells on a curved one; off is the cut-and-band chain as first shipped, for the next space opened)", isOn: $model.blendedCore)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What to look for")
                    .font(.headline)
                Text("Three cubes on a slab 1.6 m ahead, with a sphere above them (still, so screenshots compare; launch with --turning for motion). They must stay put while you move your head. Pinch a cube to light it up; the tap count rises. In Mixed the room shows around the slab; in Full it is dark. The swim probe puts a yellow cross in the room 1.5 m ahead of where you look when it comes on, and a cyan dot on your head the same distance ahead: turn your head. The cross must stay in the room, the dot in view; a dot that lags the turn and catches up when you stop says the lead is short, one that runs ahead says it is long. With the adaptive lead on, the display latency is the number to move until the dot holds still; the numbers line shows the lead in force. With the two-refresh pipeline, the late count during quick turns should fall to near zero (the plan is two refreshes, and the line says so) and the dot must still hold still with the lead one refresh longer; if it lags, the fixed lead or the display latency is what to move. With the render scale at 1.5×, the cubes' and the sphere's edges should lose the magnified staircase (the settings line says the texels per degree in force); watch the GPU and the late count on the numbers line, which the extra pixels raise. The control cube (its toggle, or --control-cube) is a plain RealityKit cube to the right of the engine's three, the same size and a like pale blue, drawn by the device's own render with no presenter between: capture both in one frame and measure its top edge with the engine cubes' by the same script. The same wobble on the control is the device's render or the capture; a straight control beside a wavy engine cube is the presenter's. With the blended core (its toggle, or --blended-core, for the next space opened) the grids blend with their depth kept and there is no band and no alpha test along a silhouette: beside the control cube, the engine cubes' edges should hold as still as the control's if the shipped cut's rasterization was the shimmer, and still shimmer if it is the texture's own change from frame to frame; the gpu on the numbers line should read under the shipped core plus band (one pass over the grid instead of two). The IPD and the view offset (their steppers, or --ipd and --view-offset, for the next space opened) move the nominal eyes the engine renders from, while RealityKit shows the grids from the device's real eyes: the headset settled it, the kinks on the cube tops at rest and the waves with the gaze are that difference. Measure the eyes (the button, or --measure-eyes at a launch): the calibration space reads the device's tracked eyes and the presenter's space opens rendering from them; the settings line says eyes measured L (…) R (…) mm. Beside the control cube, the middle cube's far edge should hold as straight and still as the control's at rest and while glancing; against the manual pair (the toggle off, the steppers at the same numbers) the two should look alike, and any residual is the eye tracker's loose z, the depth error at a sliver, or the gaze's own half millimetre. The silhouette cells (their toggle, or --silhouette-cells alpha, live): with the measured eyes in force, the engine sphere's limb beside the control sphere's, at rest and while glancing, with the alpha crossing against the shipped skirt; the skirt's limb read as a polygon of cells whose segments breathed with the gaze, and the crossing puts each rim vertex on the texture's edge at the surface's own depth with no cell stretched to the shell, so its limb should hold as the control's does, a chord per cell (about a quarter of a texel inside the circle at the grid's 7.5-texel cells).")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Numbers (last second)")
                    .font(.headline)
                Text(model.statusLine)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                if !model.materialLine.isEmpty {
                    Text(model.materialLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(28)
        .task {
            let arguments = CommandLine.arguments
            if arguments.contains("--measure-eyes") {
                // The measurement first, which ends with the presenter's space open.
                await measureEyes()
            } else if arguments.contains("--open-space") {
                await openImmersiveSpace(id: "presenter")
            } else {
                return
            }
            if arguments.contains("--hide-window") {
                dismissWindow(id: "control")
            }
        }
    }

    /// The measurement the eye row shows greyed in its steppers: the kept one while it is in
    /// force.
    private var measuredEyesShown: MeasuredEyes? {
        model.measuredEyesInForce ? model.measuredEyes : nil
    }

    /// The calibration: the presenter's space closed if it is open (one immersive space at a
    /// time), the calibration space opened, the measurement awaited (the engine's helper on the
    /// space's compositor layer, 60 frames), the space closed, the pair kept for this device
    /// and put in force, and the presenter's space opened rendering from it.
    private func measureEyes() async {
        guard model.eyeMeasurement != .running else { return }
        if model.spaceOpen {
            await dismissImmersiveSpace()
        }
        model.eyeMeasurement = .running
        model.eyeMeasurementNote = "Measuring the eyes in the calibration space…"
        let opened = await openImmersiveSpace(id: "eyeCalibration")
        guard case .opened = opened else {
            model.eyeMeasurement = .idle
            model.eyeMeasurementNote = "The calibration space did not open (\(String(describing: opened))); nothing measured."
            return
        }
        let result = await model.awaitEyeMeasurement()
        await dismissImmersiveSpace()
        model.keepMeasuredEyes(result)
        await openImmersiveSpace(id: "presenter")
    }
}


/// The grids the window offers, each eye's vertex count.
enum ExampleGrid: String, CaseIterable, Identifiable {
    case standard, dense

    var id: String { rawValue }

    var columns: Int { self == .dense ? 512 : 256 }
    var rows: Int { self == .dense ? 480 : 240 }
    var label: String { "\(columns)×\(rows)" }

    static func remembered() -> ExampleGrid {
        ExampleGrid(rawValue: UserDefaults.standard.string(forKey: "grid") ?? "") ?? .standard
    }

    func remember() {
        UserDefaults.standard.set(rawValue, forKey: "grid")
    }
}
