#if os(visionOS)
import ARKit
import Foundation
import Metal
import simd

/// visionOS adapter that runs CoolWeb's own ARKitSession — separate from the
/// engine's — with hand tracking (gesture input) and scene reconstruction
/// (occlusion depth + attach raycasts). Fresh provider instances are created
/// on every start: ARKit providers are one-shot and cannot be re-run.
public final class CoolWebSpatialSession: @unchecked Sendable {
    private let session = ARKitSession()
    private let lock = NSLock()
    private var updateTask: Task<Void, Never>?
    private var poses: [CoolWebHandSide: CoolWebHandPose] = [:]
    private var occlusionMeshesByID: [UUID: CoolWebOcclusionMesh] = [:]
    /// Head pose source for the gaze-triggered glove suit-up.
    private var worldTracking: WorldTrackingProvider?
    /// Kept for `handAnchors(at:)` pose prediction — the anchor update
    /// stream alone lags visibly when the hand moves fast.
    private var handTrackingProvider: HandTrackingProvider?

    public init() {}

    public static var isHandTrackingSupported: Bool {
        HandTrackingProvider.isSupported
    }

    public static var isSceneReconstructionSupported: Bool {
        SceneReconstructionProvider.isSupported
    }

    public func start() {
        lock.withLock {
            guard updateTask == nil else { return }
            updateTask = Task { [weak self] in
                guard let self else { return }
                let handTracking = HandTrackingProvider()
                let sceneReconstruction = SceneReconstructionProvider()
                var providers: [any DataProvider] = []
                if HandTrackingProvider.isSupported {
                    self.lock.withLock { self.handTrackingProvider = handTracking }
                    providers.append(handTracking)
                }
                if SceneReconstructionProvider.isSupported {
                    providers.append(sceneReconstruction)
                }
                if WorldTrackingProvider.isSupported {
                    let worldTracking = WorldTrackingProvider()
                    self.lock.withLock { self.worldTracking = worldTracking }
                    providers.append(worldTracking)
                }
                guard !providers.isEmpty else {
                    self.clearTask()
                    return
                }
                do {
                    try await session.run(providers)
                } catch {
                    print("CoolWeb: ARKit session failed to run — \(error)")
                    self.clearTask()
                    return
                }
                await withTaskGroup(of: Void.self) { group in
                    if HandTrackingProvider.isSupported {
                        group.addTask {
                            for await update in handTracking.anchorUpdates {
                                guard !Task.isCancelled else { break }
                                self.handle(handUpdate: update)
                            }
                        }
                    }
                    if SceneReconstructionProvider.isSupported {
                        group.addTask {
                            for await update in sceneReconstruction.anchorUpdates {
                                guard !Task.isCancelled else { break }
                                self.handle(meshUpdate: update)
                            }
                        }
                    }
                }
                self.clearTask()
            }
        }
    }

