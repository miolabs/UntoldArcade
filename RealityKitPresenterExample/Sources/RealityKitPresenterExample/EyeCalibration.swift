//
//  EyeCalibration.swift
//  RealityKitPresenterExample
//
//  The eye calibration: the presenter renders from nominal eyes, the IPD apart at the ARKit
//  device anchor plus the view offset, while RealityKit shows the grids from the device's
//  TRACKED eyes it never tells the presenter about. On the headset (2026-10-27) the tracked
//  eyes sat 24.7 mm below the anchor, and that difference showed as the kinks at rest and the
//  shimmer with the gaze along every silhouette (the parallax of cells drawn at a wrong
//  depth); with the measured eyes dialled in by hand the engine's cubes looked almost like the
//  RealityKit control cube. Compositor Services does hand out the tracked eyes
//  (`LayerRenderer.Drawable.views[i].transform`), so the app measures them itself: a second
//  immersive space, `EyeCalibration`, holds a bare `CompositorLayer` on which the engine's
//  `XREyeMeasurement` runs its minimal frame loop for 60 frames, drawing nothing (the room
//  shows through), averages the transforms and hands them back; the window closes that space,
//  keeps the pair for this device (`MeasuredEyes`) and opens the presenter's space with
//  `configuration.eyeTransforms` set.
//

import CompositorServices
import Foundation
import simd
import SwiftUI
import UIKit
import UntoldEngineXR
import UntoldEngineXRRealityKit

/// The compositor layer the eyes are measured on: ProceduralGeometry's configuration (the
/// dedicated layout, no foveation, sRGB BGRA), so the view transforms are the ones the
/// engine's Compositor path renders from.
struct EyeCalibrationLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities _: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

/// Where a measurement stands: none running, one running in the calibration space, or the
/// last one's result (nil when no frame gave a view).
enum EyeMeasurementState: Equatable {
    case idle
    case running
    case finished(XREyeMeasurement.Result?)
}

/// The eyes measured on a device, kept across launches: the device anchor to each eye (left,
/// right), half the range of each axis over the frames, the frames, when, and the device
/// (`identifierForVendor`), so that a measurement is used only on the headset it was taken on:
/// the eyes are the fit's, and another device or another user's fit measures again.
struct MeasuredEyes: Equatable {
    var eyeTransforms: [simd_float4x4]
    var spreads: [SIMD3<Float>]
    var frames: Int
    var date: Date
    var deviceIdentifier: String

    static let defaultsKey = "measuredEyes"

