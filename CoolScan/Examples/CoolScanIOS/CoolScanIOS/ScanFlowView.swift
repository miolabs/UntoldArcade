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
            case .choosing:
                choiceView
            case let .reconstructing(progress):
                reconstructionView(progress: progress)
            case let .uploading(sent, total, file):
                transferView(
                    title: "Sending photos to \(model.remoteServerName)…",
                    detail: file.isEmpty ? "\(sent)/\(total) files" : "\(sent + 1)/\(total) · \(file)",
                    fraction: total == 0 ? 0 : Double(sent) / Double(total)
                )
            case let .remote(stage, progress, eta):
                transferView(
                    title: "\(model.remoteServerName) is reconstructing…",
                    detail: stage + (eta.map { " · about \(Int($0 / 60) + 1) min left" } ?? ""),
                    fraction: progress
                )
            case .downloading:
                transferView(title: "Downloading the model…", detail: "Almost there", fraction: nil)
            case .installing:
                transferView(title: "Installing…", detail: "", fraction: nil)
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

    /// Offered when a Mac server is reachable: full-detail remote
    /// reconstruction versus the phone's reduced on-device pass.
    private var choiceView: some View {
        VStack(spacing: 18) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Where should the 3D model be built?")
                .font(.title3.weight(.semibold))
            VStack(spacing: 10) {
                Button {
                    Task { await model.chooseMac() }
                } label: {
                    VStack(spacing: 2) {
                        Text("On \(model.remoteServerName)")
                            .font(.headline)
                        Text("Full detail · a few minutes · needs the same Wi‑Fi")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await model.chooseLocal() }
                } label: {
                    VStack(spacing: 2) {
                        Text("On this iPhone")
                            .font(.headline)
                        Text("Reduced detail · about a minute")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
        }
        .padding()
    }

    private func transferView(title: String, detail: String, fraction: Double?) -> some View {
        VStack(spacing: 16) {
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text("You can leave this screen; the job continues in the library.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
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
        case choosing
        case reconstructing(progress: Double)
        case cooking
        case uploading(sent: Int, total: Int, file: String)
        case remote(stage: String, progress: Double, eta: Double?)
        case downloading
        case installing
        case failed(String)
        case done(scanID: String)

        var showsCancel: Bool {
            switch self {
            case .initializing, .capturing, .choosing, .reconstructing, .uploading, .remote: true
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

    /// Mac server discovery runs for the whole flow so the choice after the
    /// capture is instant.
    let discovery = ServerDiscovery()
    private var remoteClient: ServerClient?
    private var remoteJobID: String?
    private(set) var remoteServerName = "your Mac"

    /// Under Documents, not tmp: the capture must survive until it has been
    /// uploaded, and the system may purge tmp while the app is not running.
    private let workDirectory = RemoteReconstruction.pendingDirectory
        .appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)

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
        discovery.start()

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
                await decideWhereToReconstruct()
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
        if let remoteClient, let remoteJobID {
            Task { try? await remoteClient.cancel(jobID: remoteJobID); try? await remoteClient.delete(jobID: remoteJobID) }
            RemoteReconstruction.removePending(jobID: remoteJobID)
        }
        cleanUp()
    }

    // MARK: - Mac / iPhone decision

    private func decideWhereToReconstruct() async {
        session = nil // release the camera either way
        if let client = await availableServer() {
            remoteClient = client
            phase = .choosing
        } else {
            await reconstruct()
        }
    }

    /// Manual address first, then the first discovered server.
    private func availableServer() async -> ServerClient? {
        if let manual = ServerSettings.manualBaseURL {
            let client = ServerClient(baseURL: manual)
            if let health = try? await client.health() {
                remoteServerName = health.serverName
                return client
            }
        }
        for server in discovery.servers {
            guard let url = try? await ServerDiscovery.resolve(server) else { continue }
            let client = ServerClient(baseURL: url)
            if let health = try? await client.health(), health.photogrammetrySupported {
                remoteServerName = health.serverName
                return client
            }
        }
        return nil
    }

    func chooseLocal() async {
        ServerSettings.preferMac = false
        await reconstruct()
    }

    func chooseMac() async {
        ServerSettings.preferMac = true
        guard let client = remoteClient else { return await reconstruct() }
        await reconstructRemotely(client: client)
    }

    private func reconstructRemotely(client: ServerClient) async {
        let scanID = UUID().uuidString
        let name = "Scan " + Date().formatted(date: .abbreviated, time: .shortened)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        do {
            let files = RemoteReconstruction.captureFiles(in: workDirectory)
            let jobID = try await RemoteReconstruction.submit(
                name: name, files: files, options: ServerSettings.options,
                client: client, scanID: scanID, progress: { [weak self] in self?.apply($0) }
            )
            remoteJobID = jobID
            // The Mac has every file; the local capture is no longer needed.
            try? FileManager.default.removeItem(at: workDirectory)

            _ = try await RemoteReconstruction.collect(
                jobID: jobID, client: client, scanID: scanID,
                progress: { [weak self] in self?.apply($0) }
            )
            remoteJobID = nil
            ScanStore.shared.reload()
            cleanUp()
            phase = .done(scanID: scanID)
        } catch {
            cleanUp()
            phase = .failed("Mac reconstruction failed: \(error.localizedDescription)")
        }
    }

    private func apply(_ remote: RemoteReconstruction.Phase) {
        switch remote {
        case .connecting: phase = .uploading(sent: 0, total: 0, file: "")
        case let .uploading(sent, total, file): phase = .uploading(sent: sent, total: total, file: file)
        case let .remote(stage, progress, eta): phase = .remote(stage: stage, progress: progress, eta: eta)
        case .downloading: phase = .downloading
        case .installing: phase = .installing
        }
    }

    private func reconstruct() async {
        phase = .reconstructing(progress: 0)
        session = nil // release the camera before reconstruction (no-op after the decision step)

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
        discovery.stop()
        SharedRenderer.resumeRendering()
        try? FileManager.default.removeItem(at: workDirectory)
    }
}
