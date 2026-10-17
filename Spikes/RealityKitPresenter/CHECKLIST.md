# Headset checklist — RealityKit presenter spike (stage 0)

The spike answers the four questions of `UntoldEngine/docs/proposals/XRRealityKitPresenter.md`
section 3 "Stage 0". Nothing here touches the engine. Run the items in this order on the
Apple Vision Pro; write what you see (and the numbers) back, and the results go into the
plan note's "Progress" section with decisions D2–D5.

## Build and install

1. Open `UntoldArcade/Spikes/RealityKitPresenter/RealityKitPresenter.xcodeproj` (regenerate
   with `xcodegen generate` in that folder if you change `project.yml`).
2. Scheme `RealityKitPresenter`, destination your Apple Vision Pro (visionOS 27 for the
   IOSurface route; the replace route runs on visionOS 2 and later). The team is in
   `Config/Local.xcconfig`; the bundle id is `com.miolabs.RealityKitPresenterSpike`. The Group
   Activities capability is already registered on the app id (a signed `xcodebuild` run did it on
   2026-10-16); automatic signing picks the profile up.
3. Run. The window opens with the switches, the numbers, the colour-ramp reference, the
   SharePlay controls and a log. Press **Open Space**.

## What the space shows (expected picture, both pattern modes)

- World-locked (default): a 0.25 m checkered floor at your feet with a yellow dot on the ARKit
  origin and a red line along +x and a blue line along −z from it; a checkered wall 2.5 m
  ahead, 4 m wide and 3 m high, with a round hole at head height ringed in green; passthrough
  beyond the wall's edges and through the hole (sky alpha 0).
- Head-locked: a 10° angular checker on a plane 2 m in front of you that follows your head.
- In both: a yellow crosshair on the view axis, a yellow ring 10° off it, a white bar sweeping
  left to right every 4 s, the colour band at the top (greys 0.0–0.9 then red, green, blue,
  white), one green square bottom-left seen by the left eye only and two magenta squares
  bottom-right seen by the right eye only.
- Log lines to check first: "Eye material loaded" (not "using the fallback"), "ARKit session
  running", "World tracking: running" in the header.

## 0. Smoke

- [ ] The picture above appears in Mixed immersion. Floor under your feet, wall ahead, hole
      shows the room.
- [ ] Close one eye at a time: the left eye sees the green square and no magenta; the right eye
      sees the two magenta squares and no green. (Both in one eye, or a doubled image, means the
      Camera Index Switch did not discard the other eye's grid: question 2 fails.)
- [ ] Numbers after 10 s: frames per second ≈ 90, RealityKit updates ≈ 90, dropped tickets 0.

## 1. Texture hand-off (D2) — route `replace(using:)` first

Look around normally for 30 s, then read the window:

- [ ] Frames per second (tickets committed): ______ RealityKit updates/s: ______
- [ ] Dropped tickets total / per second: ______ (a drop = an Update with the render thread
      still holding the previous ticket)
- [ ] Main thread in the replace calls, avg / max ms: ______ (this is the cost the plan worried
      about: two `replace(using:)` + two `replace(bufferIndex:using:)` per frame; the two rows
      under it split it into the texture part and the grid part). In the visionOS 26.5 simulator
      on the Mac this was 8 ms average with spikes to 27 ms at 90 fps and no drops, so the
      headset number decides.
- [ ] Isolate the cost: **Texture size** to 960 × 912 → replace ms ______ (a texture-size-bound
      cost means RealityKit copies the frame); **Update the grids every frame** off → replace ms
      ______ (now only the two texture replaces run; the grids keep their last positions, so
      stay in World-locked for this one). Back to full size and grids on afterwards.
- [ ] Ticket age at pickup avg / max ms: ______ Render encode + commit avg / max: ______
- [ ] GPU ms avg / max: ______ Commit→completion lag avg / max ms: ______
- [ ] Command buffers in flight at commit, max: ______ (2 or more means the previous buffer was
      still running when the next was committed; note whether the picture tears or stalls then)
- [ ] The moving bar: smooth, or does it stutter / jump (dropped frames)? ______

Then switch **Texture route** to **IOSurface resource (27)** (the log says "Textures rebuilt"):

- [ ] Same readings: fps ______ dropped ______ replace ms ______ in flight ______
- [ ] Tearing or flicker on the bar? ______ (two slots per eye: the slot being drawn may still
      be the one on screen if RealityKit lags a frame; a third slot is a one-line change in
      `EyeTextures.swift`, `slotCount`)

Decision rule for D2: `replace(using:)` holds 90 fps with no drops and its main-thread cost
stays under about 2 ms → the plan's baseline stands; otherwise the IOSurface route, if it does
better. Write both sets of numbers down.

Then switch to **Shared handle (27, device)** (Metal shared textures through
`LowLevelDeviceResource(sharedTextureHandle:)`, the plan's D2 fallback as written; it exists on the
device only, the simulator SDK marks `makeSharedTexture` unavailable). If the log says the route
could not be made, write down the error line:

- [ ] Same readings: fps ______ dropped ______ replace ms ______ in flight ______ tearing ______

Note: the IOSurface and the shared-handle routes do the same per-frame toggle of two device
resources per eye; they differ only in where the Metal texture comes from.

## 2. The material (question 2)

- [ ] Eye discard: the one-eye check of the smoke test passes in both routes.
- [ ] Tone map off: hold the window's colour-ramp reference next to the band at the top of the
      frame. Do the ten greys and the four colours match (same brightness steps, same hue)?
      ______ Any difference between Mixed and Full immersion? ______
- [ ] Passthrough: with "Sky is passthrough" on, the room shows through the hole and beyond the
      wall in Mixed; off, the sky is dark blue. In Full immersion with it on, the sky is black.
- [ ] Edges: describe the wall's outline against the passthrough (clean, a halo, a dark
      fringe?) and the hole's edge: ______

