# CoolBasket 🏀

Mixed-reality basketball for Apple Vision Pro, built on Untold Engine — and
the first real consumer of the engine's **physics backend plugin seam**
(untoldengine/UntoldEngine discussion #1116, PRs #1123/#1129/#1139/#1140).

Look at the floor and pinch to put a hoop in your room. Pick a ball up by
pinching near it, by closing your hand on it — catch a bounce — or by taking
it between your two palms; flick, open or part your hands to throw. Your hands
also dribble and swat. Drop as many balls as you like — every one can be grabbed, thrown and scored with. They
bounce off your **real floor, walls and furniture** (ARKit plane detection; the ceiling is left out, so a lob can go up),
off the backboard, the rim and each other — put one down through the hoop to
score.

## What's inside

| Piece | What it demonstrates |
|---|---|
| `CoolBasketPhysicsBackend` | A complete pure-Swift `PhysicsBackend`: dynamic spheres vs. real-world planes, static box and sphere colliders, and kinematic hand bodies; restitution/friction/rolling; fixed-capacity contact & trigger buffers drained through the engine's `PhysicsEventSink`. |
| `CoolBasketPlugin` | `PhysicsBackendPlugin` manifest + `registerCoolBasketPhysics()` — installed before renderer creation, driven by the engine's `PhysicsCoordinator`, zero engine changes. |
| `CoolBasketScene` | The ball and the hoop are artist models (`Resources/Models`, cooked to `.untold` from Blender: a size-7 ball with baked seam and pebble textures, a regulation glass-and-post unit with its net, lowered to a 2.75 m rim — 3.05 m proved too high to play under in a room). What the ball hits is analytic and invisible: boxes for the post, base and glass, a ring of static **sphere** colliders for the rim, and an under-rim **trigger volume** — all in the engine-owned `RigidBodyComponent`/`ColliderComponent` vocabulary. Grabbing removes the ball's body components, releasing re-adds them. |
| `CoolBasketNet` | The net swings. On the Jolt backend the model's net is driven by a **soft body** (Jolt's own XPBD through the plugin's side channel): a lattice of 84 particles read off the artist's rest geometry — the 12 rim hooks pinned, 5 rows of knots, the open bottom scallops — joined by near-rigid cords, plus a soft spring from every knot to a pinned ghost at its rest position, standing in for the cord's bending stiffness so the net keeps the artist's shape and swings back (the net feels a third of gravity: at full weight its own tension stiffens the diamonds and a swish barely moves it; tuned so a swish flares it a hand's width and it settles in about a second). The ball and the net collide both ways. Every frame the artist's net meshes (cords, knots, scallops — ~28 k vertices) are skinned to the nearest cord and written straight into their vertex buffers. On the built-in backend the net stays the model's static mesh. |
| `CoolBasketGame` | Gaze-driven hoop placement with a ghost preview. Any number of equal balls: three holds from the tracked hands — a pinch near a ball, a hand closing on it (fingers curling, read off the skeleton), or the ball between two palms — carried at the pinch point, on the palm or between the palms, and thrown with the hands' velocity when they open or part (`CoolBasketGrabRules`, pure and tested; grabbing removes the body, releasing re-adds it through the component seam); a ball that falls out of the world or rolls far away is removed (the Drop button makes a new one). A hand that leaves the cameras' view — looking up at the hoop takes it there — keeps the ball: mid-swing that is the throw, otherwise the ball waits until the hand is seen again (the other hand may take it). Score via `PhysicsEvents.onTrigger`, counting only a downward pass through the rim. |
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
opens: the shared [UntoldJoltPhysics](../Plugins/UntoldJoltPhysics) plugin
(Jolt Physics, the default — the net only swings on it), or the demo's own
pure-Swift backend. The choice persists; the engine's registry locks on the
first physics step, so switching afterwards needs an app restart.
`-physicsEngine jolt` / `-physicsEngine coolBasket` select it from the command
line. The window also shows the rim height and what the hands are holding.

The backend itself is platform-independent:

```bash
swift test   # unit tests: bounce, rest, bounded planes, box rebound, trigger, the swat, the rim, a made basket, the net, the throw
```

Automated simulator runs can skip the gaze-and-pinch steps with the launch
arguments `-autoOpenSpace` (opens the immersive space at launch),
`-autoPlaceHoop` (confirms the hoop placement after a short beat) and
`-autoDropBalls` (drops five balls in front of the hoop), `-autoDropThroughRim`
(drops one ball straight through the rim — a swish, for watching the net),
`-autoPlaceDistance <m>` (puts the hoop that far ahead; the simulator's fixed
view sees the rim only from about 5 m), and pick the backend
with `-physicsEngine jolt` or `-physicsEngine coolBasket`. Dropping balls is the
quickest way to see the backends apart: the built-in backend resolves no
ball-against-ball contact, so balls fall through each other; Jolt piles them.

## Coming next

A net for the built-in backend too (a CPU XPBD solver over the same lattice,
reusing its low-restitution "catch" planes and `nudgeBody` reaction channel),
and cords with real bending stiffness (Jolt's Cosserat rods) in place of the
shape springs.
