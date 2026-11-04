"""Turn the artist's zombie .blend (Zombie_new_cloth.blend) into the game rig, cook it with
the untold exporter and write the cloth sidecar the simulation binds to.

The source file is a review file: nine scenes of garment variants, lights, cameras, cloth
simulation proxies and render shells. Two scenes matter. "Scene" holds the rig the demo
has always used (armature + skinned body + eyes, plus the OLD fused shirt-and-trousers
mesh this script no longer takes). "Intact Blood and Dirt Review" holds the new garments:
a shirt (`ZOMBIE_CLOTH.002`, a closed two-layer shell about 1.15 mm thick plus seven
buttons and fourteen bits of thread), trousers (`ZOMBIE_CLOTH.001`, two panels whose
side seams were never sewn, plus five belt loops) and the shoes with the belt loops of the
old outfit (`ZOMBIE_CLOTH.004`). Both garments are skinned to a copy of the armature
(`Zombie_Armature.001`) that adds one bone, `Hips.001`, same head and direction as
`Hips`; the script checks the copy's rest pose against the original and folds that bone
back into `Hips`. This script keeps that set only and makes it the rig the demo and its
clip pipeline expect, the UE4-mannequin convention that `ZombieAA` had:

  * bones renamed to `root/pelvis/spine_01..03/neck_01/head`, `clavicle_l/upperarm_l/
    lowerarm_l/hand_l`, `thigh_l/calf_l/foot_l/ball_l` (+ fingers) — sides by POSITION:
    the artist's `_R` bones sit on +X, which is the character's LEFT (it faces -Y);
  * the two neck bones merged into one `neck_01` (weights summed), `Hips` made a deform
    bone, a `root` bone added at the origin for root motion;
  * the whole set scaled from 0.76 m to HEIGHT metres and the scale applied;
  * the shoes re-skinned with the body's weights (nearest skin face) and freed of every
    hand and finger weight, as the fused clothes were; the garments keep the artist's
    weights, cleaned: `Hips.001` folded into `Hips`, the non-bone groups (skin, body,
    hair, Group, GROW) dropped, hand weights removed, bones farther than REACH pruned,
    four influences at most, renormalised, and the shirt's arm weights taken off its
    hips (within HIP_ARM_FREE of the pelvis, tapered over HIP_ARM_TAPER beyond) — the
    same weights go into the sidecar, so what the simulation pins is exactly what the
    skin draws;
  * the garments turned into SIMULATION PROXIES: the trousers' two panels sewn at the side
    seams (merge by distance on the boundary vertices only), every vertex inside or within
    2 mm of the body pushed out to 2 mm, then decimated to about 3,000 vertices; the shirt
    cut to its OUTER layer (a face is outer when its normal points away from the nearest
    body point; the hem strip, which the artist butted against the shell's bottom edge,
    is sewn back on where the rim between them cut it off), buttons and bits dropped,
    its buttoned front sewn (the panels overlap by
    14 mm at the placket, the buttons sit in the overlap: the hidden panel's overlap is
    trimmed and the two edges are zipped together, up to the collar's notch), decimated to
    about 4,000. The decimation is a shortest-edge-first collapse that never moves a
    boundary or UV-seam vertex off its line, never makes an edge shorter than 8.5 mm or
    longer than 39 mm, never makes a sliver, and keeps the UVs; after it every vertex,
    edge midpoint and face centre of both proxies is pushed to 2 mm off the body (a
    40 mm chord over a thigh sags into the skin). The trousers proxy is what the game
    draws for now; the shirt proxy only simulates. The shirt's weights are graded across
    every seam between bones' regions (the artist's jump from the upper arm to the spine
    over a single edge at the armhole, and the like at the waist and the elbow: the
    vertices within 6 cm of a seam are blurred over about 5 cm);
  * the artist's shirt SHELL (`Shirt_Render`: both layers, the fold, the seven buttons and
    the fourteen bits, the floating buttons seated on the fabric) is the shirt the game
    draws: it takes the proxy's weights (the BODY's, interpolated from the nearest skin
    face so the particles' reference is the skin itself in every pose, then capped and
    graded; the shell samples them from the nearest proxy face, capped at four), so body-skinned — the
    cloth off, the player out of range — it sits where the simulation would put it at
    rest, and the sidecar carries its RENDER BINDING to the proxy (`render_binding`):
    per shell vertex the nearest proxy triangle at the bind pose, the barycentric
    coordinates of the closest point, and the vertex's rest offset in that triangle's
    frame, so the simulated triangles carry the shell rigidly (its normals the game
    reads off the exported mesh, one per exported copy, since the exporter splits a
    vertex on the artist's sharp edges, and carries in the same frame); a button or a
    bit binds whole to the one triangle nearest its centre and stays rigid, and the
    fabric within BUTTON_PATCH (10 mm) of a button's centre binds to the button's
    triangle as well — the button, its two bits of thread and the fabric they sit on
    one rigid patch, since bound each to its own nearest triangle they interpenetrated
    on the headset (2026-10-31). The proxy
    itself is kept in the rig file as `Shirt_Proxy`, hidden and not exported: it lives
    in the sidecar only;
  * a SECOND shirt proxy of about 16,000 particles (`refine_proxy`, 2026-11-04), for the
    GPU solver of Docs/GPUCloth.md: three headset rounds read the 3,995-particle shirt
    as paper, and at its 17.5 mm median edge the smallest fold it can show is about
    five edges long, 8.5 cm, where a shirt's folds read at 3-5 cm; the drawn shell's
    own median edge is 8.25 mm, so 16,000 particles (8.4 mm hexagonal spacing over the
    shirt's 0.99 m²) is where the proxy stops hiding folds the shell could draw, and
    finer buys nothing. It is cut from the same sewn outer layer, before the 4,000
    decimation: collapsed to 10,000 at a 3 mm minimum (the clean), every edge split at
    its midpoint, then collapsed to 16,000 with the limits 4.5 / 18 mm and 10 degrees
    (15,979 particles, 31,681 triangles, edges 4.5-29.1 mm with the median at 8.8), and
    run through the SAME
    pipeline as the 4k proxy — the body's weights, the hand weights off, four
    influences, the hips freed of arm weight, the slack schedule read off the artist's
    weights with the same bands in metres, the armhole seam, the outward winding, the
    2 mm push-off — and the shell bound to it with the same button patches and rigid
    islands. It is written as a second sidecar, `<NAME>.cloth16k.json`, beside the
    first (`ZombieCloth.Configuration.sidecar` picks it; the Jolt arm keeps the 4k,
    since at 16k its step is four times its 3.4 ms), so the two are a live A/B and the
    4k file's garments are cooked unchanged, byte for byte. The skin hulls stay their
    margin off BOTH proxies, one set for both files, so a hull moves in the 4k file
    too where the finer proxy comes nearer it than the 4k's chords did — six of the
    eleven on 2026-11-04, measured against the 2026-11-03 cook's points: the neck
    from 35 points to 28 (the 16k collar sat 1.1 mm inside the old hull; it receded
    up to 14.7 mm and grew 5.4 elsewhere, the nearest-vertex pushes being path
    dependent), the left upper arm three points by 3.5 mm (the 16k sleeve was 1.25
    mm off its old hull, under the margin), the right upper arm 37 to 38 points and
    up to 10.9 mm OUTSIDE its old hull somewhere, the right forearm 34 to 32 and 7 mm
    in, the left forearm four points by 0.13 mm, the left clavicle one point by under
    a micrometre; the pelvis, the three spine links and the right clavicle are the
    points they were. Both proxies clear every hull by the margin afterwards. The
    16k file also carries what the GPU solver otherwise derives at attach — the hulls'
    planes, a rest normal and a schedule region per particle, the constraint graph's
    counts — and is kept in the rig file as `Shirt_Proxy16k`, hidden, like the first;
  * the ragdoll's twenty capsules fitted to this body and logged in the rig's syntax
    (`fit_capsules`): inside the skin the part's bones move and a centimetre inside the
    shirt and the trousers proxies (CAPSULE_GARMENT_MARGIN: a cloth particle's collision
    radius when the capsules were the cloth's colliders, kept for the ragdoll A/B), for
    ZombieRagdollRig.swift's table, which ZombieRagdollRigTests holds to the export;
  * the cloth's SKIN COLLIDERS (`fit_skin_hulls`): for the pelvis, the three spine bones,
    the neck, the clavicles and the upper and lower arms — eleven — the convex hull of
    the skin whose heaviest bone is the collider's — the full body, before the skin
    under the trousers goes — each point first pulled inward by what a 20 degree bend
    of the other bones it carries weight for would move it (the hull is rigid, the skin
    is blended), voxel-downsampled to at most 48 points, inset 1 mm and pushed in
    wherever a face stands within a particle's radius of the resting shirt (the hollow
    of the armpit, which the upper arm's hull bridged 11 mm through the proxy), in the
    joint's bind frame, for the game to move with the joint as a kinematic hull on a
    layer only the cloth meets. The back-stop stands for the skin only where a particle sits near
    its target; with the arms raised the sleeves' particles sat up to 15 cm from theirs
    and sank into the arm in patches (headset, 2026-10-31), and the ragdoll's capsules,
    fitted inside the skin and a particle's radius under the garments, cannot stand for
    it;
  * the belt loops of the new trousers join the shoes as rigid skin: they ride the waist;
  * the texture sets baked into one 2x2 atlas of TEX_SIZE tiles: face, body and the old
    clothes (the shoes) take three tiles as before; the fourth tile holds the shirt and
    the trousers as two quarter tiles of TEX_SIZE/2 (box-downscaled from the artist's
    2048 and 4096 squares), the UVs moved into their tile or quarter. The artist's
    Metallic, Height and Emissive maps are not used (the engine material takes base
    colour, roughness and normal; the garments' metallic and emissive maps are empty);
  * the alpha-masked hair cards and the cornea shell dropped, the shape keys baked, the
    skin under the trousers and the shoes removed (one face ring kept under every edge;
    the skin under the shirt stays: the shell hangs off it, and the back-stop, a
    millimetre behind the skinned position, keeps the proxy off it), and body, eyes,
    shoes, belt loops, the shirt shell and the trousers
    proxy joined into one mesh with one material — the engine binds the animation per
    skinned node and the exporter splits per material;
  * a sidecar `<NAME>.cloth.json` beside the export, in ENGINE space (the exporter's
    scale and axes: engine (x, y, z) = Blender (x, z, -y)): per garment the particles,
    triangles (wound consistently, outward on the whole: the rolled cuffs and the inside
    of the collar face the body, and those particles are listed so the game can put their
    back-stop on the body side), joint paths, influences, the per-particle slack
    (`maxDistance`; the shirt's schedule is `shirt_slack`: the collar band and the cuffs
    pinned, the yoke 7 cm, the sleeves 11 cm, the armhole band 15 cm, the chest 9, the back
    10, the hem band 12, the buttoned front 5 mm; the trousers' waist pinned, their hems
    2 cm, the rest 3), the back-stop depth, the dominant joint, the bind-pose joint
    matrices and, for the shirt, the render binding with the shell's rest positions; the
    game binds the shell's vertices (the trousers' particles) to the exported vertices by
    position (the exporter splits vertices on UV seams, so one maps to several); beside
    the garments, the skin colliders (`colliders`: the joint's path, the shape `hull`
    and its points in the joint's bind frame, flat);
  * everything else deleted and orphan data purged.

Env: SRC (artist .blend), OUT_BLEND (prepped rig .blend, the BLEND for the retarget
tools), OUT_DIR (the Models folder; the exporter writes <OUT_DIR>/<NAME>/<NAME>.untold +
Textures/, and stages an HDR/ side folder that this script deletes; the sidecar goes
beside the .untold), NAME (default Zombie), HEIGHT (default 1.75), TEX_SIZE (default
2048).
Run headless (the exit-code flag makes an uncaught error fail the Blender process):
  /Applications/Blender.app/Contents/MacOS/Blender -b --python-exit-code 1 --python Tools/blender/prep_zombie.py
Requires the Untold Engine Blender add-on (untold_exporter) installed.
"""
import bpy, bmesh, os, json, hashlib, heapq, math, shutil, time, itertools
import numpy as np
from mathutils import Vector, Matrix
from mathutils.geometry import closest_point_on_tri
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree
from pathlib import Path

SRC = os.environ.get("SRC", os.path.expanduser("~/Downloads/Zombie_new_cloth/Zombie_new_cloth.blend"))
OUT_BLEND = os.environ.get("OUT_BLEND", os.path.expanduser("~/Projects/Untold/zombie_bd.blend"))
OUT_DIR = os.environ.get("OUT_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                                 "Sources", "CoolZombieKit", "Resources", "Models"))
NAME = os.environ.get("NAME", "Zombie")
HEIGHT = float(os.environ.get("HEIGHT", "1.75"))
TEX_SIZE = int(os.environ.get("TEX_SIZE", "2048"))

# Source object -> working name. The rig and the body come from the scene "Scene", the
# garments from "Intact Blood and Dirt Review" (object names are unique across scenes).
KEEP = {"Zombie_Armature": "Zombie", "ZOMBIE_BODY": "Body", "Plane": "Eyes",
        "ZOMBIE_CLOTH.002": "Shirt", "ZOMBIE_CLOTH.001": "Trousers", "ZOMBIE_CLOTH.004": "Shoes"}
# The garments' own armature: checked against the rig, then dropped.
GARMENT_ARMATURE = "Zombie_Armature.001"
GARMENTS = ("Shirt", "Trousers")
# The artist's vertex groups that are not bones (cloth panel masks): dropped from the garments.
NON_BONE_GROUPS = {"skin", "body", "hair", "Group", "GROW"}

# Artist bone -> mannequin bone. Suffix handled separately: artist `_R` = +X = character's left.
RENAME = {
    "Hips": "pelvis", "Spine_down": "spine_01", "Spine_mid": "spine_02", "Spine_top": "spine_03",
    "Neck_down": "neck_01", "Head": "head",
    "clavicle": "clavicle", "Arm": "upperarm", "Forearm": "lowerarm", "Hand": "hand",
    "Leg_Up": "thigh", "Leg_Low": "calf", "Feet": "foot", "feet_finger": "ball",
    "Finger_Index_1": "index_01", "Finger_Index_2": "index_02", "Finger_Index_3": "index_03",
    "Finger_Middle_1": "middle_01", "Finger_Middle_2": "middle_02", "Finger_Middle_3": "middle_03",
    "Finger_Ring_1": "ring_01", "Finger_Ring_2": "ring_02", "Finger_Ring_3": "ring_03",
    "Finger_Pinky_1": "pinky_01", "Finger_Pinky_2": "pinky_02", "Finger_Pinky_3": "pinky_03",
    "Thumb_1": "thumb_01", "Finger_Thumb_2": "thumb_02", "Finger_Thumb_3": "thumb_03",
}


def log(*a):
    print("prep_zombie:", *a, flush=True)


def fail(*a):
    print("prep_zombie: FAIL", *a, flush=True)
    raise SystemExit(1)


def mannequin_name(bone_name, head_x):
    """Map an artist bone name to the mannequin one; sides from the bone's position."""
    base, side = bone_name, None
    if bone_name.endswith("_R") or bone_name.endswith("_L"):
        base = bone_name[:-2]
        side = "l" if head_x > 0 else "r"  # +X is the character's left (faces -Y)
    new = RENAME.get(base)
    if new is None:
        return None
    return f"{new}_{side}" if side else new


# ---------------------------------------------------------------- load + isolate
bpy.ops.wm.open_mainfile(filepath=SRC)
source_hash = hashlib.sha256(open(SRC, "rb").read()).hexdigest()
# One scene: the active one stays as the container (a scene is only a container here)
# and every other scene goes; the kept objects are linked into it below.
scene = bpy.context.scene
for sc in list(bpy.data.scenes):
    if sc != scene:
        bpy.data.scenes.remove(sc)
scene.name = "Scene"
if scene.unit_settings.scale_length != 1.0:
    fail("unit scale", scene.unit_settings.scale_length, "(the exporter folds it into the export; this script expects 1)")
keep_objects = [bpy.data.objects[n] for n in KEEP]
garment_arm = bpy.data.objects[GARMENT_ARMATURE]
for o in list(bpy.data.objects):
    if o not in keep_objects and o != garment_arm:
        bpy.data.objects.remove(o, do_unlink=True)
# The kept objects go straight into the scene root; every collection goes.
for o in keep_objects + [garment_arm]:
    if o.name not in scene.collection.objects:
        scene.collection.objects.link(o)
for c in list(bpy.data.collections):
    bpy.data.collections.remove(c)
bpy.context.view_layer.update()
for o in keep_objects:
    o.hide_set(False); o.hide_viewport = False; o.hide_render = False
    o.name = KEEP[o.name]
    if o.type == "MESH":
        o.data.name = o.name
arm = bpy.data.objects["Zombie"]
body, eyes, shirt, trousers, shoes = (bpy.data.objects[n] for n in ("Body", "Eyes", "Shirt", "Trousers", "Shoes"))
garments = [shirt, trousers]
meshes = [body, eyes, shoes] + garments
for o in [arm] + meshes:
    if max(abs(x - y) for r0, r1 in zip(o.matrix_world, Matrix.Identity(4)) for x, y in zip(r0, r1)) > 1e-5:
        fail(o.name, "is not at the origin:", [tuple(round(x, 4) for x in r) for r in o.matrix_world])

# The garments were skinned to a copy of the armature with one extra bone. The copy must
# hold the rig's rest pose exactly, or the artist's weights describe another body.
for b in arm.data.bones:
    c = garment_arm.data.bones.get(b.name)
    if c is None:
        fail(GARMENT_ARMATURE, "lacks bone", b.name)
    d = max(abs(x - y) for r0, r1 in zip(b.matrix_local, c.matrix_local) for x, y in zip(r0, r1))
    if d > 1e-5:
        fail(GARMENT_ARMATURE, "rest pose differs on", b.name, "by", d)
extra = [b for b in garment_arm.data.bones if b.name not in arm.data.bones]
if [b.name for b in extra] != ["Hips.001"]:
    fail(GARMENT_ARMATURE, "extra bones", [b.name for b in extra], "(expected Hips.001 only)")
hips, hips2 = arm.data.bones["Hips"], extra[0]
if (hips.head_local - hips2.head_local).length > 1e-5 or (hips.tail_local - hips.head_local).normalized().dot((hips2.tail_local - hips2.head_local).normalized()) < 1 - 1e-5:
    fail("Hips.001 is not Hips' head and direction")
if max(abs(x - y) for r0, r1 in zip(arm.matrix_world, garment_arm.matrix_world) for x, y in zip(r0, r1)) > 1e-5:
    fail(GARMENT_ARMATURE, "world matrix differs from the rig's")
log(f"{GARMENT_ARMATURE}: rest pose matches the rig on {len(arm.data.bones)} bones; Hips.001 sits on Hips")

# Every mesh hangs on the rig: parent + ARMATURE modifier pointing at it. This comes
# before the bone rename, which reaches a mesh's vertex groups only through its modifier
# or parent.
for m in meshes:
    mw = m.matrix_world.copy()
    m.parent = arm
    m.matrix_parent_inverse = arm.matrix_world.inverted()
    m.matrix_world = mw
    mod = next((md for md in m.modifiers if md.type == "ARMATURE"), None) or m.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
bpy.data.objects.remove(garment_arm, do_unlink=True)

# Eyes: keep one UV map.
for m in meshes:
    while len(m.data.uv_layers) > 1:
        m.data.uv_layers.remove(m.data.uv_layers[-1])


def merge_group_into(m, src_name, dst_name):
    """Add the weights of vertex group `src_name` into `dst_name` and drop the source."""
    g_src = m.vertex_groups.get(src_name); g_dst = m.vertex_groups.get(dst_name)
    if g_src is None:
        return 0
    if g_dst is None:
        g_dst = m.vertex_groups.new(name=dst_name)
    src_index = g_src.index; moved = 0
    for v in m.data.vertices:
        w = next((g.weight for g in v.groups if g.group == src_index), 0.0)
        if w > 0:
            g_dst.add([v.index], w, "ADD"); moved += 1
    m.vertex_groups.remove(g_src)
    return moved


# Garments: Hips.001 -> Hips (same bone), the cloth panel masks go.
bone_names_artist = {b.name for b in arm.data.bones}
for m in garments:
    moved = merge_group_into(m, "Hips.001", "Hips")
    dropped = [g.name for g in m.vertex_groups if g.name not in bone_names_artist]
    for name in dropped:
        m.vertex_groups.remove(m.vertex_groups[name])
    unexpected = set(dropped) - NON_BONE_GROUPS
    if unexpected:
        fail(m.name, "has vertex groups that are neither bones nor the known panel masks:", sorted(unexpected))
    log(f"{m.name}: Hips.001 folded into Hips on {moved} vertices; dropped groups {dropped}")

# ---------------------------------------------------------------- rig
bpy.ops.object.select_all(action="DESELECT")
arm.select_set(True); bpy.context.view_layer.objects.active = arm

# Neck_up -> Neck_down weights (summed), before the bone goes.
for m in meshes:
    merge_group_into(m, "Neck_up", "Neck_down")

bpy.ops.object.mode_set(mode="EDIT")
eb = arm.data.edit_bones
neck_up = eb["Neck_up"]; neck = eb["Neck_down"]; head = eb["Head"]
head.use_connect = False
head.parent = neck
neck.tail = head.head.copy()
eb.remove(neck_up)
root = eb.new("root")
root.head = Vector((0, 0, 0)); root.tail = Vector((0, 0, 0.1)); root.roll = 0
hips = eb["Hips"]
hips.use_connect = False
hips.parent = root
bpy.ops.object.mode_set(mode="OBJECT")

arm.data.bones["Hips"].use_deform = True
for b in arm.data.bones:
    if b.name == "root":
        continue
    new = mannequin_name(b.name, b.head_local.x)
    if new is None:
        log("WARNING: no mannequin name for bone", b.name)
        continue
    b.name = new
# Bone renames propagate to vertex groups; make sure.
bone_names = {b.name for b in arm.data.bones}
for m in meshes:
    stale = [g.name for g in m.vertex_groups if g.name not in bone_names]
    if stale:
        fail("vertex groups without a bone on", m.name, stale)
log("bones:", len(arm.data.bones), sorted(bone_names))


def bone_path(bone):
    """The joint path the exporter writes for a bone (`/root/pelvis/spine_01`)."""
    names = [bone.name]
    parent = bone.parent
    while parent is not None:
        names.append(parent.name)
        parent = parent.parent
    return "/" + "/".join(reversed(names))


# ---------------------------------------------------------------- scale to HEIGHT
dg = bpy.context.evaluated_depsgraph_get()
zs = [(body.matrix_world @ v.co).z for v in body.evaluated_get(dg).to_mesh().vertices]
factor = HEIGHT / (max(zs) - min(zs))
log(f"height {max(zs) - min(zs):.3f} m -> {HEIGHT} m, scale x{factor:.3f}")
for m in meshes:
    mw = m.matrix_world.copy()
    m.parent = None
    m.matrix_world = mw
for o in [arm] + meshes:
    o.scale = (factor, factor, factor)
bpy.ops.object.select_all(action="DESELECT")
for o in [arm] + meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
for m in meshes:
    m.parent = arm
    m.matrix_parent_inverse = arm.matrix_world.inverted()
    mod = next(md for md in m.modifiers if md.type == "ARMATURE")
    mod.object = arm

# ---------------------------------------------------------------- skin
# The shoes (and before them the fused clothes) came with automatic weights of their own,
# which disagree with the body's where it bends, so the skin pokes through; they take the
# body's weights instead, interpolated from the nearest skin face, and nothing of them
# follows a hand or a finger. The garments keep the artist's weights (the simulation
# pins its particles to them, and the sidecar carries the same numbers), cleaned below.
def transfer_weights(src, dst):
    for g in src.vertex_groups:
        if dst.vertex_groups.get(g.name) is None:
            dst.vertex_groups.new(name=g.name)
    mod = dst.modifiers.new("BodyWeights", "DATA_TRANSFER")
    mod.object = src
    mod.use_vert_data = True
    mod.data_types_verts = {"VGROUP_WEIGHTS"}
    mod.vert_mapping = "POLYINTERP_NEAREST"
    mod.layers_vgroup_select_src = "ALL"
    mod.layers_vgroup_select_dst = "NAME"
    mod.mix_mode = "REPLACE"
    mod.mix_factor = 1.0
    with bpy.context.temp_override(object=dst, active_object=dst, selected_objects=[dst], selected_editable_objects=[dst]):
        bpy.ops.object.modifier_move_to_index(modifier=mod.name, index=0)
        bpy.ops.object.modifier_apply(modifier=mod.name)

HAND_PREFIXES = ("hand", "thumb", "finger", "index", "middle", "ring", "pinky")

def unhand(obj, fallback="lowerarm"):
    """Takes every hand and finger weight off `obj` and renormalises what is left; a
    vertex that had nothing else goes to the forearm of its side."""
    names = [g.name for g in obj.vertex_groups]
    hand = {i for i, n in enumerate(names) if n.lower().startswith(HAND_PREFIXES)}
    changed = rescued = 0
    for v in obj.data.vertices:
        weights = {g.group: g.weight for g in v.groups if g.weight > 0}
        held = weights.keys() & hand
        if not held:
            continue
        changed += 1
        side = "_l" if any(names[i].endswith("_l") for i in held) else "_r"
        for i in held:
            obj.vertex_groups[i].remove([v.index])
        rest = {i: w for i, w in weights.items() if i not in hand}
        total = sum(rest.values())
        if total < 1e-4:
            obj.vertex_groups[fallback + side].add([v.index], 1.0, "REPLACE")
            rescued += 1
        else:
            for i, w in rest.items():
                obj.vertex_groups[i].add([v.index], w / total, "REPLACE")
    return changed, rescued

transfer_weights(body, shoes)
changed, rescued = unhand(shoes)
log(f"shoes: weights taken from the body; {changed} vertices freed of the hands ({rescued} moved to the forearm)")
for m in garments:
    changed, rescued = unhand(m)
    log(f"{m.name}: {changed} vertices freed of the hands ({rescued} moved to the forearm)")

# No bone weighs on a vertex more than REACH metres from it. The automatic weights
# leave a little of the pelvis on the wrists (the hands hang beside the hips in the
# bind pose), and taking the hand weights off the cuffs doubled it to 15 %: with the
# arm raised a metre from where it was bound, that is a 15 cm fin on the vertices that
# have it beside vertices that do not (headset, 2026-10-27). A quarter of a metre is
# farther than any bone legitimately reaches on this body (the spine bones sit 13 cm
# apart, a shoulder vertex is 20 cm from the upper spine) and well short of the wrist
# to the pelvis (45 cm), so the crotch, the armpits and the collar keep their blends.
REACH = 0.25

def bone_segments(arm):
    return {b.name: (arm.matrix_world @ b.head_local, arm.matrix_world @ b.tail_local) for b in arm.data.bones if b.use_deform}

def segment_distance(p, a, b):
    ab = b - a; t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-9)))
    return (p - (a + ab * t)).length

