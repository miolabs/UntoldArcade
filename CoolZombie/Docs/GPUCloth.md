# The shirt on the GPU: an XPBD cloth solver beside the Jolt one

Design, 2026-11-03, for the `feature/zombie_cloth` line at 4c98053 (the
engine checkout is the miolabs fork of UntoldEngine at 7348a52f, the Jolt
plugin at abb4517). Paths are relative to the package root unless they
name the engine (`.build/checkouts/UntoldEngine/Sources/UntoldEngine`,
written `E/` below), the Jolt plugin (`.build/checkouts/UntoldJoltPhysics/
Sources`, `J/`), Jolt itself (`.build/checkouts/JoltPhysics/Jolt`, `JP/`)
or the CoolCloth demo (`/Users/godshadow/Projects/Untold/UntoldArcade/
CoolCloth`, `CC/`). Every count below was re-measured on the sidecar as
cooked on 2026-11-03 (`Sources/CoolZombieKit/Resources/Models/Zombie/
Zombie.cloth.json`, 2,948,037 bytes) unless a file and line says otherwise.

## 1. Why

Three headset rounds have judged the shirt as the README's "Cloth" section
built it: a 3,995-particle proxy of the artist's shell, a Jolt skinned soft
body held within its slack of the skin, a 1 mm back-stop behind the skinned
surface, eleven convex hulls fitted to the skin as colliders, and the
29,402-vertex shell bound to the proxy's triangles and written over the
body's deformation every frame (README.md:774-830). On 2026-10-31 the
headset read it as paper while its edges were held at 1e-6 m/N
(README.md:796-798), and the compliances went to 1e-2 / 2e-2 / 0.3 m/N so
the triangles could give in-plane (README.md:805-814); on 2026-11-02 the
ragdoll's capsules, which stand 47 mm off the pelvis and 67 mm off the
lower spine (README.md:905-907), were replaced by the eleven skin-fitted
hulls, at the price of a Jolt step of 3.4 ms median on the Mac against
1.7 ms without them (README.md:916-918); on 2026-11-03 the rolled cuffs
were pinned whole and a wrist band stepped to the sleeve, because the
drawn shirt had torn into flat shards around a swinging forearm where a
pinned corner met a free one (README.md:343-350). After the third round
the owner's verdict stood: still not a shirt — paper-like motion, coarse
crumples that do not fall under gravity, and skin showing through at the
arms. Tripling the slack (`-clothSlack 3`, ZombieCloth.swift:287-293)
changed little, so the tether is not the limit.

