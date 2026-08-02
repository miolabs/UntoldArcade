# CoolWeb

A Spider-Man web-shooter demo for [Untold Engine](https://github.com/untoldengine/UntoldEngine),
built as a Rendering Extension plugin. Strike the classic web-shooter pose on
Apple Vision Pro — thumb, index and pinky extended, middle and ring curled —
and a web line fires from your wrist, blooms into a small net near the
surface it hits, and stays tethered to your hand (a closed fist keeps
holding it). Open your palm to let it go.

## How it works

- **Gesture** — CoolWeb runs its own `ARKitSession` with `HandTrackingProvider`.
  A per-finger extension ratio (end-to-end distance over chain length) feeds a
  hysteresis classifier; the web fires on pose onset, aimed from the wrist
  through the knuckles.
- **Attach** — `SceneReconstructionProvider` meshes are kept twice: as
  `MTLBuffer`s for a depth-only occlusion pre-pass, and as CPU world-space
  triangles for the fire-time raycast (Möller–Trumbore), so webs stick to
  arbitrary room geometry, not just detected planes.
- **Strand** — a position-based rope (Verlet + sequential distance
  constraints). The tip flies kinematically toward the hit while rope pays out
  behind it, then pins to the surface with slight slack so the strand sags;
  the root follows the tracked wrist. Released strands dangle, then dissolve.
- **Rendering** — one alpha-blended draw at `.beforePostProcess`: every rope
  segment is a camera-facing ribbon (procedural from the vertex id, capsule SDF
  in the fragment) plus a surface-oriented impact splat that draws a procedural
  spoke-and-spiral web pattern.

## Building

```sh
swift build            # library (use /usr/bin/swift)
swift test             # host tests
Scripts/build-metallib.sh   # rebuild committed metallibs after shader edits
```

The example app is in `Examples/CoolWebVisionOS`. Hand tracking and scene
reconstruction require a real Vision Pro; the simulator provides neither.