def prune_far_weights(obj, arm, reach=REACH):
    segments = bone_segments(arm)
    names = [g.name for g in obj.vertex_groups]
    mw = obj.matrix_world
    pruned = 0; rehomed = 0; dropped_total = 0.0; farthest = 0.0
    for v in obj.data.vertices:
        weights = {names[g.group]: g.weight for g in v.groups if g.weight > 0 and names[g.group] in segments}
        if not weights:
            continue
        p = mw @ v.co
        distances = {n: segment_distance(p, *segments[n]) for n in weights}
        dropped = {n: w for n, w in weights.items() if distances[n] > reach}
        if not dropped:
            continue
        pruned += 1; dropped_total += sum(dropped.values()); farthest = max(farthest, max(distances[n] for n in dropped))
        for n in dropped:
            obj.vertex_groups[n].remove([v.index])
        kept = {n: w for n, w in weights.items() if n not in dropped}
        total = sum(kept.values())
        if total < 1e-4:
            nearest = min(segments, key=lambda n: segment_distance(p, *segments[n]))
            obj.vertex_groups[nearest].add([v.index], 1.0, "REPLACE"); rehomed += 1
        else:
            for n, w in kept.items():
                obj.vertex_groups[n].add([v.index], w / total, "REPLACE")
    return pruned, rehomed, dropped_total, farthest

for m in [body, shoes] + garments:
    pruned, rehomed, dropped, farthest = prune_far_weights(m, arm)
    log(f"{m.name}: {pruned} vertices lost weights of bones farther than {REACH} m ({rehomed} rehomed, {dropped:.1f} weight dropped in all, farthest {farthest:.2f} m)")


def cap_influences(obj, arm, limit=4, floor=1e-3):
    """At most `limit` bones per vertex (the smallest weights go), weights summing to 1
    and none below `floor` once normalised (the artist's automatic weights leave traces
    of a millionth that would round to nothing in the sidecar; a trace is judged after
    the normalisation, since the raw weights of a vertex may sum to more than 1, and the
    rest is renormalised until no trace is left); a vertex left with no bone at all (it
    was weighted to a panel mask only) goes to the nearest bone. The exporter makes the
    same cut, so the sidecar and the skin agree."""
    segments = bone_segments(arm)
    names = [g.name for g in obj.vertex_groups]
    mw = obj.matrix_world
    capped = rehomed = 0; histogram = {}
    for v in obj.data.vertices:
        weights = sorted(((g.weight, g.group) for g in v.groups if g.weight > 0), reverse=True)
        if len(weights) > limit:
            capped += 1
            weights = weights[:limit]
        while weights:
            total = sum(w for w, _ in weights)
            kept = [(w, gi) for w, gi in weights if w / total >= floor]
            if len(kept) == len(weights):
                break
            weights = kept
        kept_groups = {gi for _, gi in weights}
        # The indices first, then the removals: a vertex's group elements are live views
        # into its array, which shifts with every removal.
        for gi in [g.group for g in v.groups]:
            if gi not in kept_groups:
                obj.vertex_groups[gi].remove([v.index])
        if not weights:
            p = mw @ v.co
            nearest = min(segments, key=lambda n: segment_distance(p, *segments[n]))
            obj.vertex_groups[nearest].add([v.index], 1.0, "REPLACE"); rehomed += 1
            weights = [(1.0, obj.vertex_groups[nearest].index)]
        else:
            total = sum(w for w, _ in weights)
            for w, gi in weights:
                obj.vertex_groups[gi].add([v.index], w / total, "REPLACE")
        histogram[len(weights)] = histogram.get(len(weights), 0) + 1
    return capped, rehomed, dict(sorted(histogram.items()))

for m in garments:
    capped, rehomed, histogram = cap_influences(m, arm)
    log(f"{m.name}: {capped} vertices cut to 4 influences, {rehomed} rehomed to the nearest bone; influences per vertex {histogram}")

# ---------------------------------------------------------------- images
def image(name):
    img = bpy.data.images.get(name)
    if img is None:
        fail(f"image {name} missing")
    return img


TEX_DIR = os.path.splitext(OUT_BLEND)[0] + "_textures"
os.makedirs(TEX_DIR, exist_ok=True)
_resampled = {}


def pixels(img):
    w, h = img.size
    a = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(h, w, 4)


