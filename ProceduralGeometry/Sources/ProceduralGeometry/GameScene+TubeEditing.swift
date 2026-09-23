//
//  GameScene+TubeEditing.swift
//  ProceduralGeometry
//
//  Tap-to-activate, drag-the-endpoints tube editing: a tube has no visible control points at
//  all. Tapping its own mesh arms it for editing (its two endpoints become faintly visible and
//  grabbable); dragging an armed endpoint extends the tube along a locked cardinal axis, adding
//  a 90-degree bend wherever the hand's heading changes.
//
//  All of that turn-detection/axis-locking logic itself lives in
//  ProceduralGeometryExtension.TubeEndpointDrag now, not here — it has no XR dependency of its
//  own, so it's reusable by any consumer of the extension, not just this demo. What's left in
//  this file is purely this demo's own interaction design: which entities represent "grab here"
//  regions, how a tube becomes active, and how that's shown. A different app could make
//  completely different choices here (a gizmo, proximity-based grabbing with no proxy entities
//  at all, a different highlight scheme) while reusing TubeEndpointDrag unchanged.
//
//  Reshaping or removing an existing bend once it's been placed is intentionally out of scope —
//  the prior handle-per-control-point scheme supported it, but that scheme is also what caused
//  the reindexing/desync bugs this rewrite eliminates. With only two proxy entities per tube,
//  ever, there's nothing left to reindex.
//

import simd
import UntoldEngine
import ProceduralGeometryExtension

extension GameScene {
    /// Endpoint proxy spheres are otherwise fully invisible (opacity 0, see
    /// `createTubeEndpointHandles`) — this is how much of them shows once their tube is active,
    /// just enough to signal "grab here" without looking like a permanent control point.
    private static let activeEndpointOpacity: Float = 0.6

    /// Call once per frame with the current tap state. A tap on a tube's own mesh, or on one of
    /// its (otherwise invisible) endpoint proxies, arms that tube for editing; a tap on anything
    /// else — including empty space — disarms whichever tube was previously active.
    func handleTubeTap(pickedEntityId: EntityID?) {
        guard let pickedEntityId else {
            setActiveTube(nil)
            return
        }
        if getEntityComponent(entityId: pickedEntityId, componentType: TubePathComponent.self) != nil {
            setActiveTube(pickedEntityId)
        } else if let handleInfo = tubeEndpointHandles[pickedEntityId] {
            setActiveTube(handleInfo.tubeId)
        } else {
            setActiveTube(nil)
        }
    }

    private func setActiveTube(_ tubeId: EntityID?) {
        guard tubeId != activeTubeId else { return }
        if let previous = activeTubeId, let endpoints = tubeEndpoints[previous] {
            updateMaterialOpacity(entityId: endpoints.startHandleId, opacity: 0)
            updateMaterialOpacity(entityId: endpoints.endHandleId, opacity: 0)
        }
        activeTubeId = tubeId
        if let tubeId, let endpoints = tubeEndpoints[tubeId] {
            updateMaterialOpacity(entityId: endpoints.startHandleId, opacity: Self.activeEndpointOpacity)
            updateMaterialOpacity(entityId: endpoints.endHandleId, opacity: Self.activeEndpointOpacity)
        }
    }

    /// Call when a gesture starts and `pickedEntityId` is one of this tube system's endpoint
    /// proxies. Returns `nil` if that proxy's tube isn't the currently-active one (dragging only
    /// does anything once the tube has been tapped first) — all the actual axis-locking/turn
    /// logic lives in `TubeEndpointDrag.init?` from here on.
    func beginTubeDrag(proxyId: EntityID) -> TubeEndpointDrag? {
        guard let handleInfo = tubeEndpointHandles[proxyId], handleInfo.tubeId == activeTubeId else {
            return nil
        }
        return TubeEndpointDrag(tubeId: handleInfo.tubeId, isStart: handleInfo.isStart)
    }

    /// Call every frame a drag is active, after `SpatialManipulationSystem` has already moved
    /// the proxy for this frame. Feeds the proxy's current position into `TubeEndpointDrag` and
    /// moves the proxy to wherever that reports back — the proxy is purely this demo's own
    /// visual/pickable stand-in for the tip; `TubeEndpointDrag` has no idea it exists.
    func updateEndpointDrag(_ drag: inout TubeEndpointDrag, proxyId: EntityID) {
        let rawPosition = getPosition(entityId: proxyId)
        let constrainedPosition = drag.update(rawPosition: rawPosition)
        translateTo(entityId: proxyId, position: constrainedPosition)
    }

    /// Creates the two invisible-but-pickable endpoint proxies for a newly-created tube and
    /// registers them. These are the *only* entities this editing system ever creates for a
    /// tube — inserting a bend creates no new entity at all, since bends are never individually
    /// grabbed once placed.
    @discardableResult
    func createTubeEndpointHandles(
        tubeId: EntityID,
        startPosition: SIMD3<Float>,
        endPosition: SIMD3<Float>
    ) -> (startHandleId: EntityID, endHandleId: EntityID) {
        let startHandleId = createEndpointProxy(tubeId: tubeId, isStart: true, position: startPosition)
        let endHandleId = createEndpointProxy(tubeId: tubeId, isStart: false, position: endPosition)
        tubeEndpoints[tubeId] = (startHandleId: startHandleId, endHandleId: endHandleId)
        return (startHandleId: startHandleId, endHandleId: endHandleId)
    }

    private func createEndpointProxy(tubeId: EntityID, isStart: Bool, position: SIMD3<Float>) -> EntityID {
        let handleId = createEntity()
        setEntityName(entityId: handleId, name: isStart ? "TubeEndpoint_Start" : "TubeEndpoint_End")
        // Bigger than the tube's own radius so it pokes out on every side and stays pickable,
        // even though it's normally invisible.
        setEntityMeshDirect(
            entityId: handleId,
            meshes: BasicPrimitives.createSphere(extent: 0.08),
            assetName: "TubeEndpointProxy"
        )
        translateTo(entityId: handleId, position: position)
        updateMaterialOpacity(entityId: handleId, opacity: 0)
        tubeEndpointHandles[handleId] = (tubeId: tubeId, isStart: isStart)
        return handleId
    }
}
