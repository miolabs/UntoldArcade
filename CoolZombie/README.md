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
branch, and `Package.resolved` (the visionOS project keeps its own copy)
records the exact commit (upstream 0.24.1 merged into the fork, the
reach IK bend fix the elbows need, the per-frame simulation stepping
the headset needs and the XR background GPU gate, as of 29 October
2026). Moving on is
`swift package update UntoldEngine` plus the same revision in the Xcode
project's resolved file.

The Mac build is the sandbox: it runs the very same `ZombieChaseGame` as
the headset, with the orbiting red cube standing in for the player, so
whatever is tuned here holds on the device. A row of dropdowns along the
top (and the keys) control it, paused or running; reset and play/pause
sit bottom right. The zombie appears on the first running frame, not in
the paused start: the body stays hidden until an update has posed it and
set the ragdoll on that pose (a skinned mesh with no pose yet draws
stretched across the room, which is what the headset showed while the
clips loaded):

- **Layout** (or K): Open, Pillars, Wall, Room — boxes the zombie routes
  around (`ZombieNavigator`: a grid path with the obstacles inflated by
  the character's radius, string-pulled so the goal is the farthest
  waypoint in a clear line; root motion that carries the zombie into a
  box is pushed back out). The chase judges distance along the route, so
  a cube behind the wall is approached the long way round. **Room file**
  appears when the app was started with `-layoutFile <name|path>`: the
  bundled `sample` living room, or a room saved on the headset (see
  visionOS below) — the same walls and furniture the zombie met there,
  with the spawn point moved out to the headset's 4 m.
- **Cube** (or L): Orbit circles the arena; Behind wall parks the cube
  0.8 m past the wall, walling the zombie off. With the player within 3 m
  but the way round at least 1.4 times longer than the straight line, the
  chase enters its *contact* phase: it walks to the wall in front of the
  player, turns to
  face it and plants both hands on it (the `k_wall_hold` clip, the hold
  segment of the Kimodo hands-on-wall take, standing 0.22 m off the face
  so the palms meet it), and lets go the moment the player is reachable
  again or moves away. No IK yet: the pose is aligned to the wall plane,
  which is exact for a flat wall.
- **Height**: Low keeps the cube near the floor; Person lifts it to chest
  height, so the reach for it can be checked at both (`-height person`).
- **Clips** (or J): the clip set — every set present in the bundle is
  loaded at start and a switch rebuilds the motion database in place;
  `-clipSet <name>` only picks the initial one.
- **Reset**: back to the spawn point.
- Camera: WASD pans and dollies, Q/E move vertically, right-drag orbits
  the zombie, Shift+right-drag free-looks; Space plays and pauses.
- Test hooks: `-layout wall` starts on a layout, `-play` skips the paused
  start, `-debugLog` prints the phase, positions and distance every two
  seconds, so `swift run CoolZombie -layout wall -play -debugLog` shows in
  its console whether the zombie goes around the wall, and adding
  `-target behindWall` whether it ends up with its hands on it;
  `-cloth off|skin|world|ragdoll`, `-clothSolver jolt|gpu` and
  `-clothIterations <n>` pick the shirt's simulation (the GPU arm's own
  knobs, `-clothSubsteps <n>` and the rest, are listed under Cloth) and
  `-collisionSteps <n>` / `-workerThreads <n>` the Jolt
  world's sub-steps and threads (see Physics; the Cloth and Solver
  dropdowns switch the shirt's model and solver live), `-resetEvery
  <seconds>` resets the zombie
  every so often (a fallen one stands up).

## Assets

The demo is written so assets swap without code changes: drop in new
`.untold` clips, list them in `ZombieResources.chaseClips`, and the motion
database rebuilds from whatever is loaded. The layout is:

```
Sources/CoolZombieKit/Resources/
  Models/Zombie/Zombie.untold                 the zombie: skeleton + one skinned mesh
  Models/Zombie/Zombie.cloth.json             the cloth sidecar: shirt and trousers proxies, the shirt shell's binding
  Models/Zombie/Zombie.cloth16k.json          the second sidecar (2026-11-04): the same shell bound to a 15,979-particle shirt proxy, for the GPU arm
  Models/Zombie/Textures/Zombie_BaseColor.png 4K atlas: face, body, shoes, shirt + trousers tiles
  Models/Zombie/Textures/Zombie_Roughness.png
  Models/Zombie/Textures/Zombie_Normal.png
  Animations/<clip>/<clip>.untold             one folder per clip