def box_down(arr, size):
    h, w, _ = arr.shape
    f = max(1, w // size)
    if f <= 1:
        return arr
    return arr[: (h // f) * f, : (w // f) * f].reshape(h // f, f, w // f, f, 4).mean(axis=(1, 3))


def new_image(name, arr, colorspace):
    """A fresh image from an array, written to TEX_DIR and packed (the artist's 4K originals
    stay out of the prepped file)."""
    h, w, _ = arr.shape
    img = bpy.data.images.new(name, w, h, alpha=True)
    img.pixels.foreach_set(np.ascontiguousarray(arr, dtype=np.float32).reshape(-1))
    img.filepath_raw = os.path.join(TEX_DIR, name + ".png")
    img.file_format = "PNG"
    img.alpha_mode = "STRAIGHT"
    img.save()
    img.pack()
    img.colorspace_settings.name = colorspace
    return img


# Artist texture prefixes -> the names the model ships with.
TEX_NAMES = {"CARA_FUSIONADA": "ZombieFace", "CUERPO": "ZombieBody", "ropa": "ZombieClothes"}


def texture_name(img_name, suffix=""):
    stem = os.path.splitext(img_name)[0].replace(".1001", "").replace(".1002", "")
    for prefix, new in TEX_NAMES.items():
        if stem.startswith(prefix + "_"):
            return new + "_" + stem[len(prefix) + 1:] + suffix
    return stem + suffix


def downscale(img, size=TEX_SIZE, colorspace=None):
    """The image resampled to at most `size` texels, as a new packed image (cached by name)."""
    key = img.name
    if key in _resampled:
        return _resampled[key]
    cs = colorspace or img.colorspace_settings.name
    arr = box_down(pixels(img), size)
    out = new_image(texture_name(img.name), arr, cs)
    _resampled[key] = out
    return out


def principled_material(name, base, rough=None, metal=None, normal=None, alpha=False, alpha_value=None, resample=True):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    def tex(img, colorspace, y):
        node = nt.nodes.new("ShaderNodeTexImage")
        node.image = downscale(img) if resample else img
        node.image.colorspace_settings.name = colorspace
        node.location = (-500, y)
        return node

    tb = tex(base, "sRGB", 300)
    nt.links.new(tb.outputs["Color"], bsdf.inputs["Base Color"])
    if rough is not None:
        nt.links.new(tex(rough, "Non-Color", 0).outputs["Color"], bsdf.inputs["Roughness"])
    else:
        bsdf.inputs["Roughness"].default_value = 0.7
    if metal is not None:
        nt.links.new(tex(metal, "Non-Color", -300).outputs["Color"], bsdf.inputs["Metallic"])
    else:
        bsdf.inputs["Metallic"].default_value = 0.0
    if normal is not None:
        nm = nt.nodes.new("ShaderNodeNormalMap"); nm.location = (-250, -600)
        nt.links.new(tex(normal, "Non-Color", -600).outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    if alpha:
        nt.links.new(tb.outputs["Alpha"], bsdf.inputs["Alpha"])
    if alpha_value is not None:
        bsdf.inputs["Alpha"].default_value = alpha_value
    if alpha or alpha_value is not None:
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "DITHERED" if alpha else "BLENDED"
        try:
            mat.blend_method = "HASHED" if alpha else "BLEND"
        except Exception:
            pass
    return mat


def slot_index(obj, needle):
    for i, s in enumerate(obj.material_slots):
        if s.material and needle in s.material.name.lower():
            return i
    return None


def material_maps(mat):
    """The base colour, roughness and normal images a Principled material reads. The artist's
    garment materials also carry Metallic, Height and Emissive maps; the engine material
    has no use for them (the metallic and emissive maps are empty anyway), so they are
    left behind."""
    bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")

    def image_at(socket):
        if not socket.is_linked:
            return None
        node = socket.links[0].from_node
        if node.type == "NORMAL_MAP":
            return image_at(node.inputs["Color"])
        return node.image if node.type == "TEX_IMAGE" else None

    maps = tuple(image_at(bsdf.inputs[s]) for s in ("Base Color", "Roughness", "Normal"))
    if any(m is None for m in maps):
        fail(mat.name, "lacks a base colour, roughness or normal image:", [m.name if m else None for m in maps])
    return maps


# ---------------------------------------------------------------- one mesh, one material
# The engine binds the animation per skinned mesh node, and the exporters split a
# multi-material object into one node per material (the add-on's September exporter
# also drops the skin of the fragments), so a character that must stay one animated
# body is one mesh with one material: the texture sets go into one 2x2 atlas of
# TEX_SIZE tiles — face, body and the old clothes (worn by the shoes) a tile each, the
# shirt and the trousers a quarter of the fourth tile each (TEX_SIZE/2 squared: the
# artist's 2048 shirt maps halved, the 4096 trousers maps quartered) — the UVs move into
# their tile, the alpha-masked hair cards and the cornea shell go (the material is
# opaque), the shape keys are baked, and the objects are joined into one.
TILE = TEX_SIZE
ATLAS = TILE * 2
# (u0, v0, size) as fractions of the atlas; row 0 is the bottom.
TILES = {"face": (0.0, 0.5, 0.5), "body": (0.5, 0.5, 0.5), "clothes": (0.0, 0.0, 0.5),
         "shirt": (0.5, 0.0, 0.25), "trousers": (0.75, 0.0, 0.25)}


def tile_pixels(tile):
    u0, v0, size = TILES[tile]
    return int(u0 * ATLAS), int(v0 * ATLAS), int(size * ATLAS)


def blank_atlas(fill):
    a = np.empty((ATLAS, ATLAS, 4), dtype=np.float32)
    a[:] = fill
    return a


def place(atlas, img, tile):
    """Box-downscale `img` to the tile's size and write its colour into the tile."""
    x0, y0, size = tile_pixels(tile)
    arr = box_down(pixels(img), size)
    h, w, _ = arr.shape
    if h > size or w > size:
        fail(f"{img.name} ({w}x{h}) does not fit tile {tile} ({size}px): not a power-of-two multiple")
    atlas[y0:y0 + h, x0:x0 + w, :3] = arr[:, :, :3]


atlas_base = blank_atlas((0.5, 0.5, 0.5, 1.0))
atlas_rough = blank_atlas((0.7, 0.7, 0.7, 1.0))
atlas_normal = blank_atlas((0.5, 0.5, 1.0, 1.0))
sources = {
    "face": tuple(image(n) for n in ("CARA_FUSIONADA_BaseColor.png", "CARA_FUSIONADA_Roughness.png", "CARA_FUSIONADA_Normal.png")),
    "body": tuple(image(n) for n in ("CUERPO_BaseColor.png", "CUERPO_Roughness.png", "CUERPO_Normal.png")),
    "clothes": material_maps(shoes.material_slots[0].material),
    "shirt": material_maps(shirt.material_slots[slot_index(shirt, "camisa")].material),
    "trousers": material_maps(trousers.material_slots[slot_index(trousers, "pantalon")].material),
}
for tile, (base, rough, normal) in sources.items():
    log(f"tile {tile}: {base.name} {tuple(base.size)}, {rough.name} {tuple(rough.size)}, {normal.name} {tuple(normal.size)} -> {tile_pixels(tile)[2]}px")
    place(atlas_base, base, tile)
    place(atlas_rough, rough, tile)
    place(atlas_normal, normal, tile)
body_alpha_tex = box_down(pixels(image("CUERPO_Alpha.png")), TILE)[:, :, 0]
log(f"alpha<0.5 texels: body {float((body_alpha_tex < 0.5).mean()):.1%} (those faces go)")

atlas_base_img = new_image("Zombie_BaseColor", atlas_base, "sRGB")
atlas_rough_img = new_image("Zombie_Roughness", atlas_rough, "Non-Color")
atlas_normal_img = new_image("Zombie_Normal", atlas_normal, "Non-Color")
atlas_mat = principled_material("Zombie", atlas_base_img, rough=atlas_rough_img, normal=atlas_normal_img, resample=False)
del atlas_base, atlas_rough, atlas_normal


def apply_shape_keys(obj):
    """Bake the current shape-key mix into the mesh (the zombie look lives in the keys)."""
    if not obj.data.shape_keys:
        return
    with bpy.context.temp_override(object=obj, active_object=obj, selected_objects=[obj], selected_editable_objects=[obj]):
        bpy.ops.object.shape_key_remove(all=True, apply_mix=True)


def delete_faces(obj, doomed):
    """Drop the polygons whose index is in `doomed`; loose geometry goes with them."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    faces = [bm.faces[i] for i in doomed]
    bmesh.ops.delete(bm, geom=faces, context="FACES")
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()


def uv_centre_alpha(obj, poly):
    uv = obj.data.uv_layers.active.data
    cu = sum((uv[li].uv for li in poly.loop_indices), Vector((0, 0))) / len(poly.loop_indices)
    x = int(min(max(cu.x % 1.0, 0.0), 0.999999) * TILE)
    y = int(min(max(cu.y % 1.0, 0.0), 0.999999) * TILE)
    return body_alpha_tex[y, x]


def remap_uvs(obj, slot_tiles):
    """Move each polygon's UVs into the atlas tile (or quarter tile) of its material slot."""
    uv = obj.data.uv_layers.active.data
    for poly in obj.data.polygons:
        tile = slot_tiles.get(poly.material_index)
        if tile is None:
            continue
        u0, v0, size = TILES[tile]
        for li in poly.loop_indices:
            u, v = uv[li].uv
            u = u if 0.0 <= u <= 1.0 else u % 1.0
            v = v if 0.0 <= v <= 1.0 else v % 1.0
            uv[li].uv = (u * size + u0, v * size + v0)


for m in meshes:
    apply_shape_keys(m)

# Body: face + skin slots; the hair cards (alpha-masked faces of the skin slot) go.
face_slot = slot_index(body, "cara"); skin_slot = slot_index(body, "cuerpo")
hair = [p.index for p in body.data.polygons if p.material_index == skin_slot and uv_centre_alpha(body, p) < 0.5]
remap_uvs(body, {face_slot: "face", skin_slot: "body"})
delete_faces(body, hair)
log(f"body: face slot {face_slot}, skin slot {skin_slot}, hair faces removed {len(hair)}")


# ---------------------------------------------------------------- simulation proxies
# Both garments become the particle meshes the game simulates and, until the render
# shell is bound to them, what it draws. The body (hair gone, shape keys baked, game
# scale) is the reference surface for everything below.
def surface_tree(objs):
    """A BVH over the polygons of `objs` in world space."""
    verts, polys = [], []
    for o in objs:
        base = len(verts); mw = o.matrix_world
        verts += [tuple(mw @ v.co) for v in o.data.vertices]
        polys += [tuple(base + i for i in p.vertices) for p in o.data.polygons]
    return BVHTree.FromPolygons(verts, polys)


body_tree = surface_tree([body])


def islands(bm):
    """Connected components of `bm` by edges, largest first, as lists of BMVerts."""
    bm.verts.index_update()
    seen = set(); out = []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack = [v]; comp = []; seen.add(v.index)
        while stack:
            x = stack.pop(); comp.append(x)
            for e in x.link_edges:
                y = e.other_vert(x)
                if y.index not in seen:
                    seen.add(y.index); stack.append(y)
        out.append(comp)
    out.sort(key=len, reverse=True)
    return out


def boundary_loops(bm):
    """The boundary of `bm` as ordered vertex loops (lists of BMVerts)."""
    edges = {e for e in bm.edges if e.is_boundary}
    loops = []
    while edges:
        e = edges.pop(); loop = [e.verts[0], e.verts[1]]
        while True:
            last = loop[-1]
            nxt = next((x for x in last.link_edges if x in edges), None)
            if nxt is None:
                break
            edges.remove(nxt); loop.append(nxt.other_vert(last))
        if loop[-1] == loop[0]:
            loop.pop()
        loops.append(loop)
    # Longest first, ties by centroid: the edge set iterates in memory order, which
    # differs from run to run, and the cuff loops are the same length give or take one.
    loops.sort(key=lambda l: (-len(l), tuple(round(c, 5) for c in sum((v.co for v in l), Vector()) / len(l))))
    return loops


def describe_loops(name, loops, mw):
    for i, loop in enumerate(loops):
        zs = [(mw @ v.co).z for v in loop]; xs = [(mw @ v.co).x for v in loop]
        log(f"  {name} boundary loop {i}: {len(loop)} verts, z {min(zs):.3f}..{max(zs):.3f}, x {min(xs):.3f}..{max(xs):.3f}")


def mesh_stats(obj):
    """(vertices, triangles, min/median/max edge, min face area, min angle in degrees,
    islands, boundary loops, then the 10th and 90th percentile edge) of a triangle mesh
    in world units. The percentiles come last so the callers that unpack the first nine
    read as they did; they say how uniform a proxy's spacing is, which the 16k proxy's
    8.4 mm target is about (2026-11-04)."""
    bm = bmesh.new(); bm.from_mesh(obj.data); bm.transform(obj.matrix_world)
    lengths = np.array([e.calc_length() for e in bm.edges])
    areas = [f.calc_area() for f in bm.faces]
    angles = [min(l.calc_angle() for l in f.loops) for f in bm.faces]
    stats = (len(bm.verts), len(bm.faces), float(lengths.min()), float(np.median(lengths)), float(lengths.max()),
             min(areas), math.degrees(min(angles)), len(islands(bm)), len(boundary_loops(bm)),
             float(np.percentile(lengths, 10)), float(np.percentile(lengths, 90)))
    bm.free()
    return stats


def report_proxy(name, obj, loops, min_edge=0.008, max_edge=0.040, min_area=1e-6, min_angle=5.0):
    """Log a proxy's mesh_stats and hold them to the limits the tests check and to one
    piece with `loops` openings; returns the stats. The limits are per garment: the 4k
    shirt and the trousers take the defaults (the asset tests' 8-40 mm and 5 degrees),
    the 16k shirt 4-30 mm and 10 degrees (Docs/GPUCloth.md, section 5)."""
    stats = mesh_stats(obj)
    nv, nf, emin, emed, emax, amin, angmin, nisl, nloops, e10, e90 = stats
    log(f"{name} proxy: {nv} verts, {nf} tris, edges {emin * 1000:.1f}/{e10 * 1000:.1f}/{emed * 1000:.1f}/{e90 * 1000:.1f}/{emax * 1000:.1f} mm (min/p10/median/p90/max), "
        f"min face area {amin * 1e6:.2f} mm², min angle {angmin:.1f}°, {nisl} island(s), {nloops} boundary loop(s)")
    if not (emin >= min_edge and emax <= max_edge and amin >= min_area and angmin >= min_angle):
        fail(f"{name} proxy breaks the mesh limits (edges {min_edge}..{max_edge} m, area >= {min_area} m², angle >= {min_angle}°)")
    if nisl != 1 or nloops != loops:
        bm = bmesh.new(); bm.from_mesh(obj.data)
        sizes = [len(p) for p in islands(bm)]
        loose = sum(1 for v in bm.verts if not v.link_edges)
        bm.free()
        fail(f"{name} proxy: must be one piece with {loops} openings, not {nisl} piece(s) of {sizes[:8]} vertices ({loose} loose) with {nloops}")
    return stats


def decimate_proxy(obj, target, min_edge=0.0085, max_edge=0.036, min_angle=8.0, min_area=2e-6, deviation=0.002, max_valence=12, split_long=True):
    """Shortest-edge-first half-edge collapse of `obj` (triangulated first) down to about
    `target` vertices, and on until no edge is shorter than `min_edge`.

    A collapse keeps one endpoint where it is and moves the other onto it, so no vertex
    changes position, UV or weights: a vertex on a boundary or a UV seam only ever slides
    along that line into another vertex of it (and only when it lies within `deviation`
    of the line through its two neighbours), the link condition keeps the mesh manifold,
    and a collapse that would make a face smaller than `min_area`, an angle below
    `min_angle` degrees, an edge longer than `max_edge`, a normal that turns more than
    about 70 degrees or a vertex of more than `max_valence` edges is refused — unless the
    face was already that bad: a face may never get worse, but a cluster of degenerate
    faces may be collapsed out of existence. An edge shorter than `min_edge` is below
    what the proxy can hold, so it goes whatever it crosses (with the edge limit eased to
    39 mm, still inside what the tests allow): the artist's meshes carry millimetre-wide
    seam and hem strips between seam lines, and across those a boundary or seam vertex
    may move onto the other line too, its corners keeping their own UVs where the other
    line's UV island has none for them (the texture shifts by the strip's width). The
    result is the near-uniform triangle mesh a particle simulation wants,
    with the garment's outline and UV layout intact. Edges longer than `max_edge` are
    split first (a collapse never shortens an edge) — unless `split_long` is off: the
    16k proxy (`refine_proxy`) has already split every edge at its midpoint, and this
    partial split, run on it at a 12 mm limit, left 304 zero-area faces and 89
    non-manifold edges (measured 2026-11-04), so that garment skips it and lets the
    collapse's own long-edge rule hold what the midpoint split made."""
    bm = bmesh.new(); bm.from_mesh(obj.data)
    # Zero-length edges and zero-area faces (coincident vertices the artist left, or a
    # weld made) cannot be collapsed away by the quality rules below: dissolve them first.
    bmesh.ops.dissolve_degenerate(bm, dist=1e-4, edges=bm.edges[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
    long_edges = [e for e in bm.edges if e.calc_length() > max_edge] if split_long else []
    for _ in range(4):
        if not long_edges:
            break
        bmesh.ops.subdivide_edges(bm, edges=long_edges, cuts=1, use_grid_fill=False)
        bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
        long_edges = [e for e in bm.edges if e.calc_length() > max_edge]
    bm.verts.ensure_lookup_table(); bm.faces.ensure_lookup_table()
    degenerate = sum(1 for f in bm.faces if f.calc_area() < 1e-10)
    shortest = min(e.calc_length() for e in bm.edges)
    log(f"{obj.name}: triangulated to {len(bm.verts)} verts / {len(bm.faces)} tris for decimation; shortest edge {shortest * 1000:.2f} mm, {degenerate} zero-area faces")
    uv_layer = bm.loops.layers.uv.active
    deform = bm.verts.layers.deform.active
    P = np.array([v.co[:] for v in bm.verts], dtype=np.float64)
    faces = [[l.vert.index for l in f.loops] for f in bm.faces]
    fuv = [[tuple(l[uv_layer].uv) for l in f.loops] for f in bm.faces]
    fmat = [f.material_index for f in bm.faces]
    weights = [dict(v[deform].items()) if deform is not None else {} for v in bm.verts]
    materials = [m for m in obj.data.materials]
    group_names = [g.name for g in obj.vertex_groups]  # the names live on the mesh since Blender 3.0
    before = (len(bm.verts), len(bm.faces))
    bm.free()

    n = len(P)
    vf = [set() for _ in range(n)]
    for fi, f in enumerate(faces):
        for v in f:
            vf[v].add(fi)
    alive_v = [True] * n; alive_f = [True] * len(faces)
    min_sin = math.sin(math.radians(min_angle))

    def neighbours(v):
        return {x for fi in vf[v] for x in faces[fi] if x != v}

    def edge_faces(a, b):
        return vf[a] & vf[b]

    def is_feature(a, b):
        fs = edge_faces(a, b)
        if len(fs) != 2:
            return True
        f0, f1 = fs
        ua0, ub0 = fuv[f0][faces[f0].index(a)], fuv[f0][faces[f0].index(b)]
        ua1, ub1 = fuv[f1][faces[f1].index(a)], fuv[f1][faces[f1].index(b)]
        return abs(ua0[0] - ua1[0]) + abs(ua0[1] - ua1[1]) + abs(ub0[0] - ub1[0]) + abs(ub0[1] - ub1[1]) > 1e-5

    def tri_quality(a, b, c):
        """(twice the area as a vector, min sine of an angle, longest edge, shortest edge)
        of triangle abc."""
        ab, bc, ca = b - a, c - b, a - c
        cross = np.cross(ab, -ca)
        area2 = float(np.linalg.norm(cross))
        lab, lbc, lca = float(np.linalg.norm(ab)), float(np.linalg.norm(bc)), float(np.linalg.norm(ca))
        if min(lab, lbc, lca) <= 0:
            return cross, 0.0, max(lab, lbc, lca), 0.0
        # sin of the angle at each corner = 2A / (product of the two edges there)
        s = min(area2 / (lab * lca), area2 / (lab * lbc), area2 / (lbc * lca))
        return cross, s, max(lab, lbc, lca), min(lab, lbc, lca)

    def collapse_quality(v, u):
        """(worst min-sine among the new faces, None) when v may move onto u, else
        (None, why not)."""
        shared = [fi for fi in vf[v] if u in faces[fi]]
        if not shared or len(shared) > 2:
            return None, f"edge of {len(shared)} faces"
        nv, nu = neighbours(v), neighbours(u)
        apex = {x for fi in shared for x in faces[fi] if x != u and x != v}
        if (nv & nu) != apex:
            return None, "link condition"  # a pinch would make the mesh non-manifold
        if len(nv | nu) - 2 > max_valence:
            return None, "valence"
        fine = length(v, u) < min_edge  # below the proxy's resolution: goes whatever it crosses
        edge_limit = 0.039 if fine else max_edge
        if not fine:
            feature_edges = [x for x in nv if is_feature(v, x)]
            if feature_edges:
                if len(feature_edges) != 2 or u not in feature_edges:
                    return None, f"feature vertex with {len(feature_edges)} feature edges" + ("" if u in feature_edges else ", not along one")
                w = feature_edges[0] if feature_edges[1] == u else feature_edges[1]
                a, b = P[u], P[w]; ab = b - a
                t = max(0.0, min(1.0, float(np.dot(P[v] - a, ab) / max(float(np.dot(ab, ab)), 1e-12))))
                if float(np.linalg.norm(P[v] - (a + ab * t))) > deviation:
                    return None, "feature deviation"
        worst = 1.0
        for fi in vf[v]:
            if fi in shared:
                continue
            old = faces[fi]
            o_cross, o_s, o_longest, _ = tri_quality(P[old[0]], P[old[1]], P[old[2]])
            o_area2 = float(np.linalg.norm(o_cross))
            tri = [u if x == v else x for x in old]
            cross, s, longest, shortest = tri_quality(P[tri[0]], P[tri[1]], P[tri[2]])
            area2 = float(np.linalg.norm(cross))
            # A good face may not go bad, unless the bad face it becomes has an edge
            # below min_edge, which the next drain collapses (a vertex tented over three
            # collinear ones leaves that way); a bad one may change (the sweeps below
            # take the slivers out one collapse at a time).
            if area2 * 0.5 < min_area and o_area2 * 0.5 >= min_area and shortest >= min_edge:
                return None, "area"
            if s < min_sin and o_s >= min_sin and shortest >= min_edge:
                return None, "angle"
            if longest > edge_limit and longest > o_longest:
                return None, "long edge"  # a long edge may never grow past the limit
            if o_s >= min_sin and area2 > 0 and float(np.dot(cross, o_cross)) / (area2 * o_area2) < 0.34:
                return None, "normal turn"
            worst = min(worst, s)
        return worst, None

    def collapse(v, u):
        shared = [fi for fi in vf[v] if u in faces[fi]]
        for fi in shared:
            alive_f[fi] = False
            for x in faces[fi]:
                vf[x].discard(fi)
        for fi in shared:
            for x in faces[fi]:
                if x != v and x != u and not vf[x]:
                    alive_v[x] = False; lost.append(x)  # an ear vertex whose only face went
        for fi in list(vf[v]):
            k = faces[fi].index(v)
            uv_v = fuv[fi][k]
            # The corner that moves to u takes u's UV from the deleted face of the same UV
            # island; a corner with no such donor (the edge crossed a seam) keeps its own.
            donor = next((d for d in shared if abs(fuv[d][faces[d].index(v)][0] - uv_v[0]) + abs(fuv[d][faces[d].index(v)][1] - uv_v[1]) < 1e-5), None)
            if donor is not None:
                fuv[fi][k] = fuv[donor][faces[donor].index(u)]
            faces[fi][k] = u
            vf[u].add(fi)
        vf[v] = set(); alive_v[v] = False

    def length(a, b):
        return float(np.linalg.norm(P[a] - P[b]))

    lost = []
    count = n; refused = 0

    def try_collapse(a, b):
        """Collapse edge (a, b) the better way round if the rules allow; True when done."""
        nonlocal count
        best = None
        for v, u in ((a, b), (b, a)):
            q, _ = collapse_quality(v, u)
            if q is not None and (best is None or q > best[0]):
                best = (q, v, u)
        if best is None:
            return False
        collapse(best[1], best[2]); count -= 1 + len(lost); lost.clear()
        return True

    def alive_edges(shorter_than=None):
        seen = set(); out = []
        for fi in range(len(faces)):
            if not alive_f[fi]:
                continue
            f = faces[fi]
            for a, b in ((f[0], f[1]), (f[1], f[2]), (f[2], f[0])):
                key = (min(a, b), max(a, b))
                if key not in seen:
                    seen.add(key)
                    d = length(a, b)
                    if shorter_than is None or d < shorter_than:
                        out.append((d, key[0], key[1]))
        return out

    def drain(heap):
        """Shortest edge first: collapse until the target is met and no edge is shorter
        than min_edge. Returns the short edges whose collapse the rules refused."""
        nonlocal refused
        heapq.heapify(heap)
        short_left = []
        while heap:
            d, a, b = heapq.heappop(heap)
            if not (alive_v[a] and alive_v[b]) or b not in neighbours(a):
                continue
            if count <= target and d >= min_edge:
                break
            if try_collapse(a, b):
                u = a if alive_v[a] else b
                for x in neighbours(u):
                    heapq.heappush(heap, (length(u, x), min(u, x), max(u, x)))
            else:
                refused += 1
                if d < min_edge:
                    short_left.append((d, a, b))
        return [(d, a, b) for d, a, b in short_left if alive_v[a] and alive_v[b] and b in neighbours(a)]

    stuck = drain(alive_edges())
    for attempt in range(3):
        if not stuck:
            break
        stuck = drain(stuck)
    # A short edge whose collapse the link condition refuses sits on a hollow 3-cycle
    # through a third vertex y (a-y and b-y are edges, a-b-y is no face): collapsing
    # a-y or b-y first opens the way. Failing that, any collapse next to the edge may.
    # And when the 3-cycle is the base of a TENT — a vertex w of exactly three faces
    # whose three neighbours are the cycle, a cap a few millimetres across that the
    # collapses leave at the rolled cuffs' creases (the 16k proxy, 2026-11-04: five
    # of them, every edge of each base link-refused from both ends and the apex's
    # own collapses refused by the feature rules, the whole proxy held at a 2.9 mm
    # edge) — the cap is below the proxy's resolution and goes: its apex is collapsed
    # onto the nearest of the three, which the link condition allows by construction
    # (the two shared faces' apexes are the other two) and which leaves the base as
    # one face wound like the surface around it; the feature rules are set aside for
    # it, as they are for any edge under `min_edge`. The 4k proxy has no stuck edge
    # and never reaches this.
    def tent_apex(a, b):
        for w in sorted(neighbours(a) & neighbours(b)):
            nw = neighbours(w)
            if len(nw) == 3 and len(vf[w]) == 3 and all(q in neighbours(p) for p in nw for q in nw if p != q):
                return w
        return None

    tents = 0
    for d, a, b in sorted(set(stuck)):
        if not (alive_v[a] and alive_v[b] and b in neighbours(a)):
            continue
        w = tent_apex(a, b)
        if w is not None:
            c = min(neighbours(w), key=lambda x: length(w, x))
            log(f"  {obj.name}: edge {a}-{b} of {d * 1000:.2f} mm is the base of a tent at vertex {w} ({', '.join(f'{length(w, x) * 1000:.1f}' for x in sorted(neighbours(w)))} mm to its three neighbours): the apex collapsed onto {c}")
            collapse(w, c); count -= 1 + len(lost); lost.clear(); tents += 1
            if try_collapse(a, b):
                continue
        apex = {x for fi in vf[a] & vf[b] for x in faces[fi] if x != a and x != b}
        for y in sorted((neighbours(a) & neighbours(b)) - apex, key=lambda y: min(length(a, y), length(b, y))):
            if try_collapse(a, y) or try_collapse(b, y):
                break
        if alive_v[a] and alive_v[b] and b in neighbours(a) and not try_collapse(a, b):
            for v in (a, b):
                for x in sorted(neighbours(v), key=lambda x: length(v, x)):
                    if x not in (a, b) and alive_v[x] and try_collapse(v, x):
                        break
        if alive_v[a] and alive_v[b] and b in neighbours(a) and not try_collapse(a, b):
            cycle = sorted((neighbours(a) & neighbours(b)) - apex)
            log(f"  {obj.name}: edge {a}-{b} of {d * 1000:.2f} mm left: {collapse_quality(a, b)[1]} / {collapse_quality(b, a)[1]}; "
                f"3-cycle through {cycle}: "
                + "; ".join(f"{p}->{q} {collapse_quality(p, q)[1]}" for y in cycle for p, q in ((a, y), (y, a), (b, y), (y, b))))
            for x in [a, b] + cycle:
                log(f"    vertex {x}: at {tuple(round(float(c) * 1000, 1) for c in P[x])} mm, valence {len(neighbours(x))}, faces {[faces[fi] for fi in sorted(vf[x])]}, "
                    f"feature edges {[y for y in sorted(neighbours(x)) if is_feature(x, y)]}")
    for d, a, b in drain(alive_edges(min_edge)):
        log(f"  {obj.name}: edge {a}-{b} of {d * 1000:.2f} mm left after the retries: {collapse_quality(a, b)[1]} / {collapse_quality(b, a)[1]}")
    # Faces that are slivers or next to nothing in area with edges no shorter than
    # min_edge (collinear vertices) escape the shortest-edge rule: collapse their
    # shortest edge if the rules allow it, then drain the short edges that made.
    for sweep in range(3):
        bad = []
        for fi in range(len(faces)):
            if not alive_f[fi]:
                continue
            t = faces[fi]
            cross, s_min, _, _ = tri_quality(P[t[0]], P[t[1]], P[t[2]])
            if float(np.linalg.norm(cross)) * 0.5 < min_area or s_min < min_sin:
                bad.append(fi)
        if not bad:
            break
        fixed = 0
        for fi in bad:
            if not alive_f[fi]:
                continue
            t = faces[fi]
            for a, b in sorted(((t[0], t[1]), (t[1], t[2]), (t[2], t[0])), key=lambda e: length(*e)):
                if try_collapse(a, b):
                    fixed += 1
                    break
        log(f"{obj.name}: {len(bad)} sliver or zero-area faces, {fixed} collapsed away (sweep {sweep + 1})")
        if fixed == 0:
            for fi in bad[:6]:
                t = faces[fi]
                log(f"  {obj.name}: face {t} edges {[round(length(*e) * 1000, 2) for e in ((t[0], t[1]), (t[1], t[2]), (t[2], t[0]))]} mm: "
                    + "; ".join(f"{a}->{b} {collapse_quality(a, b)[1]}" for a, b in ((t[0], t[1]), (t[1], t[0]), (t[1], t[2]), (t[2], t[1]), (t[2], t[0]), (t[0], t[2]))))
            break
        for d, a, b in drain(alive_edges(min_edge)):
            log(f"  {obj.name}: edge {a}-{b} of {d * 1000:.2f} mm left after the sweep: {collapse_quality(a, b)[1]} / {collapse_quality(b, a)[1]}")

    # Rebuild the mesh: surviving vertices in their old order, UVs per corner, weights.
    index = {}
    coords = []
    for i in range(n):
        if alive_v[i]:
            index[i] = len(coords); coords.append(tuple(P[i]))
    tris = [[index[x] for x in faces[fi]] for fi in range(len(faces)) if alive_f[fi]]
    uvs = [fuv[fi] for fi in range(len(faces)) if alive_f[fi]]
    me = bpy.data.meshes.new(obj.data.name)
    me.from_pydata(coords, [], tris)
    # Smooth shading, as the garments came: with flat faces the exporter would split
    # every vertex per face (it keys vertices on the corner normal too). Each face keeps
    # its material slot (the UV remap works per slot).
    me.polygons.foreach_set("use_smooth", [True] * len(tris))
    me.polygons.foreach_set("material_index", [fmat[fi] for fi in range(len(faces)) if alive_f[fi]])
    me.update()
    uv = me.uv_layers.new(name="UVMap")
    uv.data.foreach_set("uv", [c for f in uvs for corner in f for c in corner])
    for mat in materials:
        me.materials.append(mat)
    old = obj.data
    obj.data = me
    bpy.data.meshes.remove(old)
    me.name = obj.name
    for name in group_names:
        obj.vertex_groups.new(name=name)
    for i in range(n):
        if alive_v[i]:
            for gi, w in weights[i].items():
                obj.vertex_groups[gi].add([index[i]], w, "REPLACE")
    log(f"{obj.name}: decimated {before[0]} verts / {before[1]} tris -> {len(coords)} verts / {len(tris)} tris ({refused} collapses refused, {tents} tents dissolved)")
    return len(coords), len(tris)


def refine_proxy(obj, target, clean_target=10000, clean_edge=0.003, min_edge=0.0045, max_edge=0.018, min_angle=10.0):
    """The 16,000-particle shirt proxy (Docs/GPUCloth.md, section 5; 2026-11-04): `obj`
    is the sewn outer layer, refined in place.

    Why a second proxy: three headset rounds read the 3,995-particle shirt as paper
    with coarse crumples that do not fall under gravity, and its resolution is one of
    the two limits (the solver is the other). At a 17.5 mm median edge the smallest
    fold the proxy can show is four or five edges long, 7-9 cm, where a shirt's folds
    read at 3-5 cm; that wants 6-10 mm spacing, four times the particles, which Jolt
    could not afford (it solves a soft body's edges on one thread) and the GPU solver
    can (a 16k frame costs about twice a 4k one, not four times). The drawn shell's
    own median edge is 8.25 mm, so 16,000 particles — 8.4 mm hexagonal spacing over
    the shirt's 0.99 m² — is where the proxy stops hiding folds the shell could draw,
    and 26,000 left 26 slivers and 10 non-manifold edges after the collapse.

    How: the outer layer is cleaned first by the existing collapse run down to
    `clean_target` vertices with `clean_edge` as its minimum (the artist's shell
    carries 1,826 triangles under 8 degrees and edges down to 0.12 mm along its seam
    and hem strips, and the midpoint split of a sliver is four slivers; the collapse to
    a target takes the strips' slivers out along the way, shortest edge first, where a
    drain of the sub-3 mm edges alone, the first try, left four slivers of 4.4 mm
    whose vertices' valence refused every collapse, and the 16k collapse could not
    finish what their quartering made: 8.2 degrees and a 3.66 mm edge were left,
    2026-11-04); then EVERY edge is split once at its midpoint
    (`bmesh.ops.subdivide_edges`, cuts 1, a triangle into four), which carries the UVs
    and the artist's weights to the new vertices (`recap_influences` cuts the five to
    eight they inherit back to four); then the collapse runs down to `target` with the
    limits `min_edge`, `max_edge` and `min_angle` — the 4k rules at half the scale —
    with `decimate_proxy`'s own partial long-edge split bypassed (see there). The
    result is one piece with the four openings, no sliver and no non-manifold edge:
    15,979 vertices and 31,681 triangles, edges 4.5 / 5.8 / 8.8 / 12.8 / 29.1 mm
    (min / p10 / median / p90 / max), the smallest angle 10.1 degrees, 8.4 s on a 44 s
    cook (2026-11-04; the collapse eases its edge limit to 39 mm where it removes an
    edge under `min_edge`, as the 4k does, which is where the few edges over `max_edge`
    come from, and five tents are dissolved on the way, see `decimate_proxy`). The
    triangle count follows the vertex count: on a genus-0 surface with four openings
    F = 2V + 4 - B, and the 281 boundary edges are twice the 4k's 142, as a halved
    spacing should give. Logs each stage's counts and seconds; `report_proxy` holds
    the result to 4-30 mm and 10 degrees afterwards."""
    t0 = time.perf_counter()
    before = (len(obj.data.vertices), len(obj.data.polygons))
    decimate_proxy(obj, clean_target, min_edge=clean_edge, split_long=False)
    t1 = time.perf_counter()
    nv, nf, emin, emed, emax, amin, angmin, nisl, nloops, e10, e90 = mesh_stats(obj)
    log(f"{obj.name} refine: cleaned to {clean_target} at {clean_edge * 1000:.0f} mm in {t1 - t0:.1f} s: {before[0]} verts / {before[1]} faces -> {nv} verts / {nf} tris, "
        f"edges {emin * 1000:.2f}/{emed * 1000:.1f}/{emax * 1000:.1f} mm, min angle {angmin:.1f}°, {nisl} island(s), {nloops} loop(s)")
    bm = bmesh.new(); bm.from_mesh(obj.data)
    bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=1, use_grid_fill=True)
    bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
    degenerate = sum(1 for f in bm.faces if f.calc_area() < 1e-10)
    non_manifold = sum(1 for e in bm.edges if not e.is_manifold and not e.is_boundary)
    split = (len(bm.verts), len(bm.faces))
    bm.to_mesh(obj.data); bm.free(); obj.data.update()
    t2 = time.perf_counter()
    log(f"{obj.name} refine: every edge split at its midpoint in {t2 - t1:.1f} s: {split[0]} verts / {split[1]} tris, "
        f"{degenerate} zero-area faces, {non_manifold} non-manifold edges")
    decimate_proxy(obj, target, min_edge=min_edge, max_edge=max_edge, min_angle=min_angle, split_long=False)
    t3 = time.perf_counter()
    nv, nf, emin, emed, emax, amin, angmin, nisl, nloops, e10, e90 = mesh_stats(obj)
    log(f"{obj.name} refine: collapsed to {target} in {t3 - t2:.1f} s ({t3 - t0:.1f} s in all): {nv} verts / {nf} tris, "
        f"edges {emin * 1000:.1f}/{e10 * 1000:.1f}/{emed * 1000:.1f}/{e90 * 1000:.1f}/{emax * 1000:.1f} mm (min/p10/median/p90/max), "
        f"min face area {amin * 1e6:.2f} mm², min angle {angmin:.1f}°, {nisl} island(s), {nloops} loop(s)")
    return nv, nf


def recap_influences(obj):
    """Four influences at most again after the decimation: the vertices it makes by
    splitting a long edge inherit the groups of both ends (up to eight), and the sidecar
    carries what the exporter's cut keeps."""
    capped, rehomed, histogram = cap_influences(obj, arm)
    log(f"{obj.name}: {capped} split vertices cut back to 4 influences ({rehomed} rehomed); influences per vertex {histogram}")


ARM_BONES = ("clavicle_", "upperarm_")
TORSO_BONES = ("spine_", "neck_", "pelvis")
# The sleeves' bones against the body panel's (the torso and the clavicles, whose region
# is the yoke): the seam between them is the armhole as a tailor would cut it, where the
# sleeve cap meets the body — not the wider set of arm-against-torso edges above, which
# also runs between the clavicle and the spine across the yoke.
SLEEVE_BONES = ("upperarm_", "lowerarm_")
BODY_BONES = TORSO_BONES + ("clavicle_",)
# Metres either side of a weight seam that are graded; the wider band around the armhole
# seam that is blurred further, and the number of passes.
SEAM_BAND = 0.06
ARMPIT_BAND = 0.12
ARMPIT_PASSES = 200
# The armhole seam (sleeve cap against body panel) as world-space segments, taken from
# the artist's weights BEFORE the grading: graded, the dominant bone flips back and forth
# across the blurred band and the "seam" between dominants zigzags three edges wide, so a
# band measured from it comes out twice as wide as asked. The artist's weights hand the
# sleeve over across single edges, which is one clean line per arm once the stray
# pockets' rims are dropped (`seam_chains`; `shirt_slack` uses it).
sleeve_seam_segments = []
# The bone that dominates each shirt particle under the ARTIST's weights (filled in the
# main flow before the proxy takes the body's): the garment's own regions — which
# particles are the sleeves — are a tailor's matter the artist's weights draw (the sleeve
# cap is handed to the upper arm at the armhole seam), where the body's weights draw the
# deltoid's skin, which reaches over the shoulder top the shirt hangs from. `shirt_slack`
# reads the sleeves from here.
artist_dominant = {}


def vertex_weights(obj):
    return {v.index: {g.group: g.weight for g in v.groups if g.weight > 0} for v in obj.data.vertices}


def dominant_group(weights):
    return max(weights, key=weights.get) if weights else None


def weight_jumps(obj, names, weights=None):
    """Per edge, the L1 distance between its ends' weight vectors, worst first, as
    (jump, (index a, index b), position a, position b, the two dominant bones)."""
    mw = obj.matrix_world
    weights = weights or vertex_weights(obj)
    jumps = []
    for e in obj.data.edges:
        a, b = e.vertices
        wa, wb = weights[a], weights[b]
        jump = sum(abs(wa.get(k, 0.0) - wb.get(k, 0.0)) for k in wa.keys() | wb.keys())
        da, db = dominant_group(wa), dominant_group(wb)
        jumps.append((jump, (a, b), mw @ obj.data.vertices[a].co, mw @ obj.data.vertices[b].co,
                      (names[da] if da is not None else None, names[db] if db is not None else None)))
    jumps.sort(key=lambda j: j[0], reverse=True)
    return jumps


def seam_edges(obj, weights, sides=None):
    """The edges whose ends are dominated by different bones; with `sides`, a pair of
    name-prefix tuples, only those with one end on each side. As world-space segments."""
    names = [g.name for g in obj.vertex_groups]
    mw = obj.matrix_world
    out = []
    for e in obj.data.edges:
        a, b = e.vertices
        da, db = dominant_group(weights[a]), dominant_group(weights[b])
        if da is None or db is None or da == db:
            continue
        if sides is not None:
            na, nb = names[da], names[db]
            if not ((na.startswith(sides[0]) and nb.startswith(sides[1])) or (nb.startswith(sides[0]) and na.startswith(sides[1]))):
                continue
        out.append((mw @ obj.data.vertices[a].co, mw @ obj.data.vertices[b].co))
    return out


def seam_chains(obj, weights, sides, keep=2):
    """The seam edges between `sides` (as `seam_edges`) grouped into connected chains,
    the `keep` largest kept as world-space segments, the rest dropped: the artist's
    automatic weights leave stray pockets of one bone's dominance inside the other's
    region (a spot of upper arm on the shoulder blade), and each pocket's rim is a
    little seam of its own that a band measured from "the seam" would wrap in. The
    armhole is two chains, one per arm. Logs the chain sizes."""
    names = [g.name for g in obj.vertex_groups]
    mw = obj.matrix_world
    pairs = []
    for e in obj.data.edges:
        a, b = e.vertices
        da, db = dominant_group(weights[a]), dominant_group(weights[b])
        if da is None or db is None or da == db:
            continue
        na, nb = names[da], names[db]
        if (na.startswith(sides[0]) and nb.startswith(sides[1])) or (nb.startswith(sides[0]) and na.startswith(sides[1])):
            pairs.append((a, b))
    parent = {}

    def find(x):
        while parent.setdefault(x, x) != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x

    for a, b in pairs:
        parent[find(a)] = find(b)
    chains = {}
    for a, b in pairs:
        chains.setdefault(find(a), []).append((a, b))
    sizes = sorted((len(c) for c in chains.values()), reverse=True)
    kept = sorted(chains.values(), key=len, reverse=True)[:keep]
    log(f"{obj.name}: seam {sides[0]} against {sides[1]}: {len(pairs)} edges in {len(chains)} chains of {sizes[:8]}{'...' if len(sizes) > 8 else ''}; the {len(kept)} largest kept")
    return [(mw @ obj.data.vertices[a].co, mw @ obj.data.vertices[b].co) for chain in kept for a, b in chain]


def within(obj, segments, distance):
    """The vertex indices within `distance` of any of the world-space `segments`."""
    mw = obj.matrix_world
    return {v.index for v in obj.data.vertices if any(segment_distance(mw @ v.co, a, b) <= distance for a, b in segments)}


def mark_sleeve_seam(obj, weights=None):
    """The armhole seam of `obj` as its weights draw it, for `shirt_slack`: returns
    (the wider arm-against-torso seam edges, the sleeve-cap-against-body-panel chains as
    world segments); fails when there is no seam of either kind. The caller keeps the
    segments (the 4k shirt's in `sleeve_seam_segments`, the 16k shirt's in its own
    list, since 2026-11-04 the two proxies each read their seam off their own artist
    weights before the body's replace them)."""
    weights = weights or vertex_weights(obj)
    armhole = seam_edges(obj, weights, sides=(ARM_BONES, TORSO_BONES))
    if not armhole:
        fail(obj.name, "has no armhole seam: no edge runs from an arm bone's vertex to a torso bone's")
    segments = seam_chains(obj, weights, sides=(SLEEVE_BONES, BODY_BONES))
    if not segments:
        fail(obj.name, "has no sleeve seam: no edge runs from an upper-arm vertex to a body-panel vertex")
    return armhole, segments


def grade_weight_seams(obj, arm, band=SEAM_BAND, blend=0.5, passes=16, trace=0.03,
                       armpit_band=ARMPIT_BAND, armpit_passes=ARMPIT_PASSES):
    """NOT RUN since the proxy took the body's weights (2026-10-31; kept for the record and
    for a cook that would grade them again): blurred weights are not the skin's, and the
    proxy's skinned positions are the body the cloth collides with — graded, the chase
    pose (arms forward, spine flexed) put 20-41 % of the yoke's, chest's and upper arms'
    particles inside the skin, the deepest 36 mm; ungraded, the body's weights leave 4 %
    of the armpit's a few millimetres in (12 mm at worst) and nothing else, at the price
    of skinned armhole edges stretching to 2.4 times their rest length at the 99th
    percentile and 9.8 at worst in that pose (1.85 and 3.9 graded), which the armhole
    band's slack absorbs. What follows is the pass as it was written for the artist's
    weights.

    The artist's automatic weights hand the shirt from one bone to the next across
    single edges: at the armhole from the upper arm (0.98) to the spine (0.73) a
    centimetre apart, and as sharply from spine_01 to spine_02 at the waist and from the
    upper arm to the forearm at the elbow. Skinned with the arms held forward, the armhole
    edges stretch to twenty times their length; the cloth keeps its rest lengths, so under
    each arm it sat 13 cm from its skinned target whatever the solver did (Mac,
    2026-10-30); the waist and the elbow do the same when the body bends or the forearm
    turns. This grades the weights across every seam, in place: a seam is an edge whose
    ends are dominated by different bones; every vertex within `band` of one has its
    weights replaced by the blend of its one-ring's (inverse edge length weighted,
    `blend` of the ring against the rest of itself) `passes` times, then the shirt is
    capped at four influences again. The passes are a blur, and their number its width:
    sixteen half-weight passes over 1.7 cm edges spread a step over about 5 cm either
    side, which fits inside the band (the vertices beyond it hold their weights) and
    stays a local ramp. Run to convergence instead, the band — three quarters of the
    shirt, since the seams at the yoke and the back lie close — becomes one harmonic
    blend of every bone around it: the upper arm's weight reached the shoulder blade
    and a pure spine_02 pocket there met it across a jump of 0.77. The armhole alone is
    then blurred further: the vertices within `armpit_band` of the armhole seam (an arm
    bone's region against a torso bone's, as the artist left it) take `armpit_passes`
    more. The chase's idle holds the arms out in front, 40 cm from where they hang in
    the bind pose, and the sleeve's underside hangs between that arm and a flank that
    did not move; the cloth keeps its rest lengths where the skinning stretches them,
    so the farthest particle from its skinned target there is what the ramp's width
    sets: 16.3 cm with the artist's weights, 9.4 after the 16 passes, 5.2 with two
    hundred more over 12 cm (ZombieClothTests measures it, on the skin alone the same
    figure: the ragdoll's capsules play no part). Wider or deeper than that it turns
    back up (6.7 cm at 300 passes over 11 cm, 7.1 at 400 over 12, the blur reaching the
    yoke and the back), and a band of 13 cm or more carries arm weight to within 20 cm
    of the pelvis, which ZombieSkinTests forbids. The blur's tails go:
    a bone left with less than `trace` of a vertex is dropped and the rest renormalised,
    since 3 % of a bone moves a vertex by nothing the eye sees and only carries a far
    bone where the prune took it off (two per cent of the upper arm had reached the
    waist, and ZombieSkinTests holds the hips to no arm weight at all). The sleeve seam
    as the artist's weights draw it, before the blur, is kept (`sleeve_seam_segments`)
    for the sidecar's armhole band (`shirt_slack`): the graded skin still stretches those
    edges most. Positions never move: the particles stay the proxy's own. Logs the worst
    jumps before and after."""
    names = [g.name for g in obj.vertex_groups]
    weights = vertex_weights(obj)
    mw = obj.matrix_world
    positions = {v.index: mw @ v.co for v in obj.data.vertices}
    seams = seam_edges(obj, weights)
    armhole_before, segments = mark_sleeve_seam(obj, weights)
    sleeve_seam_segments[:] = segments
    seam_band = within(obj, seams, band)
    armpit = within(obj, armhole_before, armpit_band)
    before = weight_jumps(obj, names, weights)

    def blur(vertices, count):
        ring = {i: [] for i in vertices}
        for e in obj.data.edges:
            a, b = e.vertices
            length = max((positions[a] - positions[b]).length, 1e-4)
            if a in ring:
                ring[a].append((b, 1.0 / length))
            if b in ring:
                ring[b].append((a, 1.0 / length))
        for _ in range(count):
            blended = {}
            for i, neighbours in ring.items():
                total = sum(w for _, w in neighbours)
                if total <= 0:
                    continue
                mixed = {k: (1.0 - blend) * w for k, w in weights[i].items()}
                for j, a in neighbours:
                    for k, w in weights[j].items():
                        mixed[k] = mixed.get(k, 0.0) + blend * a / total * w
                norm = sum(mixed.values())
                blended[i] = {k: w / norm for k, w in mixed.items() if w > 0}
            weights.update(blended)

    blur(seam_band, passes)
    blur(armpit, armpit_passes)
    graded = seam_band | armpit
    for i in graded:
        kept = {k: w for k, w in weights[i].items() if w >= trace} or dict(weights[i])
        norm = sum(kept.values())
        weights[i] = {k: w / norm for k, w in kept.items()}
        v = obj.data.vertices[i]
        for gi in [g.group for g in v.groups]:
            obj.vertex_groups[gi].remove([i])
        for gi, w in weights[i].items():
            obj.vertex_groups[gi].add([i], w, "REPLACE")
    capped, rehomed, histogram = cap_influences(obj, arm)
    after = weight_jumps(obj, names)
    armhole_after = seam_edges(obj, vertex_weights(obj), sides=(ARM_BONES, TORSO_BONES))
    log(f"{obj.name} seams: {len(seams)} edges between bones' regions ({len(armhole_before)} at the armhole, {len(sleeve_seam_segments)} of them sleeve cap against body panel), {len(seam_band)} vertices within "
        f"{band * 100:.0f} cm graded over {passes} passes, {len(armpit)} within {armpit_band * 100:.0f} cm of the armhole over {armpit_passes} more; "
        f"{capped} vertices capped back to 4 influences; influences per vertex {histogram}; "
        f"armhole seam afterwards {len(armhole_after)} edges between dominants")
    for label, jumps in (("before", before), ("after", after)):
        worst = jumps[0]
        log(f"  {obj.name} weight jumps {label}: worst {worst[0]:.3f} across {worst[1]} {tuple(round(c, 3) for c in worst[2])} ({worst[4][0]}) - "
            f"{tuple(round(c, 3) for c in worst[3])} ({worst[4][1]}); {sum(1 for j in jumps if j[0] > 0.5)} edges jump more than 0.5, "
            f"{sum(1 for j in jumps if j[0] > 0.3)} more than 0.3; next {[round(j[0], 3) for j in jumps[1:6]]}")
    return len(seams), len(graded), before[0][0], after[0][0]


def orient_outward(obj, tree):
    """Consistent face normals, pointing away from the body (the reference surface)."""
    bm = bmesh.new(); bm.from_mesh(obj.data)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()
    mw = obj.matrix_world
    vote = 0.0
    for f in bm.faces:
        c = mw @ f.calc_center_median()
        loc, _, _, _ = tree.find_nearest(c)
        d = c - loc
        if d.length > 1e-6:
            vote += f.normal.dot(d.normalized())
    if vote < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
        log(f"{obj.name}: faces flipped to point away from the body")
    bm.to_mesh(obj.data); bm.free()


def push_off_body(obj, tree, clearance=0.002, rounds=8):
    """Every vertex, edge midpoint and face centre of `obj` ends at least `clearance` off
    the body, in place: a vertex inside the body or closer than that moves out along the
    body's normal at its nearest point by the shortfall (along the normal only, so two
    vertices nearest to the same body vertex keep their own places; moved onto the
    nearest point itself they would coincide and leave zero-length edges), and an edge or
    a face whose middle sags into the body (a 40 mm chord over a thigh does) moves its
    corners out by that shortfall; a few rounds, since a move can shorten a neighbour's
    clearance. Returns (vertices moved in the first round, of which inside the body,
    corners moved for a midpoint or a centre) and fails when something stays inside."""
    bm = bmesh.new(); bm.from_mesh(obj.data)
    mw = obj.matrix_world; inv = mw.inverted()

    def shortfall(p):
        loc, nrm, _, _ = tree.find_nearest(p)
        return clearance - (p - loc).dot(nrm), nrm

    moved = inside = chords = 0
    for r in range(rounds):
        changed = 0
        for v in bm.verts:
            d, nrm = shortfall(mw @ v.co)
            if d > 0:
                v.co = inv @ (mw @ v.co + nrm * d); changed += 1
                if r == 0:
                    moved += 1; inside += d > clearance
        for e in bm.edges:
            d, nrm = shortfall(mw @ ((e.verts[0].co + e.verts[1].co) / 2))
            if d > 0:
                for v in e.verts:
                    v.co = inv @ (mw @ v.co + nrm * d)
                changed += 1; chords += 1
        for f in bm.faces:
            d, nrm = shortfall(mw @ f.calc_center_median())
            if d > 0:
                for v in f.verts:
                    v.co = inv @ (mw @ v.co + nrm * d)
                changed += 1; chords += 1
        if changed == 0:
            break
    worst = min([-shortfall(mw @ v.co)[0] for v in bm.verts]
                + [-shortfall(mw @ ((e.verts[0].co + e.verts[1].co) / 2))[0] for e in bm.edges]
                + [-shortfall(mw @ f.calc_center_median())[0] for f in bm.faces]) + clearance
    log(f"{obj.name}: {moved} vertices pushed out to {clearance * 1000:.0f} mm from the body ({inside} were inside it), "
        f"{chords} edge or face middles lifted; nearest point now {worst * 1000:.2f} mm off")
    if worst < 0:
        fail(obj.name, "still reaches into the body after the push-out")
    bm.to_mesh(obj.data); bm.free()
    return moved, inside, chords


# --- the full shirt stays for the render-binding phase ---------------------------
shirt_render = shirt.copy(); shirt_render.data = shirt.data.copy()
shirt_render.name = "Shirt_Render"; shirt_render.data.name = "Shirt_Render"
scene.collection.objects.link(shirt_render)
shirt_render.parent = arm; shirt_render.matrix_parent_inverse = arm.matrix_world.inverted()

# --- trousers: belt loops off, side seams sewn, out of the body, decimated ------
bm = bmesh.new(); bm.from_mesh(trousers.data)
parts = islands(bm)
log(f"trousers: {len(parts)} islands {[len(p) for p in parts]}")
panels = [p for p in parts if len(p) > 1000]
loops_small = [p for p in parts if len(p) <= 1000]
if len(panels) != 2 or len(loops_small) != 5:
    fail("trousers: expected two panels and five belt loops")
belt_verts = {v.index for p in loops_small for v in p}
bm.free()
# The belt loops: a copy of the trousers with the panels removed; they ride the waist as skin.
belt = trousers.copy(); belt.data = trousers.data.copy()
belt.name = "BeltLoops"; belt.data.name = "BeltLoops"
scene.collection.objects.link(belt)
belt.parent = arm; belt.matrix_parent_inverse = arm.matrix_world.inverted()
bm = bmesh.new(); bm.from_mesh(belt.data); bm.verts.ensure_lookup_table()
bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.index not in belt_verts], context="VERTS")
bm.to_mesh(belt.data); bm.free()
# The trousers: panels only, then the seams.
bm = bmesh.new(); bm.from_mesh(trousers.data); bm.verts.ensure_lookup_table()
bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.index in belt_verts], context="VERTS")
seam_verts = [v for v in bm.verts if v.is_boundary]
before_verts = len(bm.verts)
bmesh.ops.remove_doubles(bm, verts=seam_verts, dist=0.0005)
sewn = before_verts - len(bm.verts)
parts = islands(bm); loops = boundary_loops(bm)
log(f"trousers: {sewn} boundary vertices merged at 0.5 mm (the side seams); {len(parts)} island(s), {len(loops)} boundary loop(s)")
describe_loops("trousers", loops, trousers.matrix_world)
if len(parts) != 1 or len(loops) != 3:
    fail("trousers: the sewn garment must be one piece with three openings (waist and two hems)")
bm.to_mesh(trousers.data); bm.free()
# Out of the hips (144 vertices of the artist's trousers sit inside the body) before
# the decimation, and off the body again after it, when the long edges are known.
push_off_body(trousers, body_tree)
stats = mesh_stats(trousers)
log("trousers before decimation: %d verts, %d faces, edges %.1f/%.1f/%.1f mm, min area %.3f mm², min angle %.2f°"
    % (stats[0], len(trousers.data.polygons), stats[2] * 1000, stats[3] * 1000, stats[4] * 1000, stats[5] * 1e6, stats[6]))
decimate_proxy(trousers, 3000)
recap_influences(trousers)
orient_outward(trousers, body_tree)
push_off_body(trousers, body_tree)
report_proxy("trousers", trousers, loops=3)
if belt.data.vertices and len(belt.data.vertices) != len(belt_verts):
    fail("belt loops lost vertices")
log(f"belt loops: {len(belt.data.vertices)} verts, {len(belt.data.polygons)} faces, kept undecimated as rigid skin")

# --- shirt: the outer layer of the shell, decimated --------------------------------
def outer_layer(obj, body_tree, fold=0.5, margin=0.15, sew=0.0015):
    """Cut the closed two-layer shell of `obj` down to its outer layer, in place.

    The shell is one closed surface about 1 mm thick: an outer layer, an inner layer
    and, at every opening (neck, hem, cuffs, the placket edges), a rim of millimetre-wide
    faces joining them. A face is outer when its normal points away from the body — but
    not face by face: under the arm a sleeve faces the torso, and a rolled cuff faces
    every way. The vote is taken per smooth region (faces joined across edges that fold
    less than about 60 degrees; a rim meets a layer at a right angle), weighted by area:
    the sleeve's outer layer is one region and its armpit goes with it. A region whose
    vote is weaker than `margin` of its area (a rim band) is neither and goes, as do the
    buttons and the bits of thread (other islands); an outer piece cut off from the
    largest by a rim is sewn back onto it where their boundaries meet within `sew` (the
    hem strip, see below), or goes."""
    bm = bmesh.new(); bm.from_mesh(obj.data)
    parts = islands(bm)
    log(f"{obj.name}: {len(parts)} islands {[len(p) for p in parts[:8]]}...")
    main = set(v.index for v in parts[0])
    bm.faces.index_update()
    main_faces = [f for f in bm.faces if all(v.index in main for v in f.verts)]
    if sum(1 for e in bm.edges if e.is_boundary and all(v.index in main for v in e.verts)) != 0:
        fail(obj.name, "the shell is not closed")
    bmesh.ops.recalc_face_normals(bm, faces=main_faces)
    bm.normal_update()
    mw = obj.matrix_world
    in_main = {f.index for f in main_faces}
    region_of = {}; regions = []
    for f in main_faces:
        if f.index in region_of:
            continue
        region = []; stack = [f]; region_of[f.index] = len(regions)
        while stack:
            x = stack.pop(); region.append(x)
            for e in x.edges:
                for g in e.link_faces:
                    if g.index in in_main and g.index not in region_of and x.normal.dot(g.normal) > fold:
                        region_of[g.index] = len(regions); stack.append(g)
        regions.append(region)
    label = {}; outer_area = inner_area = rim_area = 0.0
    for region in regions:
        vote = area = 0.0
        for f in region:
            c = mw @ f.calc_center_median()
            loc, _, _, _ = body_tree.find_nearest(c)
            d = c - loc; a = f.calc_area(); area += a
            if d.length > 1e-6:
                vote += f.normal.dot(d.normalized()) * a
        side = 1 if vote > margin * area else (-1 if vote < -margin * area else 0)
        for f in region:
            label[f.index] = side
    # A region not voted outer that touches no inner region is part of the outer surface
    # all the same: a patch under the arm that faces the torso, a pleat, or the crease of
    # a rolled cuff, which faces every way and joins the sleeve to the roll (the real rims
    # at the openings touch both layers and stay out).
    filled = 0
    for _ in range(10):
        changed = 0
        for region in regions:
            if label[region[0].index] > 0:
                continue
            around = {label[g.index] for f in region for e in f.edges for g in e.link_faces if g.index in in_main and region_of[g.index] != region_of[f.index]}
            if 1 in around and -1 not in around:
                for f in region:
                    label[f.index] = 1
                changed += 1
        filled += changed
        if not changed:
            break
    for region in regions:
        area = sum(f.calc_area() for f in region); side = label[region[0].index]
        if side > 0: outer_area += area
        elif side < 0: inner_area += area
        else: rim_area += area
    log(f"{obj.name} shell: {len(main_faces)} faces in {len(regions)} smooth regions -> outer {sum(1 for l in label.values() if l > 0)} faces "
        f"({outer_area:.3f} m²), inner {sum(1 for l in label.values() if l < 0)} ({inner_area:.3f} m²), neither {sum(1 for l in label.values() if l == 0)} ({rim_area * 1e4:.1f} cm²); "
        f"{filled} enclosed regions filled; {sum(len(p) for p in parts[1:])} vertices of buttons and bits dropped")
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if label.get(f.index, 0) <= 0], context="FACES")
    parts = islands(bm)
    if len(parts) > 1:
        # The outer surface can come in pieces: the artist's hem is a doubled strip of
        # its own, the lowest 1.5-4 cm of the shirt, butted against the shell's bottom
        # edge with its top rim on the shell's bottom rim — two rims a fabric's
        # thickness tall, one facing up and one down, each touching an inner layer, so
        # the fill above leaves them and the strip's outer face (voted outer, clearly)
        # is cut off from the rest. Dropped, the proxy's hem stopped 9-33 mm above the
        # drawn hem and the shell's hem strip rode the boundary triangles as a 3 cm
        # lever on the hem band's 12 cm of slack (2026-10-31). The rims coincide, so
        # the strip's top edge sits on the main piece's bottom edge: each boundary
        # vertex of a loose piece is welded onto the nearest boundary vertex of the
        # main piece within `sew`, the trousers' side-seam stitch; a piece that stays
        # loose after that is a scrap and goes.
        main_boundary = [v for v in parts[0] if v.is_boundary]
        tree = KDTree(len(main_boundary))
        for i, v in enumerate(main_boundary):
            tree.insert(mw @ v.co, i)
        tree.balance()
        targets = {}; moves = []
        for p in parts[1:]:
            for v in p:
                if not v.is_boundary:
                    continue
                co, i, d = tree.find(mw @ v.co)
                if d <= sew:
                    targets[v] = main_boundary[i]; moves.append(d)
        pieces = [(len(p), min((mw @ v.co).z for v in p), max((mw @ v.co).z for v in p)) for p in parts[1:]]
        filled = []
        if targets:
            bmesh.ops.weld_verts(bm, targetmap=targets)
            # The two edges do not match vertex for vertex along their whole length:
            # where the main piece's edge steps (the placket's corner) a few vertices
            # find no partner and a sliver of a hole is left between the edges, a
            # handful of edges round and millimetres across. Those are filled; the
            # decimation collapses the slivers.
            small = [l for l in boundary_loops(bm) if len(l) <= 8]
            if small:
                filled = [(len(l), max((mw @ a.co - mw @ b.co).length for a in l for b in l)) for l in small]
                hole_edges = {e for l in small for v in l for e in v.link_edges if e.is_boundary}
                bmesh.ops.holes_fill(bm, edges=list(hole_edges), sides=8)
        parts = islands(bm)
        log(f"{obj.name} outer layer: {len(pieces)} loose piece(s) of {[n for n, _, _ in pieces]} vertices (z {min(z for _, z, _ in pieces):.3f}..{max(z for _, _, z in pieces):.3f}); "
            f"{len(targets)} boundary vertices welded onto the main piece's boundary"
            + (f" (moved {min(moves) * 1000:.2f}..{max(moves) * 1000:.2f} mm)" if moves else "")
            + f"; {len(filled)} sliver hole(s) between the edges filled {[(n, round(d * 1000, 1)) for n, d in filled]} (vertices, mm across); {len(parts)} piece(s) left")
        for p in parts[1:]:
            zs = [(mw @ v.co).z for v in p]; xs = [(mw @ v.co).x for v in p]
            log(f"{obj.name} outer layer: loose piece of {len(p)} vertices dropped (z {min(zs):.3f}..{max(zs):.3f}, x {min(xs):.3f}..{max(xs):.3f})")
        keep = set(v.index for v in parts[0])
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.index not in keep], context="VERTS")
    loops = boundary_loops(bm)
    log(f"{obj.name} outer layer: {len(bm.verts)} verts, {len(bm.faces)} faces, {len(loops)} boundary loop(s)")
    describe_loops(obj.name, loops, mw)
    bm.to_mesh(obj.data); bm.free()
    obj.data.update()


