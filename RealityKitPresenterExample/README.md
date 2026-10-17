# RealityKit Presenter example

The Untold Engine's XR frame shown by RealityKit instead of Compositor Services: the immersive
space holds an `UntoldXRPresenterView` (from the engine's `UntoldEngineXRRealityKit` target)
where the other visionOS examples hold a `CompositorLayer`. The engine renders every frame as
it always does; RealityKit shows each eye on a grid displaced by the engine's own depth, so the
system owns the space and can add what a compositor layer never gets: Spatial Personas in a
SharePlay session, native entities, SwiftUI attachments. The why and the plan are in the engine
repository, `docs/proposals/SpatialPersonasResearch.md` and `XRRealityKitPresenter.md`
(untoldengine/UntoldEngine#1371); this app is the try-out of its stage 2.

The scene has nothing to load: a slab 1.6 m ahead of where the session began, three cubes
turning on it, a sphere above, a sun. A pinch on a cube lights it up.

## Running it

```bash
cd RealityKitPresenterExample
xcodegen generate      # the project is generated from project.yml
open RealityKitPresenterExample.xcodeproj
```

The team goes in `Config/Local.xcconfig` (gitignored; see `Config/Config.xcconfig`). The
engine comes from the fork branch the presenter is developed on until it lands upstream
(`project.yml` says which, and how to point it at a local checkout).

Runs in the simulator (visionOS 2 and later; the eye switch shows the left eye's grid in the
simulator's single view) and on an Apple Vision Pro. Launch arguments `--open-space` and
`--hide-window` open the space at start and close the window, for simulator screenshots.

## What to look for

- The slab, the cubes and the sphere appear where the window says, and stay put while you
  move your head (a drift that follows the head means the frame's lead is off: the
  presenter's `leadSeconds`).
- Close one eye at a time on the headset: the picture must be whole in each eye. A doubled
  picture means the eye material fell back (the window's material line says which).
- A pinch on a cube lights it orange and the tap count rises: the space's pinches reach the
  engine through the presenter's input target.
- Mixed: the room shows around the slab. Full: dark around it.
- The numbers, once a second in the window and in the console: RealityKit updates and engine
  frames per second, dropped tickets (RealityKit asked for a frame while the engine still had
  the previous one), the main thread's time in the replace calls, the ticket's age when the
  engine took it, the engine's CPU frame, and the GPU span.
