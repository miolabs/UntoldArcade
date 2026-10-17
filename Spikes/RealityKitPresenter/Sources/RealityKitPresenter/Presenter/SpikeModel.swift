//
//  SpikeModel.swift
//  RealityKitPresenter spike
//
//  The switches of the control window and the state the app shares between the window,
//  the immersive space and the SharePlay controller. Main actor; the render thread only
//  ever sees a RenderSettingsSnapshot copied into its ticket.
//

import Foundation
import Observation
import SwiftUI

enum TextureRoute: String, CaseIterable, Identifiable {
    /// visionOS 2: `LowLevelTexture.replace(using:)` once per frame on the main thread.
    case replace
    /// visionOS 27: `LowLevelDeviceResource(textureDescriptor:iosurface:plane:)` over IOSurfaces
    /// we allocate, two per eye, the LowLevelTexture pointed at the next one every frame with
    /// `replace(deviceResource:using:)`. Runs on the device and in the simulator.
    case deviceResource
    /// visionOS 27, device only: Metal shared textures through
    /// `LowLevelDeviceResource(sharedTextureHandle:)`, the plan's D2 fallback as written (the
    /// simulator SDK marks `makeSharedTexture` unavailable; the device SDK has it).
    case sharedHandle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .replace: return "replace(using:)"
        case .deviceResource: return "IOSurface resource (27)"
        case .sharedHandle: return "Shared handle (27, device)"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .replace:
            return true
        case .deviceResource:
            if #available(visionOS 27, *) { return true } else { return false }
        case .sharedHandle:
            #if targetEnvironment(simulator)
            return false
            #else
            if #available(visionOS 27, *) { return true } else { return false }
            #endif
        }
    }
}

enum PatternMode: Int, CaseIterable, Identifiable {
    /// The synthetic scene (floor, wall with a hole, sky) stays put in the world.
    case worldLocked = 0
    /// A plane in front of the eye with an angular checker: swim here means the lead is off.
    case headLocked = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .worldLocked: return "World-locked"
        case .headLocked: return "Head-locked"
        }
    }
}

/// What the render thread needs from the switches, copied into every ticket.
struct RenderSettingsSnapshot: Sendable {
    var pattern: PatternMode
    var passthroughSky: Bool
    var showOverlays: Bool
    var headLockedDistance: Float
    var farShell: Float
    var tearThreshold: Float
    var interpupillaryDistance: Float
}

@Observable
@MainActor
final class SpikeModel {
    // MARK: Switches

    var route: TextureRoute = .replace
    /// The lead in refresh periods: the ticket's target time is its post time plus this.
    var leadPeriods: Double = 2.0
    var fullImmersion = false {
        didSet { immersionSelection = fullImmersion ? .full : .mixed }
    }
    var pattern: PatternMode = .worldLocked
    var showAnchorMarkers = false
    var passthroughSky = true
    var showOverlays = true
    var refreshRate: Double = 90
    var interpupillaryDistanceMillimetres: Double = 63
    var headLockedDistance: Double = 2.0
    var farShell: Double = 100
    var tearThreshold: Double = 0.3
    /// Whether the grids are rewritten every ticket (the kernel and replace(bufferIndex:using:)).
    /// Off isolates the texture hand-off cost; the grids keep their last positions.
    var updateGrids = true
    /// 1: the headset's per-eye drawable size (D5 of the plan); 2: half of it per side.
    var textureDivisor = 1
    var textureWidth: Int { 1920 / textureDivisor }
    var textureHeight: Int { 1824 / textureDivisor }

    // MARK: State

    var immersionSelection: any ImmersionStyle = .mixed
    var spaceOpen = false

    let stats = SpikeStatsStore()
    let counters = SpikeCounters()
    let session = PresenterSessionController()

    var leadSeconds: Double { leadPeriods / refreshRate }

    /// `--open-space` on the command line opens the immersive space at launch, `--hide-window`
    /// then closes the control window (simulator screenshots).
    var opensSpaceAtLaunch: Bool { CommandLine.arguments.contains("--open-space") }
    var hidesWindowAtLaunch: Bool { CommandLine.arguments.contains("--hide-window") }

    func snapshot() -> RenderSettingsSnapshot {
        RenderSettingsSnapshot(
            pattern: pattern,
            passthroughSky: passthroughSky,
            showOverlays: showOverlays,
            headLockedDistance: Float(headLockedDistance),
            farShell: Float(farShell),
            tearThreshold: Float(tearThreshold),
            interpupillaryDistance: Float(interpupillaryDistanceMillimetres / 1000)
        )
    }
}