def placket_chains(loop, mw, half_width=0.035, front_y=0.06):
    """The two edges of the shirt's front in `loop` (the big boundary loop of the outer
    layer), each ordered bottom to top: the two maximal runs of loop vertices at the
    front within `half_width` of the centre line, trimmed at both ends of the steps that
    run along the hem or the collar rather than up the front."""
    n = len(loop)
    pos = [mw @ v.co for v in loop]
    marked = [abs(p.x) < half_width and p.y < front_y for p in pos]
    if all(marked) or not any(marked):
        fail("shirt: the front of the big boundary loop was not found")
    start = next(i for i in range(n) if not marked[i])
    runs = []; run = []
    for k in range(1, n + 1):
        i = (start + k) % n
        if marked[i]:
            run.append(i)
        elif run:
            runs.append(run); run = []
    if len(runs) != 2:
        fail(f"shirt: expected the two edges of the front in the big loop, found {len(runs)} runs of {[len(r) for r in runs]} vertices")

    def vertical(a, b):
        d = pos[b] - pos[a]
        return abs(d.z) >= max(abs(d.x), abs(d.y))

    chains = []
    for run in runs:
        while len(run) > 2 and not vertical(run[0], run[1]):
            run.pop(0)
        while len(run) > 2 and not vertical(run[-1], run[-2]):
            run.pop()
        chain = [loop[i] for i in run]
        if (mw @ chain[0].co).z > (mw @ chain[-1].co).z:
            chain.reverse()
        chains.append(chain)
    return chains


