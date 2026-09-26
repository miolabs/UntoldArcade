//
//  CaptureSession.swift
//  CoolMirrorCapture
//

import ARKit
import CoolMirrorMocap
import Foundation
import Observation
import simd
import UIKit

/// Runs ARKit body tracking and streams every tracked body anchor update
/// as a `MocapFrame` to the mirror. Also projects the tracked skeleton onto
/// the camera preview so a screen recording of the phone shows the raw
/// tracking over the real body.
@Observable
@MainActor
final class CaptureSession: NSObject {
    static var isSupported: Bool { ARBodyTrackingConfiguration.isSupported }

    private(set) var status = "starting…"
    private(set) var isTracked = false
    private(set) var framesPerSecond = 0
    private(set) var trackedJointCount = 0
    private(set) var videoFormat = ""
    /// Raw motion between consecutive frames (see `MocapJitterMeter`).
    private(set) var jitterReport = ""
    /// Flip count since the last reset, to read after stepping out of view.
    private(set) var flipTotals = ""

    /// Skeleton overlay: joints projected into the preview view, in points.
    var showSkeleton = true
    private(set) var overlayPoints: [MocapJoint: CGPoint] = [:]
    private(set) var overlayTracked: Set<MocapJoint> = []
    /// Camera frame rate to ask for (the tracker runs at the camera rate; a
    /// lower rate gives each frame more exposure).
    var preferredFrameRate = 60 {
        didSet { if preferredFrameRate != oldValue, isRunning { start() } }
    }

    private var isRunning = false
    /// Set by the preview view from its layout.
    var viewportSize = CGSize.zero
    var interfaceOrientation: UIInterfaceOrientation = .landscapeRight

    let session = ARSession()
    private let sender = MocapSender()
    private var sentTimes: [TimeInterval] = []
    private var statusTimer: Timer?
    private var jitter = MocapJitterMeter()

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
        // Body tracking only: nothing else competes for the frame (the
        // frame semantics stay at their default, .bodyDetection, which the
        // 3D tracker relies on).
        configuration.planeDetection = []
        configuration.environmentTexturing = .none
        // The largest format at the requested rate (or the nearest rate
        // the device offers).
        let formats = ARBodyTrackingConfiguration.supportedVideoFormats
        let rates = Set(formats.map(\.framesPerSecond))
        let rate = rates.min { abs($0 - preferredFrameRate) < abs($1 - preferredFrameRate) } ?? preferredFrameRate
        if let format = formats.filter({ $0.framesPerSecond == rate }).max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
            configuration.videoFormat = format
        }
        videoFormat = "\(Int(configuration.videoFormat.imageResolution.width))×\(Int(configuration.videoFormat.imageResolution.height)) @ \(configuration.videoFormat.framesPerSecond) fps"
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        if !sender.isConnected {
            sender.start()
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        sender.stop()
        session.pause()
        isRunning = false
        status = "stopped"
    }

    private func refreshStatus() {
        let now = Date().timeIntervalSinceReferenceDate
        sentTimes.removeAll { now - $0 > 1 }
        framesPerSecond = sentTimes.count
        status = sender.status
        jitterReport = jitter.report
        flipTotals = jitter.totals
    }

    func resetCounters() {
        jitter.reset()
        flipTotals = jitter.totals
    }

    /// Builds the wire frame from the anchor: joint transforms in the
    /// anchor's space, the anchor's own world orientation as `.root`, its
    /// world position and which joints ARKit actually saw.
    nonisolated static func frame(from anchor: ARBodyAnchor, timestamp: TimeInterval) -> MocapFrame {
        let definition = ARSkeletonDefinition.defaultBody3D
        let skeleton = anchor.skeleton
        let transforms = skeleton.jointModelTransforms
        var rotations: [MocapJoint: simd_quatf] = [:]
        var positions: [MocapJoint: simd_float3] = [:]
        var tracked: Set<MocapJoint> = []
        for joint in MocapJoint.allCases {
            if joint == .root {
                rotations[.root] = simd_quatf(anchor.transform)
                positions[.root] = .zero
                tracked.insert(.root)
            } else {
                let index = definition.index(for: ARSkeleton.JointName(rawValue: joint.arKitName))
                if index != NSNotFound, index >= 0, index < transforms.count {
                    let transform = transforms[index]
                    rotations[joint] = simd_quatf(transform)
                    positions[joint] = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                    if skeleton.isJointTracked(index) {
                        tracked.insert(joint)
                    }
                }
            }
        }
        let position = anchor.transform.columns.3
        return MocapFrame(
            sequence: 0,
            timestamp: timestamp,
            isTracked: anchor.isTracked,
            rootPosition: simd_float3(position.x, position.y, position.z),
            rotations: rotations,
            positions: positions,
            trackedJoints: tracked
        )
    }

    /// Projects the body's joints into the preview for the overlay.
    private func updateOverlay(camera: ARCamera, body: ARBodyAnchor, frame: MocapFrame) {
        guard showSkeleton, viewportSize.width > 0 else {
            overlayPoints = [:]
            return
        }
        var points: [MocapJoint: CGPoint] = [:]
        for (joint, position) in frame.positions {
            let world = body.transform * simd_float4(position, 1)
            let point = camera.projectPoint(
                simd_float3(world.x, world.y, world.z), orientation: interfaceOrientation, viewportSize: viewportSize
            )
            if point.x.isFinite, point.y.isFinite {
                points[joint] = point
            }
        }
        overlayPoints = points
        overlayTracked = frame.trackedJoints
    }
}

extension CaptureSession: ARSessionDelegate {
    nonisolated func session(_: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let body = anchors.compactMap({ $0 as? ARBodyAnchor }).first else { return }
        let timestamp = Date().timeIntervalSinceReferenceDate
        var frame = Self.frame(from: body, timestamp: timestamp)
        Task { @MainActor in
            self.isTracked = body.isTracked
            self.trackedJointCount = frame.trackedJoints.count
            self.sender.send(frame)
            self.sentTimes.append(frame.timestamp)
            // The sender assigns sequence numbers; the meter only needs
            // successive frames to differ.
            frame.sequence = UInt32(truncatingIfNeeded: self.sentTimes.count) &+ UInt32(truncatingIfNeeded: Int(timestamp * 1000))
            self.jitter.add(frame, at: timestamp)
            if let camera = self.session.currentFrame?.camera {
                self.updateOverlay(camera: camera, body: body, frame: frame)
            }
        }
    }

    nonisolated func session(_: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.status = "ARKit failed: \(error.localizedDescription)" }
    }
}
