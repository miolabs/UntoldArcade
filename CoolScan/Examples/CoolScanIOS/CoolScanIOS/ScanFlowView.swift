import RealityKit
import SwiftUI
import UIKit

/// Guided Object Capture flow: walk around the object, reconstruct on
/// device, cook to `.untold`, and land the result in the scan library.
/// Requires a LiDAR iPhone; the library screen gates entry on
/// `ObjectCaptureSession.isSupported`.
struct ScanFlowView: View {
    /// Called with the new scan's id once it is cooked and in the library.
    let onFinished: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ScanFlowModel()

    var body: some View {
        ZStack {
            switch model.phase {
            case .initializing:
                ProgressView("Preparing camera…")
            case .capturing:
                captureView
            case let .reconstructing(progress):
                reconstructionView(progress: progress)
            case .cooking:
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Saving your scan…")
                        .font(.headline)
                    Text("Converting the model to the Untold format.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case let .failed(message):
                failureView(message: message)
            case let .done(scanID):
                ProgressView()
                    .onAppear { onFinished(scanID) }
            }
        }
        .navigationBarBackButtonHidden(model.phase.hidesBackButton)
        .toolbar {
            if model.phase.showsCancel {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
        }
        .task { await model.start() }
    }

    @ViewBuilder
    private var captureView: some View {
        if let session = model.session {
            ObjectCaptureView(session: session)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    captureStatus(for: session)
                        .padding(.top, 8)
                }
                .overlay(alignment: .bottom) {
                    captureControls(for: session)
                        .padding(.bottom, 30)
                }
        } else {
            ProgressView()
        }
    }

    /// Live guidance: the session's own feedback (too close, too fast, low
    /// light…) plus the shot counter. Following these is the single biggest
    /// lever on reconstruction quality.
    @ViewBuilder
    private func captureStatus(for session: ObjectCaptureSession) -> some View {
        VStack(spacing: 6) {
            if session.state == .capturing {
                Text("Pass \(model.passNumber) · \(session.numberOfShotsTaken)/\(session.maximumNumberOfInputImages) photos")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
            ForEach(Self.messages(for: session.feedback), id: \.self) { message in
                Text(message)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.yellow.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.feedback)
    }

    private static func messages(for feedback: Set<ObjectCaptureSession.Feedback>) -> [String] {
        feedback.compactMap { item in
            switch item {
            case .objectTooClose: "Move farther from the object"
            case .objectTooFar: "Move closer to the object"
            case .movingTooFast: "Slow down"
            case .environmentLowLight: "More light would help"
            case .environmentTooDark: "Too dark to capture"
            case .outOfFieldOfView: "Keep the object in view"
            case .objectNotFlippable: "This object should not be flipped"
            case .overCapturing: "This area is covered — move on"
            case .objectNotDetected: "Point at the object to detect it"
            @unknown default: nil
            }
        }
        .sorted()
    }

    @ViewBuilder
    private func captureControls(for session: ObjectCaptureSession) -> some View {
        VStack(spacing: 10) {
            switch session.state {
            case .ready:
                Button("Start Detecting") { model.beginDetecting() }
                    .buttonStyle(.borderedProminent)
            case .detecting:
                Text("Drag the box handles so it hugs the object — anything outside is discarded")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                Button("Start Capture") { model.beginCapturing() }
                    .buttonStyle(.borderedProminent)
            case .capturing:
                if session.userCompletedScanPass {
                    passCompleteControls
                } else {
                    Text("Slowly circle the object at this height")
                        .font(.callout)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                }
            default:
                EmptyView()
            }
        }
    }

    /// After each orbit: finish, or add coverage. A second pass at a
    /// different height fills legs and undersides; flipping covers the
    /// bottom for objects that can be turned over.
    private var passCompleteControls: some View {
        VStack(spacing: 8) {
            Text("Pass \(model.passNumber) complete")
                .font(.callout.weight(.semibold))
            if model.canAddPass {
                Button("Another pass (crouch lower / go higher)") { model.beginAnotherPass(flipped: false) }
                    .buttonStyle(.bordered)
                Button("Flip object, then another pass") { model.beginAnotherPass(flipped: true) }
                    .buttonStyle(.bordered)
            }
            Button("Finish Scan") { model.finish() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func reconstructionView(progress: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 240)
            Text("Building 3D model… \(Int(progress * 100))%")
                .font(.callout)
            Text("Keep the app open; everything runs on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func failureView(message: String) -> some View {
        ContentUnavailableView {
            Label("Scan failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Close") { dismiss() }
        }
    }
}

// MARK: - Model

@MainActor
final class ScanFlowModel: ObservableObject {
    enum Phase {
        case initializing
        case capturing
        case reconstructing(progress: Double)
        case cooking
        case failed(String)
        case done(scanID: String)

        var showsCancel: Bool {
            switch self {
            case .initializing, .capturing, .reconstructing: true
            default: false
            }
        }

        var hidesBackButton: Bool {
            switch self {
            case .failed, .done: false
            default: true
            }
        }
    }

    @Published var phase: Phase = .initializing
    @Published private(set) var passNumber = 1
    private(set) var session: ObjectCaptureSession?

    /// Object Capture supports up to three scan passes per session.
    static let maximumPasses = 3
    var canAddPass: Bool { passNumber < Self.maximumPasses }
    private var photogrammetry: PhotogrammetrySession?

    private let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoolScanCapture-\(UUID().uuidString)", isDirectory: true)

    private var imagesDirectory: URL {
        workDirectory.appendingPathComponent("Images", isDirectory: true)
    }

    private var checkpointDirectory: URL {
        workDirectory.appendingPathComponent("Checkpoints", isDirectory: true)
    }

    private var modelURL: URL {
        workDirectory.appendingPathComponent("model.usdz")
    }

    func start() async {
        guard session == nil else { return }
        guard ObjectCaptureSession.isSupported else {
            phase = .failed("Object Capture needs a LiDAR-equipped iPhone.")
            return
        }

        // The GPU refuses work from a process it considers backgrounded
        // (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted),
        // and a capture session created in that window never recovers. Wait
        // until the app is genuinely foreground-active before touching it.
        await waitUntilApplicationActive()

        // Only one Metal render loop while scanning: Object Capture owns the
        // camera and the GPU; the engine's off-screen MTKView would just
        // compete with it.
        SharedRenderer.pauseRendering()

        do {
            try FileManager.default.createDirectory(
                at: imagesDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: checkpointDirectory, withIntermediateDirectories: true
            )
        } catch {
            phase = .failed("Could not create the capture folders: \(error.localizedDescription)")
            return
        }

        let session = ObjectCaptureSession()
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = checkpointDirectory
        // Let the session keep shooting past its default budget: thin and
        // shiny parts (chair legs, chrome) need every extra view they can get.
        configuration.isOverCaptureEnabled = true
        session.start(imagesDirectory: imagesDirectory, configuration: configuration)
        self.session = session
        phase = .capturing

        // Track the session until capture finishes or fails.
        for await state in session.stateUpdates {
            print("CoolScan capture state: \(state)")
            switch state {
            case .completed:
                await reconstruct()
                return
            case let .failed(error):
                phase = .failed("Capture failed: \(error.localizedDescription)")
                cleanUp()
                return
            default:
                continue
            }
        }
    }

    func beginDetecting() {
        guard let session else { return }
        if !session.startDetecting() {
            phase = .failed(
                "Could not start object detection (session state: "
                    + "\(session.state)). Make sure the app is in the "
                    + "foreground and the device is unlocked, then try again."
            )
        }
    }

    private func waitUntilApplicationActive() async {
        guard UIApplication.shared.applicationState != .active else { return }
        for await _ in NotificationCenter.default.notifications(
            named: UIApplication.didBecomeActiveNotification
        ) {
            if UIApplication.shared.applicationState == .active { break }
        }
    }

    func beginCapturing() {
        session?.startCapturing()
    }

    func beginAnotherPass(flipped: Bool) {
        guard let session, canAddPass else { return }
        if flipped {
            session.beginNewScanPassAfterFlip()
        } else {
            session.beginNewScanPass()
        }
        passNumber += 1
    }

    func finish() {
        session?.finish()
    }

    func cancel() {
        session?.cancel()
        photogrammetry = nil
        cleanUp()
    }

    private func reconstruct() async {
        phase = .reconstructing(progress: 0)
        session = nil // release the camera before reconstruction

        do {
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = checkpointDirectory
            // Scans are shot in orbit order, and low-texture surfaces (black
            // plastic, fabric) need the more aggressive feature detector.
            configuration.sampleOrdering = .sequential
            configuration.featureSensitivity = .high
            let photogrammetry = try PhotogrammetrySession(
                input: imagesDirectory,
                configuration: configuration
            )
            self.photogrammetry = photogrammetry

            // .reduced is the only detail level iOS offers on device.
            try photogrammetry.process(requests: [
                .modelFile(url: modelURL, detail: .reduced),
            ])

            for try await output in photogrammetry.outputs {
                switch output {
                case let .requestProgress(_, fraction):
                    phase = .reconstructing(progress: fraction)
                case let .requestError(_, error):
                    phase = .failed("Reconstruction failed: \(error.localizedDescription)")
                    cleanUp()
                    return
                case .processingComplete:
                    await cook()
                    return
                default:
                    continue
                }
            }
        } catch {
            phase = .failed("Reconstruction could not start: \(error.localizedDescription)")
            cleanUp()
        }
    }

    private func cook() async {
        phase = .cooking
        let name = "Scan " + Date().formatted(date: .abbreviated, time: .shortened)
        let record = await ScanStore.shared.importUSDZ(at: modelURL, name: name)
        cleanUp()
        if let record {
            phase = .done(scanID: record.id)
        } else {
            phase = .failed(ScanStore.shared.lastError ?? "The scan could not be saved.")
        }
    }

    private func cleanUp() {
        SharedRenderer.resumeRendering()
        try? FileManager.default.removeItem(at: workDirectory)
    }
}
