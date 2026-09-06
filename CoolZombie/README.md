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

macOS 14+. The package pins the engine to the `feature/animation_motion_matching` branch until the animation stack merges into `develop`.

## Assets

Placeholder assets while real motion data lands:

- `redplayer` rig + `idle` clip from the engine's test resources.
- `run_forward` / `walk_forward` are generated from the engine's in-place `running` clip by injecting linear root travel (2.35 m/s and 0.94 m/s) — real traveling locomotion for the motion database, synthetic until mocap replaces it.

The demo is written so assets swap without code changes: drop in new `.untold` clips (e.g. retargeted [ChingMu MotionDecode](https://huggingface.co/datasets/CMRobot/MotionDecode) captures), list them in `configureZombieAnimation`, and the motion database rebuilds from whatever is loaded.

Planned motion data attribution: *Motion data: ChingMu MotionDecode Data Openness Program* (non-commercial use with attribution, per its access terms).

## License

MPL-2.0, matching the engine. This demo is non-commercial.

## Animations

The zombie's animation clips are cooked from [MoCap Online's Zombie Pro
pack](https://mocaponline.com/products/ue4-zombie-pro), whose license does
not permit redistributing animation data — so this repository contains no
clips, only the code. To run the demo:

- own the pack, export the sequences as glTF, and cook them with the
  Untold Engine Blender add-on into
  `Sources/CoolZombie/Resources/Animations/<clip>/<clip>.untold`, or
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
