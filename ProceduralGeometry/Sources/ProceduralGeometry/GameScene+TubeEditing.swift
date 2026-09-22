//
//  GameScene+TubeEditing.swift
//  ProceduralGeometry
//
//  Axis-constrained, 90-degree-only tube editing: extend an endpoint to add a new bend, or
//  reshape an existing bend by sliding it along one of its two axes. Entirely application-side
//  policy on top of ProceduralGeometryExtension's fully generic API — no engine or extension
//  changes needed for any of this.
//

import simd
import UntoldEngine
import ProceduralGeometryExtension

/// The six world-axis directions every drag snaps to, so every segment this demo creates is
/// exactly axis-aligned and every corner is exactly 90 degrees.
private let cardinalAxes: [SIMD3<Float>] = [
    SIMD3(1, 0, 0), SIMD3(-1, 0, 0),
    SIMD3(0, 1, 0), SIMD3(0, -1, 0),
    SIMD3(0, 0, 1), SIMD3(0, 0, -1),
]

private func nearestCardinalAxis(to direction: SIMD3<Float>) -> SIMD3<Float> {
    guard simd_length(direction) > 1e-6 else { return cardinalAxes[0] }
    let normalized = normalize(direction)
    return cardinalAxes.max { dot(normalized, $0) < dot(normalized, $1) } ?? cardinalAxes[0]
}

/// Dragging control point 0 or the last control point: extends the tube along a locked axis.
/// Whenever the pull direction switches to a different cardinal axis, a new bend point is
/// inserted at the pivot and the lock switches to the new axis — the tube "turns" wherever the
/// user's hand does, always at exactly 90 degrees.
struct EndpointDrag {
    let handleId: EntityID
    let tubeId: EntityID
    /// True if dragging control point 0 (its neighbor is always index 1, and any inserted bend
    /// always lands at index 1 too, since the dragged tip stays at index 0 for the whole drag).
    /// False if dragging the last point (its neighbor is index count-2, and both the insert
    /// index and the dragged tip's own index advance by one with every bend).
    let isStart: Bool
    var neighborPosition: SIMD3<Float>
    var lockedAxis: SIMD3<Float>
    /// Rolling buffer of the most recent raw hand positions (oldest first, capped at
    /// `recentWindowCapacity`). Turn detection reads the vector from the oldest sample to the
    /// newest — the hand's *current heading* — instead of the vector from the segment's fixed
    /// start, so redirecting doesn't get harder the longer the segment already is. Cleared after
    /// every commit, which doubles as the settle time before another commit can fire: the buffer
    /// has to fill back up with fresh motion before a new heading can even be read.
    var recentPositions: [SIMD3<Float>] = []
}

/// Dragging an existing interior bend point: slides it along one of its two existing segment
/// axes (chosen once, from the direction the user first pulls, out of only those two
/// candidates — a middle-point drag reshapes a bend, it doesn't add new ones). Whichever side's
/// axis *isn't* the locked one gets rigidly translated by the same delta as the dragged point,
/// each frame, so that side's direction — and every corner beyond it — never changes. The whole
/// tube stays axis-aligned throughout the drag, not just once you let go.
struct MiddleDrag {
    let handleId: EntityID
    let tubeId: EntityID
    let index: Int
    /// The handle's raw (unconstrained) position at gesture start, and the full control-point
    /// path at that same instant — every frame's result is recomputed fresh from these, rather
    /// than accumulated, so there's no drift over a long drag.
    let dragOrigin: SIMD3<Float>
    let originalControlPoints: [SIMD3<Float>]
    var lockedAxis: SIMD3<Float>?
    /// (back axis: neighbor[index-1] -> point, forward axis: point -> neighbor[index+1]).
    let candidateAxes: (back: SIMD3<Float>, forward: SIMD3<Float>)
}

enum TubeDrag {
    case endpoint(EndpointDrag)
    case middle(MiddleDrag)
}

extension GameScene {
    /// How many recent frames of hand position count as "current heading". Small enough to stay
    /// responsive to a deliberate direction change, large enough to smooth out per-frame
    /// hand-tracking jitter. Also sets the settle time after a commit, in frames.
    private static let recentWindowCapacity = 10
    /// Below this distance across the whole recent window, the heading is too small to read
    /// reliably (hand basically stationary) — a noise floor, not a "how hard is it to turn" knob.
    private static let minimumRecentDragDistance: Float = 0.02
    /// Minimum length, along the *true* fixed anchor, a new segment must already have before a
    /// turn can land there. This is a pure geometry-validity floor, not a turn-sensitivity knob —
    /// `TubeGeometryGenerator`'s parallel-transport frames and tangent-arc corner rounding aren't
    /// stable on a near-zero-length segment, and without this a quick redirect shortly after a
    /// previous commit (or after the drag started) could otherwise land one right next to the
    /// anchor, producing degenerate geometry that silently fails to render.
    private static let minimumSegmentLength: Float = 0.05
    private static let middleDragIntentThreshold: Float = 0.01

