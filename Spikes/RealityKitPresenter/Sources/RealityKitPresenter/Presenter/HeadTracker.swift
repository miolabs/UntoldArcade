//
//  HeadTracker.swift
//  RealityKitPresenter spike
//
//  An ARKit session with a WorldTrackingProvider of our own, as the engine's XR runtime
//  has. The render thread asks for the device pose at the ticket's target time; the
//  fallbacks are the engine's (retry at "now", then the cached pose).
//

import ARKit
import Foundation
import QuartzCore
import simd

final class HeadTracker: @unchecked Sendable {
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let lock = NSLock()
    private var cachedPose: simd_float4x4?
    private var runTask: Task<Void, Never>?
    private(set) var startError: String?

    var isSupported: Bool { WorldTrackingProvider.isSupported }

    var stateDescription: String {
        switch worldTracking.state {
        case .initialized: return "initialized"
        case .running: return "running"
        case .paused: return "paused"
        case .stopped: return "stopped"
        @unknown default: return "unknown"
        }
    }

    func start(onStatus: @escaping @Sendable (String) -> Void) {
        guard runTask == nil else { return }
        runTask = Task { [session, worldTracking] in
            do {
                try await session.run([worldTracking])
                onStatus("ARKit session running (world tracking)")
            } catch {
                onStatus("ARKit session failed: \(error)")
            }
        }
    }

    func stop() {
        session.stop()
        runTask?.cancel()
        runTask = nil
    }

    /// originFromDevice for the time, with the source it came from.
    func originFromDevice(at time: TimeInterval) -> (pose: simd_float4x4?, source: AnchorSource) {
        guard worldTracking.state == .running else {
            return (cached(), cachedPose == nil ? .missing : .cached)
        }
        if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: time), anchor.isTracked {
            remember(anchor.originFromAnchorTransform)
            return (anchor.originFromAnchorTransform, .predicted)
        }
        if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked {
            remember(anchor.originFromAnchorTransform)
            return (anchor.originFromAnchorTransform, .retried)
        }
        let pose = cached()
        return (pose, pose == nil ? .missing : .cached)
    }

    private func remember(_ pose: simd_float4x4) {
        lock.lock(); cachedPose = pose; lock.unlock()
    }

    private func cached() -> simd_float4x4? {
        lock.lock(); defer { lock.unlock() }
        return cachedPose
    }
}
