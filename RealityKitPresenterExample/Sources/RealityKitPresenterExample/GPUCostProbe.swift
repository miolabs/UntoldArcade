//
//  GPUCostProbe.swift
//  RealityKitPresenterExample
//
//  A probe for the GPU-cost investigation (Debug 3.8 ms against Release 9.5 ms): the numbers
//  line, the settings in force and the engine's per-pass GPU timings are appended to a file in
//  the app's Documents folder once a second, and a Metal GPU trace of the engine's command
//  queue is written there once, 20 seconds after the space opens, so both can be pulled from
//  the device with `devicectl device copy from`.
//

import Foundation
import Metal
import UntoldEngine

enum GPUCostProbe {
    /// "debug" or "release": the engine package's own build, which is what the frame runs on.
    static var engineBuild: String { EngineBuild.isOptimized ? "release" : "debug" }

    /// The app target's own build.
    static var appBuild: String {
        #if DEBUG
            return "debug"
        #else
            return "release"
        #endif
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var numbersFile: URL { documents.appendingPathComponent("numbers-\(engineBuild).log") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Appends one line, stamped.
    static func log(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: numbersFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: numbersFile)
        }
    }

    /// The renderer's state that bears on the frame's GPU cost, and the device's.
    static func describeRenderer() -> String {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let busy = GPUPassTiming.shared.busy()
        return "engine \(engineBuild), app \(appBuild), opaque samples \(renderInfo.opaqueSampleCount) (preferred \(renderInfo.preferredMultisampleCount)), viewport \(Int(renderInfo.viewPort.x))×\(Int(renderInfo.viewPort.y)), pass timing \(GPUPassTiming.shared.isEnabled ? "on" : "off"), thermal \(thermal), low power \(ProcessInfo.processInfo.isLowPowerModeEnabled), engine busy \(String(format: "%.2f", busy.averageMs)) ms (last \(String(format: "%.2f", busy.lastFrameMs)))"
    }

    /// The engine's per-pass GPU timings (counter samples at the stage boundaries), heaviest
    /// first, and their sum.
    static func describePasses() -> String {
        let passes = GPUPassTiming.shared.averages()
        guard !passes.isEmpty else { return "passes: none" }
        let total = passes.reduce(0.0) { $0 + $1.totalMs }
        let parts = passes.map { String(format: "%@ %.2f (v %.2f f %.2f)", $0.label, $0.totalMs, $0.vertexMs, $0.fragmentMs) }
        return String(format: "passes sum %.2f ms: ", total) + parts.joined(separator: ", ")
    }

    /// A GPU trace of `queue` for `seconds`, into Documents (needs `MetalCaptureEnabled` in
    /// the Info.plist).
    static func capture(queue: MTLCommandQueue, seconds: Double) {
        let manager = MTLCaptureManager.shared()
        guard manager.supportsDestination(.gpuTraceDocument) else {
            log("capture: the GPU trace document destination is not supported (MetalCaptureEnabled missing?)")
            return
        }
        let url = documents.appendingPathComponent("capture-\(engineBuild).gputrace")
        try? FileManager.default.removeItem(at: url)
        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = queue
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = url
        do {
            try manager.startCapture(with: descriptor)
            log("capture: started into \(url.lastPathComponent)")
        } catch {
            log("capture: could not start: \(error)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            manager.stopCapture()
            log("capture: stopped")
        }
    }
}