## 3. Timing and origin (question 3, D5's field of view)

Switch **Test pattern** to **Head-locked**:

- [ ] Turn your head briskly left/right, nod, lean sideways: the angular checker and the
      crosshair must stay glued to the view. Lag (the pattern trails and catches up) or lead
      (it runs ahead) means the lead is off; jitter means the predictions are noisy.
- [ ] Move the **Lead** slider (0 … 4 refresh periods, 11.1 ms each at 90 Hz). The lead that
      makes it stable: ______ periods (______ ms). Residual at that lead: ______
- [ ] Device anchor predicted / retried / cached / missing: ______ (retried or cached above
      zero at a lead means that lead is past ARKit's prediction horizon)

Back to **World-locked**:

- [ ] Floor and wall stay put while you move your head; at the wall's edges and the hole
      smears appear during fast turns (disocclusion) and settle — how large? ______
- [ ] Is anything cut off at the edge of your view when you look sideways (the frustum is
      ±52° horizontal, +49°/−52° vertical: wider than the display)? ______

Origins — toggle **Cube on the device anchor**:

- [ ] The yellow disc (a RealityKit entity on the scene origin) lies on the yellow dot the
      texture draws on the ARKit origin, red and blue lines pointing the same way → the two
      origins coincide. If the disc is elsewhere, note the offset: ______
- [ ] The cyan marker sits at the centre of your view 60 cm ahead and follows your head with no
      swim (it is placed from the anchor queried for "now" on the main thread).
- [ ] The orange cube is on your head (see it in a mirror, or the other participant sees it on
      you in item 4).

## 4. Personas (question 4) — needs the second Vision Pro on a FaceTime call

Both headsets install the spike (the other one on visionOS 26.6.1 runs the replace route).

- [ ] Start a FaceTime call between the two. On one, press **Start SharePlay** (or use the
      share sheet); the other accepts. Status shows "Joined, 2 participants".
- [ ] "Local participant spatial: yes" and a group immersion style in the window; the space
      opens by itself (the app mirrors `groupImmersionStyle`) or press **Open Space**.
- [ ] Mixed immersion: the other person's Persona stands beside you (side-by-side template).
      Visible? ______ Standing on the checkered floor, feet not cut? ______ In front of the
      wall checker (the wall is 2.5 m ahead, they are about 1 m beside you)? ______
- [ ] Occlusion the other way: switch to **Head-locked** and set **Head-locked distance** to
      0.5 m. The plane is now between you and the room: the Persona should be hidden where the
      plane covers them, and reappear when you look away. ______ Set it back to 2 m: they are
      in front of the plane again. ______
- [ ] Full immersion: repeat the two checks. ______ (The plan's worry: whether a `.full` group
      space shows Personas at all.)
- [ ] Does the system move the space origin for the group (the floor pattern or the yellow
      dot jumps when the session becomes spatial)? ______ (stage 4's `immersiveSpaceDisplacement`)

## Where the numbers are

All in the window's "Numbers (last half second)" group, refreshed twice a second. The log at
the bottom keeps the last 60 messages (material loading, route switches, tracking state,
errors). Every 5 s one compact line with all the numbers goes to the system log too
(Console.app on the Mac with the headset connected, subsystem
`com.miolabs.RealityKitPresenterSpike`, category `numbers`), so a run can be read back
afterwards without writing anything down. Metal's own HUD is on in the scheme
(`MTL_HUD_ENABLED`) as a cross-check.
