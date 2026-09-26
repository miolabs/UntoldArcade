//
//  BodyTrackingView.swift
//  CoolMirrorCapture
//

import ARKit
import RealityKit
import SwiftUI

/// Camera preview running the capture session (no virtual content; the
/// character is drawn on the Vision Pro).
struct BodyTrackingView: UIViewRepresentable {
    let session: CaptureSession

    func makeUIView(context _: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session.session
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion, .disableGroundingShadows]
        return view
    }

    func updateUIView(_: ARView, context _: Context) {}
}
