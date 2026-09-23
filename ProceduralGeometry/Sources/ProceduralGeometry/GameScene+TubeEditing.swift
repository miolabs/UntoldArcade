//
//  GameScene+TubeEditing.swift
//  ProceduralGeometry
//
//  Tap-to-activate tube editing: a tube has no visible control points until tapped. Tapping its
//  own mesh arms it for editing — its two endpoints, and every existing interior bend, become
//  faintly visible and grabbable. Dragging an endpoint extends the tube along a locked cardinal
//  axis, adding a 90-degree bend wherever the hand's heading changes. Dragging an existing bend
//  slides it along one of its two existing axes; dragging it far enough to collapse a segment
//  removes it, reconnecting its neighbors — the same "drag through it" language as reversing an
//  endpoint drag past a bend it just created.
//
//  All of that logic — turn-detection, axis-locking, collapse-to-remove — lives in
//  ProceduralGeometryExtension (TubeEndpointDrag, TubeInteriorBendDrag) now, not here; neither
//  type has any XR dependency of its own, so both are reusable by any consumer of the extension,
//  not just this demo. What's left in this file is purely this demo's own interaction design:
//  which entities represent "grab here" regions, how a tube becomes active, and how that's shown.
//
//  Interior-bend proxies only ever exist while their tube is active, and are always wholesale
//  regenerated from the tube's current control points (never incrementally reindexed) whenever a
//  drag concludes — the same lesson the endpoint-proxy rewrite already applied: don't track
//  indices by hand, just rebuild from the live array on the rare discrete events where topology
//  actually changes.
//

import simd
import UntoldEngine
import ProceduralGeometryExtension

/// Which kind of tube drag is in progress, paired with the proxy entity driving it — neither
/// `TubeEndpointDrag` nor `TubeInteriorBendDrag` knows proxy entities exist, so this demo tracks
/// that pairing itself.
enum ActiveTubeDrag {
    case endpoint(TubeEndpointDrag, proxyId: EntityID)
    case interiorBend(TubeInteriorBendDrag, proxyId: EntityID)

    var tubeId: EntityID {
        switch self {
        case let .endpoint(drag, _): drag.tubeId
        case let .interiorBend(drag, _): drag.tubeId
        }
    }
}

extension GameScene {
    /// Endpoint and interior-bend proxy spheres are otherwise fully invisible (opacity 0) — this
    /// is how much of them shows once their tube is active, just enough to signal "grab here"
    /// without looking like permanent control points.
    private static let activeProxyOpacity: Float = 0.6

    /// Call once per frame with the current tap state. A tap on a tube's own mesh, or on one of
    /// its (otherwise invisible) endpoint/bend proxies, arms that tube for editing; a tap on
    /// anything else — including empty space — disarms whichever tube was previously active.
    func handleTubeTap(pickedEntityId: EntityID?) {
        guard let pickedEntityId else {
            setActiveTube(nil)
            return
        }
        if getEntityComponent(entityId: pickedEntityId, componentType: TubePathComponent.self) != nil {
            setActiveTube(pickedEntityId)
        } else if let handleInfo = tubeEndpointHandles[pickedEntityId] {
            setActiveTube(handleInfo.tubeId)
        } else if let handleInfo = tubeInteriorBendHandles[pickedEntityId] {
            setActiveTube(handleInfo.tubeId)
        } else {
            setActiveTube(nil)
        }
    }

    private func setActiveTube(_ tubeId: EntityID?) {
        guard tubeId != activeTubeId else { return }
        if let previous = activeTubeId {
            if let endpoints = tubeEndpoints[previous] {
                updateMaterialOpacity(entityId: endpoints.startHandleId, opacity: 0)
                updateMaterialOpacity(entityId: endpoints.endHandleId, opacity: 0)
            }
            destroyInteriorBendProxies(tubeId: previous)
        }
        activeTubeId = tubeId
        if let tubeId {
            if let endpoints = tubeEndpoints[tubeId] {
                updateMaterialOpacity(entityId: endpoints.startHandleId, opacity: Self.activeProxyOpacity)
                updateMaterialOpacity(entityId: endpoints.endHandleId, opacity: Self.activeProxyOpacity)
            }
            regenerateInteriorBendProxies(tubeId: tubeId)
        }
    }

    /// Call when a gesture starts and `pickedEntityId` is one of this tube system's proxies.
    /// Returns `nil` if that proxy's tube isn't the currently-active one (dragging only does
    /// anything once the tube has been tapped first) — all the actual editing logic lives in
    /// `TubeEndpointDrag`/`TubeInteriorBendDrag`'s own initializers from here on.
    func beginTubeDrag(proxyId: EntityID) -> ActiveTubeDrag? {
        if let handleInfo = tubeEndpointHandles[proxyId], handleInfo.tubeId == activeTubeId {
            return TubeEndpointDrag(tubeId: handleInfo.tubeId, isStart: handleInfo.isStart)
                .map { .endpoint($0, proxyId: proxyId) }
        }
        if let handleInfo = tubeInteriorBendHandles[proxyId], handleInfo.tubeId == activeTubeId {
            return TubeInteriorBendDrag(tubeId: handleInfo.tubeId, index: handleInfo.index)
                .map { .interiorBend($0, proxyId: proxyId) }
        }
        return nil
    }

