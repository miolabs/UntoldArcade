//
//  CoolBasketSpatialSession.swift
//  CoolBasket
//

import Foundation
import simd

public enum CoolBasketHandSide: CaseIterable, Sendable {
    case left
    case right
}

/// What the basketball demo reads off a hand: the palm (hand collider,
/// palm and two-hand holds), thumb and index tips (the pinch), the palm's
/// outward normal and how far the fingers are curled (closing on a ball).
public struct CoolBasketHandPose: Sendable {
    public var isTracked: Bool
    public var palm: SIMD3<Float>
    public var thumbTip: SIMD3<Float>
    public var indexTip: SIMD3<Float>
    /// Unit vector out of the palm, the side the fingers curl toward.
    public var palmNormal: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    /// 0 open hand, 1 fist (see `CoolBasketHandPose.fingerCurl`).
    public var fingerCurl: Float = 0
    /// False when too few fingertips were actually tracked for the curl to
    /// mean anything (fingers wrapped behind the ball, the back of the hand
    /// to the cameras): the game then carries the last good reading.
    public var fingerCurlTracked: Bool = true

    public init(
        isTracked: Bool, palm: SIMD3<Float>, thumbTip: SIMD3<Float>, indexTip: SIMD3<Float>,
        palmNormal: SIMD3<Float> = SIMD3<Float>(0, 1, 0), fingerCurl: Float = 0, fingerCurlTracked: Bool = true
    ) {
        self.isTracked = isTracked
        self.palm = palm
        self.thumbTip = thumbTip
        self.indexTip = indexTip
        self.palmNormal = palmNormal
        self.fingerCurl = fingerCurl
        self.fingerCurlTracked = fingerCurlTracked
    }

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
/// grab/swat input and plane detection for real-surface colliders. Fresh
/// provider instances on every start: ARKit providers are one-shot.
public final class CoolBasketSpatialSession: @unchecked Sendable {
    private let session = ARKitSession()
    private let lock = NSLock()
    private var updateTask: Task<Void, Never>?
    private var poses: [CoolBasketHandSide: CoolBasketHandPose] = [:]
    private var planesByID: [UUID: CoolBasketWorldPlane] = [:]
    private var handTrackingProvider: HandTrackingProvider?
    private var worldTracking: WorldTrackingProvider?
    /// Called with the full plane set on every plane change (any thread).
    public var onPlanesChanged: (@Sendable ([CoolBasketWorldPlane]) -> Void)?

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
                    print("CoolBasket: ARKit session failed to run — \(error)")
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
        _ side: CoolBasketHandSide,
        at timestamp: TimeInterval
    ) -> CoolBasketHandPose? {
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

    public var detectedPlanes: [CoolBasketWorldPlane] {
        lock.withLock { Array(planesByID.values) }
    }

    // MARK: - Anchors

    private func handle(handUpdate update: AnchorUpdate<HandAnchor>) {
        let anchor = update.anchor
        let side: CoolBasketHandSide = anchor.chirality == .left ? .left : .right
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

    private static func makePose(from anchor: HandAnchor) -> CoolBasketHandPose? {
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
        let indexKnuckle = world(.indexFingerKnuckle)
        let littleKnuckle = world(.littleFingerKnuckle)
        let knuckleCenter = (indexKnuckle + littleKnuckle) * 0.5
        let side: CoolBasketHandSide = anchor.chirality == .left ? .left : .right
        // Only fingertips ARKit actually sees count toward the curl: an
        // extrapolated tip (fingers wrapped behind the ball) reads anywhere.
        let fingers: [(knuckle: HandSkeleton.JointName, tip: HandSkeleton.JointName)] = [
            (.indexFingerKnuckle, .indexFingerTip), (.middleFingerKnuckle, .middleFingerTip),
            (.ringFingerKnuckle, .ringFingerTip), (.littleFingerKnuckle, .littleFingerTip),
        ]
        let seen = fingers.filter { skeleton.joint($0.tip).isTracked && skeleton.joint($0.knuckle).isTracked }
        return CoolBasketHandPose(
            isTracked: anchor.isTracked,
            palm: (wrist + knuckleCenter) * 0.5,
            thumbTip: world(.thumbTip),
            indexTip: world(.indexFingerTip),
            palmNormal: CoolBasketHandPose.palmNormal(
                forward: world(.middleFingerKnuckle) - wrist, across: indexKnuckle - littleKnuckle, side: side
            ),
            fingerCurl: CoolBasketHandPose.fingerCurl(
                tipDistances: seen.map { simd_length(world($0.tip) - wrist) },
                knuckleDistances: seen.map { simd_length(world($0.knuckle) - wrist) }
            ),
            fingerCurlTracked: seen.count >= 2
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

    /// visionOS plane extents span the extent transform's X-Y plane with the
    /// normal along +Z — the same space `MeshResource.generatePlane(width:
    /// height:)` uses in Apple's plane-visualization sample. (Second device
    /// session confirmed it the hard way: treating anchors as X-Z/+Y turned
    /// every plane sideways and the ball fell through the world; the first
    /// session's floating ball was the unmeasured floor offset plus a chair
    /// seat, not these axes.)
    private static func makePlane(from anchor: PlaneAnchor) -> CoolBasketWorldPlane {
        let extent = anchor.geometry.extent
        let transform = anchor.originFromAnchorTransform * extent.anchorFromExtentTransform
        let center = SIMD3<Float>(
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z
        )
        let tangentU = SIMD3<Float>(
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z
        )
        let tangentV = SIMD3<Float>(
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z
        )
        let normal = SIMD3<Float>(
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z
        )
        return CoolBasketWorldPlane(
            id: anchor.id,
            center: center,
            normal: simd_normalize(normal),
            tangentU: simd_normalize(tangentU),
            tangentV: simd_normalize(tangentV),
            extentU: extent.width * 0.5,
            extentV: extent.height * 0.5,
            isFloor: anchor.classification == .floor
        )
    }

    private func clearTask() {
        lock.withLock { updateTask = nil }
    }
}
#endif