def sew_placket(obj, body_tree, cap=0.020, max_overlap=0.002):
    """Close the shirt's buttoned front, in place.

    The artist's shirt is buttoned: its two front panels overlap by 14 mm at the placket
    (the left panel in front, as on a man's shirt) and the seven buttons sit in the
    overlap, but the panels are separate surfaces, so the outer layer has a slit from the
    hem to the collar, and a proxy with that slit would gape in the simulation and show
    the culled chest. The two edges of the slit are found in the big boundary loop
    (`placket_chains`); the edge farther from the body belongs to the panel in front. The
    panel behind is trimmed of the faces along its edge, one ring at a time, until its
    edge no longer lies more than `max_overlap` over the panel in front (the overlap is
    measured along the front panel's own surface direction), and the two edges are then
    sewn bottom to top: starting from the nearest pair of their lower vertices (the front
    panel's placket hangs below the hem as a tab, which stays part of the hem), each
    vertex of the edge behind is welded onto the nearest vertex of the edge in front,
    the edges walked in step, as long as the pair are within `cap` of each other: at the
    top the edges part into the collar's notch, which stays open. The weld moves only the
    hidden panel's edge (by millimetres), keeps every corner's UV, so the seam is a UV
    seam between the two panels' islands, and drops the faces it degenerates; the panel
    in front keeps its placket texture, and the trimmed strip of the one behind was
    hidden under it anyway. Afterwards the big loop has become the collar and the hem."""
    bm = bmesh.new(); bm.from_mesh(obj.data)
    mw = obj.matrix_world

    def chains_now():
        loops = boundary_loops(bm)
        return placket_chains(max(loops, key=len), mw)

    def body_distance(chain):
        return sorted(body_tree.find_nearest(mw @ v.co)[3] for v in chain)[len(chain) // 2]

    def inward(v, chain_set):
        """The direction from a chain vertex into its panel (away from the chain)."""
        d = Vector()
        for e in v.link_edges:
            o = e.other_vert(v)
            if o not in chain_set:
                d += (mw @ o.co - mw @ v.co)
        return d.normalized()

    def overlap(back, front):
        """Median distance by which the back edge lies over the front panel."""
        front_set = set(front)
        values = []
        for a in back:
            b = min(front, key=lambda b: (mw @ b.co - mw @ a.co).length)
            values.append((mw @ a.co - mw @ b.co).dot(inward(b, front_set)))
        return sorted(values)[len(values) // 2]

    def distance(a, b):
        return (mw @ a.co - mw @ b.co).length

    chains = chains_now()
    front, back = sorted(chains, key=body_distance, reverse=True)
    log(f"{obj.name} front: edge in front {len(front)} verts (z {(mw @ front[0].co).z:.3f}..{(mw @ front[-1].co).z:.3f}, "
        f"{body_distance(front) * 1000:.1f} mm off the body), edge behind {len(back)} verts ({body_distance(back) * 1000:.1f} mm)")
    trimmed = 0
    for _ in range(4):
        lap = overlap(back, front)
        log(f"{obj.name} front: the panel behind reaches {lap * 1000:.1f} mm over the panel in front")
        if lap <= max_overlap:
            break
        faces = {f for v in back for f in v.link_faces}
        bmesh.ops.delete(bm, geom=list(faces), context="FACES")
        trimmed += len(faces)
        chains = chains_now()
        front, back = sorted(chains, key=body_distance, reverse=True)
    else:
        fail(obj.name, "the front panels still overlap after four trims")
    for label, chain in (("in front", front), ("behind", back)):
        ends = [tuple(round(c, 4) for c in (mw @ chain[k].co)) for k in (0, -1)]
        log(f"{obj.name} front: edge {label} now {len(chain)} verts, from {ends[0]} to {ends[1]}")
    # The seam: from the nearest pair among the lower vertices, walk both edges upward
    # and weld each vertex behind onto the vertex in front it is paired with; when the
    # edge behind has the next vertex closer to the same target, two of them share it;
    # when the edge in front has a vertex no vertex behind reaches, that vertex joins
    # the previous one (the front edge's own step closes), so no hole is left.
    i, j = min(((a, b) for a in range(min(8, len(back))) for b in range(min(12, len(front)))), key=lambda ab: distance(back[ab[0]], front[ab[1]]))
    if distance(back[i], front[j]) > cap:
        fail(obj.name, f"the front edges start {distance(back[i], front[j]) * 1000:.1f} mm apart; nothing to sew")
    target = front[j]; targets = {back[i]: target}; moves = [distance(back[i], target)]
    while i < len(back) - 1 or j < len(front) - 1:
        options = []
        if i < len(back) - 1 and j < len(front) - 1:
            options.append((distance(back[i + 1], front[j + 1]), "both"))
        if i < len(back) - 1:
            options.append((distance(back[i + 1], target), "behind"))
        if j < len(front) - 1:
            options.append((distance(back[i], front[j + 1]), "front"))
        d, step = min(options)
        if d > cap:
            log(f"{obj.name} front: the seam stops at z {(mw @ target.co).z:.3f}: the next pair are {d * 1000:.1f} mm apart (the collar's notch)")
            break
        if step == "both":
            i += 1; j += 1; target = front[j]
        elif step == "behind":
            i += 1
        else:
            j += 1; targets[front[j]] = target
            continue
        targets[back[i]] = target; moves.append(distance(back[i], target))
    bottom = min((mw @ v.co).z for v in targets.values())
    log(f"{obj.name} front: {trimmed} faces of the hidden overlap trimmed; {len(targets)} vertices welded onto the edge in front from z {bottom:.3f} to {(mw @ target.co).z:.3f} "
        f"(moved {min(moves) * 1000:.1f}/{sorted(moves)[len(moves) // 2] * 1000:.1f}/{max(moves) * 1000:.1f} mm, min/median/max), "
        f"{len(back) - 1 - i + len(front) - 1 - j} edge vertices left open at the collar's notch")
    bmesh.ops.weld_verts(bm, targetmap=targets)
    loops = boundary_loops(bm)
    describe_loops(obj.name, loops, mw)
    if len(loops) != 4:
        fail(obj.name, f"sewn front: expected the collar, the hem and two cuffs, found {len(loops)} boundary loops")
    if any(not v.is_manifold for v in bm.verts):
        fail(obj.name, f"sewn front: {sum(1 for v in bm.verts if not v.is_manifold)} non-manifold vertices")
    bm.to_mesh(obj.data); bm.free()
    obj.data.update()


# The automatic weights leave traces of the upper arms and the clavicles (2-6 %) on
# the shirt's flanks down to the waist, a fifth of a metre from the pelvis, where an arm
# swinging 30 cm drags the skinned target a centimetre and a half sideways. The prune
# above cannot reach them: the elbows hang beside the waist in the bind pose, so the
# upper arm is within REACH of the flank. The export is held to no arm weight within
# 20 cm of the pelvis (ZombieSkinTests, since such traces made the 15 cm cuff fin) and
# the proxy passed that by its vertex spacing alone — its traces sat just outside the
# 20 cm — but the shell samples the proxy's weights between its vertices
# (`transfer_weights`) and showed 34 of them inside (2026-10-31). So every arm weight
# within HIP_ARM_FREE of the pelvis goes from the proxy before the shell takes its
# weights, and the sidecar carries the same — tapered off over HIP_ARM_TAPER beyond
# that radius rather than cut, since the armpit grading's fringe (15 % of an upper arm
# at the lowest) reaches the radius, and a cut there would be a weight step of the
# kind the grading exists to remove.
HIP_ARM_FREE = 0.23
HIP_ARM_TAPER = 0.06
HIP_ARM_BONES = ("clavicle_", "upperarm_", "lowerarm_") + HAND_PREFIXES


def free_hips_of_arm_weights(obj, arm, radius=HIP_ARM_FREE, taper=HIP_ARM_TAPER):
    """Scales every weight of an arm bone (HIP_ARM_BONES) on the vertices of `obj` by
    their distance from the pelvis joint — nothing left within `radius`, untouched
    from `radius + taper` out, linear between — and renormalises the rest; a vertex
    left with nothing goes to the nearest bone. Returns (vertices changed, the largest
    weight taken off a vertex, vertices within `radius + taper`)."""
    pelvis = arm.matrix_world @ arm.data.bones["pelvis"].head_local
    segments = bone_segments(arm)
    names = [g.name for g in obj.vertex_groups]
    mw = obj.matrix_world
    changed = reached = 0; largest = 0.0
    for v in obj.data.vertices:
        p = mw @ v.co
        factor = min(max(((p - pelvis).length - radius) / taper, 0.0), 1.0)
        if factor >= 1.0:
            continue
        reached += 1
        weights = {names[g.group]: g.weight for g in v.groups if g.weight > 0}
        arm_weights = {n: w for n, w in weights.items() if n.lower().startswith(HIP_ARM_BONES)}
        if not arm_weights:
            continue
        changed += 1; largest = max(largest, max(arm_weights.values()) * (1 - factor))
        kept = {n: (w * factor if n in arm_weights else w) for n, w in weights.items()}
        kept = {n: w for n, w in kept.items() if w > 0}
        total = sum(kept.values())
        for n in weights:
            if n not in kept:
                obj.vertex_groups[n].remove([v.index])
        if total < 1e-4:
            nearest = min(segments, key=lambda n: segment_distance(p, *segments[n]))
            obj.vertex_groups[nearest].add([v.index], 1.0, "REPLACE")
        else:
            for n, w in kept.items():
                obj.vertex_groups[n].add([v.index], w / total, "REPLACE")
    return changed, largest, reached


outer_layer(shirt, body_tree)
sew_placket(shirt, body_tree)
# The 16k proxy (`refine_proxy`, below the 4k flow) starts from this very mesh — the
# sewn outer layer with the artist's cleaned weights — so the two proxies descend from
# one surface and differ only in their spacing; the copy is taken before the 4,000
# decimation, which is in place.
shirt16k = shirt.copy(); shirt16k.data = shirt.data.copy()
shirt16k.name = "Shirt16k"; shirt16k.data.name = "Shirt16k"
scene.collection.objects.link(shirt16k)
shirt16k.parent = arm; shirt16k.matrix_parent_inverse = arm.matrix_world.inverted()
decimate_proxy(shirt, 4000)

# The proxy's skinned positions are the cloth's whole picture of the body: the back stop
# holds a particle a millimetre behind its skinned position and the slack is measured
# from it. With the shirt's own weights (the artist's automatic ones) that picture leaves
# the body as soon as the pose leaves the bind pose: arms raised forward and the spine
# flexed, the skinned proxy sat up to 43 mm inside the skin at the upper arms, 27 mm at
# the chest and 17 mm at the yoke (measured on the rig, 2026-10-31), and the headset drew
# the skin over the shirt there. So the proxy takes the BODY's weights, interpolated
# from the nearest skin face as the shoes take them (`transfer_weights`): a particle's
# reference is then the skin under it, 2 mm off (`push_off_body`), in every pose alike,
# since the body and the proxy are skinned by the same weights off the same joints. The
# shirt's weights go first — a replace leaves whatever the body has no weight for — and
# the hand and finger weights the cuffs pick up at the wrists go (`unhand`), as the
# shoes'. The cap and the hip cleaning follow as before; the seam grading does not
# (`grade_weight_seams`: blurred weights put the targets inside the body). The slack
# schedule's regions stay the garment's: the sleeves and the armhole seam are read off
# the artist's weights first (`artist_dominant`, `mark_sleeve_seam`), since those hand
# the sleeve cap to the upper arm at the tailor's seam, where the body's weights hand the
# deltoid's skin over, up over the shoulder top the shirt hangs from.
recap_influences(shirt)
armhole, sleeve_seam_segments[:] = mark_sleeve_seam(shirt)
artist_names = [g.name for g in shirt.vertex_groups]
artist_dominant.clear()
artist_dominant.update({i: artist_names[dominant_group(w)] for i, w in vertex_weights(shirt).items() if w})
log(f"shirt: the artist's weights draw the armhole seam as {len(armhole)} edges between an arm bone's vertex and a torso bone's, "
    f"{len(sleeve_seam_segments)} of them sleeve cap against body panel; {sum(1 for n in artist_dominant.values() if n.startswith(SLEEVE_BONES))} sleeve particles")
for g in list(shirt.vertex_groups):
    shirt.vertex_groups.remove(g)
transfer_weights(body, shirt)
changed, rescued = unhand(shirt)
log(f"shirt: weights taken from the body (nearest skin face); {changed} vertices lost hand weights, {rescued} rehomed to the forearm; not graded")
recap_influences(shirt)
changed, largest, near = free_hips_of_arm_weights(shirt, arm)
log(f"shirt: {changed} of the {near} particles within {HIP_ARM_FREE + HIP_ARM_TAPER:.2f} m of the pelvis carried arm weight, taken off "
    f"(wholly within {HIP_ARM_FREE} m, tapered beyond; the most taken off one vertex {largest:.3f})")
orient_outward(shirt, body_tree)
push_off_body(shirt, body_tree)
report_proxy("shirt", shirt, loops=4)

# --- the 16k shirt proxy: the 4k pipeline, in the same order, on the finer mesh ------
# Docs/GPUCloth.md, section 5 (2026-11-04). The copy was taken above, after the placket
# was sewn and before the 4k decimation. From here every step is the 4k's: the artist's
# weights recapped and read for the sleeves and the armhole seam, then replaced by the
# body's (nearest skin face), the hands taken off, four influences, the hips freed of
# arm weight, the faces turned outward and the mesh pushed 2 mm off the body — only
# this proxy's seam and sleeves go into lists of its own, since `sleeve_seam_segments`
# and `artist_dominant` are the 4k's and that sidecar must cook unchanged.
refine_proxy(shirt16k, 16000)
recap_influences(shirt16k)
armhole16k, sleeve_seam_segments16k = mark_sleeve_seam(shirt16k)
names16k = [g.name for g in shirt16k.vertex_groups]
artist_dominant16k = {i: names16k[dominant_group(w)] for i, w in vertex_weights(shirt16k).items() if w}
log(f"shirt16k: the artist's weights draw the armhole seam as {len(armhole16k)} edges between an arm bone's vertex and a torso bone's, "
    f"{len(sleeve_seam_segments16k)} of them sleeve cap against body panel; {sum(1 for n in artist_dominant16k.values() if n.startswith(SLEEVE_BONES))} sleeve particles")
for g in list(shirt16k.vertex_groups):
    shirt16k.vertex_groups.remove(g)
transfer_weights(body, shirt16k)
changed, rescued = unhand(shirt16k)
log(f"shirt16k: weights taken from the body (nearest skin face); {changed} vertices lost hand weights, {rescued} rehomed to the forearm; not graded")
recap_influences(shirt16k)
changed, largest, near = free_hips_of_arm_weights(shirt16k, arm)
log(f"shirt16k: {changed} of the {near} particles within {HIP_ARM_FREE + HIP_ARM_TAPER:.2f} m of the pelvis carried arm weight, taken off "
    f"(wholly within {HIP_ARM_FREE} m, tapered beyond; the most taken off one vertex {largest:.3f})")
orient_outward(shirt16k, body_tree)
push_off_body(shirt16k, body_tree)
report_proxy("shirt16k", shirt16k, loops=4, min_edge=0.004, max_edge=0.030, min_angle=10.0)

# The shell is drawn and the proxy simulates, so the two must agree on where the body
# puts the shirt: hard skinned (the attach, a re-seat, the slack shut) every particle
# sits on its skinned position and the shell is rebuilt from those triangles; with the
# cloth off or the player out of range the shell is drawn by its own weights. Had the
# shell kept the artist's weights, cleaned but ungraded, those two pictures would differ
# by the grading (centimetres under the arms, where the grading moved the skin most) and
# the shirt would jump at every switch. So the shell takes the proxy's weights,
# interpolated from the nearest proxy face as the shoes take the body's — the inner layer
# the same face as the outer, a button the placket's — and is capped at four influences
# again, the exporter's cut. The grading itself was tuned on the proxy's 17 mm edges
# (its pass counts are a blur width in edges), so it is not rerun on the shell's 8 mm
# ones: the transfer carries the finished result.
transfer_weights(shirt, shirt_render)
capped, rehomed, histogram = cap_influences(shirt_render, arm)
log(f"{shirt_render.name}: weights taken from the shirt proxy; {capped} vertices cut to 4 influences, {rehomed} rehomed; influences per vertex {histogram}")


# ---------------------------------------------------------------- ragdoll capsule fit
# Engine space is the exporter's: Blender (x, y, z) -> (x, z, -y) at the game scale the
# meshes already have. The sidecar below and the capsule fit here both report in it.
from bpy_extras.io_utils import axis_conversion
CONVERSION = axis_conversion(from_forward="-Y", from_up="Z", to_forward="Z", to_up="Y").to_4x4()
if (CONVERSION @ Vector((1, 2, 3))) != Vector((1, 3, -2)):
    fail("axis conversion is not (x, z, -y):", CONVERSION @ Vector((1, 2, 3)))


def engine_point(p):
    q = CONVERSION @ p
    return [round(q.x, 6), round(q.y, 6), round(q.z, 6)]


def engine_matrix_column_major(m):
    """A Blender world matrix as the engine's, sixteen column-major floats: the sidecar's
    bind matrices (`garment_record`), whose frames the skin colliders' points are in."""
    e = CONVERSION @ m @ CONVERSION.inverted()
    return [round(e[r][c], 7) for c in range(4) for r in range(4)]


# The ragdoll (ZombieRagdollRig.swift) is twenty capsules on the rig's joints. Their
# sizes used to be the old mannequin's, and on this body the spine capsules reached
# 7 cm through the back of the shirt, so with ragdoll collisions on the cloth sat past its
# slack and jittered. Here every capsule is fitted to this body, in its bind pose, and the
# numbers are pasted into the rig's table (ZombieRagdollRigTests holds them to the export).
# The fit, per part: the skin its bones move (the body without hair, plus the shoes it
# wears), profiled around the capsule's own line in bins of CAPSULE_T_BIN along it and
# CAPSULE_SECTORS around it, where the skin's reach is the farthest vertex in the bin
# (teeth, tongue and eyes are never the farthest, so cavities do not fool it); the line
# runs along the bone through the mean of those profile points, or for the limbs from the
# centroid of their first third to their last third's (the shin leaves the ankle at the
# Achilles tendon, the femur is lateral in the thigh); the span is the bone, the chain's
# free ends taking the skin's extent (crown, finger tips, heel to the ball) and the pelvis
# the hips; the radius is the largest that keeps every surface sample within the skin's
# reach plus CAPSULE_SKIN_TOLERANCE and every point of both garment proxies, the shirt and
# the trousers, CAPSULE_GARMENT_MARGIN clear — the proxies' surfaces sampled on a lattice
# of GARMENT_SAMPLES_PER_EDGE points along every triangle edge (28 points a triangle), since
# the vertices alone put the surface 0.3-2.6 mm farther than it is — scanned by the
# millimetre and verified on a denser sampling. A high percentile of the radial distances,
# the first idea, pokes through the front and the back of every torso link: the torso is
# an ellipse and a capsule is round. The garment margin, a centimetre, was a cloth
# particle's collision radius when the capsules were the cloth's colliders: Jolt holds a
# particle its radius off a capsule, so a capsule any closer under a garment pushes the
# cloth off its skin before the part has moved at all — and the parts hang a finger's
# width off their joints at rest (the forearm 1 cm, the hand 3 cm, under the tight sleeve
# and its cuff). The radius is 3 mm now (ZombieCloth.Configuration.vertexRadius, since
# the skin hulls below took the capsules' job, 2026-11-02; SKIN_HULL_GARMENT_MARGIN is
# derived from it), and the centimetre stays as the capsules' margin for the ragdoll A/B
# (`-cloth ragdoll`): 7 mm more conservative than the particle needs, and lowering it to
# the hulls' margin would let the arm capsules grow — a re-cook worth making only if that
# A/B is still wanted. The trousers are
# not simulated yet, but they are in the sidecar and one configuration switch away, and a
# thigh capsule fitted to the shirt alone sat 0.7 mm through them.
CAPSULE_T_BIN = 0.01
CAPSULE_SECTORS = 24
CAPSULE_SKIN_TOLERANCE = 0.003
CAPSULE_GARMENT_MARGIN = 0.010
GARMENT_SAMPLES_PER_EDGE = 6
# A part thinner than this is no body: the clavicles, which the shirt's yoke hugs, keep it.
CAPSULE_MIN_RADIUS = 0.005
CAPSULE_SAFETY = 0.001
CAPSULE_TIP_INSET = 0.015


def capsule_frame(d):
    up = np.array([0, 1, 0.0]) if abs(d[1]) < 0.9 else np.array([1, 0, 0.0])
    u = np.cross(d, up); u /= np.linalg.norm(u)
    return u, np.cross(d, u)


def capsule_cylindrical(points, origin, d):
    """Station along the line, perpendicular offset, radius, and the (station, sector) bin."""
    u, v = capsule_frame(d)
    w = points - origin
    t = w @ d
    perp = w - np.outer(t, d)
    r = np.linalg.norm(perp, axis=1)
    sector = ((np.arctan2(perp @ v, perp @ u) + np.pi) / (2 * np.pi) * CAPSULE_SECTORS).astype(int) % CAPSULE_SECTORS
    return t, perp, r, np.floor(t / CAPSULE_T_BIN).astype(int), sector


def skin_profile(points, origin, d):
    """Per bin, (reach, index of the farthest vertex)."""
    t, perp, r, ti, si = capsule_cylindrical(points, origin, d)
    prof = {}
    for i in range(len(points)):
        key = (ti[i], si[i])
        if key not in prof or r[i] > prof[key][0]:
            prof[key] = (r[i], i)
    return prof, t, perp, r


def capsule_surface(a, b, d, r, step, around, latitudes):
    """Sample points on a capsule: rings along the cylinder a..b and over both caps."""
    u, v = capsule_frame(d)
    angles = (np.arange(around) + 0.5) / around * 2 * np.pi
    ring = np.outer(np.cos(angles), u) + np.outer(np.sin(angles), v)
    n = max(int(np.linalg.norm(b - a) / step) + 1, 2)
    out = [a + (b - a) * s + ring * r for s in np.linspace(0, 1, n)]
    for lat in np.linspace(0.15, 1.0, latitudes):
        th = lat * np.pi / 2
        out.append(a - d * (r * np.sin(th)) + ring * (r * np.cos(th)))
        out.append(b + d * (r * np.sin(th)) + ring * (r * np.cos(th)))
    return np.concatenate(out)


def points_to_segment(points, a, b):
    ab = b - a
    s = np.clip(((points - a) @ ab) / max(ab @ ab, 1e-12), 0, 1)
    return np.linalg.norm(points - (a + np.outer(s, ab)), axis=1)


def garment_surface(obj, n=GARMENT_SAMPLES_PER_EDGE):
    """The proxy's surface as points, engine space: every triangle sampled on the
    barycentric lattice with `n` steps along each edge (its corners, the vertices, among
    them) — (n + 1)(n + 2) / 2 points a triangle, 28 for six. ZombieRagdollRigTests samples
    the sidecar's triangles the same way."""
    mw = obj.matrix_world
    verts = np.array([engine_point(mw @ v.co) for v in obj.data.vertices])
    tris = np.array([list(p.vertices) for p in obj.data.polygons])
    a, b, c = verts[tris[:, 0]], verts[tris[:, 1]], verts[tris[:, 2]]
    return np.concatenate([(a * i + b * j + c * (n - i - j)) / n for i in range(n + 1) for j in range(n + 1 - i)])


def skin_by_dominant(objs):
    """Every skinned vertex of `objs` in engine space, with the name of its heaviest bone:
    (points, dominants) as arrays. The part a bone moves is the skin it dominates."""
    points, dominants = [], []
    for o in objs:
        names = [g.name for g in o.vertex_groups]
        for v in o.data.vertices:
            best = max(((g.weight, g.group) for g in v.groups), default=None)
            if best is None:
                continue
            points.append(engine_point(o.matrix_world @ v.co)); dominants.append(names[best[1]])
    return np.array(points), np.array(dominants, dtype=object)


def fit_capsules(body_objs, garment_objs, arm):
    """Logs one fitted capsule per ragdoll part (see above) and returns them by name as
    (from, to, radius) in engine space, the tips of the capsule. `garment_objs` are the
    proxies the capsules must stay CAPSULE_GARMENT_MARGIN under, the shirt and the
    trousers."""
    heads = {b.name: np.array(engine_point(arm.matrix_world @ b.head_local)) for b in arm.data.bones}
    points, dominants = skin_by_dominant(body_objs)
    garments = [(o.name, garment_surface(o)) for o in garment_objs]
    # The rig's parts: joint, the joint the bone aims at (or continues from), how the
    # line is laid (along the bone, or through the skin's centroids for a limb), the
    # span (the bone; the skin's extent from the joint for the head, from a finger's
    # width below the wrist for the palm; the heel to the ball for the foot; the hips
    # for the pelvis) and the bones whose skin is
    # the part's (the upper torso takes the clavicles' too: spine_03 alone moves little
    # more than the upper back).
    parts = [
        ("pelvis", "pelvis", ("toward", "spine_02"), "bone", ("hips", -0.12, 0.04), ["pelvis"]),
        ("spine_01", "spine_01", ("toward", "spine_02"), "bone", ("bone",), ["spine_01"]),
        ("spine_02", "spine_02", ("toward", "spine_03"), "bone", ("bone",), ["spine_02"]),
        ("spine_03", "spine_03", ("toward", "neck_01"), "bone", ("bone",), ["spine_03", "clavicle_l", "clavicle_r"]),
        ("neck_01", "neck_01", ("toward", "head"), "bone", ("bone",), ["neck_01"]),
        ("head", "head", ("continuing", "neck_01"), "bone", ("extent",), ["head"]),
    ]
    for s in ("l", "r"):
        parts += [
            (f"clavicle_{s}", f"clavicle_{s}", ("toward", f"upperarm_{s}"), "bone", ("bone",), [f"clavicle_{s}"]),
            (f"upperarm_{s}", f"upperarm_{s}", ("toward", f"lowerarm_{s}"), "skin", ("bone",), [f"upperarm_{s}"]),
            (f"lowerarm_{s}", f"lowerarm_{s}", ("toward", f"hand_{s}"), "skin", ("bone",), [f"lowerarm_{s}"]),
            (f"hand_{s}", f"hand_{s}", ("continuing", f"lowerarm_{s}"), "bone", ("palm",), [f"hand_{s}"]),
        ]
    for s in ("l", "r"):
        parts += [
            (f"thigh_{s}", f"thigh_{s}", ("toward", f"calf_{s}"), "skin", ("bone",), [f"thigh_{s}"]),
            (f"calf_{s}", f"calf_{s}", ("toward", f"foot_{s}"), "skin", ("bone",), [f"calf_{s}"]),
            (f"foot_{s}", f"foot_{s}", ("toward", f"ball_{s}"), "skin", ("heel_ball",), [f"foot_{s}", f"ball_{s}"]),
        ]

    def measure(skin, centre, d, lo, hi, r, dense):
        # Bins run from the capsule's first tip, as the test's do (ZombieRagdollRigTests
        # has only the tips), so both read the same skin reach.
        tip = centre + d * lo
        a, b = centre + d * (lo + r), centre + d * (hi - r)
        if hi - lo < 2 * r + 0.005:
            m = (lo + hi) / 2; a, b = centre + d * (m - 0.0025), centre + d * (m + 0.0025)
        prof, _, _, _ = skin_profile(skin, tip, d)
        samples = capsule_surface(a, b, d, r, 0.0025 if dense else 0.005, 96 if dense else 48, 14 if dense else 6)
        _, _, sr, sti, ssi = capsule_cylindrical(samples, tip, d)
        excess = -9.0
        for i in range(len(samples)):
            reach = prof.get((sti[i], ssi[i]))
            if reach is not None and sr[i] - reach[0] > excess:
                excess = sr[i] - reach[0]
        # The clearance per garment, the smallest first.
        clearances = sorted((points_to_segment(surface, a, b).min() - r, name) for name, surface in garments)
        return excess, clearances

    fitted = {}
    for name, joint, (how, other), line_rule, span_rule, bones in parts:
        p0 = heads[joint]
        d = (p0 - heads[other]) if how == "continuing" else (heads[other] - p0)
        bone_length = np.linalg.norm(d); d = d / bone_length
        skin = points[np.isin(dominants, bones)]
        centre, direction = p0.copy(), d.copy()
        for _ in range(3):
            prof, t, perp, r = skin_profile(skin, centre, direction)
            outer = np.array([prof[k][1] for k in prof])
            centre = centre + perp[outer].mean(axis=0)
        if line_rule == "skin":
            for _ in range(2):
                prof, t, perp, r = skin_profile(skin, centre, direction)
                outer = np.array([prof[k][1] for k in prof])
                t_outer = t[outer]; lo, hi = t_outer.min(), t_outer.max()
                first = skin[outer][t_outer < lo + (hi - lo) / 3]; last = skin[outer][t_outer > hi - (hi - lo) / 3]
                direction = last.mean(axis=0) - first.mean(axis=0); direction /= np.linalg.norm(direction)
                centre = skin[outer].mean(axis=0)
                prof, t, perp, r = skin_profile(skin, centre, direction)
                outer = np.array([prof[k][1] for k in prof])
                centre = centre + perp[outer].mean(axis=0)
        prof, t, perp, r = skin_profile(skin, centre, direction)
        outer = np.array([prof[k][1] for k in prof])
        station = (p0 - centre) @ direction
        if span_rule[0] == "bone":
            lo, hi = station, (heads[other] - centre) @ direction
        elif span_rule[0] == "extent":
            lo, hi = station, np.percentile(t[outer], 99.5) - CAPSULE_TIP_INSET
        elif span_rule[0] == "palm":
            # From a finger's width below the wrist: the hand part sits 3 cm off its
            # joint at rest (its limits), and a capsule up to the wrist reached into
            # the cuff and pushed it off its skin.
            lo, hi = station + 0.02, np.percentile(t[outer], 99.5) - CAPSULE_TIP_INSET
        elif span_rule[0] == "heel_ball":
            lo, hi = np.percentile(t[outer], 1) + CAPSULE_TIP_INSET, (heads[other] - centre) @ direction + 0.02
        else:
            lo, hi = station + span_rule[1], station + span_rule[2]
        radius = 0.0; stop = "?"
        for k in range(1, 300):
            excess, clearances = measure(skin, centre, direction, lo, hi, k * 0.001, False)
            if excess > CAPSULE_SKIN_TOLERANCE or clearances[0][0] < CAPSULE_GARMENT_MARGIN:
                stop = "the skin" if excess > CAPSULE_SKIN_TOLERANCE else "the " + clearances[0][1].lower()
                break
            radius = k * 0.001
        radius -= CAPSULE_SAFETY
        while radius > CAPSULE_MIN_RADIUS:
            excess, clearances = measure(skin, centre, direction, lo, hi, radius, True)
            if excess <= CAPSULE_SKIN_TOLERANCE and clearances[0][0] >= CAPSULE_GARMENT_MARGIN:
                break
            radius -= 0.001
        radius = max(radius, CAPSULE_MIN_RADIUS)
        excess, clearances = measure(skin, centre, direction, lo, hi, radius, True)
        tip_from, tip_to = centre + direction * lo, centre + direction * hi
        angle = math.degrees(math.acos(min(1, max(-1, float(direction @ d)))))
        fitted[name] = (tip_from, tip_to, radius)
        log(f"capsule {name}: {len(skin)} skin vertices, line {angle:.1f} deg off the bone, {hi - lo:.3f} m from {tuple(round(c, 3) for c in tip_from)} "
            f"to {tuple(round(c, 3) for c in tip_to)}, radius {radius:.3f} stopped by {stop}: skin excess {excess * 1000:+.1f} mm, "
            + ", ".join(f"{garment.lower()} clearance {c * 1000:+.1f} mm" for c, garment in sorted(clearances, key=lambda x: x[1])))
    log("capsules for ZombieRagdollRig.swift (engine space, the capsule's tips):")
    for name, (a, b, r) in fitted.items():
        log(f'  {name}: Capsule(from: SIMD3({a[0]:.3f}, {a[1]:.3f}, {a[2]:.3f}), to: SIMD3({b[0]:.3f}, {b[1]:.3f}, {b[2]:.3f}), radius: {r:.3f})')
    return fitted


fit_capsules([body, shoes], [shirt, trousers], arm)


# ---------------------------------------------------------------- skin colliders
# The shirt's particles carry the body's weights, so each one's skinned target is the skin
# 2 mm under it in every pose, and Jolt's back-stop holds a particle no more than BACKSTOP
# behind its target along the target's normal. That stands for the skin only where the
# particle sits near its target. With the arms raised the skinned targets spread (the
# proxy's edges stretch 2.4x at the 99th percentile) while the particles keep their rest
# lengths, so within the sleeves' and the armhole's slack (11 and 15 cm) a particle sits
# up to 15 cm from its target, and a stop placed at a target that far off no longer
# stands for the arm under the particle: on the headset (2026-10-31) the sleeves and the
# shoulders sank into the arm in patches during the animations, fine at the T-pose. The
# ragdoll's capsules cannot take over: they are fitted INSIDE the skin, a particle's
# radius under the garments (fit_capsules), a centimetre thin at the arms and, a circle
# inscribed in the torso's ellipse, centimetres inside its front and back. So the sidecar
# carries colliders fitted to the SKIN: for each collider bone the convex hull of the body
# vertices it moves most (its weight the heaviest), taken from the FULL body — before the
# skin under the trousers and the shoes is culled below — in the joint's bind frame (the
# very matrix the garments' bindJointWorldMatrices carry, inverted), for the game to move
# with the joint every frame as a kinematic hull on a layer only the cloth meets
# (JoltPhysicsBackend.addKinematicConvexHull takes a few dozen body-local points). The
# skin points are voxel-downsampled first — one point per voxel, the one farthest from
# the part's centroid, so the hull's vertices lie ON the skin and its faces sag inward
# between them by the chord rather than the whole hull sitting at the voxels' means —
# from SKIN_HULL_VOXEL, coarsened by SKIN_HULL_VOXEL_STEP until the hull has at most
# SKIN_HULL_MAX_POINTS vertices, then inset SKIN_HULL_INSET along each vertex's normal so
# that on a convex part the hull never stands proud of the skin. Every hull is verified
# against the full body's surface: its faces are sampled on a lattice and the signed
# distance to the skin measured (+ outside): a near-convex part's hull protrudes about a
# millimetre at most, and the hulls bridge the concavities (the armpit under the upper
# torso's, the crotch under the pelvis') from the outside, which is accepted.
# A hull is rigid on its bone while the skin it was cut from is blended: a skin vertex
# with weight w on the hull's bone and 1 - w on a neighbour moves, when the neighbour
# bends by an angle t, about (1 - w) |p - J| sin t away from where the hull carries it
# (J the neighbour's joint) — and that is where the first cook went wrong twice
# (2026-10-31, measured in ZombieClothTests on the chase's arms-forward idle, where the
# spine links bend 10-20 degrees each and the clavicles and the upper arms swing forward):
# the clavicles' skin, folded into spine_03's hull, stayed with the spine while the
# shoulders moved, so the shoulder caps had no hull under them and the armhole band sank
# 25-35 mm into clavicle skin with the nearest hull vertex 24-58 mm away (136 particles
# more than 2 mm inside the posed skin, 87 of them in clavicle skin); and the torso
# hulls' blended vertices stood 27-28 mm proud of the posed chest (within a millimetre
# at the bind pose), pushing the buttoned front 3.8 cm past its 5 mm slack. So the
# clavicles are hulls of their own (eleven hulls), and before the hull each skin point is
# pulled inward along its normal by that mismatch for a SKIN_HULL_BEND_ANGLE bend of every
# OTHER bone it carries weight for (capped at SKIN_HULL_BEND_MAX): a point its own bone
# carries alone keeps the millimetre, a point shared with a neighbour stands back from
# the skin by what the neighbour's bend could move it. The hulls thin toward the joints
# (where a near-target particle's back-stop is the skin anyway) and stay the skin along
# the bones, where the sleeves need them.
# Last, the garment margin, the rule the capsules obey (CAPSULE_GARMENT_MARGIN): a hull
# must stay SKIN_HULL_GARMENT_MARGIN under the resting shirt — the particle's collision
# radius (ZombieCloth.Configuration.vertexRadius, 3 mm) and half a millimetre — or it
# pushes the fabric off the artist's placement before the body has moved. A convex hull
# bridges every hollow of its skin from outside, and at the armpit the hollow is the
# shirt's: the upper arms' hulls stood 11 mm through the resting proxy there and the
# neck's 5 mm through the collar (measured on the sidecar, 2026-11-02), and in
# ZombieClothTests the shirt hung 3.2 mm lower at the back WITHOUT gravity, pushed at the
# armpits — where it had not moved at all before the hulls. So the proxy's surface is
# sampled as for the capsules (garment_surface) and, round by round, every sample closer
# than the margin moves the hull vertex nearest to it inward along that vertex's normal
# by the deficit and the hull is rebuilt, until every sample clears: nothing moves on the
# torso (12-26 mm clear), the vertices at the armpit end of an upper arm move in until
# they fall inside the hull (48 -> 35-37 vertices), the collar end of the neck likewise.
SKIN_HULL_GROUPS = (
    ("pelvis", ["pelvis"]),
    ("spine_01", ["spine_01"]),
    ("spine_02", ["spine_02"]),
    ("spine_03", ["spine_03"]),
    ("neck_01", ["neck_01"]),
    ("clavicle_l", ["clavicle_l"]), ("clavicle_r", ["clavicle_r"]),
    ("upperarm_l", ["upperarm_l"]), ("upperarm_r", ["upperarm_r"]),
    ("lowerarm_l", ["lowerarm_l"]), ("lowerarm_r", ["lowerarm_r"]),
)
SKIN_HULL_VOXEL = 0.015
SKIN_HULL_VOXEL_STEP = 0.0025
SKIN_HULL_MAX_POINTS = 48
SKIN_HULL_INSET = 0.001
SKIN_HULL_BEND_ANGLE = 20.0
SKIN_HULL_BEND_MAX = 0.03
SKIN_HULL_SAMPLES_PER_EDGE = 4
SKIN_HULL_GARMENT_MARGIN = 0.0035
SKIN_HULL_GARMENT_ROUNDS = 80


def voxel_extremes(points, voxel):
    """One point per occupied voxel of side `voxel`: of the voxel's points, the one
    farthest from the whole set's centroid, so a hull of the result has its vertices on
    the skin and not at the voxels' means inside it."""
    d = np.linalg.norm(points - points.mean(axis=0), axis=1)
    keys = np.floor(points / voxel).astype(np.int64)
    rep = {}
    for i, k in enumerate(map(tuple, keys)):
        if k not in rep or d[i] > d[rep[k]]:
            rep[k] = i
    return points[sorted(rep.values())]


def convex_hull(points):
    """The convex hull of `points` (an N x 3 array) by bmesh, as its vertices, their
    outward normals and its triangles (index arrays)."""
    bm = bmesh.new()
    verts = [bm.verts.new(Vector(p)) for p in points]
    res = bmesh.ops.convex_hull(bm, input=verts, use_existing_faces=False)
    # The interior and the unused sets overlap; bmesh refuses a vertex listed twice.
    inside = list({g for g in res["geom_interior"] + res["geom_unused"] if isinstance(g, bmesh.types.BMVert)})
    bmesh.ops.delete(bm, geom=inside, context="VERTS")
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()
    bm.verts.index_update()
    centre = sum((v.co for v in bm.verts), Vector()) / len(bm.verts)
    if any(not v.link_faces for v in bm.verts) or any((f.calc_center_median() - centre).dot(f.normal) <= 0 for f in bm.faces):
        fail("convex hull: a loose vertex or an inward face")
    V = np.array([v.co[:] for v in bm.verts]); N = np.array([v.normal[:] for v in bm.verts])
    T = np.array([[v.index for v in f.verts] for f in bm.faces])
    bm.free()
    return V, N, T


def hull_planes(V, T):
    """The outward planes of a hull's faces (`convex_hull`'s): unit normals and offsets,
    so that normal . p - offset is a point's signed distance to a face's plane and the
    largest over the faces a lower bound of its distance to the hull (+ outside), exact
    where a face is the nearest feature."""
    a, b, c = V[T[:, 0]], V[T[:, 1]], V[T[:, 2]]
    n = np.cross(b - a, c - a)
    n /= np.linalg.norm(n, axis=1)[:, None]
    return n, (n * a).sum(axis=1)


def skin_with_weights(obj):
    """Every skinned vertex of `obj` in engine space — its position, its unit normal, the
    name of its heaviest bone and every (bone, weight) it carries — for the skin hulls:
    the heaviest bone picks the hull, the other weights size the bend inset."""
    names = [g.name for g in obj.vertex_groups]
    mw = obj.matrix_world
    rot = mw.to_3x3().inverted().transposed()
    conv = CONVERSION.to_3x3()
    points, normals, dominants, weights = [], [], [], []
    for v in obj.data.vertices:
        groups = [(names[g.group], g.weight) for g in v.groups if g.weight > 0]
        if not groups:
            continue
        points.append(engine_point(mw @ v.co))
        normals.append(list(conv @ (rot @ v.normal).normalized()))
        dominants.append(max(groups, key=lambda g: g[1])[0])
        weights.append(groups)
    return np.array(points), np.array(normals), np.array(dominants, dtype=object), weights


def fit_skin_hulls(body_obj, garment_objs, arm):
    """The cloth's skin colliders (see above): one convex hull per SKIN_HULL_GROUPS
    entry, in the joint's bind frame, as the sidecar's "colliders" list — {"joint": the
    joint path the garments' jointPaths use, "shape": "hull", "points": flat x y z
    triples in engine space, joint-local}. `body_obj` must be the full body;
    `garment_objs` the simulated proxies the hulls must stay SKIN_HULL_GARMENT_MARGIN
    under — since 2026-11-04 BOTH shirt proxies, the 4k and the 16k, whose surfaces
    are sampled together so one set of hulls serves both sidecars (the finer proxy
    samples the same surface more closely, so where its samples come nearer a hull
    than the 4k's chords did the hull stands back a little further, and the 4k file's
    colliders move with it; the cook log says where). Each skin point is first pulled
    inward by the bend inset (the comment above), then hulled, then the hull's
    vertices inset SKIN_HULL_INSET, then pushed in wherever a garment comes closer
    than the margin. Logs each hull, its insets, its fit against the skin and its
    clearance of the garments, together and each."""
    points, normals, dominants, weights = skin_with_weights(body_obj)
    garment_surfaces = [(o.name, garment_surface(o)) for o in garment_objs]
    garment = np.concatenate([surface for _, surface in garment_surfaces])
    heads = {b.name: np.array(engine_point(arm.matrix_world @ b.head_local)) for b in arm.data.bones}
    bend = math.sin(math.radians(SKIN_HULL_BEND_ANGLE))
    tree = surface_tree([body_obj])
    to_blender = CONVERSION.inverted()
    n = SKIN_HULL_SAMPLES_PER_EDGE
    colliders = []; worst = (-9.0, None)
    for joint, groups in SKIN_HULL_GROUPS:
        bone = arm.data.bones[joint]
        bind = engine_matrix_column_major(arm.matrix_world @ bone.matrix_local)
        M = Matrix([[bind[c * 4 + r] for c in range(4)] for r in range(4)])
        to_local = M.inverted()
        Mi = np.array(to_local)
        garment_local = garment @ Mi[:3, :3].T + Mi[:3, 3]
        chosen = np.flatnonzero(np.isin(dominants, groups))
        if len(chosen) < 4:
            fail("skin hull", joint, "has", len(chosen), "skin vertices")
        # What a SKIN_HULL_BEND_ANGLE bend of each OTHER bone the point carries weight
        # for would move it, summed: the point stands back from the skin by that much.
        inset = np.array([min(SKIN_HULL_BEND_MAX, bend * sum(w * np.linalg.norm(points[i] - heads[name]) for name, w in weights[i] if name not in groups and name in heads))
                          for i in chosen])
        skin = points[chosen] - normals[chosen] * inset[:, None]
        local = np.array([(to_local @ Vector(p))[:] for p in skin])
        if np.abs(np.array([(M @ Vector(p))[:] for p in local[:64]]) - skin[:64]).max() > 1e-5:
            fail("skin hull", joint, "does not round-trip through the sidecar's bind matrix")
        voxel = SKIN_HULL_VOXEL
        while True:
            V, N, T = convex_hull(voxel_extremes(local, voxel))
            if len(V) <= SKIN_HULL_MAX_POINTS:
                break
            voxel += SKIN_HULL_VOXEL_STEP
        V = V - N * SKIN_HULL_INSET
        # The garment margin (above). Only the garment's samples near the hull can come
        # close; a deficit under a hundredth of a millimetre is the float's, not a face's.
        near = garment_local[np.all((garment_local > V.min(axis=0) - 0.05) & (garment_local < V.max(axis=0) + 0.05), axis=1)]
        clearance_before = None; clearance_after = None; pushes = 0; pushed_max = 0.0; before_count = len(V); rounds = 0
        if len(near) == 0:
            # No garment within 5 cm of the hull — a group far from every simulated garment
            # (none today: the farthest of the eleven, the pelvis, has shirt samples 30 mm
            # off) — has nothing to stay under: the push is skipped and the clearance is
            # logged as such (an empty array's min() would raise instead).
            garment_text = "no garment within 5 cm of the hull, margin not applied"
        else:
            for rounds in range(SKIN_HULL_GARMENT_ROUNDS + 1):
                fn, fo = hull_planes(V, T)
                clearance = (near @ fn.T - fo).max(axis=1)
                if clearance_before is None:
                    clearance_before = clearance.min()
                bad = np.flatnonzero(clearance < SKIN_HULL_GARMENT_MARGIN - 1e-5)
                if len(bad) == 0 or rounds == SKIN_HULL_GARMENT_ROUNDS:
                    break
                nearest = np.argmin(((near[bad][:, None, :] - V[None, :, :]) ** 2).sum(axis=2), axis=1)
                deficit = np.zeros(len(V))
                np.maximum.at(deficit, nearest, SKIN_HULL_GARMENT_MARGIN - clearance[bad])
                pushes += int((deficit > 0).sum()); pushed_max = max(pushed_max, float(deficit.max()))
                V, N, T = convex_hull(V - N * deficit[:, None])
            clearance_after = clearance.min()
            if clearance_after < SKIN_HULL_GARMENT_MARGIN - 0.001:
                fail("skin hull", joint, "stands", round(float(SKIN_HULL_GARMENT_MARGIN - clearance_after) * 1000, 2), "mm within the garment margin after", rounds, "rounds")
            # The clearance per proxy against the finished hull, so the log says which of
            # the two set the margin.
            fn, fo = hull_planes(V, T)
            each = []
            for garment_name, surface in garment_surfaces:
                local = surface @ Mi[:3, :3].T + Mi[:3, 3]
                close = local[np.all((local > V.min(axis=0) - 0.05) & (local < V.max(axis=0) + 0.05), axis=1)]
                each.append(f"{garment_name} {(close @ fn.T - fo).max(axis=1).min() * 1000:+.1f} mm" if len(close) else f"{garment_name} none within 5 cm")
            garment_text = (f"garment clearance {clearance_before * 1000:+.1f} mm -> {clearance_after * 1000:+.1f} mm after {rounds} rounds, "
                            f"{pushes} vertex pushes, the largest {pushed_max * 1000:.1f} mm (per proxy: {', '.join(each)})")
        a, b, c = V[T[:, 0]], V[T[:, 1]], V[T[:, 2]]
        samples = np.concatenate([(a * i + b * j + c * (n - i - j)) / n for i in range(n + 1) for j in range(n + 1 - i)])
        signed = np.empty(len(samples)); where = []
        for i, p in enumerate(samples):
            w = to_blender @ (M @ Vector(p))
            loc, nrm, _, dist = tree.find_nearest(w)
            signed[i] = dist if (w - loc).dot(nrm) >= 0 else -dist
            where.append(engine_point(w))
        k = int(np.argmax(signed))
        if signed[k] > worst[0]:
            worst = (signed[k], joint)
        lo, hi = V.min(axis=0), V.max(axis=0)
        log(f"skin hull {joint}: {len(skin)} skin vertices of {groups}, bend inset mean {inset.mean() * 1000:.1f} mm, max {inset.max() * 1000:.1f} mm "
            f"({100 * (inset < 0.002).mean():.0f} % of the points under 2 mm), voxel {voxel * 1000:.1f} mm -> {len(V)} points, {len(T)} faces, "
            f"extents (joint frame) x {lo[0]:+.3f}..{hi[0]:+.3f} y {lo[1]:+.3f}..{hi[1]:+.3f} z {lo[2]:+.3f}..{hi[2]:+.3f} m; "
            f"against the skin over {len(samples)} face samples: max protrusion {signed[k] * 1000:+.1f} mm at {tuple(round(x, 3) for x in where[k])}, "
            f"median depth {-np.median(signed) * 1000:.1f} mm, {100 * (signed > 0.001).mean():.0f} % of the samples more than 1 mm outside; "
            f"{garment_text}, {before_count} -> {len(V)} vertices")
        colliders.append({"joint": bone_path(bone), "shape": "hull",
                          "points": [round(float(x), 6) for p in V for x in p]})
    log(f"skin hulls: {len(colliders)} colliders, {sum(len(c['points']) // 3 for c in colliders)} points in all, "
        f"the largest protrusion {worst[0] * 1000:+.1f} mm ({worst[1]})")
    return colliders


skin_hulls = fit_skin_hulls(body, [shirt, shirt16k], arm)


def hull_plane_set(points):
    """The planes of a hull's convex surface as the GPU solver builds them at attach
    (`GPUClothSolver.HullPlaneSet`, ZombieClothGPUSolver.swift): every triple's plane
    kept when all the points lie on one side within a micrometre, oriented outward,
    deduplicated at 1e-4 in the normal and the offset, in double precision — the same
    brute force, so the sidecar's planes are the runtime's to the rounding (87 / 83 / 82
    / 88 / 66 / 84 / 82 / 66 / 70 / 60 / 64 on the eleven hulls as cooked on 2026-11-03,
    832 in all; 87 / 83 / 82 / 88 / 52 / 84 / 82 / 66 / 72 / 60 / 60, 816, once the
    hulls were fitted against both proxies on 2026-11-04 and the 16k collar pushed the
    neck's in, see `fit_skin_hulls`) and the kit can skip the few milliseconds and the
    asset test can compare. Returns one [n.x, n.y, n.z, d] per plane, a point inside
    where n . p + d < 0, in the joint's bind frame like the points, as the kernel reads
    them (nested, not flat like `points`: the design writes the plane as that quadruple
    and the asset test reads it so).
    Written to the 16k sidecar only (2026-11-04): the 4k file keeps the shape it had
    (points without planes, its garments byte for byte the cook before this one), and
    the runtime keeps computing the planes for a sidecar without them."""
    P = np.asarray(points, dtype=np.float64); n = len(P)
    idx = np.array(list(itertools.combinations(range(n), 3)))
    normals = np.cross(P[idx[:, 1]] - P[idx[:, 0]], P[idx[:, 2]] - P[idx[:, 0]])
    lengths = np.linalg.norm(normals, axis=1)
    ok = lengths >= 1e-12
    normals = normals[ok] / lengths[ok][:, None]; base = P[idx[ok, 0]]
    s = np.einsum("tnj,tj->tn", P[None, :, :] - base[:, None, :], normals)
    low, high = s.min(axis=1), s.max(axis=1)
    outward = high <= 1e-6
    inward = ~outward & (low >= -1e-6)
    normals[inward] *= -1
    keep = outward | inward
    candidates = np.concatenate([normals[keep], -(normals[keep] * base[keep]).sum(axis=1)[:, None]], axis=1)
    found = []
    for c in candidates:
        if not found or not np.any(np.all(np.abs(np.array(found) - c) <= 1e-4, axis=1)):
            found.append(c)
    return [[round(float(x), 7) for x in p] for p in found]


# The 16k sidecar's colliders: the same eleven hulls (the same points, fitted above
# against both proxies) with their planes beside the points.
colliders16k = [dict(c, planes=hull_plane_set(np.array(c["points"]).reshape(-1, 3))) for c in skin_hulls]
log(f"skin hull planes for the 16k sidecar: {[len(c['planes']) for c in colliders16k]} per hull, "
    f"{sum(len(c['planes']) for c in colliders16k)} in all (the 2n - 4 bound {sum(2 * len(c['points']) // 3 - 4 for c in skin_hulls)})")


# ---------------------------------------------------------------- UVs into the atlas
# Eyes: the eye faces use the face textures; the cornea shell goes.
cornea_slot = slot_index(eyes, "cornea")
eye_slots = {i: "face" for i in range(len(eyes.material_slots)) if i != cornea_slot}
remap_uvs(eyes, eye_slots)
delete_faces(eyes, [p.index for p in eyes.data.polygons if p.material_index == cornea_slot])
log(f"eyes: cornea slot {cornea_slot} removed, {len(eyes.data.polygons)} faces left")
# Shoes: the old clothes tile. Belt loops, trousers: the trousers quarter. Shirt and its
# render shell: the shirt quarter.
remap_uvs(shoes, {i: "clothes" for i in range(len(shoes.material_slots))})
for o in (belt, trousers):
    remap_uvs(o, {i: "trousers" for i in range(len(o.material_slots))})
for o in (shirt, shirt16k, shirt_render):
    remap_uvs(o, {i: "shirt" for i in range(len(o.material_slots))})

# The skin under the trousers and the shoes goes: it is never seen, and where the two
# meshes bend apart it is what pokes through. A face is covered when a ray from its
# centre along its normal meets the clothes within `reach`; a one-face ring stays under
# every edge of the clothes, so a hem that lifts a little shows skin, not a hole. The
# hands and wrists are never culled: the rolled cuffs stand off the arm, and when the
# hand bends away from a cuff the skin under it shows — culled, it showed the inside of
# the cuff through a hole (headset, 2026-10-27). The skin under the SHIRT stays: the
# shirt is simulated cloth that hangs off the body — it swings, sags and is dented, and
# where it leaves the torso the torso must be there — and where the body presses into
# the cloth the back-stop (BACKSTOP, below) holds each particle within a millimetre
# behind its skinned position, which the push-out put 2 mm off the skin, so the proxy
# and the shell's outer layer on it stay off the body. The cover is the trousers proxy
# and the rigid clothing.
def covered_faces(obj, tree, reach=0.04, keep_groups=(), keep_near=(), keep_radius=0.08):
    mw = obj.matrix_world; nm = mw.to_3x3().inverted().transposed()
    names = [g.name for g in obj.vertex_groups]
    keep_index = {i for i, n in enumerate(names) if n.lower().startswith(keep_groups)}
    kept_vertices = set()
    for v in obj.data.vertices:
        if any(g.group in keep_index and g.weight > 0 for g in v.groups) \
           or any((mw @ v.co - point).length < keep_radius for point in keep_near):
            kept_vertices.add(v.index)
    covered = set()
    for p in obj.data.polygons:
        if any(v in kept_vertices for v in p.vertices):
            continue
        c = mw @ p.center; n = (nm @ p.normal).normalized()
        if tree.ray_cast(c + n * 0.001, n, reach)[0] is not None:
            covered.add(p.index)
    exposed_vertices = {v for p in obj.data.polygons if p.index not in covered for v in p.vertices}
    return [i for i in covered if not any(v in exposed_vertices for v in obj.data.polygons[i].vertices)]

wrists = [arm.matrix_world @ arm.data.bones[name].head_local for name in ("hand_l", "hand_r")]
hidden = covered_faces(body, surface_tree([trousers, shoes, belt]), keep_groups=HAND_PREFIXES, keep_near=wrists)
delete_faces(body, hidden)
log(f"body: {len(hidden)} faces under the trousers and the shoes removed, {len(body.data.polygons)} left (the skin under the shirt stays)")


# ---------------------------------------------------------------- cloth sidecar data
# In engine space (CONVERSION, above). The particles are the proxy vertices before the
# join (the join keeps every vertex where it is), the triangles the proxy faces,
# counter-clockwise seen from outside the garment (the faces point away from the body,
# see orient_outward).
def ring(bm, seeds, depth):
    """`seeds` plus the vertices within `depth` edges of them."""
    out = set(seeds); frontier = set(seeds)
    for _ in range(depth):
        nxt = set()
        for v in frontier:
            for e in v.link_edges:
                o = e.other_vert(v)
                if o not in out:
                    out.add(o); nxt.add(o)
        frontier = nxt
    return out


# How far BEHIND its skinned position a particle may be pushed: Jolt's back stop is a
# sphere (a plane, at its default radius) whose surface starts this far behind the
# skinned vertex, against its normal, and a particle inside it is pushed back out. The
# push-out above leaves every particle 2 mm off the body, so the stop is what the skin
# kept under the shirt (`covered_faces`) can be seen through: at 3 mm (with the proxy
# drawn and the skin under it culled) the stop sat 1 mm inside the skin, and at 5 mm,
# the first cook with the skin kept, 3 mm inside it — and Jolt switches a stop off
# where it is not short of the slack, so 5 mm also switched the buttoned front's off
# (2026-10-31). One millimetre keeps the proxy, and the shell's outer layer on it, a
# millimetre off the skin wherever the body presses into the cloth; the inner layer, a
# millimetre inside the proxy, may touch the skin and is never seen.
BACKSTOP = 0.001


def constraint_counts(triangles, count, pins):
    """The constraint graph the GPU solver builds from a garment at attach
    (`GPUClothSolver.ConstraintGraph`, ZombieClothGPUSolver.swift), counted here the
    same way so the 16k sidecar can carry the figures and the asset test can hold the
    kit's build to them (Docs/GPUCloth.md, section 5; 2026-11-04): the unique edges of
    the faces (one stretch constraint each) and those on the boundary; the interior
    edges whose two opposite vertices differ (one bend pair each, across the edge);
    the edges and the pairs dropped for having a pin at both ends (a pin has no
    inverse mass, Jolt's rule, SoftBodySharedSettings.cpp:218); what is kept; the CSR
    entries, two per kept constraint; and the most on one particle. The keys are the
    kit's names. On the 4k shirt the figures are 11,849 edges, 142 on the boundary,
    11,707 pairs, 1,424 and 1,282 dropped, 10,425 + 10,425 kept, 41,700 entries and 22
    at most. The shear split of the pairs (Jolt's 8 degree quad test) is not here: the
    kit decides it in single precision and a double-precision count puts one pair of
    the 4k shirt's on the other side."""
    sides = {}
    for x, y, z in triangles:
        corners = (x, y, z)
        for i in range(3):
            a, b, o = corners[i], corners[(i + 1) % 3], corners[(i + 2) % 3]
            sides.setdefault((min(a, b), max(a, b)), []).append(o)
    boundary = pairs = pin_edges = pin_pairs = edges_kept = pairs_kept = 0
    degree = [0] * count
    for (a, b), opposite in sides.items():
        if len(opposite) == 1:
            boundary += 1
        if len(opposite) >= 2 and opposite[0] != opposite[1]:
            pairs += 1
            o0, o1 = opposite[0], opposite[1]
            if o0 in pins and o1 in pins:
                pin_pairs += 1
            else:
                pairs_kept += 1; degree[o0] += 1; degree[o1] += 1
        if a in pins and b in pins:
            pin_edges += 1
        else:
            edges_kept += 1; degree[a] += 1; degree[b] += 1
    # The design's single `pinPinDropped` (section 5) is the sum of the two drops; the
    # kit names them apart and the asset test holds the file to exactly these nine keys.
    return {"edges": len(sides), "boundaryEdges": boundary, "bendPairs": pairs,
            "pinPinEdgesDropped": pin_edges, "pinPinBendPairsDropped": pin_pairs,
            "stretchConstraints": edges_kept, "bendConstraints": pairs_kept,
            "entries": 2 * (edges_kept + pairs_kept), "maxEntriesPerParticle": max(degree)}


def garment_record(obj, name, slack, render=None, extended=False):
    """The sidecar entry for a proxy: `slack(bm, loops)` returns the per-vertex
    maxDistance list (0 pins), the per-vertex region name and the region name table.
    The faces are wound consistently and point away from the
    body on the whole (orient_outward), but not every one does: the rolled cuffs and the
    inside of the collar wrap back towards the arm and the neck. A back-stop placed
    behind the face would sit on the wrong side of those particles, so the ones whose
    normal points at the body are listed (`bodyFacingParticles`) for the game to put
    their back-stop on the body side. `render`, when given, is the drawn shell's binding
    to this proxy (`render_binding`), written under the garment as "render".

    `extended` (the 16k sidecar, Docs/GPUCloth.md section 5, 2026-11-04) adds what the
    GPU solver otherwise derives at attach, so the kit can skip the work and the asset
    test can hold the kit's build to the cook's: `restNormal` per particle, the
    area-weighted normal of its rest faces in engine space (the sum of the faces'
    cross products, outward by the winding, normalised), which the predict kernel
    rotates into the back-stop normal; `regions`, the slack schedule's band names in
    SLACK's order, and `region` per particle, its index into them, so a band can be
    stiffened or softened by name (the kernel's `regionScale`); and `constraintCounts`
    (`constraint_counts`). The 4k sidecar's garments do without them, byte for byte as
    before, and the runtime computes them for a sidecar that lacks them."""
    mw = obj.matrix_world
    if max(abs(x - y) for r0, r1 in zip(mw, Matrix.Identity(4)) for x, y in zip(r0, r1)) > 1e-5:
        fail(obj.name, "is not at the origin; the exporter would bake another transform")
    bm = bmesh.new(); bm.from_mesh(obj.data); bm.verts.ensure_lookup_table()
    bm.normal_update()
    loops = boundary_loops(bm)
    max_distance, region_names, region_table = slack(bm, loops)
    body_facing = []
    for v in bm.verts:
        p = mw @ v.co
        loc, nrm, _, _ = body_tree.find_nearest(p)
        if v.normal.dot(nrm) < 0:
            body_facing.append(v.index)
    bm.free()
    me = obj.data
    names = [g.name for g in obj.vertex_groups]
    bone_order = {b.name: i for i, b in enumerate(arm.data.bones)}
    used = sorted({names[g.group] for v in me.vertices for g in v.groups if g.weight > 0}, key=bone_order.get)
    if any(n not in bone_order for n in used):
        fail(obj.name, "weights on a group that is not a bone:", [n for n in used if n not in bone_order])
    joint_index = {n: i for i, n in enumerate(used)}
    influences = []; dominant = []
    for v in me.vertices:
        ws = sorted(((g.weight, names[g.group]) for g in v.groups if g.weight > 0), reverse=True)
        if not ws or len(ws) > 4:
            fail(obj.name, f"vertex {v.index} has {len(ws)} influences")
        total = sum(w for w, _ in ws)
        influences.append([[joint_index[n], round(w / total, 6)] for w, n in ws])
        dominant.append(joint_index[ws[0][1]])
    triangles = []
    for p in me.polygons:
        if len(p.vertices) != 3:
            fail(obj.name, "is not a triangle mesh")
        triangles.append(list(p.vertices))
    pins = sum(1 for d in max_distance if d == 0)
    log(f"{name} sidecar: {len(me.vertices)} particles, {len(triangles)} triangles, {len(used)} joints, {pins} pins, "
        f"slack histogram {dict(sorted(((round(d, 3), max_distance.count(d)) for d in set(max_distance))))}, "
        f"{len(body_facing)} particles face the body")
    record = {
        "name": name,
        "particles": [engine_point(mw @ v.co) for v in me.vertices],
        "triangles": triangles,
        "jointPaths": [bone_path(arm.data.bones[n]) for n in used],
        "influences": influences,
        "maxDistance": [round(d, 4) for d in max_distance],
        "backstop": BACKSTOP,
        "bodyFacingParticles": body_facing,
        "pinCount": pins,
        "dominantJoint": dominant,
        "bindJointWorldMatrices": [engine_matrix_column_major(arm.matrix_world @ arm.data.bones[n].matrix_local) for n in used],
    }
    if render is not None:
        record["render"] = render
    if extended:
        P = np.array(record["particles"], dtype=np.float64); T = np.array(triangles)
        face_normals = np.cross(P[T[:, 1]] - P[T[:, 0]], P[T[:, 2]] - P[T[:, 0]])  # twice the area, outward
        vertex_normals = np.zeros_like(P)
        for k in range(3):
            np.add.at(vertex_normals, T[:, k], face_normals)
        lengths = np.linalg.norm(vertex_normals, axis=1)
        if lengths.min() <= 0:
            fail(obj.name, "a particle has no rest normal (no face, or faces that cancel)")
        vertex_normals /= lengths[:, None]
        pins = {i for i, d in enumerate(max_distance) if d == 0}
        counts = constraint_counts(triangles, len(me.vertices), pins)
        record["restNormal"] = [[round(float(c), 7) for c in n] for n in vertex_normals]
        record["regions"] = list(region_table)
        record["region"] = [region_table.index(r) for r in region_names]
        record["constraintCounts"] = counts
        log(f"{name} sidecar (extended): regions {dict((r, region_names.count(r)) for r in region_table)}; "
            f"constraint graph {counts}; rest normals unit within {abs(np.linalg.norm(np.array(record['restNormal']), axis=1) - 1).max():.1e}")
    return record


def surface_distances(bm, seeds, limit):
    """Dijkstra over the edges from `seeds` (BMVerts at distance 0): {BMVert: distance
    along the surface} for every vertex within `limit`. Edge paths overestimate the true
    geodesic by a few per cent on a triangle mesh, close enough for a band's width."""
    bm.verts.ensure_lookup_table()
    dist = {v: 0.0 for v in seeds}
    heap = [(0.0, v.index) for v in seeds]
    heapq.heapify(heap)
    while heap:
        d, i = heapq.heappop(heap)
        v = bm.verts[i]
        if d > dist.get(v, math.inf):
            continue
        for e in v.link_edges:
            o = e.other_vert(v); nd = d + e.calc_length()
            if nd <= limit and nd < dist.get(o, math.inf):
                dist[o] = nd
                heapq.heappush(heap, (nd, o.index))
    return dist


# The shirt's slack schedule, metres (0 pins), and the bands that place it, along the
# surface (`surface_distances`) where a band is measured from a loop or a seam. The
# headset showed the shirt as a second skin — the same 3 cm everywhere — with a
# sawtooth collar and cuffs fighting the hands (2026-10-30): a shirt hangs from its
# shoulders. So the collar band (the collar, its stand and its points, within
# COLLAR_BAND of the collar loop) and the cuffs (the whole rolled cuff: every particle
# within CUFF_BAND up the forearm's axis of the cuff loop's plane and within CUFF_RADIUS
# of the axis, both layers of the roll) are hard skinned and follow the body exactly —
# the rolled cuffs ride the forearm's animation and never fight the hand parts' tracking
# error — and the wrist band above them (the next CUFF_GRADE up the axis) is held to
# 3 cm, the step from the pins to the sleeve's 11. Until 2026-11-03 the cuffs were
# measured along the surface from the cuff loop, and a rolled cuff is two layers: the
# roll's outer layer lay within 6 cm of its free edge and the sleeve's own end under it
# did not (over the roll and back is 8 cm), so at the same height a third of the
# particles were pinned and the rest had the sleeve's 11 cm, and 36 triangles had a
# pinned corner and a free one. When the forearm swung, the pinned corners went with the
# bone and the free ones lagged or were shoved by the forearm's hull, the triangles
# sheared, and the drawn shirt bound to them tore into flat shards around the wrist
# (headset, 2026-11-03). The yoke (the back and the
# shoulder tops within YOKE_BAND below the collar band, not the chest) is held to 7 cm
# (1 cm over 12 cm until 2026-10-31: with the arms forward the shoulder blades spread
# under the skin and the yoke's lateral edge sat 4.4-6.3 cm from its targets — the
# figure moves with the slack around it, the cloth settling where the whole lets it —
# a fight on anything tighter; the collar band's pins, 8 cm out from the neck, are what
# the shirt hangs from, and the yoke's 7 cm keep it on the shoulders through a swing);
# below it the chest (9 cm), the back (10) and the hem band (the lowest HEM_BAND of the
# body panels, 12) hang freer the lower they are, the sleeves swing on 11 cm (7.3-10.7 cm
# off their targets under the raised arms, beside the armhole band) and the armhole band (within
# ARMHOLE_BAND of the sleeve seam, the armpit, where the skin's weights stretch the
# skinned edges most) on 15 (see SLACK); the buttoned front keeps its 5 mm, since the
# buttons hold the panels to the chest. The chest is what lies in
# front of the torso's axis below the shoulder line, the back what lies behind it.
# The armhole band's 15 cm (2026-10-31): with the body's weights on the proxy, ungraded,
# the skinned armhole edges stretch to 2.4 times their rest length at the 99th percentile
# in the arms-forward chase pose (9.8 at worst), and the cloth, which keeps its rest
# lengths, settles up to 15.5 cm from its targets under the arms; on 6 cm the clamp
# pulled those particles back every pass and the edges pulled them out again — the fight
# the headset showed as jitter — so the band's slack covers that stretch all but a
# centimetre (the cloth settles farther the looser the regions around it: 11.5, 13.0,
# 14.0, 15.5 cm as the band widened and the sleeves and the yoke opened, so the slack is
# set where that settling has all but stopped), while the back-stop alone keeps it off
# the skin. It is the armpit: the shoulder tops
# are the yoke's (taken first), so nothing that shows hangs on it. The band is 10 cm
# wide (ARMHOLE_BAND): the stretch reaches that far from the seam — at 6 cm the sleeve
# beside the band sat 7.3, then 10.7, then 13.1 cm off its targets as its own slack was
# opened (the cloth settles where the whole lets it), so the band takes that zone and the
# sleeve's 11 cm cover what lies beyond.
SLACK = {"collar": 0.0, "cuff": 0.0, "wrist": 0.03, "placket": 0.005, "yoke": 0.07, "sleeve": 0.11, "armhole": 0.15, "chest": 0.09, "back": 0.10, "hem": 0.12}
COLLAR_BAND = 0.08
CUFF_BAND = 0.06
CUFF_RADIUS = 0.10
CUFF_GRADE = 0.03
YOKE_BAND = 0.10
HEM_BAND = 0.12
ARMHOLE_BAND = 0.10
# The armhole band stays off the centre of the chest: the artist's seam chain meanders
# from the shoulder down the flank and makes a side trip across the pectoral (the
# automatic weights bleed a little upper arm there), so without the cut a dozen particles
# at 5-8 cm from the centre line got the band's slack (2026-10-31); the armhole itself
# lies farther out than this from the centre line.
ARMHOLE_MIN_X = 0.09
# Blender y of the torso's axis (the spine runs at y 0.10-0.14, the chest in front of
# it at smaller y) and Blender z of the shoulder line (the upper arms start at 1.41):
# above it a yoke vertex is a shoulder top whatever its y.
TORSO_AXIS_Y = 0.10
SHOULDER_Z = 1.40
PLACKET_HALF_WIDTH = 0.02
PLACKET_FRONT_Y = 0.06


# The buttons on the fabric: a button floating more than BUTTON_SEAT off it is seated on
# it (seat_buttons), its bits of thread — the islands within BUTTON_BITS of its centre —
# with it; and the fabric within BUTTON_PATCH of a button's centre binds to the button's
# triangle (render_binding), a rigid patch under it.
BUTTON_SEAT = 0.0005
BUTTON_BITS = 0.012
BUTTON_PATCH = 0.010


def render_binding(shell, proxy):
    """The drawn shell's binding to the simulated proxy, at the bind pose, as the sidecar's
    "render" block (engine space where a position is stored; a frame coordinate is the
    same in both spaces, the axis conversion being a rotation).

    Every shell vertex binds to the proxy triangle nearest to it by point-to-triangle
    distance (the inner layer to the same outer-proxy triangle as the outer, a millimetre
    farther), at the barycentric coordinates of the closest point, with its rest offset
    from that point expressed in the triangle's frame — e1 along the first edge, n the
    face normal, t across — so a triangle that tilts or moves carries the vertex
    rigidly: position = bary(a, b, c) + off.x e1 + off.y n + off.z t. The normals are
    not here: the exporter writes a normal per face corner and splits a vertex whose
    corners disagree — on the artist's sharp edges, the cuff rolls, the placket's edge
    and the collar's creases, a thousand of the shell's vertices become two or more with
    normals up to 170 degrees apart — so one rest normal per vertex (the smooth one, the
    first cook's) lit those creases flat whenever the cloth was on while the body's own
    skinning showed them (2026-10-31). The game reads each exported copy's normal off
    the mesh and carries it in the same frame (ZombieCloth.RenderShell), which keeps
    the cloth on and the cloth off lit alike. The buttons and the bits of thread (every
    island but the largest) are rigid: all the vertices of one bind to the single
    triangle nearest the island's centre, so the island keeps its shape whatever the
    cloth under it does. The fabric under a button is rigid with it: on the headset
    (2026-10-31) the buttons sat half inside the fabric, since the fabric under a button
    followed its own nearest triangles while the button followed one, and the placket's
    triangles tilt against each other within its 5 mm of slack; so the islands are
    grouped by proximity (a button's two bits of thread sit within BUTTON_BITS of its
    centre), every island of a group takes the largest's triangle, and every fabric
    vertex within BUTTON_PATCH of any of the group's centres takes it too, bound at the
    closest point on that triangle — button, thread and the fabric they sit on move as
    one piece. The vertices are written main island first, then each rigid
    island whole, and `rigidIslands` gives each one's [first, count]; the rest positions
    are what the game binds to the exported vertices by position (the exporter splits
    vertices on UV seams and sharp edges, so one maps to several); the shell's
    triangles are not needed, the mesh has them. The arrays are flat triples (x y z,
    u v w) for a compact file. Logs the binding's figures, the sharp edges, and checks
    that the rounded numbers rebuild every vertex within a twentieth of a millimetre."""
    for o in (shell, proxy):
        if max(abs(x - y) for r0, r1 in zip(o.matrix_world, Matrix.Identity(4)) for x, y in zip(r0, r1)) > 1e-5:
            fail(o.name, "is not at the origin; the binding would be in another frame than the export")
    pm = proxy.data
    PV = np.array([v.co[:] for v in pm.vertices], dtype=np.float64)
    PT = np.array([list(p.vertices) for p in pm.polygons])
    if PT.shape[1] != 3:
        fail(proxy.name, "is not a triangle mesh")
    tree = BVHTree.FromPolygons([tuple(p) for p in PV], [tuple(int(i) for i in t) for t in PT])
    sm = shell.data
    SV = np.array([v.co[:] for v in sm.vertices], dtype=np.float64)
    sharp = sm.attributes.get("sharp_edge")
    sharp_edges = [e for e, a in zip(sm.edges, sharp.data) if a.value] if sharp is not None else []
    log(f"{shell.name}: {len(sharp_edges)} sharp edges on {len({i for e in sharp_edges for i in e.vertices})} vertices, "
        f"{sum(1 for p in sm.polygons if not p.use_smooth)} flat faces, custom normals {sm.has_custom_normals}: the exporter splits their corners; the game carries each copy's own normal")
    bm = bmesh.new(); bm.from_mesh(sm)
    parts = [[v.index for v in part] for part in islands(bm)]
    bm.free()
    order = list(parts[0]); rigid = []
    for part in parts[1:]:
        rigid.append((len(order), len(part))); order.extend(part)
    order = np.array(order)
    n = len(order); main_count = len(parts[0])
    tri = np.empty(n, dtype=np.int64); closest = np.empty((n, 3))
    for k in range(main_count):
        loc, _, index, _ = tree.find_nearest(Vector(SV[order[k]]))
        tri[k] = index; closest[k] = loc[:]
    for start, count in rigid:
        centre = SV[order[start:start + count]].mean(axis=0)
        loc, _, index, _ = tree.find_nearest(Vector(centre))
        tri[start:start + count] = index; closest[start:start + count] = loc[:]
    # The button patches (BUTTON_PATCH, above): islands within BUTTON_BITS of each other
    # are one group; the group's smaller islands and the fabric within BUTTON_PATCH of
    # any of its centres take the largest island's triangle, at the closest point on it,
    # so bary and offset follow and the rebuild check below holds as before.
    centres = [SV[order[s:s + c]].mean(axis=0) for s, c in rigid]
    link = list(range(len(rigid)))

    def group_of(i):
        while link[i] != i:
            link[i] = link[link[i]]; i = link[i]
        return i

    for i in range(len(rigid)):
        for j in range(i + 1, len(rigid)):
            if np.linalg.norm(centres[i] - centres[j]) < BUTTON_BITS:
                link[group_of(i)] = group_of(j)
    groups = {}
    for i in range(len(rigid)):
        groups.setdefault(group_of(i), []).append(i)
    fabric = KDTree(main_count)
    for k in range(main_count):
        fabric.insert(Vector(SV[order[k]]), k)
    fabric.balance()
    patches = []
    for members in groups.values():
        lead = max(members, key=lambda i: rigid[i][1])
        t = tri[rigid[lead][0]]
        a, b, c = (Vector(PV[PT[t, i]]) for i in range(3))
        for i in members:
            if i != lead:
                s, cnt = rigid[i]
                tri[s:s + cnt] = t; closest[s:s + cnt] = closest_point_on_tri(Vector(centres[i]), a, b, c)[:]
        hit = {k for i in members for _, k, _ in fabric.find_range(Vector(centres[i]), BUTTON_PATCH)}
        for k in hit:
            tri[k] = t; closest[k] = closest_point_on_tri(Vector(SV[order[k]]), a, b, c)[:]
        s, cnt = rigid[lead]
        reach = np.linalg.norm(SV[order[s:s + cnt]] - centres[lead], axis=1).max()
        patches.append((cnt, len(members) - 1, len(hit), reach))
    A, B, C = PV[PT[tri, 0]], PV[PT[tri, 1]], PV[PT[tri, 2]]
    e1 = B - A; e1 /= np.linalg.norm(e1, axis=1)[:, None]
    nn = np.cross(e1, C - A); nn /= np.linalg.norm(nn, axis=1)[:, None]
    tt = np.cross(nn, e1)
    v0, v1, v2 = B - A, C - A, closest - A
    d00, d01, d11 = (v0 * v0).sum(1), (v0 * v1).sum(1), (v1 * v1).sum(1)
    d20, d21 = (v2 * v0).sum(1), (v2 * v1).sum(1)
    den = d00 * d11 - d01 * d01
    bv = (d11 * d20 - d01 * d21) / den; bw = (d00 * d21 - d01 * d20) / den
    bary = np.stack([1 - bv - bw, bv, bw], axis=1)
    if bary.min() < -1e-4 or bary.max() > 1 + 1e-4:
        fail(shell.name, f"a closest point lies outside its triangle: barycentric {bary.min():.5f}..{bary.max():.5f}")
    bary = np.clip(bary, 0, 1); bary /= bary.sum(axis=1)[:, None]
    X = SV[order]
    d = X - closest
    offset = np.stack([(d * e1).sum(1), (d * nn).sum(1), (d * tt).sum(1)], axis=1)
    bary_r, offset_r = np.round(bary, 6), np.round(offset, 6)
    rebuilt = bary_r[:, 0:1] * A + bary_r[:, 1:2] * B + bary_r[:, 2:3] * C + offset_r[:, 0:1] * e1 + offset_r[:, 1:2] * nn + offset_r[:, 2:3] * tt
    position_error = np.linalg.norm(rebuilt - X, axis=1)
    distance = np.linalg.norm(d, axis=1)
    farthest = np.argsort(distance[:main_count])[-3:][::-1]
    # A shell vertex below the lowest corner of its triangle hangs off the proxy's edge
    # as a lever: the hem, when the outer-layer cut dropped the hem strip, hung 9-33 mm
    # below (see outer_layer).
    below = (np.minimum(np.minimum(A[:, 2], B[:, 2]), C[:, 2]) - X[:, 2])[:main_count]
    log(f"{shell.name} render binding: {n} vertices ({main_count} in the shell, {len(rigid)} rigid islands of {sorted(set(c for _, c in rigid), reverse=True)} vertices) "
        f"on {len(set(tri.tolist()))} of the proxy's {len(PT)} triangles; offset from the closest point median {np.median(distance) * 1000:.2f} mm, "
        f"max {distance.max() * 1000:.1f} mm; along the normal {offset[:, 1].min() * 1000:+.1f}..{offset[:, 1].max() * 1000:+.1f} mm "
        f"({100 * (offset[:, 1] < -0.0005).mean():.0f} % of the vertices more than 0.5 mm inside: the inner layer); "
        f"rebuilt from the rounded numbers within {position_error.max() * 1000:.4f} mm; "
        f"shell vertices farthest from the proxy: " + ", ".join(f"{distance[k] * 1000:.1f} mm at {tuple(round(float(c), 3) for c in X[k])}" for k in farthest)
        + f"; shell vertices below their triangle's lowest corner: {int((below > 0.002).sum())} by more than 2 mm, the lowest {below.max() * 1000:.1f} mm")
    log(f"{shell.name} button patches (the fabric within {BUTTON_PATCH * 1000:.0f} mm of a button's centre on the button's triangle): "
        f"{len(patches)} groups; per group [island vertices, bits, fabric vertices patched, the island's reach mm]: "
        + ", ".join(f"[{cnt}, {bits}, {hit}, {reach * 1000:.1f}]" for cnt, bits, hit, reach in patches)
        + f"; {sum(hit for _, _, hit, _ in patches)} fabric vertices patched in all")
    if position_error.max() > 5e-5:
        fail(shell.name, "the render binding does not rebuild the shell")
    return {
        "vertexCount": int(n),
        "restPositions": [round(float(c), 6) for p in X for c in (CONVERSION @ Vector(p))],
        "triangle": [int(t) for t in tri],
        "barycentric": [round(float(c), 6) for c in bary.ravel()],
        "offset": [round(float(c), 6) for c in offset.ravel()],
        "rigidIslands": [[int(start), int(count)] for start, count in rigid],
    }


def shirt_slack_for(obj, artist_dominant, sleeve_seam_segments, label="shirt"):
    """The slack function (`garment_record`'s `slack(bm, loops)`) of a shirt proxy —
    `obj`, with the bone that dominated each of its particles under the ARTIST's weights
    and its sleeve seam as those weights drew it, read before the body's weights
    replaced them (the main flow's `artist_dominant` and `sleeve_seam_segments` for the
    4k proxy, their 16k twins for the other, 2026-11-04). The schedule is metres
    throughout, so the same bands fit both spacings; the collar, yoke and hem bands are
    Dijkstra along the proxy's edges (`surface_distances`), which overestimates the
    geodesic by a few per cent and so moves a band's edge by a few per cent either way
    between the spacings — inward at the collar on 2026-11-04, whose pin band is 5 %
    smaller in area at 16k (535 cm^2 against 563; 133 particles the 4k pins are yoke
    there, none the reverse) because the coarse mesh's chords cut under the collar's
    curvature and its edge paths come out shorter, the yoke 3 % smaller, the hem the
    same within 1 % — and the cuff and armhole rules are geometric.

    The per-particle slack of the shirt by SLACK's regions (see there). The collar is
    the loop with the highest centroid (the front is sewn, so it is a loop of its own),
    the cuffs the two loops out at the wrists (the pins reach CUFF_BAND up the forearm's
    axis, both layers of the roll, the wrist band CUFF_GRADE beyond), the hem what is
    left; the sleeves are the
    particles whose heaviest bone is an arm's (SLEEVE_BONES) and the armhole seam is the
    artist's sleeve-against-body seam kept before the grading (`sleeve_seam_segments`).
    A particle takes the first region that claims it, in SLACK's order — the collar and
    the cuffs first, since nothing may loosen a pin, the buttoned front before the yoke,
    the yoke before the armhole band (the shoulder tops are what the shirt hangs from),
    the armhole band before the sleeve, the hem band before the chest and the back.
    Logs each region's count and extent. Returns the slack per vertex, the region name
    per vertex and SLACK's names."""
    def shirt_slack(bm, loops):
        mw = obj.matrix_world
        collar = max(loops, key=lambda l: sum((mw @ v.co).z for v in l) / len(l))
        cuffs = [l for l in loops if l is not collar and abs(sum((mw @ v.co).x for v in l) / len(l)) > 0.3]
        hems = [l for l in loops if l is not collar and l not in cuffs]
        if len(cuffs) != 2 or len(hems) != 1:
            fail(f"{label}: expected the collar, two cuffs and the hem among the loops, found {len(loops)} loops: {len(cuffs)} at the wrists")
        hem = hems[0]
        collar_z = min((mw @ v.co).z for v in collar)
        names = [g.name for g in obj.vertex_groups]
        dominant = artist_dominant or {i: names[dominant_group(w)] for i, w in vertex_weights(obj).items() if w}
        collar_band = set(surface_distances(bm, collar, COLLAR_BAND))
        # The cuffs along the forearm's axis, both layers of the roll (see SLACK): up the
        # axis from the cuff loop's plane, within CUFF_RADIUS of the axis so nothing else
        # at that height is caught, the pins to CUFF_BAND and the wrist band CUFF_GRADE
        # beyond them.
        cuff_band, wrist_band = set(), set()
        for loop in cuffs:
            centre = sum((mw @ v.co for v in loop), Vector()) / len(loop)
            side = "l" if centre.x > 0 else "r"
            elbow = arm.matrix_world @ arm.data.bones[f"lowerarm_{side}"].head_local
            hand = arm.matrix_world @ arm.data.bones[f"hand_{side}"].head_local
            axis = (hand - elbow).normalized()
            for v in bm.verts:
                d = (mw @ v.co) - centre
                along = -d.dot(axis)
                if (d - d.dot(axis) * axis).length > CUFF_RADIUS:
                    continue
                if along < CUFF_BAND:
                    cuff_band.add(v)
                elif along < CUFF_BAND + CUFF_GRADE:
                    wrist_band.add(v)
        wrist_band -= cuff_band
        yoke_reach = set(surface_distances(bm, list(collar_band), YOKE_BAND))
        hem_band = set(surface_distances(bm, hem, HEM_BAND))
        # The sleeves, like the band, stay off the centre of the chest: the artist's weights
        # leave an upper-arm pocket on the pectoral, 7-9 cm from the centre line, that is
        # the chest's (ARMHOLE_MIN_X, above).
        sleeve = {v for v in bm.verts if dominant.get(v.index, "").startswith(SLEEVE_BONES) and abs((mw @ v.co).x) >= ARMHOLE_MIN_X}
        if not sleeve_seam_segments:
            fail(f"{label}: the sleeve seam is unknown; mark_sleeve_seam did not run on this proxy")
        armhole = {v for v in bm.verts if abs((mw @ v.co).x) >= ARMHOLE_MIN_X
                   and any(segment_distance(mw @ v.co, a, b) <= ARMHOLE_BAND for a, b in sleeve_seam_segments)}
        region = {}
        for v in bm.verts:
            p = mw @ v.co
            if v in collar_band:
                region[v] = "collar"
            elif v in cuff_band:
                region[v] = "cuff"
            elif v in wrist_band:
                region[v] = "wrist"
            elif abs(p.x) < PLACKET_HALF_WIDTH and p.y < PLACKET_FRONT_Y and p.z < collar_z:
                region[v] = "placket"
            elif v in yoke_reach and v not in sleeve and (p.y >= TORSO_AXIS_Y or p.z >= SHOULDER_Z):
                region[v] = "yoke"
            elif v in armhole:
                region[v] = "armhole"
            elif v in sleeve:
                region[v] = "sleeve"
            elif v in hem_band:
                region[v] = "hem"
            elif p.y < TORSO_AXIS_Y:
                region[v] = "chest"
            else:
                region[v] = "back"
        log(f"{label}: {len(loops)} loops; collar loop {len(collar)} verts (z from {collar_z:.3f}), cuff loops {[len(l) for l in cuffs]}, hem loop {len(hem)}; "
            f"{len(sleeve_seam_segments)} sleeve seam edges, {len(sleeve)} sleeve particles")
        for name in SLACK:
            chosen = [mw @ v.co for v in bm.verts if region[v] == name]
            if not chosen:
                fail(f"{label}: the {name} region is empty")
            log(f"  {label} {name:8s} {len(chosen):5d} particles, slack {SLACK[name] * 1000:5.1f} mm, x {min(p.x for p in chosen):+.2f}..{max(p.x for p in chosen):+.2f} "
                f"y {min(p.y for p in chosen):+.2f}..{max(p.y for p in chosen):+.2f} z {min(p.z for p in chosen):.2f}..{max(p.z for p in chosen):.2f}")
        return [SLACK[region[v]] for v in bm.verts], [region[v] for v in bm.verts], list(SLACK)
    return shirt_slack


TROUSERS_REGIONS = ("waist", "hem", "leg")


def trousers_slack(bm, loops):
    """The waist loop and its two-ring pinned, the hems 2 cm, the rest 3 cm; the region
    names (TROUSERS_REGIONS) beside the slack, as `shirt_slack_for` returns them."""
    mw = trousers.matrix_world
    waist = max(loops, key=lambda l: sum((mw @ v.co).z for v in l) / len(l))
    pinned = ring(bm, waist, 2)
    hems = {v for l in loops if l is not waist for v in l}
    log(f"trousers: waist loop {len(waist)} verts, pinned with two-ring {len(pinned)}, hem verts {len(hems)}")
    region = ["waist" if v in pinned else ("hem" if v in hems else "leg") for v in bm.verts]
    return [{"waist": 0.0, "hem": 0.02, "leg": 0.03}[r] for r in region], region, list(TROUSERS_REGIONS)


# ---------------------------------------------------------------- buttons on the fabric
# The artist's buttons float: four of the seven sat 2.3-3.6 mm above the placket (their
# nearest vertex to the fabric; their centres 4.6-5.7 mm off), the top two and the lowest
# touched (measured on the rig, 2026-10-31). Nothing showed at the Mac's distance; in the
# headset, a hand from the shirt, the gap read as a button come loose. Each floating
# button is moved onto the fabric along the fabric's normal until its nearest vertex is
# BUTTON_SEAT off it, and the bits of thread wound around it (the small islands within
# BUTTON_BITS of its centre) move with it, so the thread stays wound. The seat keeps the
# button clear of the 0.2 mm within which the game binds the shell to the exported mesh
# (ZombieCloth.bindTolerance), so no fabric vertex is mistaken for a button's.
def seat_buttons(shell, seat=BUTTON_SEAT, bits_within=BUTTON_BITS):
    """Moves every rigid island of `shell` that floats more than `seat` off the fabric
    (the largest island) onto it, each with the small islands around its centre; logs
    the gaps before and after."""
    bm = bmesh.new(); bm.from_mesh(shell.data)
    parts = [[v.index for v in part] for part in islands(bm)]
    bm.free()
    mw = shell.matrix_world; inv = mw.inverted()
    V = [mw @ v.co for v in shell.data.vertices]
    main = set(parts[0])
    fabric = BVHTree.FromPolygons(V, [tuple(p.vertices) for p in shell.data.polygons if p.vertices[0] in main], all_triangles=False)

    def gap(part):
        """The island's nearest vertex to the fabric: its signed distance (+ outside) and the fabric's normal there."""
        best = None
        for i in part:
            loc, nrm, _, dist = fabric.find_nearest(V[i])
            s = dist if (V[i] - loc).dot(nrm) >= 0 else -dist
            if best is None or s < best[0]:
                best = (s, nrm)
        return best

    pieces = parts[1:]
    centres = [sum((V[i] for i in part), Vector()) / len(part) for part in pieces]
    sizes = sorted({len(p) for p in pieces}, reverse=True)
    buttons = [k for k, part in enumerate(pieces) if len(part) == sizes[0]]
    taken = set(); moved = []
    for k in buttons:
        s, n = gap(pieces[k])
        if s <= seat:
            moved.append((s, 0, 0.0)); continue
        shift = -(s - seat) * n
        group = [k] + [j for j, part in enumerate(pieces) if j != k and j not in taken and len(part) < sizes[0]
                       and (centres[j] - centres[k]).length < bits_within]
        taken.update(group)
        for j in group:
            for i in pieces[j]:
                V[i] = V[i] + shift
                shell.data.vertices[i].co = inv @ V[i]
        moved.append((s, len(group) - 1, shift.length))
    shell.data.update()
    after = [gap(pieces[k])[0] for k in buttons]
    log(f"{shell.name}: {len(buttons)} buttons of {sizes[0]} vertices among {len(pieces)} rigid islands; gaps to the fabric before "
        + ", ".join(f"{s * 1000:.1f}" for s, _, _ in moved) + " mm, after " + ", ".join(f"{s * 1000:.1f}" for s in after)
        + " mm; " + ", ".join(f"{d * 1000:.1f} mm with {bits} bits" for s, bits, d in moved if d > 0))
    if max(after) > seat + 1e-4:
        fail(shell.name, "a button is still off the fabric")


seat_buttons(shirt_render)

cloth = {
    "garments": [garment_record(shirt, "shirt", shirt_slack_for(shirt, artist_dominant, sleeve_seam_segments), render=render_binding(shirt_render, shirt)),
                 garment_record(trousers, "trousers", trousers_slack)],
    "colliders": skin_hulls,
}
# The 16k sidecar (Docs/GPUCloth.md, section 5; 2026-11-04): the same shell bound to the
# 16k proxy — the same rigid islands and button patches, the offsets smaller since more
# shell vertices sit near a proxy vertex — under the garment's SAME name, `shirt`, since
# the game simulates the garments `Configuration.garments` names and the file is a
# drop-in for the first; the same trousers; the same eleven hulls with their planes.
# Both shirt garments carry the phase-2 keys (`garment_record(extended=True)`).
cloth16k = {
    "garments": [garment_record(shirt16k, "shirt", shirt_slack_for(shirt16k, artist_dominant16k, sleeve_seam_segments16k, label="shirt16k"),
                                render=render_binding(shirt_render, shirt16k), extended=True),
                 garment_record(trousers, "trousers", trousers_slack, extended=True)],
    "colliders": colliders16k,
}

# ---------------------------------------------------------------- one object
# One material everywhere, then one object. After the join every polygon must sit on
# slot 0: the exporters split by material INDEX, not by material. The shirt shell is
# drawn, so it joins; the shirt proxy only simulates, so it stays out, hidden (the
# SCENE export skips hidden objects) and in the rig file for inspection.
shell_positions = [shirt_render.matrix_world @ v.co for v in shirt_render.data.vertices]
meshes = [body, eyes, shoes, belt, shirt_render, trousers]
for m in meshes + [shirt, shirt16k]:
    for s in m.material_slots:
        s.material = atlas_mat
with bpy.context.temp_override(object=body, active_object=body, selected_objects=meshes, selected_editable_objects=meshes):
    bpy.ops.object.join()
for p in body.data.polygons:
    p.material_index = 0
while len(body.material_slots) > 1:
    body.active_material_index = len(body.material_slots) - 1
    with bpy.context.temp_override(object=body, active_object=body):
        bpy.ops.object.material_slot_remove()
body.name = "ZombieMesh"; body.data.name = "ZombieMesh"
meshes = [body]
log(f"joined: {len(body.data.vertices)} verts, {len(body.data.polygons)} faces, slots {[s.material.name for s in body.material_slots]}, groups {len(body.vertex_groups)}")
shirt.name = "Shirt_Proxy"; shirt.data.name = "Shirt_Proxy"
# The 16k proxy stays in the rig file beside the 4k, hidden and not exported alike.
shirt16k.name = "Shirt_Proxy16k"; shirt16k.data.name = "Shirt_Proxy16k"
for proxy in (shirt, shirt16k):
    proxy.hide_set(True); proxy.hide_render = True
    for p in proxy.data.polygons:
        p.material_index = 0
    while len(proxy.material_slots) > 1:
        proxy.active_material_index = len(proxy.material_slots) - 1
        with bpy.context.temp_override(object=proxy, active_object=proxy):
            bpy.ops.object.material_slot_remove()

# The game binds the shell's vertices to the exported ones by position, within 0.2 mm,
# and hands a vertex two of them claim to the nearer: the artist's shell has a thousand
# pairs of its own vertices closer than that (thread wound around the buttons, seam
# strips) and the kept skin and the trousers' waist run under it. What matters is that
# no OTHER part's vertex sits within the tolerance of a shell vertex, or the shell would
# drag it along; this counts them, the shell's own near pairs apart, and refuses a
# coincidence (a part exactly on the shell cannot be told from it).
joined_tree = KDTree(len(body.data.vertices))
for v in body.data.vertices:
    joined_tree.insert(body.matrix_world @ v.co, v.index)
joined_tree.balance()
shell_tree = KDTree(len(shell_positions))
for i, p in enumerate(shell_positions):
    shell_tree.insert(p, i)
shell_tree.balance()
foreign = []; own_pairs = 0; nearest_foreign = math.inf
for p in shell_positions:
    own_pairs += len(shell_tree.find_range(p, 0.0002)) - 1
    # A joined vertex is the shell's own when a shell vertex sits on it exactly.
    others = [dd for co, _, dd in joined_tree.find_range(p, 0.0002) if shell_tree.find(co)[2] > 1e-7]
    if others:
        foreign.append(p); nearest_foreign = min(nearest_foreign, min(others))
log(f"shell against the rest of the mesh: {len(foreign)} shell vertices have another part's vertex within 0.2 mm"
    + (f" (nearest {nearest_foreign * 1000:.3f} mm; e.g. {[tuple(round(c, 3) for c in p) for p in foreign[:4]]})" if foreign else "")
    + f"; {own_pairs // 2} near pairs among the shell's own vertices")
if nearest_foreign == 0.0:
    fail("a vertex of another part sits exactly on a shell vertex; the game could not tell them apart")

# ---------------------------------------------------------------- purge + save
# The artist's materials carry fake users (and their 4K maps with them): only the atlas
# material stays.
for mat in list(bpy.data.materials):
    if mat is not atlas_mat:
        mat.use_fake_user = False
bpy.data.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)
for img in list(bpy.data.images):
    if img.users == 0:
        bpy.data.images.remove(img)
scene.frame_start, scene.frame_end, scene.render.fps = 1, 1, 30
os.makedirs(os.path.dirname(OUT_BLEND), exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND, compress=True)
log("saved", OUT_BLEND)

dg = bpy.context.evaluated_depsgraph_get()
for m in meshes:
    me = m.evaluated_get(dg).to_mesh()
    zs = [(m.matrix_world @ v.co).z for v in me.vertices]
    log(f"  {m.name}: z {min(zs):.3f}..{max(zs):.3f} tris {sum(len(p.vertices) - 2 for p in me.polygons)} mats {[s.material.name for s in m.material_slots]}")
for n in ("root", "pelvis", "spine_03", "neck_01", "head", "upperarm_l", "hand_l", "thigh_l", "foot_l", "ball_l"):
    b = arm.data.bones[n]
    log(f"  bone {n}: parent={b.parent.name if b.parent else None} head={tuple(round(v, 3) for v in b.head_local)}")

# ---------------------------------------------------------------- export + sidecar
asset_dir = os.path.join(os.path.abspath(OUT_DIR), NAME)
os.makedirs(asset_dir, exist_ok=True)
out = os.path.join(asset_dir, NAME + ".untold")
try:
    bpy.ops.preferences.addon_enable(module="untold_exporter")
    import untold_exporter
except Exception as e:
    fail("untold_exporter add-on:", e)
# The add-on's operator wraps this same call (it only adds the progress bar); calling
# the bridge gives the result back, with the vertex count the sidecar records.
bridge = untold_exporter.exporter_bridge()
res = bridge.export_asset(context=bpy.context, output_path=Path(out), scope="SCENE", file_type_name="tile",
                          convert_orientation=True, source_orientation="blender-native", validate=False,
                          compress_geometry=False, color_grade_lut_path=None, bake_textures=False,
                          texture_quality="balanced", keep_texture_temp=False)
exported_vertices = int(res["vertex_count"])
log(f"EXPORT {res['mesh_count']} mesh(es), {exported_vertices} vertices, {res['bytes_written']} bytes -> {out}")
if res["mesh_count"] != 1:
    fail("the export holds", res["mesh_count"], "meshes; the body must be one")
# The exporter stages its material-preview environment beside every export; it is not
# part of the asset (the kit bundle copies the Models folder whole).
hdr_dir = os.path.join(asset_dir, "HDR")
if os.path.isdir(hdr_dir):
    shutil.rmtree(hdr_dir)
    log(f"removed the exporter's side folder {hdr_dir}")

# Two sidecars from one cook (2026-11-04): the 4k one as it always was, and the 16k one
# beside it, both stamped with the same source and export so a stale one is told apart.
# JSON holds both under the 8 MB warning (2.95 MB and 4.99 MB on 2026-11-04, the shell
# binding 2.25 and 2.29 MB of them; the 16k's particles, rest normals, influences and
# triangles are the other 2.7 MB), so the design's note that a binary blob would come
# when the JSON passes the mark stays a note.
for filename, data in ((NAME + ".cloth.json", cloth), (NAME + ".cloth16k.json", cloth16k)):
    for g in data["garments"]:
        g["sourceFile"] = os.path.basename(SRC)
        g["sourceHash"] = source_hash
        g["exportedVertexCount"] = exported_vertices
    sidecar = os.path.join(asset_dir, filename)
    with open(sidecar, "w") as f:
        json.dump(data, f, sort_keys=True, separators=(",", ":"))
    size = os.path.getsize(sidecar)
    render_bytes = sum(len(json.dumps(g["render"], separators=(",", ":"))) for g in data["garments"] if "render" in g)
    log(f"sidecar {sidecar}: {size} bytes ({size / 1e6:.2f} MB, the render binding {render_bytes / 1e6:.2f} MB of it), "
        f"garments {[(g['name'], len(g['particles']), len(g['triangles']), g['pinCount'], g.get('render', {}).get('vertexCount')) for g in data['garments']]}, "
        f"colliders {len(data['colliders'])} with {sum(len(c.get('planes', [])) for c in data['colliders'])} planes")
    if size > 8e6:
        log(f"WARNING: the sidecar passes 8 MB ({size / 1e6:.2f} MB); the render binding is most of it")
print("DONE")