    public func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let task = updateTask
            updateTask = nil
            poses.removeAll()
            occlusionMeshesByID.removeAll()
            worldTracking = nil
            handTrackingProvider = nil
            return task
        }
        task?.cancel()
        session.stop()
        setCoolWebOcclusionMeshes([])
        CoolWebSurfaceStore.shared.clear()
    }

    /// Latest world-space pose for a hand, or nil before first tracking.
    public func handPose(_ side: CoolWebHandSide) -> CoolWebHandPose? {
        lock.withLock { poses[side] }
    }

    /// Pose predicted for `timestamp` (systemUptime timebase) via
    /// `handAnchors(at:)` — much lower perceived latency than the anchor
    /// stream, which is what keeps the glove glued to a moving hand. Falls
    /// back to the latest streamed pose when prediction is unavailable.
    public func predictedHandPose(
        _ side: CoolWebHandSide,
        at timestamp: TimeInterval
    ) -> CoolWebHandPose? {
        let provider = lock.withLock { handTrackingProvider }
        if let provider, provider.state == .running {
            let anchors = provider.handAnchors(at: timestamp)
            let anchor = side == .left ? anchors.0 : anchors.1
            if let anchor, let pose = Self.makePose(from: anchor) {
                return pose
            }
        }
        return handPose(side)
    }

    /// Current head (device) transform in the world frame, or nil until
    /// world tracking runs. Drives the gaze-triggered glove suit-up.
    public func headTransform() -> simd_float4x4? {
        let provider = lock.withLock { worldTracking }
        guard let provider, provider.state == .running else { return nil }
        return provider.queryDeviceAnchor(
            atTimestamp: ProcessInfo.processInfo.systemUptime
        )?.originFromAnchorTransform
    }

    // MARK: - Hand anchors

    private func handle(handUpdate update: AnchorUpdate<HandAnchor>) {
        let anchor = update.anchor
        let side: CoolWebHandSide = anchor.chirality == .left ? .left : .right

        guard update.event != .removed else {
            lock.withLock { _ = poses.removeValue(forKey: side) }
            return
        }
        guard let pose = Self.makePose(from: anchor) else {
            lock.withLock { poses[side]?.isTracked = false }
            return
        }
        lock.withLock { poses[side] = pose }
    }

    private static func makePose(from anchor: HandAnchor) -> CoolWebHandPose? {
        guard let skeleton = anchor.handSkeleton else { return nil }
        let originFromAnchor = anchor.originFromAnchorTransform

        func world(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let transform = originFromAnchor
                * skeleton.joint(name).anchorFromJointTransform
            return SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
        }

        let wrist = world(.wrist)
        return CoolWebHandPose(
            isTracked: anchor.isTracked,
            wrist: wrist,
            thumb: CoolWebFingerChain(points: [
                wrist,
                world(.thumbKnuckle),
                world(.thumbIntermediateBase),
                world(.thumbIntermediateTip),
                world(.thumbTip),
            ]),
            index: CoolWebFingerChain(points: [
                world(.indexFingerMetacarpal),
                world(.indexFingerKnuckle),
                world(.indexFingerIntermediateBase),
                world(.indexFingerIntermediateTip),
                world(.indexFingerTip),
            ]),
            middle: CoolWebFingerChain(points: [
                world(.middleFingerMetacarpal),
                world(.middleFingerKnuckle),
                world(.middleFingerIntermediateBase),
                world(.middleFingerIntermediateTip),
                world(.middleFingerTip),
            ]),
            ring: CoolWebFingerChain(points: [
                world(.ringFingerMetacarpal),
                world(.ringFingerKnuckle),
                world(.ringFingerIntermediateBase),
                world(.ringFingerIntermediateTip),
                world(.ringFingerTip),
            ]),
            little: CoolWebFingerChain(points: [
                world(.littleFingerMetacarpal),
                world(.littleFingerKnuckle),
                world(.littleFingerIntermediateBase),
                world(.littleFingerIntermediateTip),
                world(.littleFingerTip),
            ])
        )
    }

    // MARK: - Scene reconstruction anchors

    private func handle(meshUpdate update: AnchorUpdate<MeshAnchor>) {
        let anchor = update.anchor
        switch update.event {
        case .removed:
            lock.withLock { _ = occlusionMeshesByID.removeValue(forKey: anchor.id) }
            CoolWebSurfaceStore.shared.remove(id: anchor.id)
        case .added, .updated:
            let geometry = anchor.geometry
            let faces = geometry.faces
            let occlusionMesh = CoolWebOcclusionMesh(
                vertexBuffer: geometry.vertices.buffer,
                vertexOffset: geometry.vertices.offset,
                vertexStride: geometry.vertices.stride,
                indexBuffer: faces.buffer,
                indexOffset: 0,
                indexCount: faces.count * 3,
                indexType: faces.bytesPerIndex == 2 ? .uint16 : .uint32,
                transform: anchor.originFromAnchorTransform
            )
            lock.withLock { occlusionMeshesByID[anchor.id] = occlusionMesh }

            let (worldVertices, indices) = Self.copyGeometry(from: anchor)
            CoolWebSurfaceStore.shared.update(
                id: anchor.id,
                worldVertices: worldVertices,
                indices: indices
            )
        }
        let meshes = lock.withLock { Array(occlusionMeshesByID.values) }
        setCoolWebOcclusionMeshes(meshes)
    }

    /// CPU copy of a mesh anchor's triangles, transformed to world space, for
    /// the attach raycast.
    private static func copyGeometry(
        from anchor: MeshAnchor
    ) -> ([SIMD3<Float>], [UInt32]) {
        let geometry = anchor.geometry
        let transform = anchor.originFromAnchorTransform

        let vertices = geometry.vertices
        var worldVertices = [SIMD3<Float>]()
        worldVertices.reserveCapacity(vertices.count)
        let vertexBase = vertices.buffer.contents() + vertices.offset
        for i in 0 ..< vertices.count {
            let p = (vertexBase + vertices.stride * i)
                .assumingMemoryBound(to: Float.self)
            let world = transform * SIMD4<Float>(p[0], p[1], p[2], 1)
            worldVertices.append(SIMD3<Float>(world.x, world.y, world.z))
        }

        let faces = geometry.faces
        let indexCount = faces.count * 3
        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        let indexBase = faces.buffer.contents()
        if faces.bytesPerIndex == 2 {
            let typed = indexBase.assumingMemoryBound(to: UInt16.self)
            for i in 0 ..< indexCount { indices.append(UInt32(typed[i])) }
        } else {
            let typed = indexBase.assumingMemoryBound(to: UInt32.self)
            for i in 0 ..< indexCount { indices.append(typed[i]) }
        }
        return (worldVertices, indices)
    }

    private func clearTask() {
        lock.withLock { updateTask = nil }
    }
}
#endif
