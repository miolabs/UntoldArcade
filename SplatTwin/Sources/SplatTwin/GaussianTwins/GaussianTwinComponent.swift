//
//  GaussianTwinComponent.swift
//  SplatTwin
//
//  A mesh entity linked to the captured Gaussian-splat twin that stands in for it up close.
//

import Foundation
import UntoldEngine

/// Where a mesh entity with a captured splat twin stands in the swap.
enum GaussianTwinState: Int, Sendable, Equatable {
    /// The mesh is drawn as usual; the splat is not shown (it may or may not be resident).
    case armed
    /// The splat payload is being read; nothing changes on screen until it is resident.
    case loading
    /// The mesh colour dithers out while the splat's opacity ramps in, over `crossFadeDuration`.
    case crossFading
    /// The splat is shown. The mesh keeps writing depth (as a shrunk shell), shadows and physics.
    case swapped
    /// The reverse fade: the mesh dithers back in while the splat ramps out.
    case reverting
}

/// Per-entity settings of the mesh-to-splat swap. Seeded from a scene's `gaussianAsset` record
/// (`GaussianAssetLinkComponent`) when the twin comes from a `.untold` file.
struct GaussianTwinOptions: Sendable, Equatable {
    /// Camera distance to the mesh's bounds centre below which the swap arms and runs;
    /// 0 swaps at any distance.
    var swapDistanceMeters: Float
    /// Added to `swapDistanceMeters` before the swap reverts, so a camera hovering at the
    /// threshold does not flip the object back and forth.
    var hysteresisMeters: Float
    /// Length of the cross-fade in seconds (wall-clock), both ways.
    var crossFadeDuration: Float
    /// Metres the depth-only occluder shell is shrunk along the mesh normals while the splat
    /// is shown, so splats on and just outside the surface are not hidden by their own mesh.
    var occluderShrinkMeters: Float
    /// Exposure offset in EV applied to the splat on top of its capture exposure.
    var exposureOffsetEV: Float
    /// In XR, tint the splat by the real-world lighting estimate (`GaussianComponent.useRealWorldTint`).
    var useRealWorldTint: Bool
    /// Where the splat sits in the mesh's local space (`GaussianComponent.splatToEntity` =
    /// `alignment.matrix`: offset, yaw about +Y, uniform scale), applied to the resident splat
    /// every tick so an edit shows at once; nil is identity.
    var alignment: GaussianSplatAlignment?
    /// Authoring aid: while the splat shows (cross-fading, swapped, reverting), keep drawing
    /// the mesh's colour, install no occluder shell and never dither the mesh, so the mesh and
    /// the splat are both visible at once and `alignment` can be judged against the surface
    /// it should sit on (an editor's align mode). The swap becomes a plain splat fade-in over
    /// an untouched mesh; the splat still swaps in by distance and follows `alignment`. A
    /// revert that starts from a plain mesh (the flag cleared as the camera leaves) keeps it
    /// plain and only fades the splat out. Not meant for shipping content.
    var showsMeshWhileSwapped: Bool

    init(
        swapDistanceMeters: Float = 0,
        hysteresisMeters: Float = 0.5,
        crossFadeDuration: Float = 0.25,
        occluderShrinkMeters: Float = 0.02,
        exposureOffsetEV: Float = 0,
        useRealWorldTint: Bool = false,
        alignment: GaussianSplatAlignment? = nil,
        showsMeshWhileSwapped: Bool = false
    ) {
        self.swapDistanceMeters = swapDistanceMeters
        self.hysteresisMeters = hysteresisMeters
        self.crossFadeDuration = crossFadeDuration
        self.occluderShrinkMeters = occluderShrinkMeters
        self.exposureOffsetEV = exposureOffsetEV
        self.useRealWorldTint = useRealWorldTint
        self.alignment = alignment
        self.showsMeshWhileSwapped = showsMeshWhileSwapped
    }

    /// The options a scene's `gaussianAsset` record asks for.
    init(link: GaussianAssetLinkComponent) {
        self.init(
            swapDistanceMeters: link.swapDistanceMeters,
            occluderShrinkMeters: link.occluderShrinkMeters,
            exposureOffsetEV: link.exposureOffsetEV,
            alignment: link.alignment
        )
    }
}

/// Links a mesh entity to the captured splat that stands in for it up close. `GaussianTwinSystem`
/// loads the payload onto the same entity, cross-fades the two through the engine's
/// `MeshFadeComponent` and `GaussianComponent.opacityScale`, and keeps the mesh's depth through a
/// `MeshOccluderComponent` while the splat is shown. Attached by `setEntityGaussianTwin`, or
/// adopted from a `.untold` scene's `GaussianAssetLinkComponent` flagged `meshTwin`. A splat
/// already on the entity when the twin is linked becomes its payload (hidden until the swap; its
/// exposure offset and tint follow the twin's options). The twin owns the entity's
/// `MeshOccluderComponent` and `MeshFadeComponent` while linked.
final class GaussianTwinComponent: Component {
    /// The `.untoldgs` (or `.ply`) file loaded when the swap arms. Change it through
    /// `setEntityGaussianTwin`, which drops the previous payload and restarts the swap.
    var payloadURL: URL?
    /// Read every tick; may be adjusted at any time.
    var options = GaussianTwinOptions()
    var state: GaussianTwinState = .armed
    /// 0...1 progress of the running cross-fade (`.crossFading` and `.reverting` only).
    var fadeProgress: Float = 0
    /// Set once a payload load has failed; the swap then stays armed and does not retry.
    var loadFailed = false
    /// Whether the last presentation drew the plain mesh under a showing splat
    /// (`GaussianTwinOptions.showsMeshWhileSwapped`). A fade that starts from that keeps the
    /// mesh plain: dithering a fully drawn mesh from nothing would be a visible pop.
    var meshKeptPlain = false

    /// Bumped on every link, relink and unlink; a load applies only if it still matches.
    var loadGeneration: UInt32 = 0
    var loadTask: Task<Void, Never>?

    required init() {}
}