    static var currentDeviceIdentifier: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown device"
    }

    init(result: XREyeMeasurement.Result, date: Date = Date(), deviceIdentifier: String = MeasuredEyes.currentDeviceIdentifier) {
        eyeTransforms = result.eyeTransforms
        spreads = result.spreads
        frames = result.frames
        self.date = date
        self.deviceIdentifier = deviceIdentifier
    }

    /// The measurement as the engine's result type, for its numbers and its line.
    var result: XREyeMeasurement.Result {
        XREyeMeasurement.Result(eyeTransforms: eyeTransforms, spreads: spreads, frames: frames)
    }

    /// The distance between the eyes, millimetres, rounded: what the IPD stepper shows greyed.
    var interpupillaryMillimetres: Int {
        Int((result.interpupillaryDistance * 1000).rounded())
    }

    /// The eyes' midpoint, millimetres, rounded: what the view offset steppers show greyed.
    var midpointMillimetres: SIMD3<Int> {
        let midpoint = result.midpoint * 1000
        return SIMD3<Int>(Int(midpoint.x.rounded()), Int(midpoint.y.rounded()), Int(midpoint.z.rounded()))
    }

    /// Each eye's position, millimetres, as the settings line names them: "L (-30.9, -24.8,
    /// -10.3) R (32.3, -24.6, -6.1) mm".
    var positionsDescription: String {
        Self.positionsDescription(eyeTransforms)
    }

    static func positionsDescription(_ eyeTransforms: [simd_float4x4]) -> String {
        let names = ["L", "R"]
        let parts = eyeTransforms.prefix(2).enumerated().map { index, transform in
            String(format: "%@ (%.1f, %.1f, %.1f)", names[index], transform.columns.3.x * 1000, transform.columns.3.y * 1000, transform.columns.3.z * 1000)
        }
        return parts.joined(separator: " ") + " mm"
    }

    /// The engine's line: the means, the spreads, the IPD and the frames.
    var description: String {
        result.description
    }

    // MARK: - UserDefaults

    /// The measurement remembered for THIS device, or nil: none, or another device's.
    static func remembered(defaults: UserDefaults = .standard) -> MeasuredEyes? {
        guard let stored = defaults.dictionary(forKey: defaultsKey),
              let device = stored["device"] as? String, device == currentDeviceIdentifier,
              let eyes = stored["eyes"] as? [[Double]], eyes.count >= 2, eyes.allSatisfy({ $0.count == 16 }),
              let spreads = stored["spreads"] as? [[Double]], spreads.allSatisfy({ $0.count == 3 }),
              let frames = stored["frames"] as? Int, frames > 0
        else { return nil }
        let transforms = eyes.map { values -> simd_float4x4 in
            let floats = values.map { Float($0) }
            return simd_float4x4(columns: (
                SIMD4<Float>(floats[0], floats[1], floats[2], floats[3]),
                SIMD4<Float>(floats[4], floats[5], floats[6], floats[7]),
                SIMD4<Float>(floats[8], floats[9], floats[10], floats[11]),
                SIMD4<Float>(floats[12], floats[13], floats[14], floats[15])
            ))
        }
        let date = Date(timeIntervalSince1970: (stored["date"] as? Double) ?? 0)
        let result = XREyeMeasurement.Result(eyeTransforms: transforms, spreads: spreads.map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) }, frames: frames)
        return MeasuredEyes(result: result, date: date, deviceIdentifier: device)
    }

    /// Keeps the measurement for this device; a later launch on the same device starts from it.
    func remember(defaults: UserDefaults = .standard) {
        let eyes = eyeTransforms.map { transform -> [Double] in
            [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3].flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
        }
        let stored: [String: Any] = [
            "device": deviceIdentifier,
            "eyes": eyes,
            "spreads": spreads.map { [Double($0.x), Double($0.y), Double($0.z)] },
            "frames": frames,
            "date": date.timeIntervalSince1970,
        ]
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

extension ExampleModel {
    /// The frames the calibration space measures over: well under a second on the headset.
    static let eyeMeasurementFrames = 60

    /// Whether a measurement is in force for the next space opened: the toggle on and a
    /// measurement kept for this device.
    var measuredEyesInForce: Bool {
        useMeasuredEyes && measuredEyes != nil
    }

    /// Runs the measurement on the calibration space's layer, from that space's compositor
    /// layer closure (not on the main actor); the engine's helper calls back from its own
    /// thread once, with the eyes averaged over the frames, or over the frames it got before
    /// the space was dismissed, or nil.
    nonisolated func startEyeMeasurement(on layerRenderer: LayerRenderer) {
        let measurement = XREyeMeasurement(frames: Self.eyeMeasurementFrames)
        measurement.start(layerRenderer: layerRenderer) { result in
            Task { @MainActor in
                self.eyesMeasured(result)
            }
        }
    }

    /// The measurement's result: what `startEyeMeasurement`'s completion hands over, kept for
    /// the window's flow, which may already be waiting.
    func eyesMeasured(_ result: XREyeMeasurement.Result?) {
        eyeMeasurement = .finished(result)
        if let waiter = eyeMeasurementWaiter {
            eyeMeasurementWaiter = nil
            waiter.resume(returning: result)
        }
    }

    /// Waits for the measurement running in the calibration space to finish (the frames
    /// measured, or the space dismissed), or returns at once the result of one that has.
    func awaitEyeMeasurement() async -> XREyeMeasurement.Result? {
        if case let .finished(result) = eyeMeasurement {
            return result
        }
        return await withCheckedContinuation { continuation in
            eyeMeasurementWaiter = continuation
        }
    }

    /// Keeps a measurement for this device and puts it in force for the next space opened;
    /// one that is not a pair (the simulator gives one view; no frame at all gives nil) is
    /// said and not kept.
    func keepMeasuredEyes(_ result: XREyeMeasurement.Result?) {
        eyeMeasurement = .idle
        guard let result, result.eyeTransforms.count >= 2 else {
            if let result {
                eyeMeasurementNote = "The measurement gave \(result.eyeTransforms.count) eye over \(result.frames) frames, not a pair (the simulator's single view): nothing kept."
            } else {
                eyeMeasurementNote = "No frame gave a view: nothing kept."
            }
            return
        }
        let measured = MeasuredEyes(result: result)
        measured.remember()
        measuredEyes = measured
        useMeasuredEyes = true
        eyeMeasurementNote = (result.frames < Self.eyeMeasurementFrames ? "Measured over \(result.frames) of \(Self.eyeMeasurementFrames) frames (the space closed early): " : "Measured: ") + result.description
    }

    /// The note on the window and in the log (the `numbers` category, with the settings line),
    /// so a run can be read back.
    var eyeMeasurementNote: String {
        get { eyeMeasurementNoteStorage }
        set {
            eyeMeasurementNoteStorage = newValue
            if !newValue.isEmpty {
                log.notice("Eye calibration: \(newValue, privacy: .public)")
            }
        }
    }

    /// The eyes in force for a configuration, for the settings line: the measured pair, or the
    /// nominal distance and offset.
    static func eyesDescription(_ configuration: XRRealityKitPresenterConfiguration) -> String {
        if let eyes = configuration.eyeTransforms, eyes.count >= 2 {
            return "eyes measured " + MeasuredEyes.positionsDescription(eyes)
        }
        let offset = configuration.viewOffsetMetres * 1000
        return "IPD \(Int((configuration.interpupillaryDistance * 1000).rounded())) mm, view offset \(viewOffsetDescription(SIMD3<Int>(Int(offset.x.rounded()), Int(offset.y.rounded()), Int(offset.z.rounded()))))"
    }
}
