# ProceduralGeometry

visionOS demo for UntoldEngine's `ProceduralGeometryExtension`: generate a tube from a list of 3D control points, then drag those points live in XR.

## Dependencies

Configured in `project.yml` as **local path** dependencies (testing only — not remote yet):

- `UntoldEngine` — pinned to branch `feature/procedural_geom_helper`. Needs to stay on this branch (or a later one that includes it) since it has the APIs this demo depends on. Not yet on `develop`.
- `ProceduralGeometryExtension` — no remote at all yet, local checkout only.

If you edit `project.yml`, regenerate the Xcode project:

```
xcodegen generate
```

## Build & Run

Open `ProceduralGeometry.xcodeproj` in Xcode, pick a visionOS simulator, and run. Or from the command line:

```
xcodebuild -project ProceduralGeometry.xcodeproj -scheme ProceduralGeometry -destination 'generic/platform=visionOS Simulator' build
```

## How the demo works

On launch, `GameScene.swift`:
1. Calls `ProceduralGeometryExtension.shared.install()` — registers the extension once.
2. Calls `createTubeEntity(...)` to build the tube.
3. Spawns one small sphere "handle" per control point, so there's something to pinch in XR.

`handleInput()` then picks a handle, drags it with the engine's `SpatialManipulationSystem`, and feeds its new position back into the tube via `setControlPoints` every frame.

## Creating your own tube

```swift
ProceduralGeometryExtension.shared.createTubeEntity(
    controlPoints: [SIMD3(0, 1, -1), SIMD3(0.5, 1, -1)], // path, world space, meters. Min 2 points.
    radius: 0.03,         // uniform radius for the whole tube
    radialSegments: 16,   // cross-section resolution
    capStart: true,       // close the ends
    capEnd: true,
    name: "MyTube"
)
```

To change a tube after creation:

- `setControlPoints(entityId:_:)`, `setRadius(entityId:_:)` — cheap, no mesh rebuild.
- `setRadialSegments(entityId:_:)`, `setCaps(entityId:capStart:capEnd:)` — changes vertex count, full rebuild.

See `GameScene.swift` for the working example, including comments on a couple of XR gesture-handling gotchas found while building this.
