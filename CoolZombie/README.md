# CoolZombie

AI character locomotion demo for [Untold Engine](https://github.com/untoldengine/UntoldEngine) — **no animation state machine**.

A wandering target orbits the arena and the character chases it. Every frame the AI states a *goal* (desired velocity and facing, straight from steering); the engine's animation stack does the rest:

- **Motion matching** searches the loaded clips for the frame that best matches the current pose and predicted trajectory — nobody calls `changeAnimation`.
- **Inertialized transitions** smooth every clip jump.
- **Root motion** moves the entity: the clips' own travel is authoritative, so there is no foot sliding from mismatched speeds.
- **Foot IK** plants the feet on the ground.

Far from the target the character runs, closing in it walks, arrived it idles — all emergent from one `setMotionMatchingGoal` call per frame.

## Run

```bash
swift run CoolZombie
```

macOS 14+. The package pins the engine to the miolabs fork's `develop`
branch (`Package.resolved` records the exact commit).

## Assets

The demo is written so assets swap without code changes: drop in new
`.untold` clips, list them in `ZombieResources.chaseClips`, and the motion
database rebuilds from whatever is loaded. None of the assets are in this
repository (see the licenses below); the expected layout is:

```
Sources/CoolZombieKit/Resources/
  Models/ZombieAA/ZombieAA.untold
  Models/ZombieAA/Textures/T_ZombieAA_BC_V2.png      base color
  Models/ZombieAA/Textures/T_ZombieAA_N_V2.png       normal
  Models/ZombieAA/Textures/T_ZombieAA_AO_R_M_V2.png  occlusion / roughness / metallic
  Animations/<clip>/<clip>.untold                    one folder per clip
```

Texture paths inside a `.untold` resolve relative to the model file, so the
`Textures/` folder must sit next to it. Cook the model with the engine's
exporter at or after commit `872ea646`: earlier exporters collapsed packed
textures onto the base color (the engine then sampled the albedo as a
normal map) and exported roughness at half strength.

## License

MPL-2.0, matching the engine. This demo is non-commercial.

## Animations

The zombie's animation clips are cooked from [MoCap Online's Zombie Pro
pack](https://mocaponline.com/products/ue4-zombie-pro), whose license does
not permit redistributing animation data — so this repository contains no
clips, only the code. To run the demo:

- own the pack, export the sequences as glTF, and cook them with the
  Untold Engine Blender add-on into
  `Sources/CoolZombieKit/Resources/Animations/<clip>/<clip>.untold`, or
- download a prebuilt demo binary from the Releases page, where the
  clips ship embedded in the compiled app as the license allows.

The `ZombieAA` model comes from Studio New Punch's "Zombie Pack V1"
(Unreal Marketplace) and is likewise not redistributable in source form —
it ships only inside the prebuilt demo binaries.

## visionOS (Apple Vision Pro)

`Examples/CoolZombieVisionOS` is a mixed-reality build: the zombie waits a
few meters in front of you in your real room; walk toward it and it comes
for you, stopping an arm's length away. The chase logic lives in the
`CoolZombieKit` library target (shared with the macOS demo); the app only
feeds it the head position from ARKit world tracking.

Open `Examples/CoolZombieVisionOS/CoolZombieVisionOS.xcodeproj` and run the
`CoolZombieVisionOS-visionOS` scheme. In the simulator the floor is placed
1 m below the head (there is no floor calibration); launch arguments
`-autoOpenSpace` and `-autoProvoke` open the immersive space and start the
chase without gaze-and-pinch input, for automated runs:

```bash
xcrun simctl launch <udid> com.miolabs.CoolZombieVisionOS -autoOpenSpace -autoProvoke
```
