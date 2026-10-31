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
  `-cloth off|skin|world|ragdoll` and `-clothIterations <n>` pick the shirt's
  simulation and `-collisionSteps <n>` / `-workerThreads <n>` the Jolt
  world's sub-steps and threads (see Physics; the Cloth dropdown switches
  the shirt's model live), `-resetEvery <seconds>` resets the zombie
  every so often (a fallen one stands up).

## Assets

The demo is written so assets swap without code changes: drop in new
`.untold` clips, list them in `ZombieResources.chaseClips`, and the motion
database rebuilds from whatever is loaded. The layout is:

```
Sources/CoolZombieKit/Resources/
  Models/Zombie/Zombie.untold                 the zombie: skeleton + one skinned mesh
  Models/Zombie/Zombie.cloth.json             the cloth sidecar: shirt and trousers proxies, the shirt shell's binding
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
within 6 cm of the cuff loops, 128 — are hard skinned (0), so the folded
collar follows the body as one thick piece and the rolled cuffs ride the
forearm's animation without fighting the hand parts' tracking error; the
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
(85), where the buttons hold the panels to the chest. Distances along the
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
and a cloth particle's collision radius (1 cm) inside the shirt and the
trousers proxies, their surfaces sampled 28 points a triangle — Jolt holds
a particle that far off a capsule, so a capsule any closer pushes the
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
the triangles' stretch, shear and bend constraints make it cloth. Their
compliances read against the particle's 50 mg: Jolt divides a violation
by the two particles' inverse masses (20,000 1/kg each) plus the
compliance over the solver step squared, so at the 1.4 ms solver step
anything below about 1e-3 m/N is rigid — the first cook's 5e-4 bend made
the shirt a stiff shell that folded in sharp plastic creases and, solved
in two passes, jittered. The edges stay rigid (cloth's weight stretches it
microns), the shear is 0.1 m/N and the bends 0.5 (a pass gives back a
little under half of a shear violation and an eighth of a bend one, so the
shirt drapes in folds broader than the proxy's triangles), and the solver
runs four iterations — Jolt's small steps, a constraint pass each on a
quarter of the sub-step — where two left every constraint fighting the
next. The frame runs: the
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
until the player returns. The report prints `jolt=on|off` beside the
cloth's own state, `joltWakes=` the times Jolt woke a resting body on its
own (a ball; the parts must never show there, and the tests hold it at
zero over the powered ragdoll) and `joints<=` the farthest a joint moved
in the last frame: the idle clip moves its fastest joint about a
millimetre a frame (half that at 100 Hz), so the joint half of the sleep
rule passes most frames; it is the particles, moving with the skin at
0.2–0.5 m/s, that keep the cloth awake during it (see the measurements
below).
The cloth is on a collision layer of its own: the balls dent it, the floor
stops it, the controller walks through it (the pair is closed both ways),
the room's boxes meet it only while the body is down, like the ragdoll —
and the ragdoll's parts do not meet it. The body the shirt collides with
is its skin, through the back-stop: the proxy carries the body's own
weights (below), so its reference is the skin in every pose. The capsules
are a ragdoll's, not a body's — fitted to this body, the pelvis still
stands 47 mm outside the skin, the lower spine 67 mm, the yoke 28 mm
(measured on the rig, 2026-10-31) — and a shirt that met them was pushed
out into a ridge at the waist and squeezed between them and the skin
stop: the fold line and much of the jitter the headset showed. `-cloth
off|skin|world|ragdoll` picks the model on both hosts — off leaves the
shirt body-skinned, `skin` hangs it on its skin alone on a layer nothing
meets (what every collision costs and adds), `world` (the default)
collides as above, `ragdoll` keeps the parts as colliders too (one way,
on a layer of its own) for the A/B — and `-clothIterations <n>` sets the
solver's iterations: four by default (the fit tests run at four), one to
six for the A/B. The same choices switch live: the Mac's Cloth dropdown,
and on the headset the control window's *Cloth* (Off / Skin only / World
/ Ragdoll too) and *Cloth iterations* (1, 2, 3, 4 or 6) pickers, each
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
the room while its coordinates hold; `-cloth off|skin|ragdoll` and
`-clothIterations <n>` set the shirt's simulation at launch and the
*Cloth* and *Cloth quality* pickers switch it live, the footnote's cloth
and frame lines side by side for each — see Physics)
without gaze-and-pinch input, for automated runs:

```bash
xcrun simctl launch <udid> com.miolabs.CoolZombieVisionOS -autoOpenSpace -autoProvoke
```