```

Texture paths inside a `.untold` resolve relative to the model file, so the
`Textures/` folder must sit next to it.

The model is the studio's own zombie (`Zombie_new_cloth.blend`, the
artist's review file: nine scenes of garment variants, lights, cameras,
render shells and cloth proxies). Two scenes matter. `Scene` holds the rig
the demo has always used: the armature (53 bones), the skinned body
(28,622 vertices, face and body materials) and the eyes, plus the old fused
shirt-and-trousers mesh the prep no longer takes. `Intact Blood and Dirt
Review` holds the new clothes, skinned to a copy of the armature with one
extra bone (`Hips.001`, same head and direction as `Hips`): the shirt
(`ZOMBIE_CLOTH.002`, 29,402 vertices) is a closed two-layer shell about a
millimetre thick, outer and inner fabric joined by a rim at every opening,
with seven buttons and fourteen bits of thread as separate islands; the
trousers (`ZOMBIE_CLOTH.001`, 7,216 vertices) are two panels, front and
back, whose side seams were never sewn, plus five closed belt loops; and
`ZOMBIE_CLOTH.004` is the shoes and the belt loops of the old outfit, rigid
skin. Each garment has its own 2048 (shirt) or 4096 (trousers) texture set.

`Tools/blender/prep_zombie.py` turns that file into the game rig and cooks
it. It checks the garments' armature against the rig (same rest pose, or it
aborts) and folds `Hips.001` into `Hips`, keeps the set above only, scales
it to 1.75 m, renames the bones to the UE4-mannequin convention the clip
pipeline and the ragdoll expect (`root/pelvis/spine_01..03/neck_01/head`,
`clavicle_l/upperarm_l/lowerarm_l/hand_l`, `thigh_l/calf_l/foot_l/ball_l`,
fingers) with the sides taken from the bones' positions, merges the two
neck bones, re-skins the shoes with the body's weights (interpolated from
the nearest skin face, every hand and finger weight removed), and cleans
the garments' own weights instead of replacing them — the panel masks the
artist's cloth setup left as vertex groups (`skin`, `body`, `hair`,
`Group`, `GROW`) go, hand weights go, every weight of a bone more than
25 cm away goes (the automatic weights left a little of the pelvis on the
wrists, which hang beside the hips in the bind pose, and with the arm
raised that little was a 15 cm fin on the cuff), four influences at most,
renormalised; and the shirt's arm weights go from its hips — nothing of
an upper arm or a clavicle within 23 cm of the pelvis, tapered off over
the 6 cm beyond — since the automatic weights left 2–6 % of the upper arms
on the flanks down to the waist, where the elbows hang in the bind pose,
too close for the 25 cm rule to reach, and the drawn shell, which samples
the proxy's weights between its vertices, showed 34 of them inside the
20 cm `ZombieSkinTests` holds the export to (2026-10-31). The simulation
pins its particles to these weights, so the sidecar carries the same
numbers the skin draws.

Then the garments become **simulation proxies**. The trousers' proxy is
also what the game draws for now; the shirt's only simulates — the game
draws the artist's shell, bound to it (below). The trousers' two
panels are sewn (a merge by distance of 0.5 mm over the boundary vertices
only: 266 seam vertices, leaving one piece with three openings, the waist
and two hems), every vertex inside the body or within 2 mm of it is pushed
out along the body's normal to 2 mm (276 vertices, 60 of them inside the
hips), and the piece is decimated to 2,999 vertices and 5,912 triangles
(median edge 18.9 mm). The shirt is cut to the outer layer of its shell: a
face is outer when its normal points away from the nearest body point,
voted per smooth region rather than per face because under the arm a
sleeve faces the torso and a rolled cuff faces every way; the rims, the
buttons and the bits of thread go. The artist's hem is a doubled strip of
its own, the lowest 1.5–4 cm of the shirt, butted against the shell's
bottom edge: its top rim sits on the shell's bottom rim, both voted inner
by a hair, so the strip's outer face (voted outer, clearly) was cut off
from the rest and dropped, the proxy's hem stopped 9–33 mm above the drawn
hem and the shell's hem strip rode the boundary triangles as a 3 cm lever
on the hem band's 12 cm of slack; the strip is now sewn back onto the main
piece where their boundaries meet (70 vertices within 0.3 mm, the stitch
the trousers' side seams use, and one 4 mm sliver of a hole between the two
edges filled), so the proxy reaches the drawn hem and no shell vertex
hangs more than 8.7 mm below its triangle's lowest corner (2026-10-31). The
shirt is buttoned: its two front
panels overlap by 14 mm at the placket, the left one in front, with the
seven buttons in the overlap, but the panels are separate surfaces, so the
outer layer has a slit from the hem to the collar, and a proxy with that
slit would gape in the simulation and show the culled chest. The script
sews it: the hidden panel is trimmed of the faces along its edge until it
no longer reaches over the panel in front (77 faces), and its edge is
welded onto the front panel's edge bottom to top (80 vertices moved
1.4 to 17.5 mm, median 6.5), up to z 1.417 m where the two edges
part into the collar's notch, which stays open; the front panel's placket
hangs below the hem as a tab and stays part of the hem. That leaves one
surface with four boundary loops — the collar, the hem and the two cuffs,
the openings a buttoned shirt has — decimated to 3,995 vertices and 7,852
triangles (median edge 17.5 mm). The decimation is the script's own
shortest-edge-first collapse: a vertex on a boundary or a UV seam only
slides along it, no face may get worse than it was, no edge ends up shorter
than 8.5 mm or longer than 39 mm, no angle below 8°, and the UVs ride
along, so the garments keep their textures (the placket seam is a UV seam
between the two panels' islands). After it the influences are capped at
four again (a vertex made by splitting a long edge inherits the groups of
both ends) and every vertex, edge midpoint and face centre of both proxies
is pushed to 2 mm off the body: a 40 mm chord over a thigh sags into the
skin even when its ends stand off it (1072 edge and face middles lifted on
the trousers before the decimation, more after). The shirt proxy then
takes the **body's** weights, interpolated from the nearest skin face
(`transfer_weights`, as the shoes take them): skinned by its own, the
artist's automatic ones, its reference left the body as soon as the pose
left the bind pose — arms raised forward and the spine flexed, the skinned
proxy sat up to 43 mm inside the skin at the upper arms, 27 at the chest
and 17 at the yoke, and the headset drew the skin over the shirt there
(2026-10-31); skinned by the body's weights off the same joints, each
particle's reference is the skin under it, 2 mm off, in every pose alike,
and the back-stop below is the body's surface. They are not graded: the
seam grading (`grade_weight_seams`, kept in the script for the record)
blurred the weights across the bones' regions to keep the skinned edges
from stretching, and blurred weights are not the skin's — graded, the
chase pose put 20–41 % of the yoke's, chest's and upper arms' particles
inside the body, the deepest 36 mm; ungraded, the body's weights leave 4 %
of the armpit's a few millimetres in (12 mm at worst) and nothing else.
The slack absorbs what the grading used to: the skinned edges at the
armpit reach 2.4 times their rest length at the 99th percentile and 9.8 at
worst in that pose (1.85 and 3.9 graded), and the cloth, which keeps its
rest lengths, settles between its targets there within the armhole band's
6 cm. The grading was written against the artist's weights: those
handed the shirt from the upper arm (0.98) to the spine
(0.73) across single centimetre edges at the armhole, and as sharply from
spine_01 to spine_02 at the waist and from the upper arm to the forearm at
the elbow, so skinned with the arms held forward the armhole edges
stretched to twenty times their length and the cloth, which keeps its rest
lengths, sat 13 cm from its skinned target under each arm whatever the
solver did. Every vertex within 6 cm of such a seam (3,013 of the shirt's
3,995) has its weights blurred over its one-ring sixteen times — a blur of
about 5 cm, kept local on purpose: run to convergence the band becomes one
harmonic blend of every bone around the yoke and the upper arm's weight
reaches the shoulder blade — and the 2,118 within 12 cm of the armhole seam
two hundred times more, since the arms-forward idle is what the grading is
for: the farthest the cloth sits from its skinned target there was 16.3 cm
with the artist's weights, 9.4 after the sixteen passes and 5.2 with the
two hundred, measured when the shirt had 3 cm of slack everywhere and 5
around the armhole; on the schedule below the band's farthest particle
rested 6.7 cm from its target graded, and rests 15.5 cm with the body's
weights, which is why the band's slack is 15 cm now (`ZombieClothTests`
holds the band within a centimetre of its slack and every particle within
a centimetre and a half of its own — the cloth settles farther the looser
the regions around it, and the slack is set where that settling has all
but stopped; wider or deeper the blur the figure turned back up, 6.7 cm at
300 passes over 11 cm under the old slack, and a band of 13 cm or more
carries arm weight to within 20 cm of the pelvis, which `ZombieSkinTests`
forbids). Then the traces under 3 % go (two per cent of the upper arm had
reached the waist) and the influences are capped at four again; the worst
jump between an edge's two weight vectors falls from 1.89 to 0.68, at the
waist, and the edges jumping more than 0.5 from 762 to 8. The positions
never move: the particles stay the proxy's own. The five belt loops of the
new trousers stay undecimated and join the shoes as rigid skin.

The shirt the game draws is the artist's **shell** (`Shirt_Render`: both
layers of fabric, the folded collar, the seven buttons and the fourteen bits
of thread — 29,402 vertices in 22 islands), not the proxy: the headset showed
the drawn proxy as a sawtooth collar of 2 cm triangles, a buttonless front
welded into one seam and dark flaps wherever the single layer creased, since
the engine lights a back face with its front normal (2026-10-30). The shell
takes the proxy's graded weights, interpolated from the nearest proxy face
the way the shoes take the body's (the inner layer from the same face as the
outer, a button from the placket's) and capped at four influences again, so
body-skinned — the cloth off, the player out of range — it sits where the
hard-skinned simulation would put it and nothing jumps at a switch; the
grading itself was tuned on the proxy's 17 mm edges (its pass counts are a
blur width in edges) and is not rerun on the shell's 8 mm ones. Then the
script writes the shell's **render binding** into the sidecar
(`render_binding`): for every shell vertex the proxy triangle nearest to it
at the bind pose (by point-to-triangle distance: the inner layer binds to
the same outer-proxy triangle as the outer, a millimetre farther), the
barycentric coordinates of the closest point, and the vertex's rest offset
in that triangle's frame — `e1` along the first edge, `n` the face normal,
`t` across — so a simulated triangle that tilts or moves carries the vertex
rigidly (position = bary(a, b, c) + off·(e1, n, t)); the buttons and the
bits are rigid, every vertex of one bound to the single triangle nearest
the island's centre. The normals are not in the binding: the exporter
writes a normal per face corner and splits a vertex whose corners disagree,
and the shell has 1,120 sharp edges — the cuff rolls, the placket's edge,
the collar's creases — on which a thousand of its vertices become two or
more exported copies with normals up to 180° apart; one rest normal per
shell vertex (the smooth one, the first cook's) lit those creases flat
whenever the cloth was on while the body's own skinning showed them, so the
game reads each exported copy's normal off the mesh at the attach and
carries it in the same frame (`RenderShell`, below), and the cloth on and
off are lit alike. The shell's rest positions go in with it, since the game
binds them to the exported vertices by position; the shell's triangles do
not (the mesh has them). The binding covers 6,020 of the proxy's 7,852
triangles; the offsets are 1 mm at the median (the inner layer) and 20 mm
at most (the placket's hidden panel, which the proxy trims), no vertex of
the shell proper hangs more than 8.7 mm below its triangle's lowest corner
(the hem strip's bottom edge between proxy vertices; 33 mm when the strip
was dropped), and the rounded numbers rebuild every shell vertex within
0.003 mm. The proxy itself stays in the rig `.blend` as `Shirt_Proxy`,
hidden and not exported: it lives in the sidecar only.

The textures go into one 4K atlas of 2048 tiles, as before: face, body and
the old clothes (worn by the shoes) a tile each; the fourth tile holds the
shirt and the trousers as two 1024 quarter tiles (the shirt's 2048 maps
halved, the trousers' 4096 maps quartered — base colour, roughness and
normal; the artist's metallic, height and emissive maps are not used), and
two quarters stay free. The script bakes the shape keys that give the face
its zombie look, removes the skin under the trousers and the shoes (a ray
from each body face along its normal that meets the trousers proxy or the
shoes within 4 cm; a one-face ring stays under every edge, the hands and
wrists are never culled — 2,711 of the body's faces go, 25,782 stay) and
keeps the skin under the shirt: the shirt is simulated cloth that hangs off
the body, swings and is dented, so where it leaves the torso the torso must
be there, and where the body presses into the cloth the back-stop pushes
each particle back to a millimetre behind its skinned position in every
solver iteration, which the push-out put 2 mm off the skin, so the proxy
and the shell's outer layer on it stay off the body (on the idle, two
seconds in, the nearest particle to the surface under the shirt is 2.0 mm
off it; `ZombieClothTests` holds every one to a millimetre). It then joins body, eyes, shoes, belt loops, the shirt
shell and the trousers proxy into one mesh of 63.7k vertices, 71,328 once
the exporter has split them on the UV seams, and 126k triangles with one opaque
material (the alpha-masked hair cards and the cornea shell are dropped), and
checks that no vertex of another part sits within 0.2 mm of a shell vertex,
the tolerance the game binds with (none does; the shell's own 1,097 pairs
closer than that — thread wound around the buttons, seam strips — the game
settles by the nearer vertex). One mesh, one material is not a
choice of taste: the engine binds the animation per skinned mesh node, and
the exporter splits a multi-material object into one node per material, so
a split body would be animated once per part.
`Tests/CoolZombieKitTests/ZombieModelTests.swift` holds the cooked model to
this. Before the skin under the clothes is culled, the script also fits the
ragdoll's twenty capsules to this body and under both garment proxies
(`fit_capsules`, see the ragdoll below) and logs them in the rig's syntax
for `ZombieRagdollRig.swift`.

Beside the model the script writes `Zombie.cloth.json`, the cloth sidecar,
in engine space (the exporter's axes: engine x, y, z is Blender x, z, −y):
per garment the particles (the proxy vertices; the game binds them to the
exported mesh by position, since the exporter splits a vertex on UV seams),
the triangles wound consistently and, on the whole, counter-clockwise seen
from outside — the rolled cuffs and the inside of the collar wrap back
towards the arm and the neck, so the particles whose normal points at the
body are listed (148 of the shirt's, 3 of the trousers') for the
game to put their back-stop on the body side — the joints they hang on as
the engine names them (`/root/pelvis/spine_01`), up to four influences per
particle summing to one, how far each particle may stray from its skinned
position (`maxDistance`; 0 pins it), the back-stop — 1 mm: Jolt's stop is a
plane that starts that far *behind* the skinned position and pushes a
particle back out of it, so with the proxy 2 mm off the skin a millimetre
keeps it, and the shell's outer layer on it, off the body; the first cook
with the skin kept under the shirt set 5 mm in the belief that a deeper
stop held the cloth farther out, which let the proxy sink 3 mm into the
skin and, not short of the buttoned front's 5 mm slack, switched that
band's stop off altogether (Jolt disables a stop that does not undercut
the slack; 2026-10-31) — the dominant joint, the bind-pose joint matrices
and, for the shirt, the render binding above.
The shirt's slack is a **schedule** (`shirt_slack`), since a shirt hangs
from its shoulders and the headset showed one 3 cm everywhere as a second
skin: the collar band — the collar, its stand and its points, every particle
within 8 cm along the surface of the collar loop, 267 — and the cuffs —
the whole rolled cuff, every particle within 6 cm up the forearm's axis of
the cuff loop's plane and within 10 cm of the axis, both layers of the
roll — are hard skinned (0), so the folded collar follows the body as one
thick piece and the rolled cuffs ride the forearm's animation without
fighting the hand parts' tracking error, and the wrist band above the
cuffs (the next 3 cm up the axis) is held to 3 cm, the step to the
sleeve's 11. Until 2026-11-03 the cuffs were measured along the surface
from the cuff loop, and a rolled cuff is two layers: the roll's outer
layer was pinned and the sleeve's end under it was not (over the roll and
back is 8 cm), so at one height a third of the particles were pinned
beside free ones with 11 cm, 36 triangles had a pinned corner and a free
one, and when the forearm swung those triangles sheared and the drawn
shirt bound to them tore into flat shards around the wrist (headset,
2026-11-03); the
yoke (the back and the shoulder tops within 10 cm below the collar band, not
the chest) is held to 7 cm, which keeps it on the shoulders the shirt
hangs from (1 cm over 12 cm until 2026-10-31: with the arms forward the
shoulder blades spread under the skin and the yoke's lateral edge sat
4.4-6.3 cm from its targets, the figure moving with the slack around it,
a fight on anything tighter; the collar band's pins are the anchor); the
chest has 9 cm, the back 10, the hem band (the lowest 12 cm of the body
panels) 12; the sleeves 11 (up to 10.7 cm off their targets under the
raised arms) and the armhole band 15
(within 10 cm of the seam between the sleeves and the body panel as the
artist's weights draw it, read before the proxy takes the body's weights,
since a tailor's seam is the garment's and the body's weights hand the
deltoid's skin over up at the shoulder top; the 15 cm covers the armpit's
stretch with the arms forward, 15.5 cm, all but a centimetre, where on 6 cm
the clamp fought every pass by 5.5); the buttoned front keeps its 5 mm
(85), where the buttons hold the panels to the chest. Where the skin's
hulls (below) stand under the fabric the slack is a soft ceiling, not a
wall: Jolt applies the clamp toward the target and then the collision
push out of the hull in every sub-step, so the hull has the last word,
and in the arms-forward idle it holds the armpit's particles 10 mm past
their slack (37.7 mm before the clavicles had hulls of their own;
2026-11-02) — accepted, since the skin under a particle is where the
fabric must not go and the slack only where it should not wander, and
loosening the band for that centimetre would let the whole sleeve settle
farther (`ZombieClothTests` bounds the excess at 15 mm and prints it).
Distances along the
surface are Dijkstra over the proxy's edges. The trousers keep their waist
and its two-ring pinned (167), 2 cm at the hems, 3 cm elsewhere.
`ZombieClothAsset.swift` decodes it; `ZombieClothAssetTests.swift` holds it
to the export (every shell vertex and every trousers particle on an exported
vertex within 0.2 mm, and no exported vertex on the shirt proxy that is not
on the shell too — the particles are a subset of the shell's outer layer by
construction, the decimation moving none of its survivors, so 3,944 of them
do coincide with shell vertices; the binding rebuilding the shell at the
bind pose within 0.1 mm, no vertex of the shell proper more than a
centimetre below its triangle's lowest corner nor 25 mm from it, every
button and bit on one triangle — the normals are the export's, and
`ZombieClothTests` holds the shell as the game evaluates it at the bind pose
to the exported mesh, every driven copy within 0.1 mm and 0.1° of its own
exported position and normal, the sharp edges' split copies included; the
slack histogram within a quarter of the cook's counts and each region where
its name says; one piece per garment with its openings traced as closed
boundary cycles — four for the shirt, three for the trousers — edges between
8 and 40 mm, consistent winding, no hand in the weights, the bind matrices
equal to the model's).

The sidecar also carries the **skin's colliders** (`colliders`): per bone
under the shirt — the pelvis, the three spine links, the neck, the two
clavicles, the upper and the lower arms, eleven — a convex hull of the skin
that bone moves most, its points in the joint's bind-pose frame in engine
space, so the hull placed at the joint's world transform is the skin in
every pose. The fit (`fit_skin_hulls`) keeps each hull on the safe side of
a skin it cannot follow exactly: a hull is rigid on its bone while the skin
is blended between bones, so a skin vertex shared with a neighbour is first
pulled inward by what a 20 degree bend of the neighbour would move it (up
to 3 cm — the first cook, inset a millimetre alone, stood 27 mm proud of
the arms-forward chest and pushed the buttoned front 3.8 cm past its 5 mm
slack, and had the clavicles' skin in the spine's hull, where it stayed
behind while the shoulders swung); the points are voxel-downsampled to 48
at most, the hull inset a millimetre, and then pushed in wherever a face
comes within a particle's radius and half a millimetre (3.5 mm) of the
resting shirt, since a convex hull bridges every hollow of its skin from
outside and at the armpit the hollow is the shirt's — the upper arms'
hulls stood 11 mm through the resting proxy there, and the shirt hung 3 mm
lower at the back without gravity, pushed at the armpits. The cook of
2026-11-02: 446 points over the eleven hulls (32-48 each), the hulls a
millimetre to a few under the skin along the arms and 16-27 mm under it at
the torso (the bend inset), the largest face protrusion through the skin
10 mm at the trapezius hollow, every hull at least 3.5 mm under the
resting shirt. They are there because the back-stop stands for the skin only where a
particle sits near its skinned target: the stop is a plane a millimetre
behind that target, and with the arms raised the skinned targets spread
(the armhole edges 2.4 times at the 99th percentile) while the cloth keeps
its rest lengths, so a particle sits up to 15 cm from its target and a stop
placed at the target no longer stands for the arm under the particle — on
the headset the sleeves and the shoulders sank into the skin in patches
during the animations, fine at the T-pose (2026-10-31). The ragdoll's
capsules cannot do this job: inscribed in the body, they are a centimetre
thin at the arms and stand centimetres outside the skin at the torso.
`ZombieCloth` puts each hull in the world as a kinematic body on the joint
it names (`addKinematicConvexHull`), on a collision layer of its own
(`skinColliderLayer`, 9) that only the awake cloth meets — never the
resting cloth, since Jolt wakes a sleeping soft body for any awake body on
a shared layer and a kinematic body that moves is awake, so the hulls would
undo the sleep every step; never the character, the parts inside them, the
balls or the room — and puts each on its joint every step: teleported
there (`setKinematicTransform`) and then targeted there
(`setKinematicTarget`, a move of nothing that leaves the body's velocity
at nought), so the hull stands at this frame's pose for all of the step's
collision steps, where the skin's targets stand (the feed is complete
after the first soft-body update), whereas a hull moved as a kinematic
target over the whole step trailed the skin by up to two thirds of the
frame's joint motion and stood proud on the trailing side of a moving
arm. The hulls are frictionless (`skinColliderFriction`, 0, not the
cloth's 0.5): Jolt's soft body reads a collider's velocity only from a
dynamic body, so a kinematic hull is a static wall to it — its move
never carried the arm's velocity into the fabric, as the first version
of this paragraph had it — and with friction its contact took the
particle's tangential velocity in the world frame, braking a sleeve
carried by its skinned target against the arm moving under it; the skin
constraints carry the sleeve, the hulls only keep it out (found reading
Jolt 5.6.0, 2026-11-02). A
particle's collision radius against them is 3 mm (`vertexRadius`): the
proxy sits 2 mm off the skin and the hull a millimetre inside it, so 3 mm
keeps the fabric where the artist put it, where the centimetre of the first
cooks would have floated the shirt 7 mm off the body. A collider whose
joint the skeleton lacks is skipped and counted in one line; a sidecar
without them (cooked before they existed) decodes, and the cloth runs on
its back-stop alone; `-cloth skin` builds none, since that cloth meets
nothing. The report prints `colliders=` with the count in the world.
Measured in ZombieClothTests on the chase's arms-forward idle — the body
skinned onto the pose, the particles more than 2 mm inside it — the
back-stop alone leaves 154 particles inside (the armhole band 131, the
yoke 13, the sleeves 10, the deepest 34.3 mm into the upper arm), and with
the hulls 65 remain (armhole band 60, sleeves 4, yoke 1, the deepest
19.8 mm at the front of an armpit; 163 and 83 before the cuff roll was
pinned whole the same day): what no hull rigid on its bone can follow, the
armpits and the shoulder caps under 68 degrees of swing on blended skin,
and the armpit's hollow in particular, which the upper arm's hull may not
fill since at rest the shirt lies in it. The hang and the sway read none
inside, on the skin alone or meeting the world, and two cuff particles
3 mm inside over the ragdoll, pushed by the lagging forearm part.

The script writes the rig `.blend` the retarget tools take as `BLEND` and
exports through the Untold add-on:

```bash
SRC=~/Downloads/Zombie_new_cloth/Zombie_new_cloth.blend OUT_BLEND=~/Projects/Untold/zombie_bd.blend \
/Applications/Blender.app/Contents/MacOS/Blender -b --python-exit-code 1 --python Tools/blender/prep_zombie.py
```

The exporter stages an `HDR/` side folder beside every export; it is not
part of the asset and the script deletes it.

## License

MPL-2.0, matching the engine. This demo is non-commercial. The zombie
model and its textures under `Models/Zombie` are the studio's own work and
ship with the demo.

## Animations

The demo ships with two interchangeable clip sets; pick one with the
launch argument `-clipSet style100` (default, committed) or `-clipSet pack`
(bring your own copy).

### 100STYLE Zombie (`-clipSet style100`, default)

The Zombie style of the [100STYLE dataset](https://www.ianxmason.com/100style/)
(Mason, Starke, Komura 2022, CC BY 4.0): one Xsens capture per locomotion
type — idle, forward/backward/sideways walks and runs, and a transitions
take — retargeted onto the mannequin rig and cooked with
`Tools/retarget_100style.py`. The script imports each BVH into Blender
headless, retargets it with a world-space delta retarget (rest poses
aligned by bone direction, so the rig's A-pose meets the Xsens T-pose;
the pelvis's direction is taken toward the second spine joint, because on
the studio's rig the first sits level with the hips and would pitch the
pelvis over), keeps every elbow in its anatomical plane (the Xsens zombie
idle holds both elbows 1.6 cm inside the shoulder-to-wrist line, a locked
hang that reads as a broken elbow at arm's length; an elbow more than 60°
from its natural pole, back and out when hanging, down and out when
raised, is moved around the shoulder-to-hand axis onto it, each bone by
the smallest swing that takes its old direction to its new one, never a
turn about its own axis, with the hand left where it was), puts the
low-passed hip path and heading into the
`root` bone (a static root for the idle), and exports through the Untold
add-on:

```bash
mkdir -p ~/Downloads/100STYLE/Zombie   # Zombie_*.bvh + Frame_Cuts.csv from the dataset page
CLIPS="ID:s100_idle,FW:s100_walk,FR:s100_run,BW:s100_walk_back,BR:s100_run_back,SW:s100_side_walk,SR:s100_side_run,TR1:s100_transitions" \
OUT=/tmp/s100 /Applications/Blender.app/Contents/MacOS/Blender -b --python Tools/retarget_100style.py
```

then copy each `<clip>/<clip>.untold` under `Sources/CoolZombieKit/Resources/Animations/`.
The cooked files (54 MB) are committed — CC BY 4.0 allows it; the demo
credits *100STYLE dataset, Mason, Starke & Komura* — so a fresh clone runs
without any pack. Pass `BLEND=<the prepped rig .blend>` to cook them for
another rig.

### Kimodo (`-clipSet kimodo`) and Mixed (`-clipSet mixed`)

Clips generated with [NVIDIA Kimodo](https://github.com/nv-tlabs/kimodo)
(`nvidia/Kimodo-SOMA-RP-v1.1`, weights licensed by NVIDIA Corporation under
the NVIDIA Open Model License) on a rented GPU from text prompts and
root-path constraints. `kimodo` is a complete set in one zombie style: an
idle and two hold idles, a shamble-to-sprint ladder (0.4 to 3.5 m/s),
backward and side walks, 45°/90°/180° turns at walking and running pace,
walking and standing pivots, start/stop transitions, plus the hands-on-a-wall
contact clip (`Tools/runpod/clips_core.json` and `clips.json`). `mixed` is
the 100STYLE set with only the Kimodo gap clips added, the first combination
tried. `Tools/runpod/README.md` documents the pod, `gen_clips.py` and the
triage; `Tools/retarget_kimodo.py` retargets the SOMA BVH output onto the
rig the same way as the 100STYLE tool:

```bash
python3 Tools/runpod/triage_clips.py ~/Downloads/kimodo_out/kimodo --prefer p0 --json picks.json   # one take per clip, one prompt style
Tools/runpod/retarget_batch.sh picks.json /tmp/kimodo_cook          # retarget + cook (cook_options.json adds trims/idle flags)
```

then copy each `<clip>/<clip>.untold` under `Sources/CoolZombieKit/Resources/Animations/`.

The arms no longer belong to the locomotion clips. A matcher jump is
chosen on feet, hips and path, so with the generated set every jump could
land on a take whose arms sat somewhere else — up, down, out — and the
upper body flapped between them. Now a pose layer (engine branch
`feature/mm_oneshot_clips`, `docs/API/UsingPoseLayers.md`) owns both arms
from the clavicles down, with a posture per chase state: the idles keep
their own arms, roaming hangs them (the idle's arms over any walk),
chasing puts the clawing hold's arms on them (the lift crossfaded over
0.4 s), and the wall hold keeps its own. Within 3 m of the player reach
IK bends the arms toward it — not a steady point but grabs: each hand
lunges at the cube and pulls back on a 1.1 s cycle, the two half a cycle
apart, whatever height the cube sits at. The arm postures are their own
Kimodo takes (`Tools/runpod/clips_arms.json`, picked by hand motion):
`k_arms_grab` reaches and grasps for the chase and the hold, `k_arms_high`
for the hyper chase — the model kept its arms forward rather than overhead,
so that tier is a small step up, not the frantic reach the prompt asked for. Hand positions also join the matching
features at a low weight, so what the clips still decide about the arms
stays close across a jump.

The feet stay where they are planted. The stance lock used to watch the
displayed foot and let go the moment a transition moved it — the one
moment a foot needs holding — so a jump's blend, the root-velocity
crossfade and the heading warp all slid the planted foot. It now locks on
the playing clip's own contact (`setFootIKStanceLocking(source:
.clipContact)`): a foot the clip holds still stays pinned whatever the
entity does, and lets go only when the clip lifts it, so the catch-up
hides in the swing. The search also weights foot position higher on the
Kimodo set (`SpeedProfile.footWeight`), so a jump lands where the feet
already are. In the headless harness the drift of a planted foot fell
from 12 to 4 cm/s, from 29-38 to 4-9 while moving.

Turning is the other place the sets differ. With no clip turning sharply
enough, the matcher's orientation warp rotates the entity under whatever
plays, which reads as the mesh turning on still feet. The pure Kimodo set
has 45°/90°/180° arcs and standing pivots, so its warp is cut to 0.3 rad/s
and only bites at walking speed (`SpeedProfile.warpRate`/`warpSpeed`):
the feet do the turning, at the price of a few degrees of heading lag. The
100STYLE set has no turn clips and keeps the full warp.

Generated takes are not cyclic: a walk's last frame sits 20-30 cm from its
first, and a start, stop or pivot cannot loop at all, so a loop wrap is a
hard cut. The chase therefore lists every locomotion clip as *one-shot* in
the motion-matching descriptor (`ZombieResources.oneShotClips`, engine
branch `feature/mm_oneshot_clips`): the database extrapolates their
trajectories past the end instead of wrapping and the matcher leaves them
through an inertialized jump before the end. The in-place idles, which play
on repeat outside the matcher while the zombie holds, are cooked with their
loop seam closed (`loop` in `cook_options.json`: half the last-to-first
mismatch eased out over each end). Peak pose acceleration in the headless
chase harness fell 3-5x and snap frames halved on the Kimodo and Mixed
sets; see `Tools/runpod/harness/README.md` for the harness and the
settings it chose (transition halflife 0.1 s, `minPlayTime` 0.3 s,
`maxTurnRate` 3 rad/s).

### MoCap Online Zombie Pro (`-clipSet pack`)

The zombie's animation clips are cooked from [MoCap Online's Zombie Pro
pack](https://mocaponline.com/products/ue4-zombie-pro), whose license does
not permit redistributing animation data — so this repository contains no
clips, only the code. To run the demo:

- own the pack, export the sequences as glTF, and cook them with the
  Untold Engine Blender add-on into
  `Sources/CoolZombieKit/Resources/Animations/<clip>/<clip>.untold`, or
- download a prebuilt demo binary from the Releases page, where the
  clips ship embedded in the compiled app as the license allows.

The pack's clips were cooked for the UE4 mannequin skeleton of the earlier
marketplace model; they play on the current rig only after a retarget onto
it, which the tools above do not cover yet.

## Physics

The room is a physics world on the
[UntoldJoltPhysics](https://github.com/untoldengine/UntoldJoltPhysics) plugin
(Jolt Physics as an engine backend). Every navigation box — the sandbox
layouts, a saved room, the walls and furniture ARKit detects — is a static
box in it, with a floor slab under everything, and the zombie is a
character controller (`ZombiePhysics`, over the plugin's `JoltCharacter`):
a cylinder 1.8 m tall and 0.2 m in radius standing on the entity's origin.
Each frame the controller is moved by whatever root motion did to the
entity, collides and slides that motion against the boxes — however long
the frame, so a stall never skips it over a wall — and the entity is put
where the controller ended up; the jumps the game means (spawn, reset)
are told to the controller as teleports. So a run cannot carry the zombie
through a wall, and the transition's root-velocity crossfade cannot slide
it into one once its hands are planted. That replaces the planner's
push-out (still there for a build without physics, and still the spawn
search's notion of a free point); the grid planner keeps routing around the
boxes and the chase keeps judging distance along the route. The controller
owns nothing vertical: the game pins the height to the floor it knows, so
the cylinder's flat base never climbs a low object, and a floor that moves
under the zombie moves the controller with it.

The radius is set by the wall hold: Jolt keeps the controller 2 cm off
every surface, so 0.2 m of radius stops the zombie exactly at the 0.22 m
stand-off the hold clip's hands reach. Props with rigid bodies bounce off
the controller (its inner body carries the zombie's entity, so contacts
and rays name it) and are pushed by it, but never shove it. The world is
installed before the first simulated frame — in the sandbox's setup, and
on the headset before the renderer exists — because the engine keeps the
first backend for the whole process; a reopened immersive space finds it
in place and only re-creates the controller. `-debugLog` prints
`physics=jolt` while the controller exists.

### Hits: ragdoll and reactions

Throw a ball at it: **H** or the ball button in the sandbox; in the
headset pick *Toss* or *Throw hard* in the control window, then pinch
anywhere in the room — the ball goes where you were looking when you
pinched, at the arm, leg or head your gaze crosses, or past the zombie if
you look beside it (the window's *Throw* button throws along your head
instead; `-throwBall <seconds>` and `-autoThrow <seconds>` throw one at
the chest every so often for scripted runs). The
ball is a rigid body in the same world, and so is the zombie's body: it
is a powered ragdoll all the time — the pelvis rides the animation, the
other nineteen parts are dynamic under gravity and held onto the
animation by 60 Hz joint motors (Jolt runs sub-steps of 8 ms or less for
that — three per engine step at the Mac's 60 Hz, two per 10 ms frame on
the headset, `ZombiePhysics.Configuration.collisionSteps`; the hands then
follow a run within a few centimetres; the
targets are aimed a frame ahead, except across a jump of the pelvis — a
floor snap, a respawn: over 20 cm in a frame, which no animation does —
when every part is re-seated on the new pose instead, since dynamic parts
cannot follow a teleport by force and would arrive bent, or pinned under a
floor slab raised above the feet) —
so the ball meets the actual arm, leg or head and bends it, and the
motors bring everything back (the character controller's own shape
ignores balls). What the mesh shows of the parts is a separate choice
(`Configuration.showsTrackedParts`, on): every part all the time, so
whatever the body meets bends what you see — a tracked part is off the
animation by its tracking error (hands 8-13 cm and head 7 cm in an idle,
from the joint limits; feet 2-4 cm) — or only a part a hit has (a
reaction, a stagger, the fall), the animation otherwise. Showing the
parts needs the simulation to step with every frame: both hosts set
`setEngine(.simulationStepping(.perFrame))`, because against the
engine's fixed 60 Hz step a headset drawing 100 frames a second showed
no new pose on two frames in five while the animation moved on — a
stutter of the whole upper body. When it strikes, the contact's
impulse decides what happens (only a ball counts — the fallen body's own
landings on the floor are not hits). A hard hit (2.5 N s, a 0.6 kg ball at about 4 m/s) knocks it down in
two beats. First the struck chain staggers: everything from the part
below the pelvis up — the whole upper body for a hit on the head or an
arm, one leg for a hit on a leg — goes physical under gravity, held by
soft motors that keep trying for the animation, and takes the hit
several times over, so the head snaps back and drags the torso and the
arms after it while the legs keep stepping. Half a second later the body
lets go: twenty capsules on the rig's bones
— pelvis, three spine links, neck, head, a clavicle and three more per
arm, three per leg, jointed by swing-twist constraints with a limp body's
ranges (a knee's cone centred mid-bend, so it folds backward and never
forward) — take the pose and motion the animation left the
body in plus a shove along the hit (a ball would not really floor
anyone; the body is set going the way it was struck), go dynamic with
next to no joint friction (so it collapses rather than freezing in the
shape it landed in), the character
controller steps aside, and from then on the mesh follows the parts
through the engine's physics pose (a full-weight override of every joint
that has a part; the joints without one, the toes and fingers, keep their
animated offsets under whichever part moves them). Balls keep
shoving the fallen body; *Reset* stands it up again at the spawn point.
A lighter hit ripples instead: only the parts hanging from the struck one
(the torso, for a hit on the pelvis) lose their motors and their gravity
for 0.12 s, so only the ball's momentum shows (three times over, so it
reads), then soft motors pull them back toward the live animation pose —
the animation's own, not the one on screen — and after a second the
tracking motors take them again; a second hit during the ripple widens it
and restarts it. *Reset* or a mode change cuts straight back to the
animation, standing. The engine side is a small seam (the skeleton's
joints and bind pose, this frame's joint transforms, a per-joint physics
pose with weights, applied after foot IK); the physics side is the
plugin's ragdoll (`JoltRagdoll`), built by `ZombieRagdollRig` from the
skeleton's bind pose so the parts sit on the joints and read straight back
onto them. The capsules are fitted to the body: `prep_zombie.py` profiles
the skin each part's bones move around the capsule's own line (1 cm bins
along it, 15° sectors around it, the skin's reach in a bin its farthest
vertex, so the teeth and eyes inside the head never count) and keeps the
largest radius whose surface stays within that reach everywhere, to 3 mm,
and a centimetre inside the shirt and the trousers proxies, their
surfaces sampled 28 points a triangle (`CAPSULE_GARMENT_MARGIN`: a cloth
particle's collision radius when the capsules were the cloth's colliders;
the radius is 3 mm now, against the skin's hulls, and the centimetre
stays as the margin for the ragdoll A/B) — Jolt holds a particle its
radius off a capsule, so a capsule any closer pushes the
resting garment off its skin, and the parts hang a finger's width off
their joints at rest (the forearm 1 cm, the hand 3 cm: the tracking
motors' springs leave each joint a fraction of a degree to a degree and a
half short, and it adds up along the chain; `ZombieClothTests` pins the
figures and holds the cuffs to the hands'); the line runs along the bone
through the skin's centre — for the
limbs from the centroid of their first third to their last third's, since
the shin leaves the ankle at the Achilles tendon and the femur lies
lateral in the thigh — and spans the bone, the chain's free ends reaching
the skin's extent (the crown, the palm from a finger's width below the
wrist, the heel to the ball) and the pelvis the hips. The numbers are
pasted into the rig's table and `ZombieRagdollRigTests` holds every
capsule to the export: no point of its surface more than 5 mm out of the
skin where the export keeps skin (its own bones', and the neighbouring
parts' where the caps enter them; under the trousers and the shoes the
prep culls it, under the shirt it stays),
every point of the shirt's and the trousers' surfaces 2 mm clear, at least
95 % of each capsule's surface samples with skin or a garment around them,
and every joint within a tenth of a metre of its capsule's line. The torso
is an ellipse and a capsule is round, so the spine links are as thick as
their thinnest direction allows (7-9 cm; the hips 10 cm, the head 7 cm,
the neck 4 cm), the legs as thick as the trousers leave room under them
(the thighs 3.4-4 cm, the shins 1.5 cm; the knee and the ankle would allow
5 and 2.3; the feet 2 cm along the sole, inside the shoes) and the arms as
thick as the tight sleeve leaves room under it (1.0-1.4 cm; the clavicles
the fit's floor of 5 mm under the yoke): thin for a ball to find, but the
balls are thrown at the chest. Sized for the old mannequin the capsules
reached 7 cm through the back of this shirt.
The character controller and the ragdoll are on collision
layers that ignore each other; the balls pass through the controller's
shape and meet the ragdoll's parts. The room's walls
and furniture are on a layer of their own that the controller and the
balls meet but the powered ragdoll passes through — a desk within reach
would bend a tracked arm, and a box edge jittering into a part would push
it out while the motor pulls it back, every frame — and that the fallen
body lands on: the layer matrix follows the knock-down and the stand-up.
The floor slab stays on the common layer, so the feet keep it either way.

### Cloth: the shirt as a skinned soft body

The artist's shirt — the shell: two layers of fabric, the folded collar,
the buttons — is in the exported mesh, skinned to the body like the rest,
and the cloth sidecar (`Zombie.cloth.json`, above) carries a particle proxy
of it, which is not in the mesh, and the shell's binding to that proxy.
`ZombieCloth` turns the proxy into a Jolt soft body skinned to the skeleton
and worn over the ragdoll: at the reveal every shell vertex is bound to the
exported vertices at its position (within a fifth of a millimetre; the
exporter splits a vertex on UV seams, so one drives several; an exported
vertex two shell vertices reach goes to the nearer), the body is built at
the bind pose and hard skinned onto the frame's pose before anything steps,
and from then on Jolt keeps each particle within its slack of where the
skin puts it — the schedule above: the collar band and the cuffs pinned,
the yoke 7 cm, the chest 9, the back 10, the hem band 12, the
sleeves 11, the armhole band 15, 5 mm down the buttoned front — and, in
every solver iteration, no more than a millimetre behind it (the
back-stop: the push-out left the proxy 2 mm off the body, which is kept
under the shirt; Jolt applies the edge constraints after the stop, so they
have the last word, and on the idle they leave the worst particle 3 mm
behind its target at the cuff while it stays 3.4 mm off the body), while
the triangles' stretch, shear and bend constraints make it cloth. A
triangle mesh with rigid edges can only bend isometrically — that is
paper, and the headset read the shirt as paper while its edges were held
at 1e-6 m/N (2026-10-31); cloth needs a few percent of in-plane give to
shear and drape. Jolt's compliance is physical: a constraint's equilibrium
stretch is the force through it times its compliance, whatever the
iteration count — the pass divides a violation by the two particles'
inverse masses (20,000 1/kg each at 50 mg) plus the compliance over the
solver step squared (1.4 ms: the 5.5 ms sub-step over four iterations),
which sets how much of the violation one pass gives back, not where it
settles. Under the shirt's own weight an edge carries about 0.05 N (the
0.2 kg shirt's 2 N over the few dozen edges of a ring around the torso),
so the edges' 1e-2 m/N stretches a 1.7 cm edge half a millimetre, 3
percent; the shear at 2e-2 gives twice that across the diagonals; the
bends at 0.3, a little stiffer than the 0.5 before (a pass gives back about
a fifth of a bend violation, where it gave an eighth), keep the folds broad
on the proxy's 1-4 cm triangles rather than crumpled — anything below
about 1e-3 reads as rigid at this mass and step, and the first cook's 5e-4
bend made the shirt a stiff shell that folded in sharp plastic creases
and, solved in two passes, jittered. The particles' damping is 4 1/s (2.5
before), standing in for the air's drag on the fabric, so the shirt moves
slowly, swinging after the body rather than snapping with it; and the
solver runs four iterations — Jolt's small steps, a constraint pass each
on a quarter of the sub-step — where two left every constraint fighting
the next. The frame runs: the
animation composes the pose; the physics step begins and the cloth's
`willStep` hook feeds that pose's joints to the skin (the pose the body is
drawn with); Jolt steps; the game update puts the ragdoll's pose on the
mesh and, last, the cloth reads the particles back (positions only), turns
them into mesh space, rebuilds every proxy triangle's frame from them and
evaluates the shell (`RenderShell`: each exported vertex the shell drives
its shell vertex's barycentric point plus that vertex's rest offset in the
frame, and its normal its own exported normal — read off the mesh at the
attach, when every shell vertex is matched to its exported copies — in the
frame, so the fold keeps its thickness, the creases on the artist's sharp
edges keep the split normals the exporter gave them, and a button rides
one triangle whole), and writes the shell's vertices and normals over the
deformation pass's output (`setEntityDeformationOverride`), applied after
the skinning and before the draws. The vertex pass runs over the cores
(`DispatchQueue.concurrentPerform`, runs of 2,048 driven vertices); the
figures, one thread's and the cores', are below. The body moves to compute skinning
for that
(`setEntityDeformation(.lbs)`): the price of the override. A shell vertex
found off the mesh, a joint the skeleton lacks or counts that disagree
leave the garment body-skinned, logged once — nothing is driven wrong. (A
garment without a binding — the trousers, not simulated yet — would be
drawn as its proxy, the particles and their normals written over their own
vertices.)

Whenever the body is put somewhere rather than moved — the ragdoll
re-seated on a pelvis jump or a stand-up (`ZombiePhysics.didReseat`), a
reset, the bind-pose inspection entered or left — the cloth hard skins
every particle onto its skinned position at rest, and the slack opens from
nothing over a quarter of a second; in the bind pose it stays shut until
the parts have reached the pose. A still body (no joint moved a
millimetre in a frame, no particle faster than 2 cm/s, for half a second)
puts the cloth to sleep: no feed, no override, the last override stays,
until a joint moves or something moves the particles — asleep, only their
positions are read each frame, so a ball through the hem of a sleeping
shirt wakes it instead of denting Jolt's shirt under a frozen one. A
frame's joint motion is measured against the last frame, not the last
sub-step (a long frame runs as several on one displayed pose); asleep,
it is measured from where the joints stood when the cloth fell asleep as
well, since nothing moves a sleeping shirt's particles any more and a body
creeping under the millimetre every frame would otherwise walk out from
under its frozen override for good (0.4 mm a frame wakes it on the third;
`ZombieClothTests` pins it). Beyond 4 m
from the player the override is cleared, so the shell is drawn by its own
skin weights again — the proxy's, which the prep gives it, so it sits where
the hard-skinned simulation would put it and nothing jumps at the line
(within 3.5 m: half a metre of hysteresis, so a player at the line does not
flip it) — and the return hard skins it onto the pose; asleep in range, by
contrast, the last override stays, the shell as it was last evaluated. A
particle that is not a number or 2 m from the pelvis hard skins the body
(counted in the report).

Asleep or out of range the soft body is put to sleep in Jolt
(`setSoftBodyActive`): the step skips it altogether — no solve, no
collision, no skinning — which is where the shirt's cost was (the sleep
used to save only the feed, the read-back and the override while Jolt
kept solving 24,000 constraints). Jolt wakes a sleeping soft body for any
awake rigid body that reaches its bounds on a layer the two share, and
the ragdoll's parts sit inside the shirt, so the sleep would be undone
every step on the cloth's own layer: a sleeping shirt moves to a resting
layer (`restingClothLayer`) that only the balls meet — a ball thrown at a
still zombie wakes the body in Jolt, the read-back sees the particles
move and wakes the cloth, which puts the body back on its layer — and an
out-of-range shirt to the inert layer, where nothing is fed or solved
until the player returns. The report prints `sim=on|off` (`jolt=` until
2026-11-03, when the solver seam below gave both arms one name) beside the
cloth's own state, `joltWakes=` the times Jolt woke a resting body on its
own (a ball; the parts must never show there, and the tests hold it at
zero over the powered ragdoll) and `joints<=` the farthest a joint moved
in the last frame: the idle clip moves its fastest joint about a
millimetre a frame (half that at 100 Hz), so the joint half of the sleep
rule passes most frames; it is the particles, moving with the skin at
0.2–0.5 m/s, that keep the cloth awake during it (see the measurements
below).
The cloth is on a collision layer of its own: the balls dent it, the floor
stops it, its own skin's hulls (the sidecar's colliders, Assets above, on
`skinColliderLayer`, moved with the joints every step) hold it off the
body wherever it is, the controller walks through it (the pair is closed
both ways), the room's boxes meet it only while the body is down, like the
ragdoll — and the ragdoll's parts do not meet it. The body the shirt
collides with is its skin, twice over: through the back-stop where a
particle sits near its skinned target — the proxy carries the body's own
weights (below), so its reference is the skin in every pose — and through
the hulls where it does not, the sleeves over the raised arms. The hulls
meet the two awake cloth layers and nothing else: not the resting cloth,
which a moving kinematic body on a shared layer would wake every step,
not the parts inside them, not the balls or the room. The capsules
are a ragdoll's, not a body's — fitted to this body, the pelvis still
stands 47 mm outside the skin, the lower spine 67 mm, the yoke 28 mm
(measured on the rig, 2026-10-31) — and a shirt that met them was pushed
out into a ridge at the waist and squeezed between them and the skin
stop: the fold line and much of the jitter the headset showed. `-cloth
off|skin|world|ragdoll` picks the model on both hosts — off leaves the
shirt body-skinned, `skin` hangs it on its skin alone on a layer nothing
meets (what every collision costs and adds; no hulls are built), `world`
(the default) collides as above, `ragdoll` keeps the parts as colliders
too (one way, on a layer of its own) for the A/B — `-clothColliders off`
leaves the skin's hulls out of any model, the back-stop alone (what the
hulls cost and add: on the Mac's release build the Jolt step's median is
3.4 ms with the eleven hulls against 1.7 ms without them, the same build,
idle and chase alike, 2026-11-02) — `-clothSlack <scale>` multiplies
every free particle's slack (the pins stay pins; at 3 the chest may
wander 27 cm from its target and the shirt hangs on the hulls and the
back-stop, the clamp a tunnelling guard alone: the experiment that reads
how much of the shirt's look is the tether) — and
`-clothIterations <n>` sets
Jolt's iterations: four by default (the fit tests run at four), one to
six for the A/B — and `-clothSolver jolt|gpu` picks the solver behind the
seam (below), with the GPU arm's own knobs beside it: `-clothSubsteps
<n>` (1 to 32; 16 by default, 0.625 ms each at the headset's 10 ms),
`-clothGPUIterations <n>` (1 to 4 gathers per substep; 2 by default,
the residual test's verdict below), `-clothRelaxation <r>` (0.5 by
default), `-clothAveragedJacobi on|off`, `-clothGPUDamping <d>` (unset,
Jolt's 4 1/s), `-clothHullFriction <f>` (0), `-clothGPUWait on|off` (on)
and `-clothSidecar <name>` (the bundled one), each left as it was by a
value outside its range. The GPU launch lines are `swift run CoolZombie
-play -inspect idle -debugLog -clothSolver gpu -clothSubsteps 16` on the
Mac (`-clothGPUIterations 1` for the 33-dispatch frame, `-clothGPUWait
off` for the one-frame-lag mode, `-clothColliders off` for the hulls'
cost) and `xcrun simctl launch <udid> com.miolabs.CoolZombieVisionOS
-autoOpenSpace -clothSolver gpu` on the headset. The same choices
switch live: the Mac's Cloth and Solver dropdowns,
and on the headset the control window's *Cloth* (Off / Skin only / World
/ Ragdoll too), *Solver* (Jolt / GPU), *Cloth iterations* (1, 2, 3, 4 or
6; Jolt's knob) and *GPU substeps* (8, 12, 16 or 24; the GPU's) pickers,
each
change taking the shirt off and putting it back on rebuilt
(`ZombieChaseGame.setCloth`). Off returns the body to its own
vertex-shader skinning (`ZombieCloth.detach` removes the deformation
component the attach added, `removeEntityDeformation`), so it is the
launch's `-cloth off` and the footnote's frame line reads the compute
path's GPU price against it — the per-eye cost of compute skinning the
71,300-vertex body (the shell drawn, the skin under it kept), not yet
measured on the device. The device defaults are two
iterations and two Jolt sub-steps per 10 ms frame (a 5 ms sub-step keeps
the 60 Hz motors' 8 ms bound; the Mac keeps three at 60 Hz) with Jolt's
own thread count. Measured on the Mac (M4 Max, release, 60 Hz, 35 s runs,
the report's step figure — Jolt's step plus the coordinator's read-back,
sampled once a second — as a median over the awake, in-range samples,
with the largest sample in brackets; the idle is `-play -inspect idle
-debugLog`, the chase `-play -debugLog -throwBall 8 -resetEvery 12`; one
figure per run where a configuration was run more than once):

| configuration | idle step, median (max) | chase step, median (max) | worst target, idle / chase |
| --- | --- | --- | --- |
| HEAD 9ab1901: 3 iterations, 3 sub-steps, Jolt solving the sleeping shirt | 1698 (3340) us | 2288 (11534) us | 5.2 cm / 12.9 cm |
| this change at 3 and 3, three runs | 1800 (7201), 1870 (2140), 1872 (4546) us | 2660 (3829), 3154 (4173), 3034 (4248) us | 5.2–5.3 cm / 8.8–12.0 cm |
| 2 iterations, 3 sub-steps | 1371 (4021) us | 2280 (4323) us | 5.2 cm / 8.5 cm |
| 3 iterations, 2 sub-steps | 1297 (2847) us | 2040 (2720) us | 5.3 cm / 13.3 cm |
| 2 iterations, 2 sub-steps (the device's), three runs | 940 (2122), 1045 (11602), 1300 (1808) us | 1845 (3245), 2036 (3507), 1857 (2419) us | 5.2–5.4 cm / 8.9–14.0 cm |
| skin only, 2 and 2, two runs | 1018 (3415), 966 (3642) us | 916 (47211), 905 (4006) us | 5.2–5.3 cm / 6.4–7.0 cm |
| 2 and 2, three worker threads, two runs | 1289 (2209), 901 (6286) us | 1405 (3659), 1702 (2605) us | 5.2 cm / 9.7, 8.8 cm |

Against HEAD the device's defaults take the idle step from 1698 to
940–1300 us (a quarter to two fifths off) and the chase from 2288 to
1845–2036 us (a tenth to a fifth off); this change's own three runs at 3
and 3 came out 16–38 % above HEAD's chase and 19 % apart, which is the
run-to-run spread every chase figure sits in (the idle's three runs at 2
and 2 spread 940–1300 us the same way). Not one run woke a resting body
in Jolt (`joltWakes=0` throughout, eight balls a chase). The idle's worst target is the armpit figure above
at every setting, so two iterations cost nothing there; the chase's worst
figures are the knockdown and reset transients. The two-sub-step rows at
60 Hz split a 16.7 ms frame into 8.3 ms sub-steps, past the motors' 8 ms
bound, so they stand for the step's cost and not for the ragdoll's
tracking at the device's 5 ms (their 13–14 cm chase worsts cannot be told
from motor lag); the device's own cadence, two 5 ms sub-steps at 100 Hz,
is held to the slack and to the parts' rest errors by `ZombieClothTests`
(`testTheDeviceTwoSubStepsKeepTheShirtWithinItsSlack`): at two
sub-steps the idle shirt strays 1.1 mm past its slack (the bound is 5)
and the sway 1.6 mm against the 20 mm bound (0.5 mm at three), the hands
resting 3.2 cm off their joints at either. The skin-only chase's first
median hides one 47 ms sample at a reset (its mean is 3.8 ms, the next
largest sample 13 ms; the second run's largest is 4.0 ms), where every
other configuration's chase maximum is 2.4–4.5 ms. Asleep or out of range the step is the ragdoll's
and the room's alone: 237 us median with the body asleep in Jolt, against
1744 us when Jolt still solved the far shirt. Three worker threads
measured the idle the same and the chase a sixth to a quarter lower on
the medians (1405 and 1702 against 1845 and 2036 us, two runs each),
inside the 19 % spread of the two runs at 3 and 3, so the device keeps
Jolt's default — three is worth trying on the M2, where four of the eight
cores are efficiency cores. The idle never slept
in any run: its fastest joint moves 0.7–1.0 mm a frame at 60 Hz (bursts
of 6 mm), which at the headset's 100 Hz is 0.4–0.6 mm and would pass the
1 mm rule most frames, but the shirt's particles move 0.2–0.5 m/s with
it, far over the 2 cm/s rule, and over a perfectly still powered ragdoll
the cuffs keep moving at 3–8 cm/s against the forearm and hand parts
(`ZombieClothTests` documents it), so a 2 mm joint threshold would change
nothing; the sleep fires on the skin alone, out of range, or once the
parts sleep too. With `-debugLog`
the sandbox prints the cloth's report every second (particles, pins, the
slack multiplier, awake or asleep and Jolt's state, the skin feed and
read-back microseconds, the step interval, the farthest particle from its
target, the joints' motion, the wakes Jolt gave a resting body) and warns when the override count stood still
for a second while the cloth was awake and in range; the headset shows
the short form (state, timings, counters) in the control window's
footnote, beside the frame's own line (the engine's CPU update and
encode and GPU milliseconds in a debug build, and the frames whose GPU
work finished after the compositor's deadline). A body that does not
take the deformation component at the attach is refused like a stale
sidecar, since the override's write is silent. The ragdoll's
capsules are fitted inside the body and a particle's radius under the
shirt (above), so on the default model the resting shirt stays within its
slack in every region (`ZombieClothTests` prints the figure per region for both models
and holds the default to 5 mm; sized for the old mannequin, the spine
capsules reached 7 cm through the back of this shirt and pushed the
back's particles 5 cm past their slack, jittering against the skin). The
shirt carries the body's weights and the sidecar opens the slack to 15 cm
around the armhole (Assets, above), for the arms-forward idle, where the
skinning stretches the armhole edges (2.4 times at the 99th percentile,
9.8 at worst) and the cloth, holding its rest lengths, sits up to 15.5 cm
from its skinned target under each arm — the report's `target<=` figure,
with where it sits; `ZombieClothTests` holds the band within a centimetre of its
slack and every particle within a centimetre and a half of its own (the artist's weights had
the band 16.3 cm off, the graded ones 6.7 on 6 cm with 2.7 cm of fight; the
report's own figure in that pose is the hem band's 10.8 cm, a hanging
particle on 12 cm of slack). The capsules play no
part in it: on the skin alone, with no part in the world, the figure is
the same to a millimetre. What remains is the skinned targets': the
sleeve's underside hangs between an arm that moved 40 cm and a flank that
did not, the skinning stretches those edges and the cloth will not, so the
particle rests short of a target it could reach. A wider or deeper blur
turns the figure back up and 13 cm or more puts arm weight on the hips, so
closer would take other targets (hand-painted armpit weights, or a
skinning that does not stretch), not the sidecar's blur; the 4 cm this
round aimed at was not reached.

The shell's binding, measured the same way on 2026-10-31 (two iterations,
the Mac's three sub-steps, the schedule's sidecar, 35 s runs sampled once
a second; the figures are the awake, in-range samples' medians with the
largest sample in brackets): the shirt's 29,402 shell vertices drive
32,530 exported copies (the split copies on the sharp edges). On the idle,
14 of the 33 samples awake and in range (the inspection spends the rest
with the player more than 4 m off), the skin feed takes 89 us, the
read-back 678 (1,220) us with the shell's evaluation 503 (1,008) us
inside it, and the step 1,476 (1,698) us — where the table's row at two
iterations and three sub-steps had it; the worst target is 8.8 cm, the hem
band's hanging particle on its 12 cm of slack (with the schedule the idle's
worst is the hem's, not the armpit's 5.2 cm of the table's rows). On the
chase, 23 of 34 samples awake and in range, eight balls: the skin feed
96 us, the read-back 675 (918) us, the shell 541 (720) us, the step
2,257 (3,389) us, the worst target 12.5 cm, again at the hem, at a
knockdown. One thread evaluates the shell in 628 (1,273) us on the same
idle (its read-back 772 (1,553) us, its step 1,373 (2,512) us), so the
cores take a fifth off; both figures are over 0.6 ms, which the headset's
cores, about twice slower, would make more than a millisecond of the
10 ms frame, so the pass stays split. Not a runaway, not a wake Jolt gave
a resting body and not an error line in any of the three runs.

On 2026-11-03, after the third headset round still read the shirt as
paper — coarse crumples that do not fall under gravity, skin through the
sleeves at the arms, and tripling the slack (`-clothSlack 3`) changing
little, so the tether is not the limit — the owner chose a GPU XPBD solver
in Metal compute to replace the Jolt soft body, keeping everything else of
the pipeline (the prep, the body's weights on the proxy, the schedule, the
hulls, the shell binding, the tests, the hosts), and `Docs/GPUCloth.md` is
its design: sixteen substeps of 0.625 ms per 10 ms frame over the proxy
as a CSR graph, the slack and the back-stop applied after the edges so
they are exact, the hulls as plane sets, a second cook at 16,000
particles once the solver stands. Phase 0 of it is in: `ZombieCloth` now
reaches its solver through the `ClothSolver` protocol
(`ZombieClothSolver.swift`) — the fourteen calls it made into the Jolt
backend, as the build and the destroy, the feed inside the step, the hard
skin, the frame's begin, the two position reads, the rest state with its
layer and the activity — and `JoltClothSolver`
(`ZombieClothJoltSolver.swift`) carries those calls moved verbatim: the
soft body's descriptor, the eleven hulls teleported and then targeted at
every feed, the resting layers. The thousand solver-independent lines
(the shell, the binding, the joints, the ramp, the sleep, the range, the
runaway, the report) stay where they were and serve both arms, so the two
can be A/B'd on the same proxy, hulls, schedule and tests, and the 29
cloth tests pass unchanged behind the seam with the figures above.
`Configuration.solver` (`-clothSolver jolt|gpu`, the *Solver* dropdown
and picker) picks the arm — Jolt by default until the design's gate 2 —
with the GPU arm's knobs beside it (`gpuSubsteps` 16, `gpuIterations` 2,
`gpuRelaxation` 0.5 on the raw sum, `gpuDamping` nil for Jolt's 4,
`gpuHullFriction` 0, `gpuWait` on, `sidecar` nil; the launch arguments
above), the game hands the cloth its floor and the balls as spheres
(`floorY` at the slab's height, `sphereProvider` reading
`ZombieProps`' balls through the Jolt backend's body state after the
step) for the GPU's contacts, and the diagnostics line prints `sim=on|off`
for both arms.

Phase 1 of the design landed the same day, 2026-11-03: `GPUClothSolver`
(`ZombieClothGPUSolver.swift`) behind the seam, its three kernels in
`Sources/CoolZombieKit/Shaders/ZombieClothGPU.metal` — excluded from the
SwiftPM target, as the engine and CoolCloth ship theirs, and compiled by
`Scripts/build-cloth-metallib.sh` (two seconds) into the five committed
`Resources/Shaders/ZombieCloth-{macos,ios,iossim,xros,xrossim}.metallib`,
24 KB each (35 KB since the shell kernels of phase 2, below), against the package's own minimums (macOS 14, iOS 17,
visionOS 2) because a lib built against the SDK's OS is refused on an
older device — with the C header `ZombieClothGPUShaderTypes.h` as the
ABI (`ZCParams` 256 B, `ZCEntry` 8, `ZCInfluence` 16, `ZCHullHeader` 48,
`ZCSphere` 32, `ZCStats` 64; nineteen buffer roles, five more reserved for
phase 2, which took them on 2026-11-04 for the shell's triangles, frames,
bindings, output and params), pinned on the Metal side by `static_assert` at every metallib
build and on the Swift side by `ZCLayout.mismatches()` in the tests. The
kit loads the platform's lib from `Bundle.module` through the engine's
suffix rule (`xros` / `xrossim` on the headset, `macos` on the Mac), and
`gpu` falls back to Jolt with one printed line only when the renderer has
no device or the bundle lacks the lib. At attach the solver derives
Jolt's constraint set from the sidecar's faces as a CSR graph — 11,849
edges of which 1,424 pin-pin are dropped, 11,707 cross pairs of which
1,282, 10,425 stretch and 10,425 bend constraints (1,556 of the pairs
quad-like under Jolt's 8 degrees and on the shear compliance), 41,700
entries, 22 at most and 10.44 on average per particle, rest lengths
8.5-39.1 mm, every figure the design gave — the eleven hulls as plane
sets by the design's brute force (87 / 83 / 82 / 88 / 66 / 84 / 82 / 66 /
70 / 60 / 64 = 832 planes, every one of the 446 points inside at 1e-5),
the area-weighted rest normals, the influences and the slack. Per frame
it is fed inside `willStep` (the joints, the multiplier, the delta
accumulated over a long frame's several calls), encodes at `beginUpdate`
— after Jolt's step, so the balls it sees are this frame's — one command
buffer on its own queue, S x (`zcPredict` + two `zcSolve`) + `zcStats` =
49 dispatches at sixteen substeps in one serial encoder, and waits for it
once at the first read in `readBack`, so the game's own step overlaps the
GPU; `-clothGPUWait off` blits the positions into a three-slot ring
instead and reads the last completed one, a frame late (`lag=1f`), and
since that ring and the four-slot stats ring are read with no fence the
encode keeps at most two frames in flight behind its own (the review of
3 November found the input ring's guard alone allowed four, where a GPU
three frames behind would blit over the slot being read). A game frame
without a physics step feeds nothing and encodes nothing — the shirt
stands on the last frame's positions, as Jolt's does — where the first
cut simulated the last feed's delta again and replayed its joint motion
from the pose before it; the hosts' per-frame stepping only reaches that
on a frame under 1/250 s, the engine's fixed stepping two frames in five
at 100 Hz. The
predict kernel blends up to four skin matrices, slerped per substep by the
CPU with the matrix's residual carried so the last substep reproduces the
fed pose to the bit, into the target and the rotated rest normal; the
solve kernel runs the CSR gather (CoolCloth's XPBD formula over Jolt's
compliances), then the back-stop plane, the hulls as the most-facing-plane
push-out in the hull's rigid frame (a particle enters the plane loop only
inside the hull's box in its joint frame, the points' extent plus twice
the vertex radius — the design's bounding sphere held most of the shirt
for a torso hull, so `ZCHullHeader` carries a box and is 48 B — and the
loop leaves at the first plane that reads the particle outside: without
the two the eleven hulls cost 2.7-7.0 ms of GPU per Mac frame against
0.7-1.6 with them off, measured in the release host the same day) with the optional friction
against the hull's own motion between the two bound frames, the floor
with the 0.4 xz mix, the balls backed along their velocity to the
substep's time, and the slack ball LAST so it is exact, then on the last
gather v = (x - prev) / dt capped at 4 m/s; the stats kernel reduces the
bounds, the top speed, the NaN and on-clamp counts in one threadgroup. A
hard skin is a CPU write of the skinned targets into the position,
previous and velocity buffers after a wait for anything in flight
(exact: 0.0 m against `skinnedTargets`); asleep or out of range the
solver encodes nothing (the particle bytes bitwise equal across sleeping
frames) and a ball's swept box against the last stats' bounds wakes it.

What the solver measures, in `ZombieClothGPUTests` (30 tests, skipped
without a Metal device; the fit scenarios hoisted out of
`ZombieClothTests` into `ClothFitScenarios.swift`, `ClothMetrics.swift`
and `ClothTestHarness.swift` so both arms run the same bodies with their
own bounds, the Jolt figure lines byte for byte what they were) on the
M4 Max, 2026-11-03, a debug build: the pins sit on their targets within
2.9e-6 m and the free particles within 1.4e-7 m of their slack after 300
idle frames — the first run read 0.50 mm and 0.19 mm, because the
influence weights travel as `half4` and their rounded sum was off one by
up to 3.5e-4, half a millimetre at a metre from the origin, so `zcPredict`
now divides the blend by the rounded weights' sum — the back-stop holds
1.25 mm behind the skin at the worst (Jolt 3.14), nothing sits inside the
posed skin after the hang or the sway on any model (Jolt 0 / 0 / 4), the
hang sags 9.4 mm (Jolt 10.5), the arms-forward armhole band rests
143.4 mm from its target on its 150 mm ball where Jolt's edges held it
at 67.0 against an inexact clamp, with 12 particles inside the posed skin
with the hulls and 18 without (Jolt 65 and 154: the exact back-stop does
most of the hulls' old work, and what is left sits where the convex hulls
are inside the concave back and armhole, phase 4's gap capsules), the
swing leaves none inside at any read frame (Jolt 9), a thrown ball dents
the chest 50 mm (Jolt's bound 20), the shirt sleeps after 177 still
frames and a ball wakes it in 10, two solvers are bitwise equal over 120
frames, a NaN in a free particle hard-skins the shirt the next frame (a
pin cannot run away: the kernel rewrites its target every substep), and
`onClamp` reads 1-2 % of the free particles on their slack ball at 9.8
and at 50 m/s^2 alike — the design expected nine in ten at 50, and the
figure says the shirt is edge-bound, not slack-bound, which is what the
`-clothSlack 3` experiment could only guess at. The stretch residual at
rest (`testStretchResidualAtRest`, the design's gate: under 1 % on
average and 3 % at the 99th percentile at 16 substeps, 2 % / 6 % at 8)
decided `gpuIterations`' default: one gather of the raw sum at 0.5 gives
0.73 % / 3.38 % at 16 and 12.6 % / 41.9 % at 8, the averaged Jacobi at
1.5 is worse at both (2.53 % / 10.1 %, 5.5 % / 22.0 %, three and a half
times weaker per pass at the proxy's degree as the design computed), and
two gathers meet the gate at both (0.40 % / 2.09 %, 0.80 % / 3.84 %), so
two is the default — 49 dispatches a frame instead of 33, the second
gather skipping the predict and the blend — and `-clothGPUIterations 1`
is the A/B back. The second gather recomputes its delta-lambda from
scratch (no XPBD lambda is carried between gathers) and the speed cap is
applied every substep where Jolt's is once per step, both slightly on the
stiff side of Jolt; at a compliance of 1e-2 the physical equilibrium
stretch is 0.03 % (m g c = 4.9 um on a 17 mm edge), so the 0.4-0.7 %
residuals are under-convergence, not compliance, and the gather count is
the right lever. In the same debug build (`testGPUTimingsOverThreeHundredFrames`,
300 frames of the sway at 100 Hz) the GPU takes 2.48 ms median (2.80 mean,
7.83 max) per 16-substep frame of 49 dispatches, the wait after the game's
step 2.78 ms median, the feed 0.32 ms, the read-back 13.3 ms and the shell
8.7 ms of it, debug code; the release figures are the sweep's below.

The Mac sweep the design asked for (section 7, the day-4 sweeps) ran on
2026-11-03 in the release host (`swift build -c release --product
CoolZombie`, the M4 Max, 60 Hz, so every GPU run cuts its 16.7 ms frame
into 27 substeps of 0.625 ms by the design's rule, 27 x (1 + 2) + 1 = 82
dispatches at two gathers), 35 seconds each with the once-a-second
`-debugLog` line, the idle inspect (`-play -inspect idle -debugLog`) and
the chase (`-play -debugLog`), the medians over the awake in-range lines
(13-14 of them in the idle, which walks out of range after 15 s; 22-28 in
the chase), the maximum in brackets; `step=` is the Jolt world's own step,
which on the GPU arm has neither the soft body nor the eleven kinematic
hulls in it:

| run (`-clothSolver gpu` unless Jolt) | gpu= | wait= | feed= | read= | bind= | step= | speed<= | onClamp |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Jolt, idle | — | — | — | 596 us | 467 us | 3410 us | 0.50 m/s | — |
| GPU, idle, 16 substeps (27 on the Mac), 2 gathers | 4.67 ms (6.70) | 4799 us (6860) | 75 us | 6093 us | 499 us | 245 us | 1.48 | 1 % |
| Jolt, chase | — | — | — | 600 us | 473 us | 3487 us | 5.19 | — |
| GPU, chase | 4.81 ms (8.68) | 4875 us (8768) | 76 us | 5699 us | 504 us | 263 us | 2.78 | 1 % |
| GPU, chase, `-throwBall 8 -resetEvery 12` | 5.88 ms (8.77) | 5928 us (8883) | 74 us | 6557 us | 484 us | 214 us | 4.04 | 2 % |
| GPU, idle, `-clothSubsteps 8` (14 on the Mac) | 2.28 ms (4.17) | 2426 us (4299) | 57 us | 3010 us | 467 us | 210 us | 0.65 | 2 % |
| GPU, idle, `-clothSubsteps 12` (21) | 3.69 ms (5.76) | 4013 us (5916) | 66 us | 4639 us | 475 us | 236 us | 0.41 | 1 % |
| GPU, idle, `-clothSubsteps 24` (the cap, 32) | 6.81 ms (7.46) | 7138 us (7850) | 79 us | 7734 us | 482 us | 242 us | 0.96 | 1 % |
| GPU, idle, `-clothGPUIterations 1` (55 dispatches) | 3.96 ms (5.68) | 4122 us (5870) | 74 us | 5342 us | 523 us | 178 us | 0.92 | 1 % |
| GPU, idle, `-clothAveragedJacobi on -clothRelaxation 1.5` | 5.58 ms (8.76) | 6083 us (8938) | 82 us | 6748 us | 496 us | 238 us | 1.18 | 2 % |
| GPU, idle, `-clothGPUDamping 1` | 4.73 ms (7.45) | 4943 us (7578) | 72 us | 6185 us | 487 us | 259 us | 0.63 | 1 % |
| GPU, idle, `-clothHullFriction 0.2` | 5.67 ms (8.65) | 5828 us (8803) | 74 us | 6466 us | 482 us | 181 us | 0.87 | 1 % |
| GPU, idle, `-clothGPUWait off` (`lag=1f`) | 6.30 ms (8.24) | 0 | 92 us | 586 us | 470 us | 240 us | 0.87 | 1 % |
| GPU, idle, `-clothColliders off` (no hulls) | 2.40 ms (3.65) | 2536 us (4142) | 72 us | 3152 us | 462 us | 233 us | 0.46 | 1 % |

No run printed a runaway, a warning or an error, the override writes
counted once per awake frame in every run (816-819 in the idle, 1,706 in
the chase, 1,388 with the eight balls and the resets' thirteen hard
skins), and the chase with the eight balls topped out at 4.04 m/s, the
cap. What the table says, and what it does not. The feed — the 27 x 13
slerps, the 28 x 11 hull frames, the 26 KB of uploads and the encode of
82 dispatches — is 57-92 us, inside the design's 60-100 us; the read-back
with the wait taken out of it (`-clothGPUWait off`, 586 us) is the Jolt
arm's 596-600 us to the microsecond, since it is the same shell
evaluation and override write; and the Jolt world's step falls from
3.4-3.5 ms to 0.18-0.26 ms when the soft body and the hulls leave it. But
the GPU's own time is the design's estimate several times over: 4.7 ms
median at 27 substeps where section 8 budgeted about 1.0 ms for the Mac's
27, and 2.5 ms at exactly 16 substeps in the debug test above, against
gate 1's 1.0 ms on the headset; and because the Mac's game step is
0.2 ms, the wait covers nearly the whole of it, so the frame thread pays
`gpu=` plus 0.1-0.4 ms where the Jolt arm paid its 3.4 ms step — the GPU
arm costs the Mac's frame more wall time than Jolt did, not less. The
levers measured: the eleven hulls are half of it (2.40 ms without them,
even after the box cull and the plane loop's early out took them from the
2.7-7.0 ms of the solver's first day), the second gather 0.7 ms (3.96 at
one), and the substeps nearly linearly (2.28 / 3.69 / 4.67 / 6.81 at 14 /
21 / 27 / 32), so 8 substeps with two gathers — which the residual test
holds to the design's 2 % / 6 % gate — is the cheapest frame that passes
a test today. The figures swing two to one from frame to frame at the
same substep count (3.0 to 6.7 ms inside one idle run), consistent with a
GPU that clocks down between 5 ms bursts, and the wait-off run's `gpu=`
reading higher than the waited one's (6.30 against 4.67) says the same:
the headset's figures at 16 substeps, where the display's 10 ms leaves
the GPU no idle, are the gate's, and nothing here predicts them. The
averaged Jacobi, the damping at 1 and the hull friction at 0.2 cost
nothing measurable beyond the noise; what they do to the look is the
headset's to judge. Left for gate 1, in the order the design names them:
the hull plane sets (the design's 24-point hulls or a 3-degree coplanar
merge would roughly halve the 832 planes; a tighter cull than the box is
the other half), the choice between one gather at 16 substeps (3.38 %
p99 residual, 33 dispatches) and two at 8 (3.84 %, 25 dispatches), and
`-clothGPUWait off` re-gated first if the headset's cost fails on the
wait, as section 7 says.

Phase 2 of the design, the quality phase, landed on 2026-11-04. The
owner's headset read of phase 1 at the 3,995 proxy had come back as
expected — no much difference, the same issues on Jolt and on the GPU —
since phase 1 pinned the GPU arm to Jolt's figures on Jolt's proxy, and a
proxy whose median edge is 17.5 mm cannot show a fold under 8 cm whatever
solves it. So the prep cooks a second shirt proxy, `refine_proxy`, from
the same sewn outer layer the 4k one is collapsed from: the existing
collapse run down to 10,000 vertices at a 3 mm minimum edge as the clean
(the design's drain of the sub-3 mm edges alone left four valence-stuck
5-degree slivers, which the split quartered and the final collapse could
not finish — 8.2 degrees, a 3.7 mm edge, two islands), every edge cut once
with grid fill and triangulated (39,779 vertices and 79,108 triangles, no
zero-area face, no non-manifold edge), and the collapse again to 16,000 at
a 4.5 mm minimum, an 18 mm maximum and 10 degrees, 8.9 s of a 44.6 s cook.
One thing was added to the collapse's stuck-edge stage, which the 4k proxy
never reaches: at the rolled cuffs' creases five valence-3 caps over hollow
three-cycles held a 2.9 mm edge, every base edge refused by the link
condition and the apex's own collapses by the feature rule, and the apex
is now collapsed onto its nearest neighbour (the 4k garments are byte for
byte what they were, which is the proof the 4k never gets there). The
result is 15,979 particles and 31,681 triangles in one piece with the
shirt's four openings — edges 4.5 / 5.8 / 8.8 / 12.8 / 29.1 mm at the
minimum, the tenth percentile, the median, the ninetieth and the maximum
(the 4k's 8.5 / 11.5 / 17.5 / 25.6 / 39.1), the smallest angle 10.1
degrees, 281 boundary edges where the 4k has 142, as a halved spacing
gives; the design's 29,783 triangles at 15,994 vertices cannot hold on a
four-loop surface, where Euler wants 2V + 4 - B — 1,848 pins (11.6 %: the
collar 877, the cuffs 971), 588 body-facing (3.7 %, the 4k's share), the
slack schedule unchanged in metres and its bands 3.5 to 4.5 times the 4k's
counts (collar 877, cuffs 971, wrist 271, placket 329, yoke 1,057, sleeves
2,390, armhole 4,185, chest 1,995, back 2,173, hem 1,731), the body's
weights transferred as before (one to four influences on 3,026 / 4,796 /
3,913 / 4,244 particles) and the push-off leaving the nearest point 2.00 mm
off the body. The same 29,402-vertex shell is bound to it, identical rigid
islands and button patches, and tighter, as the design predicted: the
offsets' median 0.88 mm and maximum 10.1 mm (0.96 and 20.3 on the 4k),
5,722 shell vertices within 0.1 mm of a proxy point, 39 hanging more than
2 mm below their triangle instead of 122. The skin hulls are fitted against
BOTH proxies now, so one set serves the A/B, and six of the eleven moved
against the 2026-11-03 cook's points (the first review measured them; the
cook's own log had counted three): the 16k collar sat 1.1 mm inside the
neck hull the 4k alone had allowed (the fit's log says 7.2 mm for its
samples, the 4k's own 5.3), so the neck went from 35 to 28 points,
receding up to 14.7 mm and growing 5.4 mm elsewhere; the 16k sleeve sat
1.25 mm off the left upper arm's hull, under the 3.5 mm margin, so three
of its 35 points moved 3.5 mm and the hull receded 3.4; the right arm's
iterative fits re-ran to 38 and 32 points on the upper arm and the forearm
(37 and 34), the upper arm's new hull standing up to 10.9 mm OUTSIDE its
old one somewhere, since a nearest-vertex push fit is path-dependent and a
different sample set re-pushes different vertices, the forearm's 7.0 mm
inside; the left forearm's four points moved 0.13 mm and one of the left
clavicle's under a micrometre; the pelvis, the three spine links and the
right clavicle are the points they were — 438 points in all, 816 planes
where the design and the phase-1 tests counted 832, every point inside at
1e-7, both proxies 3.5 mm or more off every hull, the largest skin
protrusion 8.3 mm at the right upper arm (10.1 at the neck before). The
4k file's shirt and trousers did not change; its colliders did, and of
the 36 figure lines the four Jolt fit tests print, the 19 that do not
meet a hull (every skin-only line among them) are byte for byte what
they were and the 17 on the hull models moved with the hulls by under a
tenth of a millimetre and a particle in the counts (the hang's sag 9.4 to
9.5 mm and its back-stop 1.14 to 1.15, the sway's excess 0.21 to 0.30 mm,
the swing's 14 inside to 13 and its 14.2 mm to 14.3, the arms-forward
19.8 mm to 19.7), which is the one thing this phase did not keep byte for
byte on the Jolt arm. Both sidecars come out of one cook:
`Zombie.cloth.json` at 2.95 MB and `Zombie.cloth16k.json` at 4.99 MB (the
design projected 4.19; the prep's 8 MB warning stands, so the JSON stays),
the second carrying the phase-2 keys the runtime does not read yet but the
asset tests pin against what the kit derives at attach — `restNormal`
(unit within 1e-7, the kit's area-weighted normal to 0.0 degrees),
`region` with a `regions` table from the schedule's bands, `planes` per
collider as the runtime computes them (nested [nx, ny, nz, d], inside
where n.p + d < 0, the joint's bind frame) and `constraintCounts` under
the kit's nine names (47,662 edges, 281 boundary, 47,381 cross pairs,
5,222 pin-pin edges and 4,957 pin-pin pairs dropped, 42,440 stretch and
42,424 bend constraints, 169,728 CSR entries, 22 at most and 10.62 on
average per particle; the trousers carry the same keys). The design's
single `pinPinDropped` is the sum, 10,179, and is not written: the code's
names win. `ZombieCloth16kAssetTests` (10 tests, skipped when the file is
not bundled) holds the file to those figures — the histogram within a
quarter, the 4k file's placement bounds, the binding's rebuild within
0.0036 mm, the planes equal to the kit's, the counts key for key.

The second file is selected, never swapped in: `-clothSidecar
Zombie.cloth16k` (the name with or without `.json`), the headset's *Proxy*
picker beside *Solver* (4k / 16k, disabled with the cloth off or on Jolt)
and the Mac's *Proxy* dropdown, each change taking the shirt off and
putting it back on the other cook, both files kept loaded once read. It is
the GPU arm's knob alone: `ZombieChaseGame` loads the 4k for the Jolt arm
whatever is named, with one printed line, `ZombieCloth` refuses a Jolt
garment over `joltParticleLimit` (8,000 particles — the case of a GPU pick
that fell back to Jolt with the 16k asset in hand) with one line rather
than solve a 13.6 ms step, and a name the bundle lacks falls back to the
4k with a line, so the picker is safe on a checkout before the cook. The
report prints `proxy=4k|16k` (thousands of particles, rounded) so a
headset line says which cook it reads, and `-clothGPUShell on|off` (on) is
the shell's switch, next.

The drawn shell is evaluated on the GPU since the same day. The frame's
encoder ends with two more dispatches after the stats: `zcTriangleFrames`,
one thread per proxy triangle — the corners into mesh space as
`expandOverride` converted them for the CPU shell, the origin added first
and the matrix second, then e1 = ab / |ab|, n = ab x ac / |ab x ac|, t = n
x e1, and a collapsed triangle leaving the frame the buffer held, the
CPU's own rule — and `zcShell`, one thread per driven exported vertex:
pos = w.(a, b, c) + o.x e1 + o.y n + o.z t and normal = r.x e1 + r.y n +
r.z t, nothing re-normalised, as `RenderShell.evaluate` has it, into two
planar `float4` streams, the positions with w 1 and the normals with w 0,
which is what the engine's `deformOverride` consumes, so phase 3 can bind
them as they are. The ABI took the five reserved buffer indices for three
new structs (`ZCShellParams` 128 B, the mesh-from-world matrix with the
garment's origin and the counts; `ZCTriangleFrame` 48 B; `ZCShellBinding`
48 B, the triangle index travelling in `barycentric.w` as a float, exact
below 2^24), and the metallibs are 35 KB each. The Swift side hands the
solver a `ClothShellSetup` at the attach (the per-slot binding the CPU
shell holds, with the attach's world-to-mesh for the bind-pose frames,
which are prefilled on the cores), sets the frame's mesh-from-world at
`beginUpdate`, and in `readBack` copies the output into the override
arrays in place of `RenderShell.evaluate` — the design's 100-150 us copy
against the shell's 503 us median on the cores — re-expressing every slot
through the change of frame when the matrix the read wants is not the one
the frame was encoded with, because the engine's `translateTo` syncs the
entity's world transform eagerly and the controller corrects the body
inside the game step, between the encode and the read. A frame with
nothing valid to copy — the hard skin after a runaway, a frame before any
encode, the knob off — runs the CPU shell and counts a fallback
(`cpuShellFallbacks` beside `gpuShellFrames`), and the report's
`shell=gpu|cpu` says which ran. The rigid islands need no branch of their
own: the prep binds every vertex of a button to one triangle, so the
formula carries the island whole. One thing found on the way: under
Metal's default fast math the standard library's `float4x4 * float4`
contracted the three corners' products into fused multiply-adds
differently after inlining, so two corners at the SAME position came out
1e-8 m apart under a scaled matrix and an exactly collapsed triangle got a
frame of rounding noise instead of its kept one; the conversion sums the
four columns by hand under `#pragma clang fp reassociate(off)
contract(off)`, which the operator's own inlined flags would not honour.
`testTheGPUShellMatchesTheCPUShell` holds the two within 4.9e-7 m and
0.005 degrees over the 29,402 slots at the bind pose and 101 frames into
the sway (the design's bounds 1e-5 m and 0.05 degrees; the angle is taken
in double precision, since a single-precision acos cannot resolve under
0.03 degrees near 1), the override written the same, 51 dispatches a frame
(49 and the shell's two), and `-clothGPUShell off` back on the cores.

The drape figure of the design's section 6 is exact now
(`ClothMetrics.Drape`), so the owner's read of the folds has a number
beside it: over the hem band's interior edges (slack 0.12, both ends in
the band) the signed dihedral per edge, positive where the fold is convex
outward, read off the geometry; the design's per-edge mean in degrees,
which falls with the edge length for the same shape and so cannot compare
two proxies; a mean absolute curvature in 1/m — the sum of |dihedral| x
edge length over the band's area, 1 / r on a cylinder of radius r at any
resolution — which can; and the fold alternations around the hem loop, the
sign changes of the signed fold at each loop vertex, resampled along the
loop's arc at 5 mm and smoothed over a 1 cm each-way window (a 3-5 cm
fold reads through a 2 cm window, a particle's own jitter does not), per
metre of hem. It is taken at the hang's 200th frame (the cloth is asleep
on the still body from frame 177 on either solver) and at the sway's last,
printed by both solvers' hang and sway rows on either proxy beside the
same shirt's figure at the sidecar's bind pose and as the change from it,
and pinned once the gate-2 verdict is in. The rest figure and the
resample are the first review's (2026-11-04): the day's first count read
"the alternations double at 16k, a fold every 4.4 cm" — 12 against 26 —
and 21 of the 16k's 22.9 per metre were the artist's own hem folds, there
before either solver ran, which the finer loop resolves and the coarser
cannot, read through a window that smoothed the 4k loop vertex to vertex
and the 16k's over three vertices. With the resample the two rest hems
read as one: 4k 15.53 1/m and 6 alternations on 1.162 m (5.2 per metre),
16k 16.61 1/m and 6 on 1.125 m (5.3 per metre). After the hang on the
GPU, the M4 Max: the 4k hem band (430 particles, 1,097 edges, 1,111 cm^2)
reads 4.99 degrees per edge, 16.45 1/m and 5.2 per metre — +0.92 1/m
(+6 %) and not one new fold — and the 16k band (1,731 particles, 4,816
edges, 1,158 cm^2) 3.86 degrees, 27.09 1/m and 8.8 per metre, +10.48 1/m
(+63 %) and +3.5 per metre: the hang folds the finer hem and leaves the
coarser as the artist drew it, which is the figure the cook is for, with
the caveat under the fit paragraph that the finer proxy's curvature
carries its unconverged stretch. After the sway +0.67 1/m and +0 at 4k on
the GPU, +9.26 1/m (+56 %) and +5.2 per metre at 16k.
The fit scenarios run at 16k on the GPU with bounds of their own
(`gpuBounds16k`, measured the day the cook landed and pinned with the 4k
rows' margins; the swing alone is six minutes of the posed-skin metric
over 15,979 particles): the finer shirt hangs lower — the chest and the
back sag 22.9 mm (9.4 at 4k), the hem band's mean 16.7 mm over the yoke's
2.8 (7.8 over 1.3) — and the first review read that as the weight, since
`particleMass` is 50 mg a particle whatever the count and the 16k shirt
is 0.8 kg to the 4k's 0.2; it is not, to this solver. Neither kernel
accumulates a Lagrange multiplier: a pass gives back `w / (w_i + w_j +
compliance / dt^2)` of a constraint's violation and nothing else, gravity
is an acceleration and the clamps and hulls are projections, so the mass
and the compliances enter only as their product, and at 50 mg the finer
proxy has the 4k's per-pass fractions exactly (61 % of a stretch
violation, 5 % of a bend). What it does not have is the 4k's convergence:
a mesh twice as fine is half as converged across the sheet after the same
32 passes, and the stretch residual the gate reads at 4k as 0.40 % mean /
2.09 % p99 (`testStretchResidualAtRest`) reads at 16k 1.37 % / 5.99 % at
the default two gathers and 0.73 % / 3.50 % at the parser's cap of four
(`testStretchResidualAtRestAt16k`, pinned to those with a quarter of
margin, the gate's 1 % / 3 % not met at either) — that unconverged stretch
is the extra sag. The per-area mass the review proposed (0.2025 kg/m^2,
12.6 mg a particle at 16k) was built and measured the same day: it is a
shirt four times stiffer per pass (86 % of a stretch violation, 17 % of a
bend), it read 1.03 % / 8.07 % with a worst edge at 28 % and sagged 15.6
mm, and in the arms-forward idle it bridged the armpit — the armhole band
100 mm behind its skinned position and 49.7 mm inside the posed skin
against 13.2 and 4.4 — so it was withdrawn, the mass left per particle
with the equivalence written on it, and the 16k hang's sag and hem floors
set to the 4k row's 5 mm (a shirt that hangs at all) rather than the 18
and 10 mm first pinned on the measurement. The 16k runs with the clamp
and the back-stop as
exact as before (nothing past its slack by more than 2e-6 m, the pins
within 3.2e-6 m, 1.67 mm behind the skin at the worst, 1.73 mm off the
surface under the shirt, nothing inside the posed skin after the hang or
the sway; at rest 14,601 of its particles read against the skin and the
nearest is 2.09 mm outside), the arms-forward armhole band's farthest
particle ON its 150 mm ball (150.004 mm, where the 4k's rested 143.4
inside it), 30 particles inside the posed skin with the hulls and 71
without (12 and 18 at 4k: four times the particles read about twice the
count, the armpit and armhole band again, where the convex hulls sit
inside the concave skin, phase 4's gap capsules), the swing at most 9
inside at a read frame and 5.2 mm deep (none and 1.1 at 4k), the sleeves
50 mm off the skin, and Jolt refusing the file outright. The cost in the
debug build on the M4 Max over 300 frames of the sway at 51 dispatches:
4k with the GPU shell, `gpu=` 1.73 ms median (5.43 max), the wait 2.09 ms,
the read-back 5.87 ms and the bind 2.57 ms (the copy, debug code); 16k,
2.30 ms median (5.38 max), 2.74, 10.85 and 3.60 ms — 2.99 ms on the 16k
attach's first frames, and 6.49 ms with the arms forward and every hull
in play (the sway on the world model 5.65, the hang 3.55), over the
design's 2.0 ms gate-2 line on this GPU before any headset figure exists.
The release figures are the sweep's:

The phase-2 Mac sweep, 2026-11-04, the release host as the phase-1 sweep
ran it (`swift build -c release --product CoolZombie`, the M4 Max at 60 Hz,
so 16 asked substeps are 27 encoded and 12 are 21, two gathers, 35 s runs,
the once-a-second `-debugLog` line, the idle inspect and the chase with
eight balls and a reset every 12 s, medians over the awake in-range lines
with the maximum in brackets; `bind=` is the shell's evaluation on the
cores or, with the GPU shell, the copy of the kernels' output; a `gulp`
process of another session held a fifth of a core throughout, which is
why every CPU figure here is a third over the phase-1 sweep's):

| run (`-clothSolver gpu` unless Jolt; `-clothSidecar Zombie.cloth16k` for 16k) | shell | gpu= | wait= | feed= | read= | bind= | step= | speed<= | onClamp |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Jolt, 4k, idle | cpu | — | — | — | 706 us | 610 us | 3294 us | 1.05 m/s | — |
| GPU, 4k, idle | gpu | 4.10 ms (8.43) | 4469 us (8855) | 203 us | 4668 us | 85 us | 331 us | 1.02 | 1 % |
| GPU, 4k, idle, `-clothGPUShell off` | cpu | 6.23 ms (8.25) | 6404 us (8370) | 157 us | 7197 us | 1133 us | 335 us | 1.16 | 1 % |
| GPU, 16k, idle, 16 substeps (27) | gpu | 6.81 ms (7.77) | 6958 us (7948) | 145 us | 7354 us | 97 us | 358 us | 1.30 | 1 % |
| GPU, 16k, idle, `-clothSubsteps 12` (21) | gpu | 5.93 ms (7.05) | 6677 us (7258) | 130 us | 7009 us | 105 us | 358 us | 1.64 | 1 % |
| GPU, 16k, idle, 16, `-clothGPUShell off` | cpu | 6.53 ms (8.08) | 6714 us (8283) | 157 us | 8869 us | 1640 us | 319 us | 1.21 | 1 % |
| GPU, 16k, idle, 12, `-clothGPUShell off` | cpu | 6.77 ms (7.17) | 6884 us (7305) | 92 us | 8435 us | 1487 us | 401 us | 1.49 | 1 % |
| GPU, 4k, chase, eight balls | gpu | 6.75 ms (8.01) | 6755 us (8457) | 162 us | 7012 us | 65 us | 444 us | 4.89 | 2 % |
| GPU, 16k, chase, 16 | gpu | 6.28 ms (8.12) | 6338 us (8188) | 158 us | 6765 us | 103 us | 420 us | 4.56 | 1 % |
| GPU, 16k, chase, 12 | gpu | 6.78 ms (8.32) | 7059 us (8713) | 132 us | 7325 us | 96 us | 358 us | 3.67 | 1 % |
| GPU, 16k, chase, 16, `-clothGPUShell off` | cpu | 6.75 ms (8.51) | 6817 us (8682) | 126 us | 8694 us | 1639 us | 356 us | 4.24 | 1 % |
| GPU, 16k, chase, 12, `-clothGPUShell off` | cpu | 5.89 ms (8.65) | 5972 us (8733) | 115 us | 7664 us | 1675 us | 372 us | 3.89 | 1 % |
| GPU, 16k, idle, 16 (27), after the reviews' fixes | gpu | 5.52 ms (7.69) | 5802 us (8127) | 76 us | 6020 us | 34 us | 306 us | 1.04 | 1 % |
| GPU, 16k, chase, 16, after the reviews' fixes | gpu | 6.06 ms (9.09) | 6132 us (9136) | 72 us | 6352 us | 21 us | 286 us | 4.39 | 1 % |

Not a runaway, not a warning and not an error line in any run, the
override written once per awake frame (817-819 in the idle, 1,342-1,439 in
the chase with its 13-15 resets' hard skins), the 16k proxy drawn through
the same shell with `proxy=16k shell=gpu` in every line of its runs, and
the Proxy dropdown reading its pick; the last two rows are the same idle
and chase run again after the reviews' fixes below, with the other
session's load gone (`feed=` 72-76 us against 145-158) and `bind=` the
copy alone (21-34 us: it had carried the previous-positions loop too).
What the table says: the GPU shell
takes the shell's CPU cost out of the frame — `bind=` falls from
1.1-1.7 ms on the cores to 65-105 us of copy, the design's 100-150 us, and
`read=` with it, 1.5 ms on the 16k idle — which is the whole of what phase
2 asked of the CPU. The GPU's own time on this Mac is 6-7 ms at the 27
substeps the 60 Hz frame asks for, 16k and 4k alike on the chase (6.28
against 6.75) and 6.81 against 4.10 on the idle, where the 4k's run caught
the GPU clocked up as the phase-1 sweep's did (4.67 then, 5.88 with the
balls); the Mac's 27 substeps and clock swings make it no measure of the
headset's 16, and the debug build's exact-16-substep figures above (2.30
ms median at 16k against 1.73 at 4k, 6.49 ms with every hull engaged)
are the nearer guide. Twelve substeps buy 0.9 ms on the idle and nothing
on the chase within the noise. The chase's `speed<=` is the read-back's
per-frame displacement over the frame, 4k and 16k alike a fifth over the
solver's 4 m/s cap (the phase-1 sweep read 4.04): the cap is on the
velocity carried into the next substep, not on where the slack clamp puts
a particle whose skinned target left faster at a knockdown.

The two reviews of phase 2 (2026-11-04) changed five more things. The
game picks the sidecar by the arm the shirt will really run on
(`ZombieChaseGame.clothSidecar(for:device:)`, a static the GPU suite
tests without a game): `ZombieCloth.gpuAvailable(device:configuration:)`
probes the GPU solver once per device — the five pipelines and a queue,
what `bind` builds — and a GPU pick on a device it cannot be built on (no
metallib for the platform, a stale one, no device at all) loads the 4k the
Jolt arm can take, with one line, where until then the pick went by the
configuration alone, the fallback came at the attach and
`joltParticleLimit` then refused the 16k outright: no shirt for a missing
metallib. `bind=` means again what the phase-1 figures measured — the
shell's evaluation and the override write on the CPU path, the copy alone
on the GPU path — the particles' conversion to mesh space having sat
under it for a day (part of the Jolt idle's 610 us above against phase
1's 467-503). With `-clothGPUWait off` the shell copy takes the frame
`readPositions` handed the cloth rather than a snapshot of its own, so the
override's shell cannot run a frame ahead of the positions the speed
sample and the runaway check read. The shell test has a third row, the
entity moved inside the frame by 5 cm and 0.1 rad between the cloth's
`beginUpdate` and its `readBack` as the controller's `translateTo` moves
it on most chase frames: the copy re-expresses the kernels' output
through the read's matrix, within 3.9e-7 m and 0.0046 degrees of the CPU
shell on the particles taken through the same matrix, and the output read
through the old matrix is that shell carried by the rigid change of frame
within 1e-5 m, which is the proof the re-expression ran. And the five
metallibs were rebuilt from the shader sources as they stand (the
committed ones pre-dated the header's last edit and, the compile being
deterministic, differed from a rebuild in their per-function hashes), the
doc comments' projected figures (29,783 triangles, 15,994 particles, 476
KB and 1.43 MB) replaced by the cook's (31,681, 15,979, 507 KB and 1.52
MB), and the prep's docstrings corrected to the six hulls that moved and
the collar band that shrank.

The suites on 2026-11-04 after everything above: `ZombieClothGPUTests` is
41 tests (the phase-1 30, the shell test with its three rows, the drape
on both proxies against their rest poses, the Jolt refusal, the sidecar
choice, the 16k rest read, the 16k stretch residual and five 16k rows),
`ZombieClothTests` 29, `ZombieClothAssetTests` 12,
`ZombieCloth16kAssetTests` 10, `ZombiePhysicsTests` 9, the whole kit
suite green in a debug build — `swift test --filter CoolZombieKitTests`,
157 tests, 41 minutes with the machine otherwise quiet (the GPU suite 16
of them with the 16k swing, the Jolt suite 24) — and the visionOS host built
for the device in Release (`xcodebuild ... -scheme
CoolZombieVisionOS-visionOS -configuration Release -destination
"generic/platform=visionOS"`). Left
for gate 2, the owner's quality verdict on the headset at 16k and 16
substeps (`Docs/GPUCloth.md` section 7): the drape figure pinned from the
verdict, `Configuration.solver`'s default flipped to `.gpu` with the
launch-argument test if it passes, the 2.0 ms `gpu=` line and the 0.6 ms
read-plus-bind on the device, and the 12,000 cook as the fallback the
owner settled on if the gate fails on cost rather than look, and phase 3's
engine PR once the GPU shirt is the shirt. On the cost the Mac's own
numbers say where the levers are, and it is not the proxy (the second
review of phase 2, 2026-11-04, from the arms-forward rows in the debug
build at exactly 16 substeps): with every hull engaged the 4k reads
`gpu=` 0.49 ms on the skin-only model and 3.65 ms with the eleven hulls,
the 16k 1.55 ms and 2.57-6.22 ms — the hull plane pass is 87 % of the 4k's
GPU time already and up to 4.7 ms of the 16k's — while on the sway the
cost per particle per substep FALLS from 27 ns at 4k to 9 ns at 16k, the
solve being dispatch-latency-bound at 4k and the finer proxy's marginal
particle about 3 ns a substep. So the 2.0 ms line is threatened by the
hull pass on either proxy: the first lever is that pass (a per-hull
bounding-sphere early-out in `zcSolve`, fewer planes per hull, the
24-point hulls or a coplanar merge of section 9), the second 12 substeps
(0.9 ms on the 16k idle, nothing on the chase within the noise), and only
then the 12,000 cook; and the headset run should print the arms-forward
idle beside the sway, since the sway alone leaves most hulls idle.

The package depends on the miolabs fork of the plugin at its
`feature/zombie_cloth` branch (the character controller, the ragdoll, the
environment boxes' layers, and the soft bodies skinned to a skeleton with
their one-way contact against ragdoll parts and the normals read-back)
until upstream takes it; then the dependency goes back to the plugin's own
URL. To work on the plugin and the demo together, `swift package edit
UntoldJoltPhysics --path ../../UntoldJoltPhysics-cloth` points the build
at a local checkout, and `swift package unedit UntoldJoltPhysics` returns
to the branch.

## visionOS (Apple Vision Pro)

`Examples/CoolZombieVisionOS` is a mixed-reality build: the zombie waits a
few meters in front of you in your real room; walk toward it and it comes
for you, stopping an arm's length away — around the furniture, and with
its hands on the wall when you stand behind one. The chase logic lives in
the `CoolZombieKit` library target (shared with the macOS demo); the app
feeds it the head pose from ARKit world tracking and the room from ARKit
plane detection and scene reconstruction.

Where it appears: 4 m ahead of your head when you enter the room, not of
the world origin — on the device the origin is wherever tracking last
started or was recentred, which the first captured room showed can be
against a wall with the room behind it. If a wall or furniture is closer
than that, the spawn pulls back to the last clear point, and if that
leaves it under 1.5 m away it goes sideways or behind you instead; the
zombie faces you either way. While it is still waiting, a room that
arrives after it was placed moves it to the corrected point. *Reset*
re-anchors to wherever you are now.

The room: every plane ARKit classifies becomes a box for the navigator
(`ZombieRoom`). Walls, doors and windows are thin boxes the height of the
plane; tables, seats and any other horizontal top between 15 cm and
1.9 m above the floor become boxes from the floor up to the top (the
zombie does not crawl under a table); floors, ceilings, slanted surfaces
and fragments under 40 cm are ignored. What has no plane — a sofa's arms,
a bed, a cabinet, a plant — comes from the scan: ARKit's scene
reconstruction mesh is rasterized, one mesh anchor at a time, into a
10 cm occupancy grid of everything between 15 cm and 1.9 m above the
floor; the cells within 30 cm of a wall's box or 15 cm of a top's box
belong to those (a wall's scan carries skirting, radiators and
curtains), the rest are clustered, clusters under six cells are noise,
and each remaining cluster becomes an oriented box (its smallest
enclosing rectangle, from the floor to its highest point), within half a
cell of the object's size. A wall the plane detection missed still
arrives this way, as a 1.9 m box along it. Once ARKit's room tracking knows which room you are
in, only that room's planes and meshes count, so what shows through an
open door stays out. The set is re-read twice a second while ARKit
refines its planes and meshes, so the boxes firm up over the first
minute in a new room — walk around it once. The control window's *Show
the room's boxes* draws them translucent to check the alignment; *Save
the room* writes the layout to the app's Documents folder (visible in
the Files app, under the app's name), from where it replays in the Mac
sandbox with `swift run CoolZombie -layoutFile <file.json>`.

Open `Examples/CoolZombieVisionOS/CoolZombieVisionOS.xcodeproj` and run the
`CoolZombieVisionOS-visionOS` scheme. The control window has *Provoke it*,
*Reset*, a *Clips* picker (the clip set, switchable while it runs) and an
inspection mode picker — *Chase* is the game; *Roam* walks
a circle around the spawn point at a walk/jog/run speed, *Idle* stands in
the idle clip, *Freeze* pauses the animation on its current pose, *T-pose*
holds the model's bind pose (an A-pose) with no clip, no foot IK and no
ragdoll pose, the asset exactly as exported — none of
which target you, so you can walk around the zombie and inspect it. On the
device the zombie stands on the floor plane ARKit detects (the world
origin's own floor estimate can be a centimetre or two off; the footnote
shows the height in use and whether it was detected or assumed, next to
the floor height the scene mesh gives and the trim in force; *Show the
detected floor* draws a 60 cm pad under the zombie at that height with a
post of 1 cm green and white bands beside it, and the *Floor trim*
stepper nudges the height by 5 mm, so feet that float or sink can be
blamed on the estimate, the asset or the clips by looking: the pad and
the bands, the T-pose, the idle. The plane detector's bias is a property
of each floor, a centimetre either way between rooms, so the height is
calibrated at run time: once the scene mesh has enough floor classified
around the zombie, the median height of those vertices is used instead of
the plane, as long as the two agree within 5 cm, and the footnote names
which one is in use; the trim is zero by default and not remembered). The
footnote also
prints the zombie's world position: a body that drifts on screen while
those numbers hold is the tracking correcting its world under it, not the
game. A standing zombie is never pushed by the room's boxes (they are
rebuilt twice a second as ARKit refines its meshes, and a jittering edge
used to shove it), and it ignores floor refinements under 1.5 cm and
follows larger ones at 2 cm/s rather than hopping or gliding with every
millimetre ARKit adjusts; the Xcode console reports any move of
a standing body with what changed in that frame. The zombie appears
about 4 m in front of wherever you look the moment it is ready, and
*Reset* brings it back in front of you; when the way ahead is blocked
within 1.5 m it takes the longest clear line to the side or behind. In the
simulator no planes are detected: the floor is placed 1 m below the
head and the bundled `sample` room (four walls, a sofa between the spawn
point and you, a table and an armchair) stands in for detection, drawn
by default so it can be seen. `-room <name|path>` loads a saved room on
either platform (`-room none` turns the sample off); launch arguments
`-autoOpenSpace`, `-autoProvoke`, `-autoRoam walk|jog|run` and
`-autoMode idle|freeze|tpose` open the immersive space and start a mode
(and `-inputWait always|never|auto`, `-framePacing full|half|halfWhenLate`
set the engine's pose-timing knobs at launch; the window's *Pose*,
*Pacing* and *AA* pickers switch the same two and the anti-aliasing live,
for telling the presentation from the tracking when the body sways against
the room while its coordinates hold; `-cloth off|skin|ragdoll`,
`-clothSolver jolt|gpu`, `-clothIterations <n>` and `-clothSubsteps <n>`
set the shirt's simulation at launch and the *Cloth*, *Solver*, *Cloth
iterations* and *GPU substeps* pickers switch it live, the footnote's
cloth and frame lines side by side for each — see Physics)
without gaze-and-pinch input, for automated runs:

```bash
xcrun simctl launch <udid> com.miolabs.CoolZombieVisionOS -autoOpenSpace -autoProvoke
```
