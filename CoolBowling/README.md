# CoolBowling 🎳

Mixed-reality bowling for Apple Vision Pro on Untold Engine, running on the
shared [UntoldJoltPhysics](../Plugins/UntoldJoltPhysics) plugin — the demo
that needs a real rigid-body solver: ten pins that stack, wobble, topple and
knock each other over.

Look at your real floor where the foul line should be and pinch: a lane runs
away from you, bumpers and all, with ten pins racked at the far end. Pinch
near the ball to pick it up and roll it. Pins down are counted from their
poses; a full rack is a strike.

## What's inside

| Piece | What it demonstrates |
|---|---|
| `CoolBowlingScene` | The lane and bumpers (static boxes), ten pins (a lathe mesh built at runtime by `CoolBowlingPinMesh` and handed to the engine with `setEntityMeshDirect`, with a **convex-hull collider** from the same profile), the ball (dynamic sphere, 6 kg), the placement ghost and two kinematic hand bodies — all in the engine-owned `RigidBodyComponent`/`ColliderComponent` vocabulary. |
| `CoolBowlingGame` | Gaze-driven lane placement, pinch grab and roll with the tracked hand velocity, pins-down scoring from pin orientation and displacement, re-rack by teleporting pins through the backend, lost-ball recovery, contact-driven sounds. |
| `CoolBowlingWorld` | ARKit planes as Jolt environment slabs, plus the game's side channel (body state, teleports). |
| `CoolBowlingSpatialSession` | Hand tracking (predicted poses), plane detection (floor-classified planes preferred), head tracking. |
| `CoolBowlingAudio` | Synthesized thud, pin clack and strike fanfare in an AVAudioSourceNode mixer. |

The pin mesh is revolved from a profile at runtime (the engine's file
loaders only take cooked `.untold` assets); `Scripts/make_bowling_textures.swift`
paints the ball, pin and lane textures. Everything is deterministic, no assets
are hand-made.

## Run it

Open `Examples/CoolBowlingVisionOS/CoolBowlingVisionOS.xcodeproj` and run the
`CoolBowlingVisionOS-visionOS` scheme on a Vision Pro (or the simulator — no
real surfaces there, but a fallback floor keeps everything in play). Press
**Step onto the Lane**, grant hand-tracking and surroundings permissions,
place the lane, and roll.

Launch arguments for unattended simulator runs: `-autoOpenSpace` (opens the
immersive space), `-autoPlaceLane` (confirms placement after a short beat) and
`-autoRoll` (rolls the ball from the foul line into the rack).

```bash
swift test   # lane geometry, pin hull, pins-down predicate, a rolled ball knocking pins over on Jolt
```
