//
//  CaptureSession.swift
//  CoolMirrorCapture
//

import ARKit
import CoolMirrorMocap
import Foundation
import Observation
import simd

/// Runs ARKit body tracking and streams every tracked body anchor update
/// as a `MocapFrame` to the mirror.
@Observable
@MainActor
final class CaptureSession: NSObject {
    static var isSupported: Bool { ARBodyTrackingConfiguration.isSupported }

    private(set) var status = "starting…"
    private(set) var isTracked = false
    private(set) var framesPerSecond = 0

    let session = ARSession()
    private let sender = MocapSender()
    private var sentTimes: [TimeInterval] = []
    private var statusTimer: Timer?

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard Self.isSupported else {
            status = "unsupported device"
            return
        }
        let configuration = ARBodyTrackingConfiguration()
        configuration.automaticSkeletonScaleEstimationEnabled = true
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        sender.start()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        sender.stop()
        session.pause()
        status = "stopped"
    }

    private func refreshStatus() {
        let now = Date().timeIntervalSinceReferenceDate
        sentTimes.removeAll { now - $0 > 1 }
        framesPerSecond = sentTimes.count
        status = sender.status
    }

    /// Builds the wire frame from the anchor: joint orientations in the
    /// anchor's space, the anchor's own world orientation as `.root` and
    /// its world position.
    nonisolated static func frame(from anchor: ARBodyAnchor, timestamp: TimeInterval) -> MocapFrame {
        let definition = ARSkeletonDefinition.defaultBody3D
        let transforms = anchor.skeleton.jointModelTransforms
        var rotations: [MocapJoint: simd_quatf] = [:]
        for joint in MocapJoint.allCases {
            if joint == .root {
                rotations[.root] = simd_quatf(anchor.transform)
            } else {
                let index = definition.index(for: ARSkeleton.JointName(rawValue: joint.arKitName))
                if index != NSNotFound, index >= 0, index < transforms.count {
                    rotations[joint] = simd_quatf(transforms[index])
                }
            }
        }
        let position = anchor.transform.columns.3
        return MocapFrame(
            sequence: 0,
            timestamp: timestamp,
            isTracked: anchor.isTracked,
            rootPosition: simd_float3(position.x, position.y, position.z),
            rotations: rotations
        )
    }
}

extension CaptureSession: ARSessionDelegate {
    nonisolated func session(_: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let body = anchors.compactMap({ $0 as? ARBodyAnchor }).first else { return }
        let frame = Self.frame(from: body, timestamp: Date().timeIntervalSinceReferenceDate)
        Task { @MainActor in
            self.isTracked = body.isTracked
            self.sender.send(frame)
            self.sentTimes.append(frame.timestamp)
        }
    }

    nonisolated func session(_: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.status = "ARKit failed: \(error.localizedDescription)" }
    }
}