    /// Call when a gesture starts and `pickedEntityId` is one of this tube system's handles.
    /// Returns `nil` if the handle's owning entity is missing its `TubePathComponent` (shouldn't
    /// happen for a handle this system created, but this stays a no-op rather than a crash if it
    /// somehow does).
    func beginTubeDrag(handleId: EntityID) -> TubeDrag? {
        guard let handleInfo = tubeControlPointHandles[handleId],
              let component = getEntityComponent(entityId: handleInfo.tubeId, componentType: TubePathComponent.self)
        else {
            return nil
        }

        let count = component.controlPoints.count
        let index = handleInfo.index
        guard index >= 0, index < count else { return nil }

        if index == 0 || index == count - 1 {
            let isStart = index == 0
            let neighborIndex = isStart ? 1 : count - 2
            let neighborPosition = component.controlPoints[neighborIndex]
            let currentPosition = component.controlPoints[index]
            let axis = nearestCardinalAxis(to: currentPosition - neighborPosition)
            return .endpoint(EndpointDrag(
                handleId: handleId,
                tubeId: handleInfo.tubeId,
                isStart: isStart,
                neighborPosition: neighborPosition,
                lockedAxis: axis
            ))
        }

        let backAxis = nearestCardinalAxis(to: component.controlPoints[index] - component.controlPoints[index - 1])
        let forwardAxis = nearestCardinalAxis(to: component.controlPoints[index + 1] - component.controlPoints[index])
        return .middle(MiddleDrag(
            handleId: handleId,
            tubeId: handleInfo.tubeId,
            index: index,
            dragOrigin: getPosition(entityId: handleId),
            originalControlPoints: component.controlPoints,
            lockedAxis: nil,
            candidateAxes: (back: backAxis, forward: forwardAxis)
        ))
    }

    /// Call every frame a drag is active, after `SpatialManipulationSystem` has already moved
    /// the handle for this frame. Returns the (possibly updated) drag state to keep threading
    /// through on subsequent frames.
    func updateTubeDrag(_ drag: TubeDrag) -> TubeDrag {
        switch drag {
        case var .endpoint(endpointDrag):
            updateEndpointDrag(&endpointDrag)
            return .endpoint(endpointDrag)
        case var .middle(middleDrag):
            updateMiddleDrag(&middleDrag)
            return .middle(middleDrag)
        }
    }

    private func updateEndpointDrag(_ drag: inout EndpointDrag) {
        let rawPosition = getPosition(entityId: drag.handleId)

        drag.recentPositions.append(rawPosition)
        if drag.recentPositions.count > Self.recentWindowCapacity {
            drag.recentPositions.removeFirst()
        }

        // Which cardinal axis the hand's *recent* motion is closest to — decoupled from how far
        // the tip has already travelled since the segment's true start, unlike comparing the
        // total delta from that fixed anchor (which makes a long existing extension have
        // ever-growing inertia against turning). `nearestCardinalAxis` still requires genuine
        // dominance within that window — the new axis has to out-vote every other axis,
        // including the currently-locked one — so this isn't just an absolute-distance trigger.
        if drag.recentPositions.count == Self.recentWindowCapacity {
            let recentDelta = rawPosition - drag.recentPositions[0]
            if simd_length(recentDelta) > Self.minimumRecentDragDistance {
                let candidateAxis = nearestCardinalAxis(to: recentDelta)
                if candidateAxis != drag.lockedAxis {
                    let fullDelta = rawPosition - drag.neighborPosition
                    let alongLockedAxis = dot(fullDelta, drag.lockedAxis)
                    if alongLockedAxis > Self.minimumSegmentLength {
                        let bendPosition = drag.neighborPosition + drag.lockedAxis * alongLockedAxis
                        let insertIndex = drag.isStart ? 1 : (tubeControlPointHandles[drag.handleId]?.index ?? 0)

                        if ProceduralGeometryExtension.shared.insertControlPoint(entityId: drag.tubeId, at: insertIndex, bendPosition) {
                            reindexHandles(forTube: drag.tubeId, insertedAtIndex: insertIndex)
                            createControlPointHandle(tubeId: drag.tubeId, index: insertIndex, position: bendPosition)
                            drag.neighborPosition = bendPosition
                            drag.lockedAxis = candidateAxis
                            drag.recentPositions.removeAll(keepingCapacity: true)
                        }
                    }
                }
            }
        }

        let updatedDelta = rawPosition - drag.neighborPosition
        let constrainedPosition = drag.neighborPosition + drag.lockedAxis * dot(updatedDelta, drag.lockedAxis)

        translateTo(entityId: drag.handleId, position: constrainedPosition)
        writeControlPoint(handleId: drag.handleId, position: constrainedPosition)
    }

