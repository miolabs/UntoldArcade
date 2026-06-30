# 🌊 WebGLWater

A port of [Evan Wallace's WebGL Water](https://github.com/evanw/webgl-water) to the
**Untold Engine**, running on **macOS** and **iOS**.

It reproduces the original's technique faithfully:

- A GPU **heightfield wave simulation** (256×256 ping-pong float textures) updated each
  frame — wave propagation, surface-normal recomputation, sphere displacement and drops.
- A **caustics** pass that projects the refracting surface onto the pool floor to compute
  light concentration (plus sphere and pool-rim shadows).
- Per-pixel **raytraced** rendering of the pool, the ball and the water surface, with
  Fresnel reflection/refraction, a sky cubemap, and underwater tinting.

A ball drops into the pool and bounces, displacing the water, while ambient ripples keep
the surface alive.

## Engine dependency

Unlike the other demos in this repo (which fetch the engine from GitHub), WebGLWater depends
on the **local engine fork** at `../../UntoldEngine` via a local Swift Package reference. The
water feature lives in the engine itself:

- `Sources/UntoldEngine/Shaders/WaterShader.metal` — sim kernels + caustics + scene shaders.
- `Sources/UntoldEngine/Systems/WaterSystem.swift` — `WaterRenderer` (pipelines, geometry,
  passes, render graph) and the public `enableWater` / `addWaterDrop` / … API.

When `enableWater(true)` is set, the engine's `buildGameModeGraph()` hands the whole frame to
`WaterRenderer`, bypassing the deferred PBR pipeline.

> The engine ships prebuilt Metal libraries. After changing any `.metal` file you must rebuild
> them with `make compile-shaders` (or `sh ./buildkernels.sh`) in the engine repo.

## Build & run

```bash
open WebGLWater.xcodeproj
```

- **macOS:** select the `WebGLWater-macOS` scheme and run (⌘R).
- **iOS:** select `WebGLWater-iOS` and an iOS 17+ simulator or device.

Build for **arm64** (Apple Silicon / device / arm64 simulator).

## Regenerating the project

The Xcode project is generated programmatically:

```bash
ruby gen_project.rb
```

## Assets

`Resources/` holds the original demo's `tiles.jpg` and the five cubemap faces
(`xpos/xneg/ypos/zpos/zneg.jpg`, with `ypos` reused for the bottom face).

## Public water API (engine)

```swift
enableWater(true)
setWaterSphere(center: simd_float3(-0.4, 0.6, 0.2), radius: 0.25)
setWaterLightDirection(simd_float3(2, 2, -1))
setWaterTilesTexture(tiles)        // MTLTexture
setWaterSkyTexture(skyCubemap)     // MTLTexture (cube)
seedWaterRipples(count: 20)
addWaterDrop(center: simd_float2(x, z), radius: 0.03, strength: 0.02) // x,z in [-1,1]
setWaterSphereCenter(center)       // call each frame to drive the ball
resetWater()
```
