# CoolBall 🏀

Mixed-reality basketball for Apple Vision Pro, built on Untold Engine — and
the first real consumer of the engine's **physics backend plugin seam**
(untoldengine/UntoldEngine discussion #1116, PRs #1123/#1129/#1139/#1140).

Look at the floor and pinch to put a hoop in your room. Pinch near the ball to
pick it up, flick to throw; your hands also dribble, swat and catch. The ball
bounces off your **real floor, walls and furniture** (ARKit plane detection),
off the backboard and the rim — put it down through the hoop to score.

## What's inside

| Piece | What it demonstrates |
|---|---|
| `CoolBallPhysicsBackend` | A complete pure-Swift `PhysicsBackend`: dynamic spheres vs. real-world planes, static box and sphere colliders, and kinematic hand bodies; restitution/friction/rolling; fixed-capacity contact & trigger buffers drained through the engine's `PhysicsEventSink`. |
| `CoolBallPlugin` | `PhysicsBackendPlugin` manifest + `registerCoolBallPhysics()` — installed before renderer creation, driven by the engine's `PhysicsCoordinator`, zero engine changes. |
| `CoolBallScene` | Ball, hoop (pole + backboard as static boxes, the rim as a ring of static **sphere** colliders) and an invisible under-rim **trigger volume**, all expressed with the engine-owned `RigidBodyComponent`/`ColliderComponent` vocabulary. |
| `CoolBallGame` | Gaze-driven hoop placement with a ghost preview. Grab/throw via pinch (release velocity from tracked hand motion — grabbing removes the body, releasing re-adds it through the component seam). Score via `PhysicsEvents.onTrigger`, counting only a downward pass through the rim. |
| `CoolBallSpatialSession` | visionOS ARKit adapter: hand tracking (predicted poses), plane detection feeding the backend's world planes, and head tracking for placement. The real floor height is measured from the detected planes; the simulator falls back to a flat floor. |

The heavyweight backend (Jolt) will live in its own package later; this demo
proves every seam the engine exposes — body lifecycle both ways, kinematic
writes, transform read-back, contact events, triggers — with the whole
simulation in a few hundred lines of Swift.

## Run it

Open `Examples/CoolBallVisionOS/CoolBallVisionOS.xcodeproj` and run the
`CoolBallVisionOS-visionOS` scheme on a Vision Pro (or the simulator — no real
surfaces there, but the fallback floor keeps the ball in play). Press
**Step onto the Court**, grant hand-tracking and surroundings permissions,
place the hoop, and shoot.

The backend itself is platform-independent:

```bash
swift test   # 10 unit tests: bounce, rest, bounded planes, box rebound, trigger, the swat, the rim, a made basket
```

Automated simulator runs can skip the gaze-and-pinch steps with the launch
arguments `-autoOpenSpace` (opens the immersive space at launch) and
`-autoPlaceHoop` (confirms the hoop placement after a short beat).

## Coming next

An XPBD net hanging from the rim, reusing the backend's low-restitution
"catch" planes and `nudgeBody` reaction channel.
