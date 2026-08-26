//
//  CoolBallSpatialSession.swift
//  CoolBall
//

import Foundation
import simd

public enum CoolBallHandSide: CaseIterable, Sendable {
    case left
    case right
}

/// The joints the football demo needs: palm for the hand collider, thumb and
/// index tips for the pinch grab.
public struct CoolBallHandPose: Sendable {
    public var isTracked: Bool
    public var palm: SIMD3<Float>
    public var thumbTip: SIMD3<Float>
    public var indexTip: SIMD3<Float>

    public var pinchPoint: SIMD3<Float> {
        (thumbTip + indexTip) * 0.5
    }

    public var pinchDistance: Float {
        simd_length(thumbTip - indexTip)
    }
}

#if os(visionOS)
import ARKit

/// visionOS adapter running the demo's own ARKitSession — hand tracking for
/// grab/kick input and plane detection for real-surface colliders. Fresh
/// provider instances on every start: ARKit providers are one-shot.
public final class CoolBallSpatialSession: @unchecked Sendable {
    private let session = ARKitSession()
    private let lock = NSLock()
    private var updateTask: Task<Void, Never>?
    private var poses: [CoolBallHandSide: CoolBallHandPose] = [:]
    private var planesByID: [UUID: CoolBallWorldPlane] = [:]
    private var handTrackingProvider: HandTrackingProvider?
    private var worldTracking: WorldTrackingProvider?
    /// Called with the full plane set on every plane change (any thread).
    public var onPlanesChanged: (@Sendable ([CoolBallWorldPlane]) -> Void)?

    public init() {}

    public static var isHandTrackingSupported: Bool {
        HandTrackingProvider.isSupported
    }

    public static var isPlaneDetectionSupported: Bool {
        PlaneDetectionProvider.isSupported
    }

    public func start() {
        lock.withLock {
            guard updateTask == nil else { return }
            updateTask = Task { [weak self] in
                guard let self else { return }
                let handTracking = HandTrackingProvider()
                let planeDetection = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
                var providers: [any DataProvider] = []
                if HandTrackingProvider.isSupported {
                    self.lock.withLock { self.handTrackingProvider = handTracking }
                    providers.append(handTracking)
                }
                if PlaneDetectionProvider.isSupported {
                    providers.append(planeDetection)
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
                    print("CoolBall: ARKit session failed to run — \(error)")
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
                    if PlaneDetectionProvider.isSupported {
                        group.addTask {
                            for await update in planeDetection.anchorUpdates {
                                guard !Task.isCancelled else { break }
                                self.handle(planeUpdate: update)
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
            planesByID.removeAll()
            handTrackingProvider = nil
            worldTracking = nil
            return task
        }
        task?.cancel()
        session.stop()
    }

    /// Pose predicted for `timestamp` (systemUptime timebase); falls back to
    /// the latest streamed pose. Prediction keeps the grab glued to a fast
    /// hand instead of trailing the anchor stream.
    public func predictedHandPose(
        _ side: CoolBallHandSide,
        at timestamp: TimeInterval
    ) -> CoolBallHandPose? {
        let provider = lock.withLock { handTrackingProvider }
        if let provider, provider.state == .running {
            let anchors = provider.handAnchors(at: timestamp)
            let anchor = side == .left ? anchors.0 : anchors.1
            if let anchor, let pose = Self.makePose(from: anchor) {
                return pose
            }
        }
        return lock.withLock { poses[side] }
    }

    /// Current head transform in the world frame, or nil until tracking runs.
    public func headTransform() -> simd_float4x4? {
        let provider = lock.withLock { worldTracking }
        guard let provider, provider.state == .running else { return nil }
        return provider.queryDeviceAnchor(
            atTimestamp: ProcessInfo.processInfo.systemUptime
        )?.originFromAnchorTransform
    }

    public var detectedPlanes: [CoolBallWorldPlane] {
        lock.withLock { Array(planesByID.values) }
    }

    // MARK: - Anchors

    private func handle(handUpdate update: AnchorUpdate<HandAnchor>) {
        let anchor = update.anchor
        let side: CoolBallHandSide = anchor.chirality == .left ? .left : .right
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

    private static func makePose(from anchor: HandAnchor) -> CoolBallHandPose? {
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
        let knuckleCenter = (world(.indexFingerKnuckle) + world(.littleFingerKnuckle)) * 0.5
        return CoolBallHandPose(
            isTracked: anchor.isTracked,
            palm: (wrist + knuckleCenter) * 0.5,
            thumbTip: world(.thumbTip),
            indexTip: world(.indexFingerTip)
        )
    }

    private func handle(planeUpdate update: AnchorUpdate<PlaneAnchor>) {
        let anchor = update.anchor
        switch update.event {
        case .removed:
            lock.withLock { _ = planesByID.removeValue(forKey: anchor.id) }
        case .added, .updated:
            let plane = Self.makePlane(from: anchor)
            lock.withLock { planesByID[anchor.id] = plane }
        }
        let planes = lock.withLock { Array(planesByID.values) }
        onPlanesChanged?(planes)
    }

    /// ARKit planes lie in their anchor's X-Z plane with the normal along
    /// +Y (device-verified: the previous X-Y/+Z reading left every surface
    /// misoriented, and the ball rested on phantom geometry mid-air). The
    /// extent transform only rotates within the plane, so the tangents come
    /// from the composed transform's X and Z columns, width along X and
    /// height along Z.
    private static func makePlane(from anchor: PlaneAnchor) -> CoolBallWorldPlane {
        let extent = anchor.geometry.extent
        let transform = anchor.originFromAnchorTransform * extent.anchorFromExtentTransform
        let center = SIMD3<Float>(
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z
        )
        let tangentU = SIMD3<Float>(
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z
        )
        let normal = SIMD3<Float>(
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z
        )
        let tangentV = SIMD3<Float>(
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z
        )
        return CoolBallWorldPlane(
            id: anchor.id,
            center: center,
            normal: simd_normalize(normal),
            tangentU: simd_normalize(tangentU),
            tangentV: simd_normalize(tangentV),
            extentU: extent.width * 0.5,
            extentV: extent.height * 0.5
        )
    }

    private func clearTask() {
        lock.withLock { updateTask = nil }
    }
}
#endif
