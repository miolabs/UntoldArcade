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
the measured lead and `--display-latency 16` its constant; `--swim-probe` shows the swim probe;
`--control-cube` stands a plain RealityKit cube beside the engine's cubes (the control for the
edge measurements on the headset's captures, below);
`--pipeline-depth 1` runs the pipeline one refresh deep, as it was; `2`, the default, two
refreshes deep (the engine's frame starts a refresh earlier, so a frame whose GPU span is
stretched by up to a refresh still lands on time, at the price of one refresh more lead);
`--render-scale 1.5` renders each eye at 1.5 times the drawable size (2880 × 2736 instead of
1920 × 1824, 2.25 times the engine's pixels), for more texels per degree than the display's
pixels (`1`, the default, is the drawable size); `--blended-core` draws the grids as a blended
core (each eye's grid through the band's blended graph itself, its depth write kept, no band
meshes, so no alpha test lies anywhere along a silhouette; `--cut-and-band`, the default, is the
alpha-tested core with the band over the cells along silhouettes); `--ipd 63` sets the
distance in millimetres between the nominal eyes the engine renders from (50 to 75; 63, the
default, is the presenter's) and `--view-offset x,y,z` moves both nominal eyes on the device by
centimetres along each axis (−5 to 5 each; x to the right, y up, z back, so forward is negative
z; zero, the default, is no offset), the eye test below. Every setting is also in the window,
at any time (the grid, the rate map, the pipeline's depth, the render scale, the silhouette and
the eyes for the next space opened), and remembered across launches (a launch argument wins for
its setting).

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
- The two-refresh pipeline (the default; `--pipeline-depth 1`, or its toggle off for the next space opened, is the one-refresh pipeline):
  during quick head turns the late count on the numbers line, which reads `N late (plan 2
  refreshes)` then, should fall to near zero where the one-refresh pipeline counts one to five
  in a hundred (a frame's GPU span stretched from 4 to 14 ms by the shared GPU still lands
  within its two refreshes; one stretched past that is held and skipped as before). The price
  is one refresh of lead: the lead on the line grows by the refresh period (10 ms at 100 Hz,
  11.1 at 90), and the dot must still hold still during a turn; a dot that lags with the
  setting on says the fixed lead (or, with the adaptive lead, the display latency) is what to
  move, not the depth.
- The render scale (`--render-scale 1.5`, or its toggle for the next space opened): the
  texture gives 12.9 texels per degree at the centre of view at the drawable size (17.6
  through the rate map) against the display's some 34 pixels per degree, so RealityKit's
  bilinear sampler shows each texel 2.6 display pixels wide and the engine's own one-texel
  steps along edges (MSAA's quarter steps, the staircase of a shallow edge) are magnified with
  it; at 1.5 (19.4 texels per degree, 26.4 through the map) a texel step is under a display
  pixel at the centre, so the cubes' and the sphere's edges should lose the magnified
  staircase. The settings line names the texture size and the texels per degree in force. The
  price is the engine's GPU frame, 2.25 times the pixels: read the GPU and the late count on
  the numbers line under the two-refresh pipeline (on the Mac the engine's GPU time per frame
  through the presenter grew by about the pixel ratio).
- The control cube (`--control-cube`, or its toggle, at any time): a plain RealityKit cube of
  the engine cubes' size to the right of the three, one step further at the same gap and the
  same height (the slab is 1.2 m wide, so it stands just past the slab's end, on the plane of
  its top), a like pale blue, lit by the room (a `SimpleMaterial`; `ControlCube.swift`). The
  engine's cubes reach the display through the presenter (the eye texture, the grid, the edge
  band) and then the device's own render of the grids; the control through the device's render
  alone. Capture both in one frame and measure the control's top edge with the engine cubes'
  by the same script: the same wobble on the control is the device's render or the capture,
  which no presenter change can touch; a straight control beside a wavy engine cube is the
  presenter's materials under the device's render. The settings line says `control cube on`
  while it stands.
- The blended core (`--blended-core`, or its toggle for the next space opened): the grids
  are drawn through the band's blended graph itself with their depth write kept, and no band
  is made, so a silhouette has no alpha test anywhere along it (the shipped core cuts at an
  alpha of 0.9 and leaves the partly covered texels to the band). The experiment the control
  cube called for: on the Mac the two chains give the same picture, so what the device
  renders differently is what this shows. Beside the control cube, the engine cubes' edges
  should hold as still as the control's under head motion if the device's rasterization of the
  shipped cut was the shimmer; if they still shimmer, it is the texture's own change from
  frame to frame at the silhouette, and the lever left is temporal. The `gpu` on the numbers
  line should read under the shipped core plus band: one pass over the grid instead of two (the
  whole-grid band cost about 11 ms on the device as a second pass). The settings line says
  `silhouette blended core (depth written, no band)`, or `cut and band (edge band on)`. Its
  depth footprint is the shipped chain's: the skirt's texels and the near part of the triangles
  stretched across a depth jump write depth at an opacity near 0, so a RealityKit entity
  standing in the sliver beside a silhouette, between an engine object and what lies behind
  it, is hidden there, as it is under the shipped band's cells, which blend over the same
  texels and write depth too (the same halo on the Mac, measured); the other eye's grid is
  collapsed in the vertex stage and writes nothing, so the picture must still be whole in
  each eye.
- The eyes (`--ipd 55`, `--view-offset 0,0,-3`, or their steppers, for the next space
  opened): the engine renders each eye, and the kernel lays each grid along that eye's rays at
  the engine's depth, from a nominal eye, 63 mm to its side of the ARKit device anchor with no
  offset; RealityKit then renders the grids from the device's real eye transforms, which it
  never tells the presenter. Where a grid cell's one depth plane is right the difference does
  not show (a vertex on the surface is on the surface from any eye), but where it is wrong (an
  edge-on sliver such as a cube's top seen from just above, a curved limb; the rim rule puts a
  sliver's texels on the nearest depth in its footprint) the real eye sees the texel displaced
  by the eyes' difference times the depth error over the distance squared: a centimetre of eye
  against 10 cm of depth error at 1.6 m is about 1.3 display pixels, the size of the kinks on
  the cube tops at rest, and under head motion the pose prediction's residual adds to it as
  the waves. The test, each setting judged for the kinks on the cube tops at rest: the IPD at
  55 and 70 mm against 63, then a few centimetres of offset along one axis at a time. If the
  eyes are the cause the kinks must change with the IPD and with the offset, growing in one
  direction and flattening in the other, and the setting that flattens them says where the
  real eyes are against the nominal ones (a calibration the presenter could carry); if ±5 cm
  and 50–75 mm, far more than any real eye can be off, change nothing, the eyes are not the
  cause and what is left is the cells' depth itself or the device's render. The whole scene
  also shifts with a lateral or vertical offset and its apparent depth with the IPD, as it
  must: judge the kinks, not the placement. The settings line names the IPD and the offset in
  force.
- Close one eye at a time on the headset: the picture must be whole in each eye. A doubled
  picture means the eye material fell back (the window's material line says which).
- A pinch on a cube lights it orange and the tap count rises: the space's pinches reach the
  engine through the presenter's input target.
- Mixed: the room shows around the slab. Full: dark around it.
- The numbers, once a second in the window and in the console: RealityKit updates per second
  with the refresh period they measure (100 updates/s is a 10 ms refresh, 90 is 11.1), engine
  frames per second, dropped tickets (RealityKit asked for a frame while the engine still had
  the previous one), late frames (a completion over the refreshes planned: the frame lands a
  refresh late and RealityKit shows the previous one twice; two refreshes deep the count says
  `(plan 2 refreshes)`), the main thread's time in the replace
  calls, the ticket's age when the engine took it, then each frame's stages from the pickup
  with its average and maximum: `cpu` (to the loop's commit of the command buffer), `wait`
  (from the commit to the GPU starting on it: the driver's submission and the GPU's queue,
  where the compositor's and RealityKit's own work go first), `gpu` (the span on the GPU) and
  `completion` (their sum, pickup to GPU end); `worst 16.6 = cpu 3.1 + wait 9.2 + gpu 4.3`
  is the second's longest frame split the same way, so a late frame reads as a slow CPU
  frame, a wait on a busy GPU, or a long span; then the engine's own GPU time, the lead in
  force and the device's thermal state.