What limits the Jolt shirt is its resolution and its solver. At 3,995
particles the proxy's median edge is 17.5 mm (cook, `shirt proxy: edges
8.5/17.5/39.1 mm`, scratchpad cook_cuff.log:70), so the smallest fold it
can show is about five edges long, 8.5 cm; a shirt's folds read at 3-5 cm,
which needs 6-10 mm spacing, four times the particles, and Jolt solves its
edges one thread per soft body (ZombiePhysics.swift:112-118), so four times
the particles is four times the 3.4 ms. The solver itself runs eight
Gauss-Seidel passes of 1.25 ms per headset frame (two collision steps of
`collisionSteps` 2, ZombieXRGame.swift:99-100, times `iterationsPerStep` 4,
ZombieCloth.swift:222; the sub-step is the collision step over the
iterations, JP/Physics/SoftBody/SoftBodyMotionProperties.cpp:953), applies
the skin constraint before the edges so neither the slack clamp nor the
back-stop is exact at a pass's end (SoftBodyMotionProperties.cpp:1043-1047;
README.md:792-794 measures the worst cuff 3 mm behind its target), and
interpolates the skinned target only over the iterations of the first
collision step after a feed (SoftBodyMotionProperties.cpp:519-532;
ZombieCloth.swift:1041-1045 documents it as a limitation). The owner has
decided to replace the Jolt soft body with a GPU XPBD solver in Metal
compute, as CoolCloth runs its 128x128 sheet (CC/Sources/CoolCloth/
CoolClothRenderExtension.swift:252-270), and to keep everything else of
the pipeline: the Blender prep, the body's weights on the proxy, the slack
schedule, the hulls, the shell binding, the kit tests, the two hosts, the
pickers and the launch arguments. The Jolt cloth stays selectable for the
A/B while the GPU one matures. The GPU's price for the particle count is
nearly flat where Jolt's is linear: a 3,995-particle frame on the GPU is
dispatch-latency bound (about 33 dispatches of a few thousand threads), and
a 16,000-particle one costs about twice as much, not four times.

## 2. Design

### Thesis

The solver is swapped behind a protocol INSIDE `ZombieCloth`, not beside
it. `ZombieCloth` makes exactly fourteen calls into the Jolt backend —
`addSoftBody` (ZombieCloth.swift:982), `removeSoftBody` (802, 1087),
`skinSoftBody` (1200, 1245), `setSoftBodySkin` (1201, 1263),
`readSoftBodyVertices` (1421, 1455-1456, 1622), `isSoftBodyActive` (1396,
1567, 1615), `setSoftBodyActive` (1398), `setSoftBodyLayer` (1393),
`addKinematicConvexHull` (1014-1017), `setKinematicTransform` and
`setKinematicTarget` (1059-1060) and `removeKinematicBody` (1089) — and
everything else in its 1,631 lines is solver-independent: the shell
(`RenderShell`, 430-539), the vertex grid and the binding (633-667,
886-935), the override arrays (683-687, 1342), the joints (`placeJoints`,
1153-1171), the ramp and the hard skin (1194-1265), the range, the sleep
and the runaway (1271-1400), the report (1522-1585) and the test accessors
(1590-1631). A sibling `ZombieGPUCloth` would duplicate those thousand
lines and drift between the two arms of the A/B; a soft-body abstraction in
the plugin's `PhysicsBackend` would cost a plugin PR and a pin in phase 1.
So a `ClothSolver` protocol takes those fourteen calls, `JoltClothSolver`
carries them verbatim, `GPUClothSolver` is new, and `ZombieChaseGame`
keeps its `cloth: ZombieCloth?` (ZombieChaseGame.swift:240) and its
`beginUpdate` / `step` / `readBack` order (806-812) untouched.

The GPU solver is an XPBD "small steps" solver over the proxy as a CSR
graph: sixteen substeps of 0.625 ms per 10 ms headset frame, one Jacobi
gather per substep, the distance constraints Jolt builds today (one per
edge, one across every interior edge; 10,425 and 10,425 after the pin-pin
drop), the slack ball and the back-stop plane applied AFTER the edges so
they are exact, the thirteen joints slerped per substep so the skinned
target moves continuously inside the frame, the eleven hulls as plane
sets (832 planes) with the most-facing-plane push-out Jolt's hull shape
does, the floor and the balls as CoolCloth's plane and spheres. It runs on
its own `MTLCommandQueue`: fed inside `willStep` as today, encoded and
committed at `beginUpdate` — after Jolt's step, so the balls it sees are
this frame's — and waited for at the first read in `readBack`, so the
game's own step overlaps the GPU and the particles are current for the same
frame's override, as they are on the Jolt path. Phase 1 needs no engine
change and no prep change: positions come back to the CPU (64 KB) and the
existing `RenderShell` and `setEntityDeformationOverride` path draws the
shirt. Phase 2 cooks a 16k proxy as a second sidecar and moves the shell
evaluation to a kernel; phase 3 is the one engine PR (a buffer-sourced
override, a primary-eye guard on the deformation pass, the override ring
one slot deeper).

### The solver

Per substep of length dt, every particle i with inverse mass w_i (0 for the
532 pins, 1/particleMass = 20,000 1/kg otherwise, ZombieCloth.swift:225,
958) is predicted as Jolt does it (SoftBodyMotionProperties.cpp:329-349):
v += g dt, v *= max(0, 1 - linearDamping dt) with linearDamping 4
(ZombieCloth.swift:260), prev = x, x += v dt. Jolt's linear damping factor
is kept rather than CoolCloth's exp(-damping dt) (CC/Shaders/
CoolCloth.metal:116) so the 4 1/s tuning carries over exactly; both forms
lose about 98 % of a velocity per second at this value, and whether that is
what keeps the crumples from falling is one of the day-4 sweeps below
(`gpuDamping`). The edge pass is CoolCloth's gather (CoolCloth.metal:
152-193) over the particle's CSR run instead of the 12-offset grid table:
for every entry (neighbour j, rest length, family, region) d = x_i - x_j,
alpha = compliance[family] x regionScale[region] / dt^2, delta_lambda =
-(|d| - rest) / (w_i + w_j + alpha), correction += w_i delta_lambda d/|d|,
and x_i += relaxation x correction. The compliances are Jolt's own
(stretch 1e-2, shear 2e-2 for the cross pairs that are quad-like, bend 0.3
m/N, ZombieCloth.swift:248-250), in the same units, because Jolt's edge
correction is d (len - rest) / (len (w0 + w1 + compliance/dt^2))
(SoftBodyMotionProperties.cpp:594-599), the same formula; at dt 0.625 ms a
stretch edge gives back 40,000 / (40,000 + 1e-2 / 3.9e-7) = 61 % of its
violation per pass and a bend pair 40,000 / (40,000 + 0.3 / 3.9e-7) =
4.9 %, where Jolt's 1.25 ms passes give 86 % and 17 %; XPBD's equilibrium
stretch does not depend on the step (README.md:799-805), only the rate of
convergence does, and the GPU runs twice the passes at half the length.

The relaxation is a knob with two forms, because the two designs that
proposed them are not the same thing: CoolCloth multiplies the RAW sum of
the corrections by 0.5 (CoolCloth.metal:191-192, `p.compliance.w`), while
an averaged Jacobi applies omega x sum / count with omega about 1.5, which
at the proxy's mean degree of 10.44 is 0.14 of the raw sum, three and a
half times weaker per pass. The default is CoolCloth's raw sum at 0.5
(`gpuRelaxation` 0.5, `gpuAveragedJacobi` false), the averaged form is the
A/B (`-clothRelaxation 1.5 -clothAveragedJacobi on`), and
`testStretchResidualAtRest` (section 6) is the gate that decides which
holds the shirt's edges within 1 % at rest before any headset build. A
second gather per substep (`gpuIterations` 2) is the cheaper lever than
more substeps when the residual says so. Graph-coloured Gauss-Seidel was
rejected: the edge-plus-bend graph needs about 22 colours, 22 dispatches
of about a thousand threads per pass, dispatch-bound; Jacobi converges more
slowly per pass and the substeps pay it back (a small step's error falls
with dt^2).

The substep count follows the frame delta, never a constant
(E/ECS/EngineExtensions.swift:50-53 is the engine's contract): the frame
delta is clamped to [1/240, 1/30] s as CoolCloth does (CC/
CoolClothRenderExtension.swift:254), the substep length is 0.01 /
`gpuSubsteps` (16 by default, so 0.625 ms), and the count is
clamp(ceil(delta / substep), 1, 32): 16 at the headset's 10 ms
(ZombieXRGame.swift:131-134 — the display is 100 Hz, not the 90 Hz the
task text says), 18 at 11.1 ms, 27 at the Mac's 16.7 ms, 32 at a 30 fps
hitch. A frame longer than 18.3 ms reaches the cloth as several `willStep`
calls on one pose (E/Renderer/SimulationStepping.swift:25-33; the cloth's
own note at ZombieCloth.swift:1143-1152): the GPU solver accumulates the
calls' deltas and encodes once at `beginUpdate` with the sum, and since the
previous and the current joints are then identical the per-substep
interpolation is a no-op, so nothing jumps.

The constraint set is built once at attach from the sidecar's faces,
exactly as Jolt's `CreateConstraints` builds it (JP/Physics/SoftBody/
SoftBodySharedSettings.cpp:189-325; the bridge asks for it at
J/CJoltBridge/CJoltBridge.cpp:772-778): one distance constraint per unique
edge, one across every interior edge between the two opposite vertices
(Jolt's `.distance` bend, ZombieCloth.swift:962; a diagonal of a coplanar
quad gets the shear compliance, the rest the bend's), and no constraint
between two pins (SoftBodySharedSettings.cpp:218 keeps an edge only when
one end is movable; the bridge zeroes a pin's mass before that at
CJoltBridge.cpp:755). On the shirt that is 11,849 edges of which 1,424 are
pin-pin, 11,707 interior edges of which 1,282 bend pairs are pin-pin, 45
bend pairs that coincide with an edge, so 10,425 + 10,425 = 20,850
constraints and 41,700 CSR entries (two per constraint), 22 at most on a
particle and 10.44 on average (scratchpad judge_counts.py over the sidecar;
the three designs' figures of 46,434, 47,112 and 836 were wrong). Each
entry carries the neighbour, a two-bit family and a six-bit region index
(the slack value of the stiffer end, keyed into a 16-entry `regionScale`
table, all 1.0 by default) so a band can be stiffened or softened without a
layout change. Dihedral bending is not in phase 1: it is a four-particle
gather with its own compliance scale, Jolt's A/B arm uses the distance
form, and the question of whether the distance form's sign-blindness is
what holds the standing crumples is answered at 16k with the drape figure
of section 6 before anything is written.

### Skinned targets, slack and back-stop

`placeJoints` keeps this frame's thirteen joint world matrices and the last
frame's (ZombieCloth.swift:1153-1171, 569-574), and the skin matrix per
joint is jointWorld x inverseBindWorld (612). The CPU slerps the rotation
and lerps the translation between the two frames once per substep, 16 x 13
= 208 pairs, and uploads the 13 matrices per substep (16 x 13 x 64 B =
13,312 B); the predict kernel blends up to four of them per particle
(1 to 4 influences, 2.60 on average, ZombieCloth.swift:939) into this
substep's target and rotates the particle's rest normal (area-weighted over
its rest faces at attach) by the same blend into the back-stop normal. The
matrix slerp is kept over the cheaper lerp of two end targets because the
end-target chord of a 30 cm bone turning 10 degrees in a frame is 1.1 mm
off the arc at mid-frame, and because the hull frames are slerped the same
way, so the skin and the hulls agree at every substep. Jolt's normal is the
sum of the unit normals of the all-skinned faces around the vertex
evaluated on the targets (SoftBodyMotionProperties.cpp:1181-1203); the
rotated rest normal differs from it only where the fabric has stretched or
folded since the bind pose, and the hang and penetration tests
(section 6) hold the sign; if they fail at the 189 triangles with a pinned
corner and a free one, a one-gather kernel over the targets is the
fallback.

After the edge gather, in this order: the slack ball, r = maxDistance x
slackScale x multiplier (the sidecar's `maxDistance`, ZombieCloth.swift:978;
`multiplier` is the ramp, 0 to 1 over 0.25 s after a hard skin, 0 out of
range or in an unreached bind pose, 1242-1260); r == 0 — a pin, or any
particle while the multiplier is 0 — puts x on the target, as Jolt's
kinematic placement does (SoftBodyMotionProperties.cpp:565-569); else the
back-stop: unless the particle is one of the 148 body-facing ones (976-979;
the rolled cuffs and the collar's inside), s = dot(x - target, n) and if
s < -backstop (0.001 m) then x -= n (s + backstop) — Jolt's 40 m sphere
centred backstop + 40 m behind the target (SoftBodyMotionProperties.cpp:
537-553) is this plane within L^2 / 80 m, 0.28 mm at the largest 15 cm of
slack and 11 um at 3 cm; then the clamp |x - target| <= r (556-563). The
clamp is last, so a pin never moves and a free particle is never past its
slack at a substep's end, where Jolt's edge pass runs after the skin and
leaves the cuff 3 mm behind (README.md:792-794). A hard skin — the attach
(ZombieCloth.swift:846), a re-seat (824, 1115-1123), the LOD's return
(1298), a runaway (1338) — is x = prev = target and v = 0 for every
particle (SoftBodyMotionProperties.cpp:1205-1216), done on the CPU: the
solver waits for anything in flight, skins the 3,995 particles with the
CPU blend that `skinnedTargets` already does for the report (611-622, about
40 us) and writes the position, previous and velocity buffers directly,
since they are shared storage. That settles the two hard-skin cases the
designs left open — a runaway found in `readBack` after the frame's GPU
work has completed, and a re-seat fired from `physics.track` inside the
game step (ZombieChaseGame.swift:950, ZombiePhysics.swift:496) while that
work is in flight — without a second command buffer. The first feed after
a build is always hard, as the bridge enforces (CJoltBridge.cpp:948-957).

### The colliders

Jolt collides the cloth with whatever rigid bodies the layer matrix lets
through (ZombiePhysics.swift:273-297): the floor slab, the balls, the room
when the body is down, and the eleven kinematic hulls on
`skinColliderLayer` 9 (102), never the character or the ragdoll's parts
under the default model. The GPU shirt takes the hulls, the floor and the
balls in phase 1 and leaves the room boxes and the ragdoll's capsules
(`ragdollAndSkin`) to phase 4.

The hulls are the sidecar's eleven point sets (32 to 48 points each, 446
in all) turned into plane sets once at attach: every triple's plane kept
when all points lie on one side, deduplicated at 1e-4, which gives 87, 83,
82, 88, 66, 84, 82, 66, 70, 60 and 64 planes for the pelvis, the three
spine links, the neck, the two clavicles, the two upper arms and the two
forearms, 832 in all, under the 2n - 4 bound of 848 (scratchpad
judge_hulls.py); the brute force is about 190,000 triples x 48 tests, a few
milliseconds once, and the prep writes the planes itself in phase 2 so the
runtime can skip it. Per substep, each hull's world transform is the slerp
of its joint's frame between the two feeds, the same product `moveSkinColliders`
takes (ZombieCloth.swift:1055-1062), uploaded as world-from-hull rigid
transforms for the substeps of the frame plus the one before (17 x 11 x
64 B = 11,968 B at 16 substeps; a rigid inverse is a transpose in the
kernel). A particle tests the eleven bounding spheres, enters the planes of
the one to three hulls that pass, is inside iff every signed distance is
below `vertexRadius` (3 mm, ZombieCloth.swift:256), and is pushed along the
plane of the largest signed distance by radius minus that distance — the
most-facing plane, as `ConvexHullShape::CollideSoftBodyVertices` picks it
(JP/Physics/Collision/Shape/ConvexHullShape.cpp:1060-1090). Friction
against a hull is the one thing the Jolt path could not have: Jolt reads a
collider's velocity only from a dynamic body (ZombieCloth.swift:297-314),
so `skinColliderFriction` is 0. On the GPU the hull's own motion over the
substep is known (two consecutive frames of its transform), so the
tangential part of the particle's displacement relative to the hull's point
motion is scaled by (1 - `gpuHullFriction`); the default is 0 to match the
Jolt arm, 0.2 is the A/B value, and `testAMovingHullCarriesTheClothByFriction`
pins the effect. The elbow and the shoulder are gaps between adjacent
hulls where skin showed through at the arm swing; phase 4 bridges them
with a capsule per adjacent pair (CoolCloth's capsule block,
CoolCloth.metal:212-231), generated at attach from the two hulls'
centroids.

The floor is the plane at the floor top (`ZombiePhysics.setObstacles(_:
floor:)`, ZombiePhysics.swift:303-306; `ZombieChaseGame` knows it as
`configuration.floorY`, ZombieChaseGame.swift:279) with CoolCloth's contact:
y clamped to floor + radius and xz mixed 0.4 toward the previous position
(CoolCloth.metal:199-203). The balls are Jolt dynamic spheres on `ballLayer`
3 (ZombiePhysics.swift:51; radius 0.12 m and mass 0.6 kg, ZombieProps.swift:
19-20; the tests' ball is 0.06 m and 0.2 kg, ZombieClothTests.swift:
1435-1440): `ZombieChaseGame` hands the cloth a sphere provider that maps
`ZombieProps`' ball entities through `physics.backend.bodyState(for:)`
(J/UntoldJoltPhysics/JoltPhysicsBackend.swift:478-503, position and
velocity after this frame's step), up to 8 spheres (`ZombieProps.capacity`
8, ZombieProps.swift:21), and the kernel backs each centre along its
velocity to the substep's time, c_k = c - v (1 - (k + 1)/S) delta, so a
5 m/s ball that moves 5 cm inside a frame meets the fabric at every
substep where it is, not only where it ends. The contact is one-way: the
dent test asserts the cloth's displacement only (ZombieClothTests.swift:
1449), and the ball still bounces off the body because the ragdoll's parts
take it on their layer (ZombiePhysics.swift:49-50); what is lost is the
0.2 kg shirt's braking of a 0.6 kg ball (Jolt gives the impulse back,
SoftBodyMotionProperties.cpp:798-816), which is not visible.

### The sim mesh and the shell

Phase 1 simulates the 3,995 proxy as cooked, in Jolt's frame: positions
relative to the entity's origin at the attach, rotation identity
(ZombieCloth.swift:950-963; the bridge fixes the body frame at
CJoltBridge.cpp:804-805), so the targets, the hull frames, the floor and
the balls need no per-substep change of space and `particleWorldPositions`
is the buffer plus the origin. Mesh space was rejected: the cloth would
then simulate in a frame that turns and accelerates with the zombie, and
a shirt that does not swing when its wearer turns is the paper look by
another route. The shell keeps the triangle + barycentric + offset binding
(`RenderShell`, ZombieCloth.swift:430-539; prep `render_binding`,
prep_zombie.py:2707-2813): per slot pos = bary.(a, b, c) + o.x e1 + o.y n
+ o.z t and normal = r.x e1 + r.y n + r.z t in the triangle's frame
(530-531), 29,402 shell vertices driving 32,530 exported copies in the game
(README.md:1031-1032) and 29,402 slots in the tests' shell-only mesh.

Phase 2 raises the proxy to about 16,000 particles. Fold wavelength needs
four to five particles; at 16k the hexagonal spacing over the shirt's
0.9866 m^2 is 8.44 mm, the drawn shell's own median edge is 8.25 mm
(scratchpad shell_stats over zombie_bd.blend), so finer than 16k buys
nothing the shell can show, and 26k leaves 26 slivers and 10 non-manifold
edges after the prep's collapse. The shell's fabric itself is not the sim
mesh: it is a closed two-layer volume (26,042 vertices, a 1.15 mm median
layer gap, 41 vertices under 0.5 mm) whose outer layer alone has 1,826
triangles under 8 degrees and edges down to 0.12 mm (cook_cuff.log:60), so
the inner layer, the rims, the 21 rigid islands and the exporter's split
copies keep the binding in every option, and a shell vertex that survives
as a particle binds at bary (1, 0, 0) with a zero offset through the
existing `render_binding` without any code. The 16k cook is a SECOND
sidecar file, `Zombie.cloth16k.json`, selected by `Configuration.sidecar`,
so the Jolt arm keeps its 3,995 (Jolt at 16k is four times 3.4 ms and
refused with one printed line), and "GPU 4k" against "GPU 16k" stays a live
A/B; the tests already take a sidecar path from `COOLZOMBIE_CLOTH_SIDECAR`
(ZombieClothTests.swift:147-152).

### Scheduling and the hand-off to the drawn mesh

The frame runs, on the one frame thread (the visionOS compositor's render
thread on the headset, E/Renderer/UntoldEngine.swift:686-689 and
CoolZombieVisionOSXRApp.swift:723-743): `AnimationSystem.update`
(UntoldEngine.swift:707), the simulation step (714) — inside which
`PhysicsCoordinator.fixedUpdate` calls `backend.step`
(E/Physics/PhysicsCoordinator.swift:104-108) and the Jolt backend calls
`willStep` and then `ujolt_world_step` (JoltPhysicsBackend.swift:284-288)
— then the game update (717) = `cloth.beginUpdate()`, `step()`,
`cloth.readBack()` (ZombieChaseGame.swift:806-812), and the render (738).
The GPU solver keeps the Jolt path's zero-frame lag by splitting its work
over those three points: in `willStep` the joints are placed and the hulls'
frames taken as today (ZombieCloth.swift:1212-1226), the solver records the
feed (the slerped matrices, the slack multiplier, the frame's delta
accumulated) and encodes nothing; at `beginUpdate` (1137), after Jolt has
stepped, it reads the balls, fills its ring slot, encodes the frame's
substeps in one command buffer on its own queue and commits; at the first
read of positions — `readBack`'s `expandOverride` (1335, 1442-1504), the
asleep speed sample (1319, 1417-1435), a hard skin, or the tests'
`particleWorldPositions` (1619-1624) — it waits for that buffer once. The
game's own step (the motion matching, `physics.track`, the hits,
`applyRagdollPose`, ZombieChaseGame.swift:928-1106) runs between the commit
and the wait, so whatever of the GPU's time it covers is free; its length
on the headset is unmeasured, which is why the footnote prints the wait.
The test harness drives `backend.step`, `beginUpdate`, `track` and
`readBack` in the same order (ZombieClothTests.swift:665-674) and reads
`particles` after `frame()` returns (683), so the lazy wait satisfies every
existing test. The solver's own queue, not `renderInfo.commandQueue`
(E/Utils/Globals.swift:177; E/Renderer/RenderResources.swift:22-25 are
public), because on the engine's queue a cloth buffer committed during
update N queues behind render N-1 and the wait would absorb that frame's
GPU time; and not a render-extension pass, which runs in the submission
phase once per eye on the frame's command buffer
(E/Systems/RenderingSystem.swift:166-190; CoolCloth gates its own with
`currentEye == 0`, CC/CoolClothRenderExtension.swift:223), a frame late
for a CPU-written override and unreachable from the test harness, which has
no render graph. `-clothGPUWait off` is the one-frame-lag mode from day
one: the frame's command buffer ends with a 64 KB blit of the positions
into a three-slot read-back ring, `readBack` takes the last completed slot
and never waits, and the pinned cuff then trails a 2 m/s wrist by up to
2 cm; the footnote's `lag=1f` says it is in force.

The hand-off to the drawn mesh is the existing array API in phase 1:
`setEntityDeformationOverride(entityId:meshIndex:indices:positions:normals:)`
(E/Animation/MeshQuery.swift:109-131) copies the arrays element by element
into a three-slot ring of shared buffers (E/ECS/Components.swift:456-513)
that the deformation pass's `deformOverride` kernel applies after the
skin (E/Systems/DeformationSystem.swift:464-488). The positions are read
straight from the shared position buffer (`contents()`, no blit), turned
into mesh space (ZombieCloth.swift:1472-1477), the shell is evaluated on
the cores (503 us median / 1,008 us max on the M4 Max, 420-429) and written
(1342). Phase 2 moves the triangle frames and the shell to two kernels
whose shared output the CPU copies into the override arrays (about
32,530 x 2 float4 to SIMD3, 100-150 us) and phase 3 removes the copy with
the engine PR: a `setEntityDeformationOverride(entityId:meshIndex:buffers:)`
taking caller-owned `MTLBuffer`s of `uint`, `float4` and `float4` (the
layout `deformOverride` already consumes, E/Shaders/
DeformOverrideCompute.metal:19-34), stored as an alternate source in
`MeshDeformationOverride` and bound by `encodeOverride` in place of the
ring slot. The same PR guards `DeformationSystem.encode` with
`isPrimaryRenderEye()` (E/Systems/GraphBuilder.swift:943-945): the graph is
built and executed once per eye (RenderingSystem.swift:181-190) and the
deformation pass has no eye guard, so today the 71,328-vertex body is
compute-skinned twice per headset frame; and it makes the override ring
`maxInFlightCommandBuffers + 1` slots deep, since it is written before the
renderer waits on the semaphore exactly as the joint ring is, and the
joint ring holds the extra slot for that reason (E/Mesh/Skeleton.swift:
214-234 against Components.swift:457). The GPU path on the engine queue
sidesteps that race once phase 3 lands; phase 1 inherits it as the Jolt
path has it today.

### The Metal source and the build

The kernels live in `Sources/CoolZombieKit/Shaders/ZombieClothGPU.metal`,
excluded from the target and compiled by `Scripts/build-cloth-metallib.sh`
into five committed metallibs under `Sources/CoolZombieKit/Resources/
Shaders/` — `ZombieCloth-{macos,ios,iossim,xros,xrossim}.metallib` — the
CoolCloth script verbatim with the names changed (CC/Scripts/
build-metallib.sh:18-43: `xcrun -sdk <sdk> metal -mtargetos=<os> -c` then
`xcrun metallib`, the target OS matching the package's minimums, because a
metallib built against the SDK's own OS is refused at `makeLibrary` time on
an older device). The engine ships its kernels the same way (E Package.swift:
17-24, 107-114) and so does CoolCloth (CC/Package.swift:24-31), and no
runtime shader compilation exists in either tree; the tuning loop pays a
two-second script run per kernel change, and `testTheMetallibExposesTheKernels`
fails loudly on a stale build. The kit loads it with `device.makeLibrary(
URL:)` from `Bundle.module` through the engine's platform-suffix rule
(E/Renderer/RenderExtensions.swift:170-197, `resourceName(baseName:)`), so
`swift run CoolZombie`, the Xcode-built visionOS example and XCTest all find
the same file. The params struct is C-side `float4` lanes mirrored
field-for-field in Swift, bound with `setBytes` (CC/Shaders/
CoolClothShaderTypes.h:9-20, CC/Sources/CoolCloth/CoolClothShaderABI.swift:
4-26); every per-particle array is an `MTLBuffer`, since 3,995 targets are
63,920 B and `setBytes` stops at 4 KB.

### The Swift shape

New, in `Sources/CoolZombieKit/`:

`ZombieClothSolver.swift` (about 150 lines) declares

    protocol ClothSolver: AnyObject {
        func build(_ garment: ClothGarmentSetup, hulls: [ClothHullSetup]) -> Bool
        func destroy()
        var particleCount: Int { get }
        var hullCount: Int { get }
        func feed(_ feed: ClothFeed)                 // willStep: joints, multiplier, delta, hard
        func hardSkin(_ feed: ClothFeed)             // attach, re-seat, LOD return, runaway
        func beginFrame(spheres: [ClothSphere])      // beginUpdate: encode + commit (GPU)
        func readPositions(into: inout [SIMD3<Float>]) -> Int   // world space; waits once (GPU)
        func readPositionsAndNormals(into:normals:) -> Int      // shell-less garments, phase 5
        func setResting(_ resting: Bool, layer: ClothRestLayer)
        var isActive: Bool { get }
        var stats: ClothSolverStats { get }          // gpu ms, wait us, dispatches, onClamp, aabb
    }

with `ClothGarmentSetup` (origin, bind positions relative to it, faces,
inverse masses, influences, maxDistance already scaled, backstop per
particle, the body-facing set, the inverse bind matrices, the compliances,
damping, speed cap, radius), `ClothHullSetup` (joint index, points in the
joint's frame, friction), `ClothFeed` (13 joint world matrices now and
before, multiplier, delta, hard), `ClothSphere` (centre, radius, velocity)
and `ClothRestLayer` (awake/resting/inert with the Jolt layer number).

`ZombieClothJoltSolver.swift` (about 250 lines, moved code):
`JoltClothSolver` holds the `JoltSoftBody`, the `[JoltKinematicBody]` hulls
and `physics`; `build` is the descriptor now at ZombieCloth.swift:956-982
plus `addSkinColliders` (999-1030); `feed` is `skinSoftBody` +
`setSoftBodySkin` (1245, 1263) plus `moveSkinColliders` (1055-1062);
`hardSkin` is 1199-1202; `beginFrame` is a no-op (Jolt stepped inside
`backend.step`); `readPositions` is `readSoftBodyVertices`; `isActive` is
`isSoftBodyActive`; `setResting` is `setSoftBodyLayer` + `setSoftBodyActive`
(1393, 1398); `destroy` is 1087-1089. Behaviour identical, and the 28 tests
of `ZombieClothTests.swift` must pass unchanged behind it before a line of
GPU code lands.

`ZombieClothGPUSolver.swift` (about 750 lines): `GPUClothSolver` with
`init?(device: MTLDevice, configuration:)` (nil, one printed line, when the
metallib or a pipeline is missing); the CSR builder (`ConstraintGraph(faces:
pins:)` reporting its counts for the tests), the hull plane builder, the
substep rule, the joint and hull slerps, the ring of input slots
(`maxInFlightCommandBuffers + 1` = 4, Globals.swift:2164), `pendingCommandBuffer`
with the lazy wait, the read-back ring for the wait-off mode, the CPU hard
skin, the swept-AABB wake test, and `gpuMilliseconds` from
`gpuEndTime - gpuStartTime` in the completed handler, which works in release
(the XR loop's own deadline accounting uses the same stamps,
E/../UntoldEngineXR/UntoldEngineXR.swift:1449-1457, 1624-1626, where the
engine's frame stats are `ENGINE_STATS_ENABLED`-only, E/Profiling/
EngineStatsMonitor.swift:163-187). `ZombieClothGPUShaderTypes.swift` (about
80 lines) mirrors `ZCParams` (256 B), `ZCEntry` (8 B), `ZCHullHeader` (32 B)
and `ZCStats` (64 B) with a layout assertion in a test.

Changed: `Package.swift` adds `exclude: ["Shaders"]` and `.copy("Resources/
Shaders")` to the kit target after `.copy("Resources/Rooms")` (Package.swift:
50). `ZombieCloth.swift`: `Garment.soft: JoltSoftBody` (544) becomes
`solver: any ClothSolver`; `SkinCollider` (627-631) and `skinColliders` go
into the Jolt solver; `init` gains `device: MTLDevice? = nil`; `attach`
builds the solver per garment (`JoltClothSolver(physics:)` or
`GPUClothSolver(device:configuration:)`, falling back to Jolt with one line
when the GPU one cannot be built); `bind` fills a `ClothGarmentSetup`
instead of a `JoltSoftBodyDescriptor`; `willStep` calls `solver.feed`;
`beginUpdate` calls `solver.beginFrame(spheres: sphereProvider?() ?? [])`;
`sampleParticleSpeed`, `expandOverride` and `particleWorldPositions` call
`solver.readPositions`; `applyBodyRest` calls `solver.setResting`;
`hardSkinNow` calls `solver.hardSkin`; `isSoftBodyActive(ofGarment:)` is
`solver.isActive`; `skinColliderCount` is `solver.hullCount`; a public
`sphereProvider: (() -> [ClothSphere])?` and `floorY` are forwarded. The
`ZombieClothBody` protocol and `ZombieClothEntityBody` (22-113) are
untouched. `ZombieChaseGame.swift`: the two `ZombieCloth(asset:configuration:)`
calls (282, 1374) pass `renderInfo.device`; `attachCloth` (1355-1361) sets
`cloth.floorY = configuration.floorY` and the sphere provider from
`ZombieProps` (`ballEntities` made public) through
`physics.backend.bodyState(for:)`. `ZombiePhysics.swift` is unchanged in
phase 1.

