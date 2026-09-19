# CoolBasket 🏀

Mixed-reality basketball for Apple Vision Pro, built on Untold Engine — and
the first real consumer of the engine's **physics backend plugin seam**
(untoldengine/UntoldEngine discussion #1116, PRs #1123/#1129/#1139/#1140).

Look at the floor and pinch to put a hoop in your room. Pinch near a ball to
pick it up, flick to throw; your hands also dribble, swat and catch. Drop as
many balls as you like — every one can be grabbed, thrown and scored with. They
bounce off your **real floor, walls and furniture** (ARKit plane detection),
off the backboard, the rim and each other — put one down through the hoop to
score.

## What's inside

| Piece | What it demonstrates |
|---|---|
| `CoolBasketPhysicsBackend` | A complete pure-Swift `PhysicsBackend`: dynamic spheres vs. real-world planes, static box and sphere colliders, and kinematic hand bodies; restitution/friction/rolling; fixed-capacity contact & trigger buffers drained through the engine's `PhysicsEventSink`. |
| `CoolBasketPlugin` | `PhysicsBackendPlugin` manifest + `registerCoolBasketPhysics()` — installed before renderer creation, driven by the engine's `PhysicsCoordinator`, zero engine changes. |
| `CoolBasketScene` | The ball and the hoop are artist models (`Resources/Models`, cooked to `.untold` from Blender: a size-7 ball with baked seam and pebble textures, a regulation glass-and-post unit with its net, lowered to a 2 m rim). What the ball hits is analytic and invisible: boxes for the post, base and glass, a ring of static **sphere** colliders for the rim, and an under-rim **trigger volume** — all in the engine-owned `RigidBodyComponent`/`ColliderComponent` vocabulary. Grabbing removes the ball's body components, releasing re-adds them. |
| `CoolBasketGame` | Gaze-driven hoop placement with a ghost preview. Any number of equal balls: grab the nearest via pinch, throw with the tracked hand velocity (grabbing removes the body, releasing re-adds it through the component seam), lost balls come back. Score via `PhysicsEvents.onTrigger`, counting only a downward pass through the rim. |
| `CoolBasketSpatialSession` | visionOS ARKit adapter: hand tracking (predicted poses), plane detection feeding the backend's world planes, and head tracking for placement. The real floor height is measured from the detected planes; the simulator falls back to a flat floor. |

The heavyweight backend (Jolt) will live in its own package later; this demo
proves every seam the engine exposes — body lifecycle both ways, kinematic
writes, transform read-back, contact events, triggers — with the whole
simulation in a few hundred lines of Swift.

## Run it

Open `Examples/CoolBasketVisionOS/CoolBasketVisionOS.xcodeproj` and run the
`CoolBasketVisionOS-visionOS` scheme on a Vision Pro (or the simulator — no real
surfaces there, but the fallback floor keeps the ball in play). Press
**Step onto the Court**, grant hand-tracking and surroundings permissions,
place the hoop, and shoot.

The control window's **Physics** picker chooses the backend before the Court
opens: the demo's own pure-Swift backend, or the shared
[UntoldJoltPhysics](../Plugins/UntoldJoltPhysics) plugin (Jolt Physics). The
choice persists; the engine's registry locks on the first physics step, so
switching afterwards needs an app restart. `-physicsEngine jolt` selects it
from the command line.

The backend itself is platform-independent:

```bash
swift test   # 10 unit tests: bounce, rest, bounded planes, box rebound, trigger, the swat, the rim, a made basket
```

Automated simulator runs can skip the gaze-and-pinch steps with the launch
arguments `-autoOpenSpace` (opens the immersive space at launch),
`-autoPlaceHoop` (confirms the hoop placement after a short beat) and
`-autoDropBalls` (drops five balls in front of the hoop), and pick the backend
with `-physicsEngine jolt` or `-physicsEngine coolBasket`. Dropping balls is the
quickest way to see the backends apart: the built-in backend resolves no
ball-against-ball contact, so balls fall through each other; Jolt piles them.

## Coming next

A simulated (XPBD) net — the model's net is a static mesh for now — reusing the backend's low-restitution
"catch" planes and `nudgeBody` reaction channel.
