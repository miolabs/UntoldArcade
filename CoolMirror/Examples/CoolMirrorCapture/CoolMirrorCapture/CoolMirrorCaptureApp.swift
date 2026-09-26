//
//  CoolMirrorCaptureApp.swift
//  CoolMirrorCapture
//
//  Put the iPhone sideways on a stand facing you (ARKit body tracking only
//  works in landscape): it tracks your body and streams the pose over the
//  local network to the CoolMirror visionOS app, which retargets it onto the
//  character in front of you like a mirror.
//

import SwiftUI

@main
struct CoolMirrorCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var capture = CaptureSession()

    var body: some View {
        ZStack(alignment: .bottom) {
            if CaptureSession.isSupported {
                BodyTrackingView(session: capture)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView(
                    "Body tracking not supported",
                    systemImage: "figure.walk.motion",
                    description: Text("This iPhone cannot run ARKit body tracking (needs an A12 chip or newer).")
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(capture.isTracked ? "Body tracked" : "Phone sideways, 3–4 m away, whole body in view", systemImage: capture.isTracked ? "figure.stand" : "figure.walk.motion")
                    .font(.headline)
                Text(capture.status)
                    .font(.footnote)
                Text("\(capture.framesPerSecond) frames/s sent")
                    .font(.footnote.monospacedDigit())
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding()
        }
        .onAppear { capture.start() }
        .onDisappear { capture.stop() }
    }
}