### The switches in the hosts and the launch arguments

`ZombieCloth.Configuration` (ZombieCloth.swift:180-346) gains `enum Solver:
String, Sendable { case jolt, gpu }` and `solver = .jolt` (the default stays
Jolt until gate 2, so `testTheLaunchArgumentsSetTheClothConfiguration`,
ZombieClothTests.swift:2182-2256, only grows), `gpuSubsteps = 16`,
`gpuIterations = 1`, `gpuRelaxation: Float = 0.5`, `gpuAveragedJacobi =
false`, `gpuDamping: Float? = nil` (nil means `linearDamping`),
`gpuHullFriction: Float = 0`, `gpuWait = true` and `sidecar: String? = nil`
(phase 2); `apply(launchArguments:)` (354-382) parses `-clothSolver
jolt|gpu`, `-clothSubsteps <n>` (1...32), `-clothGPUIterations <n>`
(1...4), `-clothRelaxation <r>`, `-clothAveragedJacobi on|off`,
`-clothGPUDamping <d>`, `-clothHullFriction <f>`, `-clothGPUWait on|off`
and `-clothSidecar <name>` with the unknown-value print of line 361. The
existing `-cloth off|skin|world|ragdoll` and the collision-model pickers
stay orthogonal and apply to both solvers (`skinOnly` builds no hulls on
the GPU either). On visionOS a "Solver" segmented picker (Jolt / GPU) and a
"GPU substeps" picker (8 / 12 / 16 / 24) sit beside "Cloth" and "Cloth
iterations" (CoolZombieVisionOSXRApp.swift:600-623), the iterations picker
disabled for the GPU and the substeps one for Jolt, the holder clamping
`gpuSubsteps` to the offered counts as it does the iterations (237-248),
and `ZombieXRGame`'s print at 227-230 names the solver and the substeps.
On the Mac a "Solver" `optionGroup` follows the "Cloth" one
(AppDelegate.swift:142-143) and the rest is launch arguments, as the
iterations are today (ZombieScene.swift:92). The launch lines: `swift run
CoolZombie -play -inspect idle -debugLog -clothSolver gpu -clothSubsteps
16` and `xcrun simctl launch <udid> com.miolabs.CoolZombieVisionOS
-autoOpenSpace -clothSolver gpu`.

