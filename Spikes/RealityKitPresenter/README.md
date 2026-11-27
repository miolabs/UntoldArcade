# RealityKit Presenter spike (stage 0)

A throwaway visionOS app, no engine code: the stage 0 spike of
`UntoldEngine/docs/proposals/XRRealityKitPresenter.md`. It settles the four unknowns of the
RealityKit presenter on the headset before the engine work starts:

1. the per-frame texture hand-off (`LowLevelTexture.replace(using:)` vs. the visionOS 27
   `LowLevelDeviceResource` routes: an IOSurface the app allocates, or a Metal shared texture's
   handle, which exists on the device but not in the simulator SDK),
2. the per-eye material (a hand-written MaterialX graph with the Camera Index Switch, an
   Unlit Surface with the tone map off and an opacity threshold),
3. the device-anchor timing and the ARKit/RealityKit origins,
4. Spatial Personas against the depth grids in a SharePlay group immersive space.

What it does: an `ImmersiveSpace` with a `RealityView`; two `LowLevelMesh` grids
(256 × 240 vertices, position + uv + a half2 tear mask) as two entities at identity; a
Metal render pass of its own on a thread that draws a test pattern (a synthetic scene of a
floor, a wall with a hole and sky, or a head-locked angular checker; a colour ramp, a moving
bar, eye marks) into two `LowLevelTexture`s, driven by tickets posted from
`SceneEvents.Update` on the main thread, where the replace calls happen and the command
buffer is made; a compute kernel fills the grid vertices from the synthetic depth in the
space of the device anchor queried for the ticket's time plus a lead; a window with the
switches and the numbers; a `GroupActivity` with `supportsGroupImmersiveSpace` and the
side-by-side template.

- `project.yml` — xcodegen spec (visionOS 2 minimum, visionOS 27 parts gated by availability).
  `xcodegen generate` writes `RealityKitPresenter.xcodeproj`, `Info.plist` and the entitlements.
- `Config/` — bundle id prefix; `Local.xcconfig` (gitignored) holds the signing team.
- `Sources/RealityKitPresenter/Shaders/` — `SpikeShaderTypes.h` (bridging header, the
  uniforms) and `SpikeShaders.metal` (`fillGrid`, `fullscreenVertex`, `patternFragment`).
- `Sources/RealityKitPresenter/Resources/EyeMaterial.usda` — the material graph.
- `Sources/RealityKitPresenter/Presenter/` — `EyeGrid` (the mesh), `EyeTextures` (the three
  routes), `TicketMailbox`, `HeadTracker` (ARKit), `PresenterRenderer` (the render thread),
  `EyePresenter` (the main-thread side), `SpikeModel` (switches), `SpikeStats` (numbers).
- `Sources/RealityKitPresenter/SharePlay/` — the activity and the session controller.
- `CHECKLIST.md` — what to run on the headset and what to look for.

Launch arguments: `--open-space` opens the immersive space at start, `--hide-window` then closes the
control window (simulator screenshots).
