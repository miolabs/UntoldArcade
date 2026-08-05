import RealityKit
import SwiftUI

/// Guided Object Capture flow: walk around the object, reconstruct on
/// device, cook to `.untold`, and land the result in the scan library.
/// Requires a LiDAR iPhone; the library screen gates entry on
/// `ObjectCaptureSession.isSupported`.
struct ScanFlowView: View {
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
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Converting to Untold format…")
                }
            case let .failed(message):
                failureView(message: message)
            case .done:
                Color.clear.onAppear { dismiss() }
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
                .overlay(alignment: .bottom) {
                    captureControls(for: session)
                        .padding(.bottom, 30)
                }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func captureControls(for session: ObjectCaptureSession) -> some View {
        VStack(spacing: 10) {
            switch session.state {
            case .ready:
                Button("Start Detecting") { model.beginDetecting() }
                    .buttonStyle(.borderedProminent)
            case .detecting:
                Button("Start Capture") { model.beginCapturing() }
                    .buttonStyle(.borderedProminent)
            case .capturing:
                if session.userCompletedScanPass {
                    Button("Finish Scan") { model.finish() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Slowly walk around the object")
                        .font(.callout)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                }
            default:
                EmptyView()
            }
        }
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
        case done

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
    private(set) var session: ObjectCaptureSession?
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
        session.start(imagesDirectory: imagesDirectory, configuration: configuration)
        self.session = session
        phase = .capturing

        // Track the session until capture finishes or fails.
        for await state in session.stateUpdates {
            switch state {
            case .completed:
                await reconstruct()
                return
            case let .failed(error):
                phase = .failed("Capture failed: \(error.localizedDescription)")
                return
            default:
                continue
            }
        }
    }

    func beginDetecting() {
        if session?.startDetecting() != true {
            phase = .failed("Could not start object detection.")
        }
    }

    func beginCapturing() {
        session?.startCapturing()
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
            let photogrammetry = try PhotogrammetrySession(
                input: imagesDirectory,
                configuration: configuration
            )
            self.photogrammetry = photogrammetry

            // .reduced keeps memory and thermals sane on phones.
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
        await ScanStore.shared.importUSDZ(at: modelURL, name: name)
        cleanUp()
        if let error = ScanStore.shared.lastError {
            phase = .failed(error)
        } else {
            phase = .done
        }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: workDirectory)
    }
}
