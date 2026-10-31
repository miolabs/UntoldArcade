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
    the fourteen bits) is the shirt the game draws: it takes the proxy's graded weights
    (interpolated from the nearest proxy face, capped at four), so body-skinned — the
    cloth off, the player out of range — it sits where the simulation would put it at
    rest, and the sidecar carries its RENDER BINDING to the proxy (`render_binding`):
    per shell vertex the nearest proxy triangle at the bind pose, the barycentric
    coordinates of the closest point, and the vertex's rest offset in that triangle's
    frame, so the simulated triangles carry the shell rigidly (its normals the game
    reads off the exported mesh, one per exported copy, since the exporter splits a
    vertex on the artist's sharp edges, and carries in the same frame); a button or a
    bit binds whole to the one triangle nearest its centre and stays rigid. The proxy
    itself is kept in the rig file as `Shirt_Proxy`, hidden and not exported: it lives
    in the sidecar only;
  * the ragdoll's twenty capsules fitted to this body and logged in the rig's syntax
    (`fit_capsules`): inside the skin the part's bones move and a cloth particle's
    collision radius (1 cm) inside the shirt and the trousers proxies, for
    ZombieRagdollRig.swift's table, which ZombieRagdollRigTests holds to the export;
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
    pinned, the yoke 1 cm, the sleeves 5 cm, the armhole band 6 cm, the chest 8, the back
    10, the hem band 12, the buttoned front 5 mm; the trousers' waist pinned, their hems
    2 cm, the rest 3), the back-stop depth, the dominant joint, the bind-pose joint
    matrices and, for the shirt, the render binding with the shell's rest positions; the
    game binds the shell's vertices (the trousers' particles) to the exported vertices by
    position (the exporter splits vertices on UV seams, so one maps to several);
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
import bpy, bmesh, os, json, hashlib, heapq, math, shutil
import numpy as np
from mathutils import Vector, Matrix
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
    islands, boundary loops) of a triangle mesh in world units."""
    bm = bmesh.new(); bm.from_mesh(obj.data); bm.transform(obj.matrix_world)
    lengths = np.array([e.calc_length() for e in bm.edges])
    areas = [f.calc_area() for f in bm.faces]
    angles = [min(l.calc_angle() for l in f.loops) for f in bm.faces]
    stats = (len(bm.verts), len(bm.faces), float(lengths.min()), float(np.median(lengths)), float(lengths.max()),
             min(areas), math.degrees(min(angles)), len(islands(bm)), len(boundary_loops(bm)))
    bm.free()
    return stats


def report_proxy(name, obj, loops, min_edge=0.008, max_edge=0.040, min_area=1e-6, min_angle=5.0):
    """Log a proxy's mesh_stats and hold them to the limits the tests check and to one
    piece with `loops` openings; returns the stats."""
    stats = mesh_stats(obj)
    nv, nf, emin, emed, emax, amin, angmin, nisl, nloops = stats
    log(f"{name} proxy: {nv} verts, {nf} tris, edges {emin * 1000:.1f}/{emed * 1000:.1f}/{emax * 1000:.1f} mm (min/median/max), "
        f"min face area {amin * 1e6:.2f} mm², min angle {angmin:.1f}°, {nisl} island(s), {nloops} boundary loop(s)")
    if not (emin >= min_edge and emax <= max_edge and amin >= min_area and angmin >= min_angle):
        fail(f"{name} proxy breaks the mesh limits (edges {min_edge}..{max_edge} m, area >= {min_area} m², angle >= {min_angle}°)")
    if nisl != 1 or nloops != loops:
        fail(f"{name} proxy: must be one piece with {loops} openings, not {nisl} piece(s) with {nloops}")
    return stats


def decimate_proxy(obj, target, min_edge=0.0085, max_edge=0.036, min_angle=8.0, min_area=2e-6, deviation=0.002, max_valence=12):
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
    split first (a collapse never shortens an edge)."""
    bm = bmesh.new(); bm.from_mesh(obj.data)
    # Zero-length edges and zero-area faces (coincident vertices the artist left, or a
    # weld made) cannot be collapsed away by the quality rules below: dissolve them first.
    bmesh.ops.dissolve_degenerate(bm, dist=1e-4, edges=bm.edges[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
    long_edges = [e for e in bm.edges if e.calc_length() > max_edge]
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
    for d, a, b in sorted(set(stuck)):
        if not (alive_v[a] and alive_v[b] and b in neighbours(a)):
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
    log(f"{obj.name}: decimated {before[0]} verts / {before[1]} tris -> {len(coords)} verts / {len(tris)} tris ({refused} collapses refused)")
    return len(coords), len(tris)


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


def grade_weight_seams(obj, arm, band=SEAM_BAND, blend=0.5, passes=16, trace=0.03,
                       armpit_band=ARMPIT_BAND, armpit_passes=ARMPIT_PASSES):
    """The artist's automatic weights hand the shirt from one bone to the next across
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
    armhole_before = seam_edges(obj, weights, sides=(ARM_BONES, TORSO_BONES))
    if not armhole_before:
        fail(obj.name, "has no armhole seam: no edge runs from an arm bone's vertex to a torso bone's")
    sleeve_seam_segments.clear(); sleeve_seam_segments.extend(seam_chains(obj, weights, sides=(SLEEVE_BONES, BODY_BONES)))
    if not sleeve_seam_segments:
        fail(obj.name, "has no sleeve seam: no edge runs from an upper-arm vertex to a body-panel vertex")
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
decimate_proxy(shirt, 4000)
recap_influences(shirt)
grade_weight_seams(shirt, arm)
changed, largest, near = free_hips_of_arm_weights(shirt, arm)
log(f"shirt: {changed} of the {near} particles within {HIP_ARM_FREE + HIP_ARM_TAPER:.2f} m of the pelvis carried arm weight, taken off "
    f"(wholly within {HIP_ARM_FREE} m, tapered beyond; the most taken off one vertex {largest:.3f})")
orient_outward(shirt, body_tree)
push_off_body(shirt, body_tree)
report_proxy("shirt", shirt, loops=4)

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
# an ellipse and a capsule is round. The garment margin is a cloth particle's collision
# radius (ZombieCloth.Configuration.vertexRadius): Jolt holds a particle that far off a
# capsule, so a capsule any closer under a garment pushes the cloth off its skin before the
# part has moved at all — and the parts hang a finger's width off their joints at rest
# (the forearm 1 cm, the hand 3 cm, under the tight sleeve and its cuff). The trousers are
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


def fit_capsules(body_objs, garment_objs, arm):
    """Logs one fitted capsule per ragdoll part (see above) and returns them by name as
    (from, to, radius) in engine space, the tips of the capsule. `garment_objs` are the
    proxies the capsules must stay CAPSULE_GARMENT_MARGIN under, the shirt and the
    trousers."""
    heads = {b.name: np.array(engine_point(arm.matrix_world @ b.head_local)) for b in arm.data.bones}
    points, dominants = [], []
    for o in body_objs:
        names = [g.name for g in o.vertex_groups]
        for v in o.data.vertices:
            best = max(((g.weight, g.group) for g in v.groups), default=None)
            if best is None:
                continue
            points.append(engine_point(o.matrix_world @ v.co)); dominants.append(names[best[1]])
    points = np.array(points); dominants = np.array(dominants, dtype=object)
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
for o in (shirt, shirt_render):
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
def engine_matrix_column_major(m):
    e = CONVERSION @ m @ CONVERSION.inverted()
    return [round(e[r][c], 7) for c in range(4) for r in range(4)]


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


def garment_record(obj, name, slack, render=None):
    """The sidecar entry for a proxy: `slack(bm, loops)` returns the per-vertex
    maxDistance list (0 pins). The faces are wound consistently and point away from the
    body on the whole (orient_outward), but not every one does: the rolled cuffs and the
    inside of the collar wrap back towards the arm and the neck. A back-stop placed
    behind the face would sit on the wrong side of those particles, so the ones whose
    normal points at the body are listed (`bodyFacingParticles`) for the game to put
    their back-stop on the body side. `render`, when given, is the drawn shell's binding
    to this proxy (`render_binding`), written under the garment as "render"."""
    mw = obj.matrix_world
    if max(abs(x - y) for r0, r1 in zip(mw, Matrix.Identity(4)) for x, y in zip(r0, r1)) > 1e-5:
        fail(obj.name, "is not at the origin; the exporter would bake another transform")
    bm = bmesh.new(); bm.from_mesh(obj.data); bm.verts.ensure_lookup_table()
    bm.normal_update()
    loops = boundary_loops(bm)
    max_distance = slack(bm, loops)
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
# COLLAR_BAND of the collar loop) and the cuffs (within CUFF_BAND of the cuff loops) are
# hard skinned and follow the body exactly — the rolled cuffs ride the forearm's
# animation and never fight the hand parts' tracking error; the yoke (the back and the
# shoulder tops within YOKE_BAND below the collar band, not the chest) is held to a
# centimetre, which is what the shirt hangs from; below it the chest, the back and the
# hem band (the lowest HEM_BAND of the body panels) hang freer the lower they are, the
# sleeves swing on 5 cm and the armhole band (within ARMHOLE_BAND of the sleeve seam,
# where the graded skin still stretches the edges most) on 6; the buttoned front keeps
# its 5 mm, since the buttons hold the panels to the chest. The chest is what lies in
# front of the torso's axis below the shoulder line, the back what lies behind it.
SLACK = {"collar": 0.0, "cuff": 0.0, "placket": 0.005, "yoke": 0.01, "sleeve": 0.05, "armhole": 0.06, "chest": 0.08, "back": 0.10, "hem": 0.12}
COLLAR_BAND = 0.08
CUFF_BAND = 0.06
YOKE_BAND = 0.12
HEM_BAND = 0.12
ARMHOLE_BAND = 0.06
# Blender y of the torso's axis (the spine runs at y 0.10-0.14, the chest in front of
# it at smaller y) and Blender z of the shoulder line (the upper arms start at 1.41):
# above it a yoke vertex is a shoulder top whatever its y.
TORSO_AXIS_Y = 0.10
SHOULDER_Z = 1.40
PLACKET_HALF_WIDTH = 0.02
PLACKET_FRONT_Y = 0.06


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
    cloth under it does. The vertices are written main island first, then each rigid
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


def shirt_slack(bm, loops):
    """The per-particle slack of the shirt by SLACK's regions (see there). The collar is
    the loop with the highest centroid (the front is sewn, so it is a loop of its own),
    the cuffs the two loops out at the wrists, the hem what is left; the sleeves are the
    particles whose heaviest bone is an arm's (SLEEVE_BONES) and the armhole seam is the
    artist's sleeve-against-body seam kept before the grading (`sleeve_seam_segments`).
    A particle takes the first region that claims it, in SLACK's order — the collar and
    the cuffs first, since nothing may loosen a pin, the buttoned front before the yoke,
    the yoke before the armhole band (the shoulder tops are what the shirt hangs from),
    the armhole band before the sleeve, the hem band before the chest and the back.
    Logs each region's count and extent."""
    mw = shirt.matrix_world
    collar = max(loops, key=lambda l: sum((mw @ v.co).z for v in l) / len(l))
    cuffs = [l for l in loops if l is not collar and abs(sum((mw @ v.co).x for v in l) / len(l)) > 0.3]
    hems = [l for l in loops if l is not collar and l not in cuffs]
    if len(cuffs) != 2 or len(hems) != 1:
        fail(f"shirt: expected the collar, two cuffs and the hem among the loops, found {len(loops)} loops: {len(cuffs)} at the wrists")
    hem = hems[0]
    collar_z = min((mw @ v.co).z for v in collar)
    names = [g.name for g in shirt.vertex_groups]
    dominant = {i: names[dominant_group(w)] for i, w in vertex_weights(shirt).items() if w}
    collar_band = set(surface_distances(bm, collar, COLLAR_BAND))
    cuff_band = set(surface_distances(bm, [v for l in cuffs for v in l], CUFF_BAND))
    yoke_reach = set(surface_distances(bm, list(collar_band), YOKE_BAND))
    hem_band = set(surface_distances(bm, hem, HEM_BAND))
    sleeve = {v for v in bm.verts if dominant.get(v.index, "").startswith(SLEEVE_BONES)}
    if not sleeve_seam_segments:
        fail("shirt: the sleeve seam is unknown; grade_weight_seams did not run on this proxy")
    armhole = {v for v in bm.verts if any(segment_distance(mw @ v.co, a, b) <= ARMHOLE_BAND for a, b in sleeve_seam_segments)}
    region = {}
    for v in bm.verts:
        p = mw @ v.co
        if v in collar_band:
            region[v] = "collar"
        elif v in cuff_band:
            region[v] = "cuff"
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
    log(f"shirt: {len(loops)} loops; collar loop {len(collar)} verts (z from {collar_z:.3f}), cuff loops {[len(l) for l in cuffs]}, hem loop {len(hem)}; "
        f"{len(sleeve_seam_segments)} sleeve seam edges, {len(sleeve)} sleeve particles")
    for name in SLACK:
        chosen = [mw @ v.co for v in bm.verts if region[v] == name]
        if not chosen:
            fail(f"shirt: the {name} region is empty")
        log(f"  shirt {name:8s} {len(chosen):5d} particles, slack {SLACK[name] * 1000:5.1f} mm, x {min(p.x for p in chosen):+.2f}..{max(p.x for p in chosen):+.2f} "
            f"y {min(p.y for p in chosen):+.2f}..{max(p.y for p in chosen):+.2f} z {min(p.z for p in chosen):.2f}..{max(p.z for p in chosen):.2f}")
    return [SLACK[region[v]] for v in bm.verts]


def trousers_slack(bm, loops):
    """The waist loop and its two-ring pinned, the hems 2 cm, the rest 3 cm."""
    mw = trousers.matrix_world
    waist = max(loops, key=lambda l: sum((mw @ v.co).z for v in l) / len(l))
    pinned = ring(bm, waist, 2)
    hems = {v for l in loops if l is not waist for v in l}
    log(f"trousers: waist loop {len(waist)} verts, pinned with two-ring {len(pinned)}, hem verts {len(hems)}")
    return [0.0 if v in pinned else (0.02 if v in hems else 0.03) for v in bm.verts]


cloth = {
    "garments": [garment_record(shirt, "shirt", shirt_slack, render=render_binding(shirt_render, shirt)),
                 garment_record(trousers, "trousers", trousers_slack)],
}

# ---------------------------------------------------------------- one object
# One material everywhere, then one object. After the join every polygon must sit on
# slot 0: the exporters split by material INDEX, not by material. The shirt shell is
# drawn, so it joins; the shirt proxy only simulates, so it stays out, hidden (the
# SCENE export skips hidden objects) and in the rig file for inspection.
shell_positions = [shirt_render.matrix_world @ v.co for v in shirt_render.data.vertices]
meshes = [body, eyes, shoes, belt, shirt_render, trousers]
for m in meshes + [shirt]:
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
shirt.hide_set(True); shirt.hide_render = True
for p in shirt.data.polygons:
    p.material_index = 0
while len(shirt.material_slots) > 1:
    shirt.active_material_index = len(shirt.material_slots) - 1
    with bpy.context.temp_override(object=shirt, active_object=shirt):
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

for g in cloth["garments"]:
    g["sourceFile"] = os.path.basename(SRC)
    g["sourceHash"] = source_hash
    g["exportedVertexCount"] = exported_vertices
sidecar = os.path.join(asset_dir, NAME + ".cloth.json")
with open(sidecar, "w") as f:
    json.dump(cloth, f, sort_keys=True, separators=(",", ":"))
size = os.path.getsize(sidecar)
log(f"sidecar {sidecar}: {size} bytes ({size / 1e6:.2f} MB), garments {[(g['name'], len(g['particles']), len(g['triangles']), g['pinCount'], g.get('render', {}).get('vertexCount')) for g in cloth['garments']]}")
if size > 8e6:
    log(f"WARNING: the sidecar passes 8 MB ({size / 1e6:.2f} MB); the render binding is most of it")
print("DONE")
