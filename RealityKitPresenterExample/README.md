# RealityKit Presenter example

The Untold Engine's XR frame shown by RealityKit instead of Compositor Services: the immersive
space holds an `UntoldXRPresenterView` (from the engine's `UntoldEngineXRRealityKit` target)
where the other visionOS examples hold a `CompositorLayer`. The engine renders every frame as
it always does; RealityKit shows each eye on a grid displaced by the engine's own depth, so the
system owns the space and can add what a compositor layer never gets: Spatial Personas in a
SharePlay session, native entities, SwiftUI attachments. The why and the plan are in the engine
repository, `docs/proposals/SpatialPersonasResearch.md` and `XRRealityKitPresenter.md`
(untoldengine/UntoldEngine#1371); this app is the try-out of its stage 2.

The scene has nothing to load: a slab 1.6 m ahead of where the session began, three cubes on
it, a sphere above, a sun. A pinch on a cube lights it up. The scene is still, so that
screenshots of one build compare with the next; `--turning` turns the cubes.

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
`--hide-window` open the space at start and close the window, for simulator screenshots;
`--turning` turns the cubes; `--aa fxaa|smaa|msaa|taa|msaataa` picks the engine's
anti-aliasing (MSAA by default: of the modes, only MSAA leaves coverage in the frame's alpha at
a silhouette, which the presenter's edge band blends into a filtered edge; FXAA leaves one
texel per edge at a constant value and SMAA none); `--no-edge-band` turns the band off;
`--lead 22` sets the fixed lead in milliseconds, `--adaptive-lead` (or `--fixed-lead`) chooses
the measured lead and `--display-latency 16` its constant; `--swim-probe` shows the swim probe.
Every setting is also in the window, at any time, and remembered across launches (a launch
argument wins for its setting).

Two things the simulator cannot show. The engine renders single-sampled there (its deferred
fallback samples the G-buffer as a plain texture), so the frame's alpha is binary in every mode
and the edge band has nothing to blend: silhouettes step texel by texel in the simulator whatever
the arguments. And the simulated viewing pose equals the rendering pose, so each eye's grid
projects back onto its texture exactly: the simulator shows the texture's own edge and nothing
of the grid's quality. Both are the headset's to judge.

## What to look for

- The slab, the cubes and the sphere appear where the window says, and stay put while you
  move your head (a drift that follows the head means the frame's lead is off: the
  presenter's `leadSeconds`).
- The swim probe (`--swim-probe`, or its toggle): a yellow cross locked to the room 1.5 m
  ahead of where you looked when it came on, and a cyan dot locked to the head the same
  distance ahead, placed every frame from the pose the frame is rendered with. Turn your head:
  the cross must stay in the room and the dot in view. A dot that lags the turn and catches
  up when you stop says the lead is short (the frame reaches the display later than it was
  posed for); one that runs ahead says it is long. The lead is fixed (`leadSeconds`, two
  refreshes) or adaptive: the ticket's age at pickup plus the frame's measured time from
  pickup to its command buffer completing, averaged over the last frames, plus a display
  latency constant for what follows (RealityKit's frame, the compositor's), 16 ms to start.
  With the adaptive lead on, move the display latency until the dot holds still during a
  turn; the numbers line shows the lead in force and the time to completion it was built
  from. The same probe dropped into a Compositor Services example (`SwimProbe.swift` needs
  only the engine) compares the two paths at one pose.
- Close one eye at a time on the headset: the picture must be whole in each eye. A doubled
  picture means the eye material fell back (the window's material line says which).
- A pinch on a cube lights it orange and the tap count rises: the space's pinches reach the
  engine through the presenter's input target.
- Mixed: the room shows around the slab. Full: dark around it.
- The numbers, once a second in the window and in the console: RealityKit updates and engine
  frames per second, dropped tickets (RealityKit asked for a frame while the engine still had
  the previous one), the main thread's time in the replace calls, the ticket's age when the
  engine took it, the engine's CPU frame, the frame's time to completion on the GPU, the GPU
  span, the engine's own GPU time, the lead in force and the device's thermal state.
