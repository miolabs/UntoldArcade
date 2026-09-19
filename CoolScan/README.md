# CoolScan

Scan a real object with your iPhone, convert it to UntoldEngine's native
`.untold` format **on the device**, and view it with live stylization —
Real (PBR), Toon, Comic, Pixel art, and Pencil sketch.

## What's inside

| Target | Role |
| --- | --- |
| `CoolScan` | Render-extension plugin: toon model-surface pipeline + comic/pixel/sketch/edge compute kernels |
| `CoolScanPipeline` | On-device USDZ → `.untold` cooker (ModelIO extraction + engine `UntoldBinaryWriter`) |
| `Examples/CoolScanIOS` | iPhone app: Object Capture scan flow, scan library, touch-orbit viewer, style picker |

## The pipeline

1. **Capture** — `ObjectCaptureSession` guides a walk-around capture
   (LiDAR iPhone required; the app gates on `ObjectCaptureSession.isSupported`).
2. **Reconstruct** — `PhotogrammetrySession` builds a textured USDZ on the
   phone (`.reduced` detail keeps memory and thermals sane).
3. **Cook** — `CoolScanPipeline.ScanCooker` loads the USDZ with ModelIO,
   recovers missing normals/tangents, and writes a native `.untold` file
   plus PNG texture siblings using the engine's public AssetFormat API.
   The result is validated through `UntoldReader` before it is accepted.
   No Blender, no ASTC baking — plain PNGs load through MTKTextureLoader.
4. **View** — `setEntityMeshAsync` loads the cooked file from Documents by
   absolute path; the viewer frames the camera from the cooked bounds and
   drives the engine orbit camera from `getIOSTouchState()`.

## Styles

- **Toon** — model-surface pipeline (`registerModelSurfacePipeline`): the
  engine supplies the model vertex shader, `coolScanToonFragment` quantizes
  half-lambert diffuse into bands and samples the entity's own base color
  texture. Opt-in per entity via `CoolScanToonComponent`.
- **Comic / Pixel / Sketch** — a compute pass at `.beforeLook`: the scene
  composite is blitted to a scratch texture, then one kernel per style
  writes the stylized image back, so the engine's look/tonemap chain still
  runs. Kernels stylize in Reinhard display space and quantize in gamma
  space (linear-space quantization crushes shadows).
- Style switching is lock-protected app-facing state: `setCoolScanStyle(_:)`
  plus `CoolScanStyleParams` for tuning (bands, halftone, pixel size…).

## Building

The package builds and tests on macOS: `swift test` covers the plugin
contract and full cooker round-trips (including a real USDZ fixture).

The example app is XcodeGen-based:

```bash
cd CoolScan/Examples/CoolScanIOS
xcodegen generate
open CoolScanIOS.xcodeproj
```

The app project references the engine by **local path**
(`../../../../UntoldEngine`); the package manifest uses the git `develop`
branch like the other UntoldArcade demos.

After editing `Shaders/CoolScan.metal`, rebuild the bundled metallibs:

```bash
CoolScan/Scripts/build-metallib.sh
```

(The script needs the engine checkout for
`UntoldEngineShaderSupport` headers; override with `UNTOLD_ENGINE_DIR`.)

## Reconstruct on your Mac (full detail)

The phone can only reconstruct at Apple's `.reduced` detail. For photoreal
results, run the reconstruction server on a Mac on the same Wi‑Fi:

```bash
cd CoolScan/Server
swift run CoolScanServer            # xcrun swift run … if `swift` is shadowed by swiftly
```

Requirements: Apple Silicon (or a supported GPU), macOS 14+. The first
build fetches MIOServerKit, SwiftNIO and the engine. The server prints its
address and advertises itself over Bonjour (`dns-sd -B _coolscan._tcp` to
check); the phone finds it automatically, or you can pin the address in
the app's **Mac server** sheet (gear icon).

After a capture the app asks where to build the model. **On your Mac**
uploads the photos *and* the on-device pose checkpoints (so the Mac skips
alignment), runs `PhotogrammetrySession` at **Full** detail by default
(Medium / Custom 250k-triangle presets available in the sheet), cooks the
result through the same pipeline with textures capped at 2K, and sends the
bundle back. The job survives the app being killed: pending jobs show in
the library under **On the Mac** and resume when the app returns.

Existing scans can be re-cooked on the Mac from their kept `source.usdz`
(long-press → **Re-cook on Mac**); the Mac keeps each job's USDZ so results
can be re-cooked server-side too (`POST /jobs/{id}/recook`).

Useful flags: `--port`, `--detail full|medium|custom`, `--jobs-dir`,
`--retention-hours`, `--max-upload-mb`, and `--stub-usdz FILE` to run the
whole API without photogrammetry (`Server/Scripts/smoke.sh` does exactly
that with curl).

## Simulator notes

- Object Capture does not run in the simulator — use **Import Sample**,
  which cooks the bundled `ball.usdz` through the exact same pipeline.
- The engine's prebuilt `-iossim` metallib targets Metal 4, so use an
  **iOS 26+ simulator runtime**; older runtimes fail with
  "language version 4.0 is not supported" and the renderer traps.
- Headless testing hooks: launch argument `-CoolScanAutoDemo` imports the
  sample and opens the viewer; env `COOLSCAN_STYLE=comic|pixel|sketch|toon`
  preselects a style; `COOLSCAN_SERVER=http://host:port` pins a server and
  `-CoolScanAutoRecookOnMac` sends the sample through it (the simulator
  shares the Mac's network, so a local stub server works).

## Scanning tips

- Matte, textured objects reconstruct best; avoid glossy/transparent items.
- Scan in diffuse light (overcast daylight is ideal), fill the frame, and
  complete at least one slow full pass around the object.
- Everything runs on device — airplane mode works fine.