### The diagnostics line

`summary` (ZombieCloth.swift:1576-1585, the headset footnote's per-frame
line, CoolZombieVisionOSXRApp.swift:284-286) becomes, on the GPU path,
`cloth shirt[gpu]: 3995 particles 29402 shell vertices mult=%.2f
awake|asleep[ out of range] sim=on|off sub=%d it=%d feed=%.0fus gpu=%.2fms
wait=%.0fus lag=0f|1f read=%.0fus bind=%.0fus hard=%d runaway=%d
writes=%d`; `jolt=on|off` (1563-1570) becomes `sim=on|off` for both
solvers, `joltWakes` is printed by the Jolt arm only. `report` (1522-1553,
the Mac's once-a-second print under `-debugLog`, ZombieScene.swift:538-552)
adds `hulls=11 planes=832 stretch=10425 bend=10425 onClamp=%d%%` where
`onClamp` is the share of free particles sitting on their slack ball at
the frame's end from the stats kernel — the number that says whether the
look is bounded by the schedule or by the solver, which the `-clothSlack 3`
experiment could only guess at on Jolt's inexact clamp. `overrideWriteCount`
keeps counting once per awake in-range frame or ZombieScene.swift:548-550
warns. The headset's frame line prints zeros for cpu/gpu in release
(CoolZombieVisionOSXRApp.swift:287-298) and only `deadlineMisses` and the
worst overrun survive (299-301; UntoldEngineXR.swift:122-124), so the gates
read `gpu=` and `wait=` from the cloth's own stamps and the deadline count
from the engine's.

## 3. Data layout

All buffers are `MTLBuffer` `.storageModeShared` (unified memory; the CPU
reads positions without a blit) owned by the `GPUClothSolver` per garment;
N is the particle count (3,995 now, 15,994 for the phase-2 cook), S the
substep cap (32), ring 4 for anything the CPU rewrites while a buffer may
be in flight. Sizes in bytes.

| buffer | element | count | 3,995 | 15,994 |
| --- | --- | --- | --- | --- |
| posA, posB (ping-pong; w = inverse mass) | float4 | N each | 127,840 | 511,808 |
| prev (substep start) | float4 | N | 63,920 | 255,904 |
| vel | float4 | N | 63,920 | 255,904 |
| rest (bind pose, world minus origin) | float4 | N | 63,920 | 255,904 |
| restNormal (area-weighted at attach) | float4 | N | 63,920 | 255,904 |
| influences (ushort4 joints, half4 weights) | 16 B | N | 63,920 | 255,904 |
| slack (maxDistance x slackScale, backstop or +inf) | float2 | N | 31,960 | 127,952 |
| target, targetNormal (this substep) | float4 | N each | 127,840 | 511,808 |
| csrOffsets | uint | N + 1 | 15,984 | 63,980 |
| csrEntries (neighbour 24 bits, family 2, region 6; rest) | 8 B | 41,700 / ~168,000 | 333,600 | ~1,347,000 |
| skinMatrices ring (per substep, 13 joints) | float4x4 | 4 x S x 13 | 106,496 | 106,496 |
| hullWorld ring (per substep + 1, 11 hulls) | float4x4 | 4 x (S + 1) x 11 | 92,928 | 92,928 |
| hullPlanes (n.xyz, d in the joint frame) | float4 | 832 | 13,312 | 13,312 |
| hullHeaders (first, count, bounding sphere) | 32 B | 11 | 352 | 352 |
| spheres ring (centre + radius, velocity) | 2 x float4 | 4 x 8 | 1,024 | 1,024 |
| params ring | 256 B | 4 | 1,024 | 1,024 |
| stats ring (maxSpeed, nan, pelvis distance, onClamp, aabb) | 64 B | 4 | 256 | 256 |
| readBack ring (wait-off mode) | float4 | 3 x N | 191,760 | 767,712 |
| phase 1 total | | | ~1.33 MB | ~4.83 MB |
| triangles (phase 2) | uint4 | T | 125,632 | 476,528 |
| triFrame (e1, n, t; phase 2) | 3 x float4 | T | 376,896 | 1,429,584 |
| shellBindings (bary, triangle; offset; normal) | 48 B | 32,530 | 1,561,440 | 1,561,440 |
| shellOut positions + normals (phase 2; the override buffers in phase 3) | 2 x float4 | 32,530 | 1,040,960 | 1,040,960 |
| overrideIndices (phase 3) | uint | 32,530 | 130,120 | 130,120 |
| phase 2-3 total | | | ~4.57 MB | ~9.47 MB |

The 16k CSR count is a projection: 47,726 edges and 47,446 bend pairs by
Euler on a 4-loop surface, about 12 % of each pin-pin as at 4k, so about
168,000 entries; the cook prints the exact figure and the asset test pins
it. The per-frame upload at 16 substeps is 13,312 + 11,968 + 256 + 256 =
25.8 KB. The engine's own override ring, which phase 1 keeps using, is
3 x 71,328 x 36 B = 7.7 MB per garment (MeshQuery.swift:123-128 sizes it to
the mesh's vertex count), and dwarfs everything above.

## 4. Kernels

All in `ZombieClothGPU.metal`, 1-D dispatches of N threads in threadgroups
of 64 inside ONE serial compute encoder per frame (successive dispatches on
a serial encoder are ordered; CoolCloth opens a new encoder per dispatch,
25 a frame, CC/CoolClothRenderExtension.swift:364-375, which this design
does not copy). Per awake in-range frame at 16 substeps and 1 iteration:
32 + 1 = 33 dispatches in phase 1, 35 in phase 2; asleep or out of range:
none, so the particle buffers are bitwise untouched across sleeping frames
(the tests compare them for exact equality, ZombieClothTests.swift:1473,
1544, 1631).

`zcPredict` (per substep k; N threads). In: posSrc, vel, rest, restNormal,
influences, skinMatrices[k], params. Out: prev = posSrc, posDst = predicted,
target_k = sum of w_j M_j rest, targetNormal_k = normalised sum of w_j R_j
restNormal. Pins (w == 0) write posDst = prev = target and vel = 0. Cost
per particle: 2.6 influences x 28 FLOP + 40 = 113 FLOP; reads 80 B, writes
64 B; per substep 0.45 MFLOP and 575 KB at 3,995.

`zcSolve` (per substep, `gpuIterations` times; N threads). In: posSrc
(predicted), prev, target, targetNormal, slack, csrOffsets, csrEntries,
params, hullHeaders, hullPlanes, hullWorld[k] and [k - 1], spheres. Out:
posDst, vel. Body: the CSR gather and relaxed correction; the slack ball
and the back-stop; the hulls (bounding sphere, planes, most-facing push-out,
the tangential motion relative to the hull's own scaled by 1 - friction);
the floor; the spheres backed to the substep's time; then, on the last
iteration, v = (x - prev)/dt capped at `maxLinearVelocity` 4 m/s
(SoftBodyMotionProperties.cpp:849-861 does the cap at the end of each
collision step), v = 0 for pins. Cost per particle: gather 10.44 x 30 =
313 FLOP, clamps 40, hulls 11 x 10 + about 2.5 hulls x 76 planes x 8 =
1,630, floor and spheres 60, finalize 15, about 2,060 FLOP; reads 16 + 16 +
16 + 16 + 8 + 8 + 10.44 x (8 + 16) = 331 B, writes 32 B; per substep
8.2 MFLOP and 1.45 MB at 3,995. The gather is order-fixed and atomic-free,
so two runs on one device are bitwise equal (`testTheGPUStepIsDeterministic`).

`zcStats` (once per frame; one threadgroup of 1,024 threads, four particles
each, simd reductions). In: posCurrent, prev, target, slack, params. Out:
the stats slot {maxSpeed, nanCount, maxPelvisDistance, onClampCount,
aabbMin, aabbMax}. Phase 1 still reads the positions for the shell, so the
CPU runaway scan (ZombieCloth.swift:1462-1464) stays as the guard; the slot
feeds `onClamp`, the swept-AABB wake test while asleep and, from phase 2,
the speed and runaway rules once the positions no longer come back.

`zcTriangleFrames` (phase 2; T threads, once per frame). In: posCurrent,
triangles, params (toMesh). Out: triFrame = (e1, n, t) of each proxy
triangle in mesh space, a collapsed triangle keeping its previous frame
(`RenderShell.frames` parity, ZombieCloth.swift:493-509). About 7,852 x
60 FLOP.

`zcShell` (phase 2; 32,530 threads, once per frame). In: posCurrent,
triangles, triFrame, shellBindings, params. Out: shellOut positions
(w = 1) and normals (w = 0) — `RenderShell.evaluate` line for line
(ZombieCloth.swift:526-531). About 32,530 x (3 x 16 + 48 + 48 + 32) B =
4.7 MB and 2 MFLOP; under 0.1 ms. Phase 3 writes the engine's override
buffers directly.

There is no normals-from-faces kernel in phase 1: the shirt's normals come
from the shell binding (each exported copy's own normal carried in the
triangle frame, 448-487), and only the trousers, which have no shell, would
need one (phase 5). There is no hard-skin kernel: the hard skin is a CPU
write (section 2).

## 5. Prep changes

Phase 1 needs none. The sidecar as cooked carries the particles, the faces,
the influences, the slack, the back-stop, the body-facing set, the joint
paths and bind matrices, the hull points and the render binding
(`garment_record`, prep_zombie.py:2542-2605; the keys read at
ZombieClothAsset.swift:79-108), and the GPU solver derives its constraint
graph, its rest normals and its hull planes at attach.

Phase 2, all in `Tools/blender/prep_zombie.py` and re-cooked, never
hand-edited: the shirt pipeline at 1884-1886 (`outer_layer`, `sew_placket`,
`decimate_proxy(shirt, 4000)`) gets a second output. After `sew_placket`, a
`refine_proxy(shirt, 16000)` cleans the outer layer with the existing
collapse at `min_edge` 3 mm (the 1,826 slivers go, 0 are left, measured),
subdivides EVERY edge once with grid fill (`bmesh.ops.subdivide_edges`,
cuts 1, then triangulate: 9,996 to 38,054 vertices and 71,912 triangles,
0 degenerate, measured in the prep reader's experiment 2) and collapses to
16,000 with `min_edge` 4.5 mm, `max_edge` 18 mm, `min_angle` 10 (15,994
vertices, 29,783 triangles, edges 4.5/5.5/8.4/12.1/25.7 mm, min angle 10.2,
no slivers, no non-manifold edges, 6.3 s on a 32 s cook). The prep's own
long-edge split (`decimate_proxy`'s `subdivide_edges` rounds at 885-886) is
bypassed for this garment: at `max_edge` 12 mm it produced 304 zero-area
faces and 89 non-manifold edges. `recap_influences` (1168; already called
at 1906) handles the 116-188 subdivided vertices that inherit five
influences, and the artist-weight reads at 1906-1912 (`mark_sleeve_seam`,
`artist_dominant`) still happen before `transfer_weights(body, shirt)` at
1915. `report_proxy` (845: `min_edge` 0.008, `max_edge` 0.040, `min_angle`
5.0) takes per-garment limits (shirt16k 0.004 / 0.030 / 10). The second
cook writes `Zombie.cloth16k.json` with the shirt16k garment, its own
`render_binding` (2707-2813; the offsets shrink, since more shell vertices
sit on a proxy vertex), the same colliders and the same trousers, projected
4.19 MB against the 8 MB warning (3139-3142). The same cook adds, per
collider, `planes` as [n.x, n.y, n.z, d] from the hull points (numpy in
Blender), per particle a `restNormal` and a `region` index into a
`regions` name table from the slack schedule's bands, and `constraintCounts`
{edges, bendPairs, pinPinDropped} for the asset test; the runtime keeps
computing planes and normals when a sidecar lacks them. The slack schedule
is metres throughout (`SLACK` and the bands at 2675-2695; the collar, yoke
and hem bands are Dijkstra along the proxy's edges, 2607-2622, which
overestimate the geodesic by a few per cent and so shift a band outward a
little on a finer mesh; the cuff and armhole rules are geometric, 2884-2907)
and needs no change; the tests that pin counts are re-pinned from the cook
log (section 6). `SKIN_HULL_MAX_POINTS` 48 (2280) stays: 832 planes cost
nothing on the GPU.

Phases 3 and 4 add nothing to the prep (the joint-gap capsules are built at
attach from the hulls' centroids; the self-collision exclusion rings are
computed at attach).

## 6. Tests

`ZombieClothTests` is a `final class` (ZombieClothTests.swift:40), so the
GPU twin is not a subclass. The fit scenarios — the hang, the idle, the
sway, the device cadence, the re-seat, the dent, the three sleep tests, the
LOD, the arms-forward idle, the arm swing, the posed-body read — move into
`Tests/CoolZombieKitTests/ClothFitScenarios.swift` as functions of a
`Harness` and a `FitBounds` struct (the literals now at 1063-1070,
1176-1180, 1241-1248, 1449, 1465-1467, 1507, 1980-1981, 2052-2056 and the
penetration bounds at 78-81), the `penetration(of:)`, `excess()` and hang
metrics (449-519 and around 1040-1070) go with them into
`ClothMetrics.swift`, the `Harness` (597-646) and the recording `Body`
(87-126) become internal in `ClothTestHarness.swift` with a `solver:` and
a `device:` parameter and a sphere list drained from the bodies the tests
add with `didAddBody` (1435-1440, 1571-1576) through
`backend.bodyState(for:)`, and `ZombieClothTests.swift` keeps calling the
scenarios with the Jolt bounds, its 28 tests green and unchanged in
meaning. Every GPU test gets its device from `MTLCreateSystemDefaultDevice()`
in `setUpWithError` and throws `XCTSkip` without one (CoolCloth's harness,
CC/Tests/CoolClothTests/CoolClothGPUTests.swift:16-21); on the Mac that is
the integrated GPU, so the GPU suite runs wherever the Jolt one does. The
GPU bounds are measured once on the Mac's GPU and pinned with the margins
the Jolt literals use; in the first commit a re-measured penetration or
swing figure may stand at Jolt's plus 25 %, then it is pinned exactly.
Nothing runs the GPU suite on the headset, and float results differ across
GPU generations, so a device-only regression is invisible to the tests;
the headset gates are the only guard there.

`ZombieClothGPUTests.swift` (new), the scenarios on the GPU with their own
bounds, and the solver's own tests:

`testTheMetallibExposesTheKernels`: the platform metallib exists in
`Bundle.module` and `library.functionNames` holds the five kernels
(`zcPredict`, `zcSolve`, `zcStats`, `zcTriangleFrames`, `zcShell`), and the
Swift mirrors' strides are 256, 8, 32 and 64 B.

`testTheConstraintGraphMatchesJolts`: 11,849 edges, 11,707 bend pairs, 142
boundary edges, 1,424 pin-pin edges and 1,282 pin-pin bend pairs dropped,
41,700 CSR entries, 22 at most per particle, every stretch rest length
within [0.0085, 0.0392] m, `csrOffsets[N]` equal to the entry count.

`testTheHullPlanesEncloseTheirPoints`: every sidecar point within 1e-5 of
inside for all its hull's planes, the per-hull counts 87 / 83 / 82 / 88 /
66 / 84 / 82 / 66 / 70 / 60 / 64 and 832 in all, a point 3 mm outside along
a face normal read as outside.

`testAHardSkinPutsEveryParticleOnItsTarget`: after attach, positions equal
`skinnedTargets` within 1e-6 m, velocities 0, `hardSkinCount` 1,
`skinMultiplier` 0.

`testPinsNeverMove` and `testTheSlackClampIsExact`: after 300 idle frames
the 532 pins are bitwise on their targets and every free particle is within
maxDistance + 1e-6 of its target (Jolt's bound is 5 mm, ZombieClothTests.swift:
1178); with gravity raised to 50 m/s^2 at least 90 % of the free particles
sit on the clamp (the `onClamp` figure).

`testTheBackStopHoldsOneMillimetreBehindTheSkin`: no non-body-facing
particle more than backstop + 1e-6 behind its skinned plane after the hang.

`testStretchResidualAtRest`: after 200 frames of the hang at 16 substeps,
mean |len - rest| / rest under 1 % and the 99th percentile under 3 % over
the stretch edges, and under 2 % / 6 % at 8 substeps; run for both
relaxation forms and the printed figures decide the default (section 2).

`testTheSubstepRuleFollowsTheFrame`: 10 ms gives 16, 11.1 ms 18, 16.7 ms
27, 5 ms 8, 50 ms 32, and `gpuSubsteps` 8 gives 8 at 10 ms.

`testTheSubstepTargetsInterpolate`: a joint turned 30 degrees in one frame;
the recorded per-substep targets lie on the arc, monotone, with no jump at
substep 0.

`testAMovingHullCarriesTheClothByFriction`: a hull translated 2 cm per
frame under a resting free patch moves the patch by at least 20 % of that
with `gpuHullFriction` 0.2 and by under 1 mm with 0.

`testACubeHullPushesParticlesOut` and `testTheFloorStopsASheet`: a free
patch dropped on a unit cube's six planes and on the floor ends with no
particle inside beyond `vertexRadius` (CoolCloth's
`testFreeClothLandsOnFloor` pattern, CoolClothGPUTests.swift:536).

`testAThrownBallDentsTheGPUShirt` and `testABallThroughASleepingGPUShirtWakesIt`:
the dent is at least 2 cm (ZombieClothTests.swift:1449 parity), the sleeping
shirt wakes within 60 frames through the swept-AABB test, `isSoftBodyActive`
true after, the writes resume (1577-1584 parity).

`testASleepingSolverEncodesNothing`: `stats.dispatches` constant and the
particle bytes equal across 20 asleep frames; `isSoftBodyActive` false.

`testTheGPUStepIsDeterministic`: two solvers, 120 frames of the sway,
identical bytes.

`testARunawayParticleHardSkinsTheGPUShirt`: a NaN written into posA[7]
through the shared buffer; the next frame reports `runawayCount` 1,
everything finite, `hardSkinCount` + 1.

`testTheGPUSolverIsRefusedWithoutADevice`: `ZombieCloth(asset:
configuration: .gpu, device: nil)` attaches on Jolt and prints once.

`testTheSkinCollidersAreCountedOnTheGPUPath`: `skinColliderCount` 11,
`physics.backend.bodyCount` 1 + 20 (the floor slab and the twenty parts; no
Jolt soft body, no kinematic hulls), `-clothColliders off` gives 0 hulls
and the same count; the Jolt file's 1 + 20 + 1 + 11 assertions (819, 1099,
1110, 1128, 1149, 1746-1762, 1776) stay Jolt-only, as do its backend soft-body
patches (1341-1387).

`testTheGPUShellMatchesTheCPUShell` (phase 2): `zcTriangleFrames` +
`zcShell` against `RenderShell.evaluate` on the same particles at the bind
pose and in a swayed frame, within 1e-5 m and 0.05 degrees over all
29,402 slots.

`testTheHangReportsItsFolds` (phase 2, the drape figure): over the hem
band's interior edges (slack 0.12), the mean absolute dihedral angle
between the two faces and the number of convex-concave alternations around
the hem loop after 300 frames of the hang, printed for the 4k and the 16k
proxy and pinned once the owner's gate-2 verdict is in; this is the number
that turns "folds under gravity" into a test.

`testGPUTimingsOverThreeHundredFrames`: prints the feed, encode, gpu, wait,
read and bind medians and maxima and asserts 300 override writes (2152-2171
parity).

`testTheLaunchArgumentsSetTheClothConfiguration` (ZombieClothTests.swift:
2182-2256, extended): the defaults jolt / 16 / 1 / 0.5 / raw-sum / nil /
0 / wait on, each new flag, and bad values left as they were.

`ZombieClothAsset16kTests.swift` (phase 2): the second sidecar's region
counts within +-25 % of the cook's (the 4k file's 532 / 85 / 66 / 287 /
478 / 497 / 532 / 430 / 1,088 are pinned at ZombieClothAssetTests.swift:
363-369), the edge bound 4-30 mm (the 4k file's 8-40 mm at 413-414), the
ratios that survive (pins 300 to a quarter, 310-311; the armhole band 500
to three tenths, 525-526; body-facing under a tenth, 396; the 21 islands,
152-155), `restNormal` unit length, `planes` on 11 colliders, and
`constraintCounts` equal to the kit's build.

## 7. Phases

| phase | deliverable | days | headset gate |
| --- | --- | --- | --- |
| 0 seam | `ClothSolver` + `JoltClothSolver` extracted, 28 tests green unchanged; `Configuration.solver`, the launch args, both hosts' pickers (`gpu` falls back to Jolt with a line); `ZombieChaseGame` sphere provider and floor | 1 | none |
| 1 GPU solver at 3,995 | metallib + script, CSR, hull planes, `zcPredict` / `zcSolve` / `zcStats`, own queue, lazy wait, wait-off ring, CPU hard skin, AABB wake, `sim=` / `gpu=` / `wait=` / `onClamp=` lines, GPU tests, Mac sweeps (relaxation form, substeps 8/12/16/24, damping 4 vs 1, hull friction 0 vs 0.2), headset build | 4-5 | gate 1 |
| 2 resolution and the GPU shell | prep `refine_proxy`, `Zombie.cloth16k.json`, `-clothSidecar` + a Proxy picker, 16k asset tests, GPU fit bounds at 16k, `zcTriangleFrames` + `zcShell` with the CPU copy, the drape figure | 3-4 | gate 2 (the quality verdict) |
| 3 engine hand-off | engine PR on `feature/cloth_gpu_override`: buffer-sourced override, `isPrimaryRenderEye()` guard on `DeformationSystem.encode`, override ring + 1; `Package.resolved` pin; `zcShell` writes the override buffers; the array path kept behind `gpuOverride = .arrays` | 2 + review | gate 3 |
| 4 contacts | room boxes as planes when the body is down, ragdoll capsules under `ragdollAndSkin`, joint-gap capsules at the elbow and shoulder, spatial-hash self-collision every second substep at 16k, the wrist band unpinned | 3 | gate 4 |
| 5 later | trousers (2,999 particles, a normals kernel), dihedral bending if gate 2 still reads flat, the Jolt arm's removal | — | — |

Phase 1 ends in a headset build, day 5-6 from the start. Its gate asks, on
the same release build and in this order so the comparison has a baseline:
sixty seconds of idle and sixty of chase with eight balls on the Jolt
picker, noting the footnote's `N late +X ms`, then the same on the GPU
picker at 16 substeps and at 8. Pass: `gpu=` at or under 1.0 ms and
`wait=` at or under 1.5 ms at 16 substeps, `deadlineMisses` not above the
Jolt run, no runaway and no shards over the five minutes with the balls,
the slack and the pins exact in the report, the picker flipping live, and
the owner's read of the same 3,995 proxy: smoother and stop-exact is the
expectation, still coarse is accepted. If the cost fails on the wait,
`-clothGPUWait off` is re-gated before anything else changes; if the look
fails at 4k for a reason the 16k cook would not address (the back-stop
sign, a hull), it is fixed before the cook.

Gate 2 is the quality verdict: at 16k and 16 substeps, folds under gravity
at the hem and the sleeves (the drape figure printed beside the owner's
read), the fabric sliding over the hulls with the friction on, no skin
through the sleeves at the arm swing, no shards, `gpu=` at or under 2.0 ms,
`deadlineMisses` not above the Jolt run, the CPU read + bind under 0.6 ms.
Pass flips `Configuration.solver`'s default to `.gpu` and the pinned
defaults test with it. Gate 3: the cloth's CPU line (feed + encode + stats)
under 0.3 ms, no visual change against gate 2, the engine's deformation
pass measured once per frame instead of twice (`setRendering(.gpuPassTiming(
.enabled))`, E/Utils/EngineSettingsAPI.swift:145, 295, on a device that
samples at stage boundaries, E/Profiling/GPUPassTiming.swift:212-222). Gate
4: `gpu=` at or under 2.5 ms with self-collision on, the collapse and the
stand-up clean, the cuff roll kept apart with the wrist band free.

What is A/B-able, each a picker or a launch argument and each a line in
the footnote: Jolt against GPU at the same proxy; 8 / 12 / 16 / 24
substeps; one or two gathers per substep; the two relaxation forms; damping
4 against 1; hull friction 0 against 0.2; wait against one frame of lag;
and from phase 2, 4k against 16k on the GPU. The eight to ten working days
to gate 2 are the honest expectation of where "fine folds" arrive.

## 8. Budget

Assumptions, to be replaced by the footnote's figures at gate 1: the
headset frame is 10 ms (100 Hz, ZombieXRGame.swift:131-134); the Apple
Vision Pro GPU is taken as about 2.5 TFLOPS fp32 with about 100 GB/s of
effective DRAM bandwidth and a shared cache that holds a 1-6 MB working
set; a dispatch of a few thousand threads costs 15-25 us of fixed latency
on Apple GPUs; the headset's cores are about twice slower than the M4
Max's (README.md:1045-1047, an estimate). No headset figure for any cloth
exists today, CoolCloth's included.

Phase 1 GPU at 3,995 particles, 16 substeps, 33 dispatches: arithmetic
8.7 MFLOP per substep (section 4), 139 MFLOP per frame, 0.06 ms at
2.5 TFLOPS; traffic 2.0 MB per substep, 32.5 MB per frame, 0.33 ms at
100 GB/s if nothing hit the cache and a fraction of that with the 1.3 MB
working set resident; dispatch latency 33 x 15-25 us = 0.5-0.8 ms, which
dominates. Estimate 0.6-0.9 ms per frame, once per frame on its own queue
(not per eye). At 8 substeps 0.3-0.5 ms. Phase 1 CPU on the frame thread,
Mac figures with the headset at about twice: the feed (208 slerps, 187 hull
transforms, 26 KB of uploads, the params) 60-100 us; the encode of 33
dispatches 60-120 us; the wait 0 to the GPU's remainder after the game's
step; the read of 63,920 B and the mesh-space conversion about 40 us (the
Jolt read-back minus its shell was 678 - 503 = 175 us, README.md:1035);
`RenderShell.evaluate` 503 us median, 1,008 max on the cores (ZombieCloth.swift:
420-429), about 1 ms on the headset; the engine's element loop over 32,530
slots x 36 B (Components.swift:505-509) 120-250 us. Total about 0.9-1.3 ms
on the Mac and 1.8-2.6 ms on the headset plus the wait; the shell is the
largest item, which is why phase 2 moves it. Against it the Jolt step
loses its soft body and its eleven kinematic hulls: 3.4 ms median with the
hulls, 1.7 ms without (README.md:916-918), of which the soft body's own
share is unmeasured and the ragdoll's and the room's floor is 237 us
(README.md:975-977). Memory 1.33 MB GPU-resident.

Phase 2 GPU at 15,994 particles, 16 substeps, 35 dispatches: arithmetic
about 35 MFLOP per substep, 560 MFLOP per frame, 0.22 ms at 2.5 TFLOPS,
realistically two to three times that; traffic 8 MB per substep, 130 MB
per frame, 1.3 ms at 100 GB/s if the 5.5 MB working set spilled and
0.4-0.7 ms with it resident; dispatch latency the same 0.5-0.8 ms, partly
overlapped. Estimate 1.2-1.8 ms at 16 substeps and 0.9-1.4 ms at 12; the
shell kernels add under 0.1 ms. CPU: the feed and encode as before, the
copy of 32,530 x 2 float4 into the override arrays 100-150 us and the
engine's loop 120-250 us; no shell pass: about 0.45-0.7 ms. Memory 9.5 MB.

Phase 3 CPU: feed + encode + the stats read, 0.15-0.25 ms; the engine's
deformation pass runs once per frame instead of twice (the 71,328-vertex
skin and the override). Phase 4 self-collision every second substep at
16k: 8 x (3 hash dispatches + a 16k-thread pair pass of about 26 MFLOP) =
24 dispatches and 0.2 GFLOP, about 0.5-0.7 ms; total 1.8-2.5 ms. The Mac
at 60 Hz runs 27 substeps of 0.62 ms: about 1.0 ms at 4k and 2.0 ms at 16k
on the M4 Max class, irrelevant to its frame.

Measurement in release: `gpu=` and `wait=` from the solver's own command
buffer stamps; `deadlineMisses` and the worst overrun from the XR loop
(UntoldEngineXR.swift:122-124, 1624-1626); the engine's `updateMs` /
`encodeMs` / `gpuExecutionMs` only in a debug build. The Jolt baseline
run of gate 1 is the reference the three designs lacked.

## 9. Risks and fallbacks

The wait stalls the compositor's render thread by more than the GPU's time
when the cloth buffer queues behind a 5-8 ms render pass (three in flight,
Globals.swift:2164-2165): the cloth buffer is committed in the update
phase, before the frame's render buffer exists (UntoldEngineXR.swift:
880-921), so it contends only with frames N-1 and N-2, and the XR loop
otherwise idles until the compositor's optimal input time (895-897);
`wait=` measures it and `-clothGPUWait off` is the fallback, 10 ms of shirt
lag and no stall.

Jacobi under-convergence at 3,995 (a stretchy shirt, a slow settle, a
longer hem): `testStretchResidualAtRest` catches it on the Mac; the
fallbacks in order are the other relaxation form, two gathers per substep
(+16 dispatches, about +0.25 ms), 24 substeps, and as a last resort a
red-black split of the CSR into two dispatches per pass.

The relaxation forms were never run on this mesh (CoolCloth's 0.5 is tuned
for twelve neighbours on a grid; the shirt has up to 22): the day-4 sweep
runs both before the headset build and the residual test pins the choice.

Damping as the cause of the crumples that do not fall: `gpuDamping` is in
the sweep (4 against 1); Jolt's 4 1/s stays the default so the first
headset A/B is like for like.

Shared-memory bandwidth at 16k (130 MB per frame nominal): `gpu=` at
gate 2; fallbacks are 12 substeps, half-precision rest lengths and targets
(about -30 %), or a space-filling-curve reorder of the particles at attach
so a particle's CSR neighbours share its cache lines; the 12k cook
(11,996 / 22,050, measured) is the last step down.

The hull plane sets are the largest FLOP term (about 1,630 per particle
per substep at 2.5 hulls passing the sphere test): `SKIN_HULL_MAX_POINTS`
24 in the prep (about 44 planes) or a 3-degree coplanar merge at load if
`gpu=` says so; the sphere test already culls eight of the eleven hulls.

Position-level hull friction can pump energy against pinned neighbours, as
CoolCloth's capsule comment warns (CoolCloth.metal:225-227): the push-out
is clamped to the radius, the friction to the substep's displacement, the
4 m/s cap and the runaway rule remain; the default is 0.

The rotated-rest-normal back-stop differs from Jolt's face-normal one at
the 189 triangles with a pinned corner and a free one: the hang and
penetration tests hold the sign; the fallback is one more gather over the
targets.

Balls and the floor only in phase 1: the GPU shirt meets no room box when
the body is down and no ragdoll capsule, and the collapse scene is
unjudged until phase 4; the ball's reaction is lost and invisible
(section 2).

The 3-slot override ring written before the semaphore wait is PLAUSIBLY one
slot short (Components.swift:457 against Skeleton.swift:214-234): phase 1
inherits exactly what the Jolt path has, phase 3 fixes it in the engine
PR, and a frame counter written into the override and read back in the
completed handler is the one-line reproduction if the owner wants it
settled first.

A metallib built without `-mtargetos=xros2.0` is refused on the device
(CC/Scripts/build-metallib.sh:13-17): the script and
`testTheMetallibExposesTheKernels` guard it; the simulator needs its own
lib (five committed, about 60 KB each).

Determinism across GPU generations is not promised: the bounds are per
device class, bitwise equality only within one; the headset gates are the
device's tests.

The 16k cook re-pins nine region counts and the edge bound at once: it
lands with the figures in the test comments as the Jolt bounds are
documented (ZombieClothTests.swift:43-81).

The Jolt arm cannot run the 16k sidecar (four times its CPU): phase 2's
A/B is "Jolt 4k" against "GPU 16k" by construction, with "GPU 4k" kept for
the like-for-like solver comparison.

The drawn shell's inner layer rides the outer layer's triangle frames at
offsets down to -18 mm; once the shirt folds at 4 cm the two sheets can
cross at a crest. Nothing checks it in phase 2; the drape figure and the
owner's read are the guard, and a per-slot clamp of the normal offset
(no slot further behind its triangle than at rest) is the fallback.

Swift 6: `GPUClothSolver` holds Metal objects and a closure; it is frame
thread only like `ZombieCloth` (177-178), `@unchecked Sendable` by the same
rule, and the hosts' picker changes already marshal through
`ZombieChaseGame.lock` (485-487, 843-845).

## 10. Reuse from CoolCloth

Verbatim, from `/Users/godshadow/Projects/Untold/UntoldArcade/CoolCloth`:
the predict body minus the wind and the model/invModel transforms (the
previous-position snapshot, the pinned pass-through, v += g dt, x += v dt;
`Sources/CoolCloth/Shaders/CoolCloth.metal:72-118`, with Jolt's linear
damping factor in place of line 116's `exp`); the XPBD gather formula
(`alpha = compliance / max(dt*dt, 1e-12)`, `denom = wi + wj + alpha`,
`deltaLambda = -(len - rest) / denom`, `correction += wi * deltaLambda *
d/len`, the `len < 1e-7` and `denom < 1e-8` guards, `x += correction *
relaxation`; 152-193) re-indexed over the CSR; the floor contact with the
0.4 xz mix (199-203); the sphere push-out (204-211); the capsule push-out
with softness for phase 4 (212-231); the finalize velocity update with the
speed cap and the pinned zero (260-281); the substep rule's skeleton (the
frame delta clamp 1/240..1/30, `min(max(requested, needed, 1), cap)`;
`Sources/CoolCloth/CoolClothRenderExtension.swift:16-25, 254-257`) with
the substep length 0.625 ms and the cap 32; the ping-pong A/B ownership
of the position state; the SIMD4-lane params ABI mirrored in Swift
(`Shaders/CoolClothShaderTypes.h:9-20`, `CoolClothShaderABI.swift:4-26`);
`Scripts/build-metallib.sh` (18-43) with the names changed, the
`Package.swift` layout (`exclude: ["Shaders"]`, the five `.copy`
metallibs, 24-31) and the platform selection replaced by the engine's
`RenderShaderLibraryPlatformResource.resourceName` (E/Renderer/
RenderExtensions.swift:195-197); the GPU XCTest harness (the device, the
queue, `makeLibrary(URL:)`, `makeFunction` + `makeComputePipelineState`,
one command buffer per frame with `commit` + `waitUntilCompleted`, the
`getBytes` / `contents` read-back and the finite and farthest-particle
assertions; `Tests/CoolClothTests/CoolClothGPUTests.swift:16-37, 155-204`);
the material presets as a second compliance knob (`CoolClothSimulation.swift:
26-57`: silk 5e-7 / 5e-6 / 5e-4, cotton 1e-6 / 1e-5 / 5e-5 — in CoolCloth's
unit-mass convention, so divided by `particleMass` 5e-5 to compare with
Jolt's 1e-2 / 2e-2 / 0.3) and its substep and iteration clamps (204-209).
Not reused: the `texture2d` state and `uint2` addressing, the 12-offset
table and `restScale`, the central-difference normals, the row and column
pin modes and the 128-column `pinTargets` `setBytes`, the grab constraint,
the wind, the rendering shaders and the grid index buffer, the engine
render-extension registration and the `.beforePostProcess` passes (the
zombie's shell is drawn by the engine's deformation pass), and the
one-encoder-per-dispatch encoding.

## 11. Open questions for the owner

Does the first headset A/B have to be equal-lag (the default: the frame
thread waits for the GPU, `wait=` printed), or is a frame of shirt lag
(`-clothGPUWait off`, 10 ms, a pinned cuff up to 2 cm behind a 2 m/s
wrist) acceptable from the start? It decides whether gate 1's cost
question is about the wait at all.

Is the phase-3 engine PR on a `feature/cloth_gpu_override` branch of the
miolabs fork, with a `Package.resolved` pin, acceptable at that point in
the schedule — the buffer-sourced `setEntityDeformationOverride`, the
`isPrimaryRenderEye()` guard on `DeformationSystem.encode` (which also
makes the muscle simulation in the same pass step once per frame instead
of twice) and the override ring one slot deeper — or should phase 3 be
deferred and the CPU copy kept until the GPU shirt is the default?

Does the resolution target stay at 16,000 particles (the shell's own
8.25 mm edge, a +6.3 s cook, the 2 ms line met at 12-16 substeps), or is
12,000 (11,996 / 22,050, +7.2 s, a third less GPU) the safer first cook
given that no headset GPU figure exists for any cloth yet?

Must the Jolt arm remain selectable after gate 2 flips the default, with
its 3,995 sidecar and the refusal line for the 16k one, or may phase 5
remove it once the A/B is no longer wanted?

Should the Mac host get a "GPU substeps" dropdown beside the "Solver" one,
or stay on launch arguments as its iterations do today?

### Settled (2026-11-03)

The owner chose the GPU path on 2026-11-03 after the third headset round;
the five questions above were settled the same day so the work could
start: the first headset A/B is equal-lag (the frame thread waits, `wait=`
printed), with `-clothGPUWait off` kept as the fallback should the wait be
the cost; the phase-3 engine PR is accepted but deferred until gate 2 has
flipped the default, so the CPU copy stays until the GPU shirt is the shirt;
the first cook targets 16,000 particles, with 12,000 as the fallback if
gate 2 fails on cost rather than look; the Jolt arm stays selectable until
the owner says otherwise; the Mac host stays on launch arguments for the
substeps, as it does for the iterations.