    /// Call every frame a drag is active, after `SpatialManipulationSystem` has already moved the
    /// proxy for this frame. Feeds the proxy's current position into whichever drag type is
    /// active and moves the proxy to wherever that reports back.
    ///
    /// Returns `false` once an interior-bend drag has removed its own bend — the caller should
    /// stop calling this for the rest of the gesture (there's nothing left to represent, and
    /// `TubeInteriorBendDrag` doesn't guard against being called again with a now-stale control
    /// point array), but should keep pumping `SpatialManipulationSystem`'s lifecycle through to
    /// the gesture's real end regardless, same as any other drag.
    ///
    /// `isGestureEnding` must be true on (and only on) the gesture's final `.ended`/`.cancelled`
    /// frame — see `TubeEndpointDrag.end`/`TubeInteriorBendDrag.end` for why that frame needs
    /// different handling than every other frame of the drag.
    @discardableResult
    func updateActiveDrag(_ drag: inout ActiveTubeDrag, isGestureEnding: Bool) -> Bool {
        switch drag {
        case .endpoint(var endpointDrag, let proxyId):
            let rawPosition = getPosition(entityId: proxyId)
            let position = isGestureEnding ? endpointDrag.end(rawPosition: rawPosition) : endpointDrag.update(rawPosition: rawPosition)
            translateTo(entityId: proxyId, position: position)
            drag = .endpoint(endpointDrag, proxyId: proxyId)
            return true

        case .interiorBend(var bendDrag, let proxyId):
            let rawPosition = getPosition(entityId: proxyId)
            if isGestureEnding {
                let position = bendDrag.end(rawPosition: rawPosition)
                translateTo(entityId: proxyId, position: position)
                drag = .interiorBend(bendDrag, proxyId: proxyId)
                return true
            }
            guard let position = bendDrag.update(rawPosition: rawPosition) else {
                return false // this bend just collapsed — nothing left to move
            }
            translateTo(entityId: proxyId, position: position)
            drag = .interiorBend(bendDrag, proxyId: proxyId)
            return true
        }
    }

    /// Keeps both endpoint proxies visually attached to the tube's actual current start/end
    /// control points. An interior-bend drag can rigidly shift one whole side of the tube —
    /// including an endpoint — to keep that side's direction unchanged (see
    /// `TubeInteriorBendDrag`); without this, the endpoint proxy — a separate entity with its own
    /// transform, otherwise only ever moved by its own drag — would stay wherever it last was,
    /// visually detaching from the tube until its own drag was started again (which re-anchors it
    /// from the tube's true geometry, masking the problem rather than avoiding it). Call every
    /// frame any drag is active, not just interior-bend drags — cheap, and removes any risk of
    /// missing a future case that also shifts an endpoint indirectly.
    func syncEndpointProxies(tubeId: EntityID) {
        guard let component = getEntityComponent(entityId: tubeId, componentType: TubePathComponent.self),
              let endpoints = tubeEndpoints[tubeId],
              let start = component.controlPoints.first,
              let end = component.controlPoints.last
        else {
            return
        }
        translateTo(entityId: endpoints.startHandleId, position: start)
        translateTo(entityId: endpoints.endHandleId, position: end)
    }

    /// Creates the two invisible-but-pickable endpoint proxies for a newly-created tube and
    /// registers them.
    @discardableResult
    func createTubeEndpointHandles(
        tubeId: EntityID,
        startPosition: SIMD3<Float>,
        endPosition: SIMD3<Float>
    ) -> (startHandleId: EntityID, endHandleId: EntityID) {
        let startHandleId = createProxy(tubeId: tubeId, name: "TubeEndpoint_Start", position: startPosition)
        let endHandleId = createProxy(tubeId: tubeId, name: "TubeEndpoint_End", position: endPosition)
        tubeEndpointHandles[startHandleId] = (tubeId: tubeId, isStart: true)
        tubeEndpointHandles[endHandleId] = (tubeId: tubeId, isStart: false)
        tubeEndpoints[tubeId] = (startHandleId: startHandleId, endHandleId: endHandleId)
        return (startHandleId: startHandleId, endHandleId: endHandleId)
    }

    /// Destroys and recreates every interior-bend proxy for `tubeId` from its current control
    /// points. Called whenever a drag concludes (never mid-drag — nothing needs to pick a new
    /// bend to grab until the current gesture is over anyway) and whenever a tube becomes active.
    func regenerateInteriorBendProxies(tubeId: EntityID) {
        destroyInteriorBendProxies(tubeId: tubeId)
        guard let component = getEntityComponent(entityId: tubeId, componentType: TubePathComponent.self) else {
            return
        }
        let count = component.controlPoints.count
        guard count > 2 else { return }

        var proxies: [EntityID] = []
        for index in 1 ..< (count - 1) {
            let proxyId = createProxy(tubeId: tubeId, name: "TubeBend_\(index)", position: component.controlPoints[index])
            // Left fully invisible (createProxy's default) even while active — only the two
            // endpoints get a visible affordance; existing bends stay grabbable (opacity doesn't
            // affect picking) but aren't shown as dots.
            tubeInteriorBendHandles[proxyId] = (tubeId: tubeId, index: index)
            proxies.append(proxyId)
        }
        tubeInteriorProxies[tubeId] = proxies
    }

    private func destroyInteriorBendProxies(tubeId: EntityID) {
        for proxyId in tubeInteriorProxies[tubeId] ?? [] {
            tubeInteriorBendHandles.removeValue(forKey: proxyId)
            destroyEntity(entityId: proxyId)
        }
        tubeInteriorProxies[tubeId] = nil
    }

    private func createProxy(tubeId: EntityID, name: String, position: SIMD3<Float>) -> EntityID {
        let handleId = createEntity()
        setEntityName(entityId: handleId, name: name)
        // Bigger than the tube's own radius so it pokes out on every side and stays pickable,
        // even when invisible.
        setEntityMeshDirect(
            entityId: handleId,
            meshes: BasicPrimitives.createSphere(extent: 0.08),
            assetName: "TubeProxy"
        )
        translateTo(entityId: handleId, position: position)
        updateMaterialOpacity(entityId: handleId, opacity: 0)
        return handleId
    }
}
