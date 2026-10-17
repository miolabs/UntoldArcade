//
//  RealityKitPresenterApp.swift
//  RealityKitPresenter spike
//
//  Stage 0 of docs/proposals/XRRealityKitPresenter.md (engine repo): a control window
//  with the switches and the numbers, and an immersive space whose RealityView shows two
//  LowLevelMesh grids textured from a Metal render pass of our own.
//

import SwiftUI

@main
struct RealityKitPresenterApp: App {
    @State private var model = SpikeModel()

    var body: some Scene {
        WindowGroup(id: "control") {
            ControlWindowView(model: model)
        }
        .defaultSize(width: 620, height: 820)

        ImmersiveSpace(id: "presenter") {
            PresenterImmersiveView(model: model)
        }
        .immersionStyle(selection: $model.immersionSelection, in: .mixed, .full)
    }
}
