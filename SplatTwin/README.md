# SplatTwin

A macOS demo built with [UntoldEngine](https://github.com/untoldengine/UntoldEngine) and the
[UntoldGaussianTwins](https://github.com/miolabs/UntoldGaussianTwins) package: three objects
stand on a floor, each a mesh linked to a Gaussian-splat twin. Walk up to one and the mesh
cross-fades to its splat with no popping; walk away and it fades back. While the splat shows,
the mesh keeps writing depth as a shrunk occluder shell, so the splat is hidden behind the
object's far side but never by its own surface, and it keeps casting its shadow.

## 🚀 Quick Start

This is an Xcode project generated via [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`.

```bash
xcodegen generate
open SplatTwin.xcodeproj
```

Select the `SplatTwin` scheme and press `Cmd+R` (macOS 26.0+, a Metal GPU).

Controls: `WASD` move, `Q`/`E` up and down, right-drag to orbit. The HUD lists each object's
state (mesh, loading, fading, splat), the swap distance and the fade length as live sliders,
and a switch for the occluder shells so you can see what they do: turn them off while an object
is swapped and its far side shows through.

## How it works

- The twins are synthesised at first launch: `SplatSynthesizer` scatters flat splats over each
  primitive's surface, bakes a fixed light into their colours the way a real capture does, and
  writes a `.untoldgs` payload to the caches folder. No downloads, no large assets.
- `GaussianTwinSystem` (from the package) loads a payload when the camera comes within the swap
  distance, runs the cross-fade through the engine's `MeshFadeComponent` and the splat's
  `opacityScale`, and switches the mesh's colour off behind its `MeshOccluderComponent` shell.
- To try a real capture, put `capture.untold` (the mesh) and `capture.untoldgs` (its cooked
  splat) into `Sources/SplatTwin/GameData/Twins/`; the demo adds it as a fourth object.

## 📁 Project Structure

```
SplatTwin/
├── project.yml
├── README.md
├── Sources/SplatTwin/
│   ├── SplatTwinApp.swift      # Window, renderer, HUD
│   ├── GameScene.swift         # Engine setup, camera, light, input
│   ├── TwinShowcase.swift      # The objects and their twins
│   ├── SplatSynthesizer.swift  # Splat covers for primitives, written as .untoldgs
│   └── GameData/Twins/         # Optional real capture pair
└── Tests/SplatTwinTests/
    └── SplatSynthesizerTests.swift
```

## Dependencies

The project points at the engine's `develop` branch (`untoldengine/UntoldEngine`), which
carries the occluder shell, mesh fade and scene link the swap builds on, and at the
`miolabs/UntoldGaussianTwins` package's `main` branch, which supplies the swap policy.
