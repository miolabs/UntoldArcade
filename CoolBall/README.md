# CoolBall ⚽️

Mixed-reality football for Apple Vision Pro, built on Untold Engine — and the
first real consumer of the engine's **physics backend plugin seam**
(untoldengine/UntoldEngine discussion #1116, PRs #1123/#1129/#1139/#1140).

**Kick the ball with your foot** — step into it or swing your leg through it.
Vision Pro tracks no legs, so an invisible boot-sized collider at floor level
follows your body (head tracking, leading ahead of your motion) and sweeps
through the ball with your momentum. Pinch near the ball to pick it up and
throw it; your hands also catch and make goalkeeper saves. The ball bounces
off your **real floor, walls and furniture** (ARKit plane detection), and off
the goal standing in your room — put it between the posts to score.

## What's inside

| Piece | What it demonstrates |
|---|---|
| `CoolBallPhysicsBackend` | A complete pure-Swift `PhysicsBackend`: dynamic spheres vs. real-world planes, static boxes and kinematic hand bodies, restitution/friction/rolling, fixed-capacity contact & trigger buffers drained through the engine's `PhysicsEventSink`. |
| `CoolBallPlugin` | `PhysicsBackendPlugin` manifest + `registerCoolBallPhysics()` — installed before renderer creation, driven by the engine's `PhysicsCoordinator`, zero engine changes. |
| `CoolBallScene` | Ball, goal (posts + crossbar as static bodies) and an invisible goal-line **trigger volume**, all expressed with the engine-owned `RigidBodyComponent`/`ColliderComponent` vocabulary. |
| `CoolBallGame` | The foot: a kinematic boot collider at floor level driven from head tracking (no leg tracking exists), leading ahead of your motion so stepping/swinging kicks with your body's momentum. Grab/throw via pinch (release velocity from tracked hand motion — grabbing removes the body, releasing re-adds it through the component seam). Score via `PhysicsEvents.onTrigger`. |
| `CoolBallSpatialSession` | visionOS ARKit adapter: hand tracking (predicted poses) + plane detection feeding the backend's world planes. Simulator falls back to a flat floor at the world origin. |

The heavyweight backend (Jolt) will live in its own package later; this demo
proves every seam the engine exposes — body lifecycle, kinematic writes,
transform read-back, events, triggers — with the whole simulation in ~500
lines of Swift.

## Run it

Open `Examples/CoolBallVisionOS/CoolBallVisionOS.xcodeproj` and run the
`CoolBallVisionOS-visionOS` scheme on a Vision Pro (or the simulator — no real
surfaces there, but the fallback floor keeps the ball in play). Press
**Step onto the Pitch**, grant hand-tracking and surroundings permissions, and
kick off.

The backend itself is platform-independent:

```bash
swift test   # 8 unit tests: bounce, rest, bounded planes, box rebound, goal trigger, the kick
```
