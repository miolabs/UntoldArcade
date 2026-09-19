# CoolBowling 🎳

Mixed-reality bowling for Apple Vision Pro on Untold Engine, running on the
shared [UntoldJoltPhysics](../Plugins/UntoldJoltPhysics) plugin — the demo
that needs a real rigid-body solver: ten pins that stack, wobble, topple and
knock each other over.

Look at your real floor where the foul line should be and pinch: the studio's
alley appears, composed as in its Blender scene — a parquet approach with the
ball return unit standing on it, the lane between its gutters (stretched to a
room-sized length), ten pins racked at the far end and the pinsetter cover
behind them. Pick the ball off the return's rack and roll it. Gutter balls
are gutter balls. The ball vanishes under the cover and comes back up through
the return's hood; two balls a frame, the deadwood cleared in between, a
fresh rack after a strike or the second ball. Pins down are counted from
their poses.

The alley is the game's, not the room's: a real surface that cuts into it (a
chair on the lane, a table over the return) is left out of the simulation
altogether, so the ball rolls through it. The floor, and every surface that
stays clear of the alley, remains solid.

## What's inside

| Piece | What it demonstrates |
|---|---|
| `CoolBowlingScene` | The alley as the studio's Blender scene, in its coordinates: approach, lane with gutters and rails (stretched to `laneLength`), arrows, deck spots, pinsetter cover, ball return unit, pins and ball are **artist models** (`Resources/Models/*.untold`, loaded with `setEntityMesh`) with **analytic, invisible colliders**: a convex hull of the regulation profile per pin, a sphere for the ball (6 kg), boxes for the lane's surface, the rails, the cover's walls and the return unit's rails (the ball comes up through its hood; the track from the pit is under the floor); the gutters and the approach are the room's floor. Plus the placement ghost and two kinematic hand bodies — all in the engine-owned `RigidBodyComponent`/`ColliderComponent` vocabulary. |
| `CoolBowlingGame` | Gaze-driven lane placement, pinch grab and roll with the tracked hand velocity, pins-down scoring from pin orientation and displacement, the pit → return → frame cycle (deadwood parked by dropping its body, re-rack by teleporting pins through the backend), lost-ball recovery, contact-driven sounds. |
| `CoolBowlingWorld` | ARKit planes as Jolt environment slabs, minus those intersecting the alley's keep-out box (a separating-axis test), plus the game's side channel (body state, teleports). |
| `CoolBowlingSpatialSession` | Hand tracking (predicted poses), plane detection (floor-classified planes preferred), head tracking. |
| `CoolBowlingAudio` | Synthesized thud, pin clack and strike fanfare in an AVAudioSourceNode mixer. |

The pins, the ball, the pinsetter cover and the ball-return unit are cooked
`.untold` models under `Sources/CoolBowling/Resources/Models` (the ball
carries its own baked textures); `Scripts/make_bowling_textures.swift` paints
the lane texture, which is the one thing still generated.

## Run it

Open `Examples/CoolBowlingVisionOS/CoolBowlingVisionOS.xcodeproj` and run the
`CoolBowlingVisionOS-visionOS` scheme on a Vision Pro (or the simulator — no
real surfaces there, but a fallback floor keeps everything in play). Press
**Step onto the Lane**, grant hand-tracking and surroundings permissions,
place the lane, and roll.

Launch arguments for unattended simulator runs: `-autoOpenSpace` (opens the
immersive space), `-autoPlaceLane` (confirms placement after a short beat) and
`-autoRoll` (bowls four balls from the foul line, one per frame step) and
`-hideWindow` (closes the control window so a screenshot sees the alley).

```bash
swift test   # alley geometry, pit and return, frame rule, keep-out filter, a rolled ball knocking pins off the lane into the pit on Jolt
```