    private func updateMiddleDrag(_ drag: inout MiddleDrag) {
        let rawPosition = getPosition(entityId: drag.handleId)
        let rawDelta = rawPosition - drag.dragOrigin

        if drag.lockedAxis == nil {
            guard simd_length(rawDelta) > Self.middleDragIntentThreshold else {
                // Not enough movement yet to know which axis the user means — hold in place.
                translateTo(entityId: drag.handleId, position: drag.dragOrigin)
                return
            }
            let normalizedDelta = normalize(rawDelta)
            let (backAxis, forwardAxis) = drag.candidateAxes
            drag.lockedAxis = dot(normalizedDelta, backAxis) >= dot(normalizedDelta, forwardAxis) ? backAxis : forwardAxis
        }

        guard let axis = drag.lockedAxis else { return }
        let delta = axis * dot(rawDelta, axis)
        let isBackSide = axis == drag.candidateAxes.back

        var newControlPoints = drag.originalControlPoints
        newControlPoints[drag.index] = drag.originalControlPoints[drag.index] + delta

        // Whichever side's axis we did NOT lock onto needs its whole chain shifted by the same
        // delta to keep its direction (and everything beyond it) unchanged — see
        // GameScene+TubeEditing.swift's MiddleDrag doc comment for why this is required, not
        // just a nice-to-have.
        if isBackSide {
            for index in (drag.index + 1) ..< newControlPoints.count {
                newControlPoints[index] = drag.originalControlPoints[index] + delta
            }
        } else {
            for index in 0 ..< drag.index {
                newControlPoints[index] = drag.originalControlPoints[index] + delta
            }
        }

        ProceduralGeometryExtension.shared.setControlPoints(entityId: drag.tubeId, newControlPoints)

        for (handleId, info) in tubeControlPointHandles where info.tubeId == drag.tubeId {
            translateTo(entityId: handleId, position: newControlPoints[info.index])
        }
    }

    /// Writes `position` into the owning tube's control-point array at this handle's current
    /// index and pushes the update to the extension. Endpoint drags only ever move their own
    /// single point (the shared chain-shift logic above is middle-drag-only), so this is enough
    /// for them on its own.
    private func writeControlPoint(handleId: EntityID, position: SIMD3<Float>) {
        guard let handleInfo = tubeControlPointHandles[handleId],
              let component = getEntityComponent(entityId: handleInfo.tubeId, componentType: TubePathComponent.self),
              handleInfo.index < component.controlPoints.count
        else {
            return
        }
        var controlPoints = component.controlPoints
        controlPoints[handleInfo.index] = position
        ProceduralGeometryExtension.shared.setControlPoints(entityId: handleInfo.tubeId, controlPoints)
    }

    /// Bumps the index of every handle for `tubeId` at or after `insertedAtIndex` by one, to
    /// match `TubePathComponent.controlPoints.insert(at: insertedAtIndex, ...)` having just
    /// shifted everything from that point on.
    private func reindexHandles(forTube tubeId: EntityID, insertedAtIndex: Int) {
        for (handleId, info) in tubeControlPointHandles
            where info.tubeId == tubeId && info.index >= insertedAtIndex
        {
            tubeControlPointHandles[handleId] = (tubeId: tubeId, index: info.index + 1)
        }
    }

    /// Creates a pickable handle sphere for one control point and registers it. Shared by the
    /// initial demo-tube setup and by newly-inserted bend points from an endpoint drag.
    @discardableResult
    func createControlPointHandle(tubeId: EntityID, index: Int, position: SIMD3<Float>) -> EntityID {
        let handleId = createEntity()
        setEntityName(entityId: handleId, name: "TubeHandle_\(index)")
        // Handle radius (0.04) is deliberately larger than the tube radius (0.03): each handle
        // sits at a control point, which is on the tube's own centerline, so a handle no bigger
        // than the tube would be fully enclosed inside it — invisible, and unpickable, since the
        // tube's own (closer) surface blocks the ray before it reaches the inner handle. Making
        // the handle bigger than the tube it's on lets it poke out on every side.
        setEntityMeshDirect(
            entityId: handleId,
            meshes: BasicPrimitives.createSphere(extent: 0.08),
            assetName: "TubeHandle"
        )
        translateTo(entityId: handleId, position: position)
        tubeControlPointHandles[handleId] = (tubeId: tubeId, index: index)
        return handleId
    }
}
