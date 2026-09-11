//
//  GaussianTwinStateMachine.swift
//  SplatTwin
//
//  The swap's decisions, kept free of scene access so they can be tested on their own.
//

import simd

/// One tick of the swap's state machine. `wantsSwap` is the distance decision for the current
/// state (see `gaussianTwinWantsSwap`), `payloadResident` whether the splat is on the GPU.
struct GaussianTwinStep: Equatable {
    var state: GaussianTwinState
    var progress: Float
}

func gaussianTwinStep(
    state: GaussianTwinState,
    progress: Float,
    wantsSwap: Bool,
    payloadResident: Bool,
    loadFailed: Bool,
    deltaTime: Float,
    duration: Float
) -> GaussianTwinStep {
    let increment = max(0, deltaTime) / max(duration, 0.001)
    switch state {
    case .armed:
        guard wantsSwap, !loadFailed else { return GaussianTwinStep(state: .armed, progress: 0) }
        return GaussianTwinStep(state: payloadResident ? .crossFading : .loading, progress: 0)
    case .loading:
        if loadFailed {
            return GaussianTwinStep(state: .armed, progress: 0)
        }
        guard payloadResident else {
            return GaussianTwinStep(state: .loading, progress: 0)
        }
        return GaussianTwinStep(state: wantsSwap ? .crossFading : .armed, progress: 0)
    case .crossFading, .swapped, .reverting:
        // The splat went away under a running swap (an app dropped it, memory pressure): back to
        // the plain mesh at once, never a colour-off mesh with nothing to show in its place.
        guard payloadResident else { return GaussianTwinStep(state: .armed, progress: 0) }
        switch state {
        case .crossFading:
            guard wantsSwap else { return GaussianTwinStep(state: .reverting, progress: 1 - progress) }
            let next = progress + increment
            return next >= 1 ? GaussianTwinStep(state: .swapped, progress: 1) : GaussianTwinStep(state: .crossFading, progress: next)
        case .swapped:
            return wantsSwap ? GaussianTwinStep(state: .swapped, progress: 1) : GaussianTwinStep(state: .reverting, progress: 0)
        default:
            guard !wantsSwap else { return GaussianTwinStep(state: .crossFading, progress: 1 - progress) }
            let next = progress + increment
            return next >= 1 ? GaussianTwinStep(state: .armed, progress: 0) : GaussianTwinStep(state: .reverting, progress: next)
        }
    }
}

/// Whether the camera is close enough for the splat to stand in for the mesh. Once the swap
/// is under way (loading, fading in or swapped) the threshold grows by the hysteresis so a
/// camera resting on it does not flip the object back and forth. A zero swap distance means
/// the splat is always preferred.
func gaussianTwinWantsSwap(distance: Float, options: GaussianTwinOptions, state: GaussianTwinState) -> Bool {
    guard options.swapDistanceMeters > 0 else { return true }
    switch state {
    case .armed, .reverting:
        return distance <= options.swapDistanceMeters
    case .loading, .crossFading, .swapped:
        return distance <= options.swapDistanceMeters + max(0, options.hysteresisMeters)
    }
}

/// The splat's opacity weight for a twin state and fade progress: hidden while the mesh is
/// shown, ramping through the cross-fades, full once swapped.
func gaussianTwinSplatOpacity(state: GaussianTwinState, progress: Float) -> Float {
    switch state {
    case .armed, .loading: return 0
    case .crossFading: return simd_clamp(progress, 0, 1)
    case .swapped: return 1
    case .reverting: return 1 - simd_clamp(progress, 0, 1)
    }
}
