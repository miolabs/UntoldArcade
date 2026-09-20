# Converts a Mixamo-rigged suit hand blend (hand_R.blend / hand_L.blend) into
# the CoolWeb glove usdz: 17 ARKit-named bones, <=4 influences, 2 materials.
# Usage: blender --background hand_R.blend --python convert_hand.py -- Right /out/hand_right.usdz /path/GloveTextures
import bpy
import sys
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
side, out_path, tex_dir = argv[0], argv[1], argv[2]   # side: Right | Left

MIX = f"mixamorig:{side}"
BONE_MAP = {
    f"{MIX}ForeArm": "forearmArm",
    f"{MIX}Hand": "wrist",
    f"{MIX}HandThumb1": "thumbKnuckle",
    f"{MIX}HandThumb2": "thumbIntermediateBase",
    f"{MIX}HandThumb3": "thumbIntermediateTip",
    f"{MIX}HandIndex1": "indexFingerKnuckle",
    f"{MIX}HandIndex2": "indexFingerIntermediateBase",
    f"{MIX}HandIndex3": "indexFingerIntermediateTip",
    f"{MIX}HandMiddle1": "middleFingerKnuckle",
    f"{MIX}HandMiddle2": "middleFingerIntermediateBase",
    f"{MIX}HandMiddle3": "middleFingerIntermediateTip",
    f"{MIX}HandRing1": "ringFingerKnuckle",
    f"{MIX}HandRing2": "ringFingerIntermediateBase",
    f"{MIX}HandRing3": "ringFingerIntermediateTip",
    f"{MIX}HandPinky1": "littleFingerKnuckle",
    f"{MIX}HandPinky2": "littleFingerIntermediateBase",
    f"{MIX}HandPinky3": "littleFingerIntermediateTip",
    # Mixamo leaf bones = real fingertip positions: kept as non-deforming
    # joints so the retarget solver knows each distal phalanx's true length.
    f"{MIX}HandThumb3_end": "thumbTip",
    f"{MIX}HandIndex3_end": "indexFingerTip",
    f"{MIX}HandMiddle3_end": "middleFingerTip",
    f"{MIX}HandRing3_end": "ringFingerTip",
    f"{MIX}HandPinky3_end": "littleFingerTip",
}
DEFORM_BONES = 17

arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
mesh = next(o for o in bpy.data.objects if o.type == 'MESH')

# --- prune skeleton to the 17 kept bones ---
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode='EDIT')
keep = set(BONE_MAP.keys())
for eb in list(arm.data.edit_bones):
    if eb.name not in keep:
        arm.data.edit_bones.remove(eb)
eb = arm.data.edit_bones
assert len(eb) == len(BONE_MAP), f"kept {len(eb)} bones"
eb[f"{MIX}ForeArm"].parent = None
assert eb[f"{MIX}Hand"].parent.name == f"{MIX}ForeArm"
for f in ["Thumb", "Index", "Middle", "Ring", "Pinky"]:
    assert eb[f"{MIX}Hand{f}1"].parent.name == f"{MIX}Hand"
    eb[f"{MIX}Hand{f}3_end"].use_deform = False

# --- web-shooter muzzle marker: a non-deforming bone parented to the wrist
# at the small emitter device on the gauntlet's inner wrist. A `webMuzzle`
# Empty in the blend wins; otherwise locate it from the geometry: the
# webshooter-material verts that protrude most toward the palm just past
# the wrist line.
wrist_b = eb[f"{MIX}Hand"]
index_b, little_b = eb[f"{MIX}HandIndex1"], eb[f"{MIX}HandPinky1"]
W = wrist_b.head.copy()
fwd = ((index_b.head + little_b.head) * 0.5 - W).normalized()
lat = (little_b.head - index_b.head)
lat = (lat - fwd * lat.dot(fwd)).normalized()
back = lat.cross(fwd) if side == "Right" else fwd.cross(lat)
palm = -back.normalized()
marker = bpy.data.objects.get("webMuzzle")
if marker:
    muzzle = marker.matrix_world.translation.copy()
    print("muzzle from Empty", tuple(round(v, 4) for v in muzzle))
else:
    ws_idx = [i for i, s in enumerate(mesh.material_slots)
              if s.material and "webshooter" in s.material.name.lower()][0]
    seen = set()
    cands = []
    for p in mesh.data.polygons:
        if p.material_index != ws_idx: continue
        for vi in p.vertices:
            if vi in seen: continue
            seen.add(vi)
            v = mesh.matrix_world @ mesh.data.vertices[vi].co
            d = v - W
            f_ = d.dot(fwd)
            if -0.02 <= f_ <= 0.04:
                cands.append((d.dot(palm), v))
    cands.sort(key=lambda t: -t[0])
    top = [v for _p, v in cands[:max(20, len(cands) // 20)]]
    muzzle = sum(top, Vector()) / len(top)
    print("muzzle from geometry", tuple(round(v, 4) for v in muzzle),
          "palm offset", round(cands[0][0], 4))
mb = eb.new("webMuzzle")
mb.head = muzzle
mb.tail = muzzle + fwd * 0.01
mb.parent = wrist_b
mb.use_deform = False
bpy.ops.object.mode_set(mode='OBJECT')

# preview-only marker sphere at the muzzle (not selected for export)
bpy.ops.mesh.primitive_uv_sphere_add(radius=0.006, location=muzzle)
bpy.context.active_object.name = "muzzle_preview_marker"

# --- rename vgroups first (so the bone rename's auto-sync is a no-op),
# drop unused vgroups ---
for old, new in BONE_MAP.items():
    g = mesh.vertex_groups.get(old)
    if g: g.name = new
kept_groups = set(BONE_MAP.values())
for g in list(mesh.vertex_groups):
    if g.name not in kept_groups:
        mesh.vertex_groups.remove(g)
for old, new in BONE_MAP.items():
    arm.data.bones[old].name = new

# --- cap influences at 4: drop EVERY membership beyond the top 4 (zero-weight
# memberships still count as USD lanes), renormalize the survivors ---
deform = {g.index: g for g in mesh.vertex_groups}
over = 0
for v in mesh.data.vertices:
    entries = [(ge.group, ge.weight) for ge in v.groups if ge.group in deform]
    entries.sort(key=lambda t: -t[1])
    kept = [(g, w) for g, w in entries[:4] if w > 1e-5]
    dropped = [g for g, _w in entries if g not in {g2 for g2, _ in kept}]
    if dropped:
        over += 1
        for g in dropped:
            deform[g].remove([v.index])
    total = sum(w for _g, w in kept)
    if total > 1e-6:
        for g, w in kept:
            deform[g].add([v.index], w / total, 'REPLACE')
print("capped influences on", over, "verts")

# smooth shading so the exporter writes usable authored normals
bpy.context.view_layer.objects.active = mesh
bpy.ops.object.select_all(action='DESELECT')
mesh.select_set(True)
bpy.ops.object.shade_smooth()

# --- materials: drop empty slots, repoint every map at the repo's source
# textures (the blend's original absolute paths are long gone) ---
bpy.context.view_layer.objects.active = mesh
bpy.ops.object.material_slot_remove_unused()
import os
for slot in mesh.material_slots:
    m = slot.material
    if not m or not m.use_nodes: continue
    key = "webshooters" if "webshooter" in m.name.lower() else "red"
    for n in list(m.node_tree.nodes):
        if n.type != 'TEX_IMAGE' or not n.image: continue
        suffix = None
        # Only these three maps are used (red is cloth: metallic ≈ 0, its
        # map is not kept in the repo).
        for candidate in ("BaseColor", "Roughness", "Normal"):
            if candidate in n.image.name:
                suffix = candidate
                break
        path = f"{tex_dir}/{key}_{suffix}.png" if suffix else None
        if path and os.path.exists(path):
            n.image.filepath = path
            n.image.source = 'FILE'
            n.image.reload()
        else:
            m.node_tree.nodes.remove(n)
print("material slots:", [s.material.name for s in mesh.material_slots])

# --- preview renders with the full textures (before they are stripped) ---
cam = bpy.data.objects.get("Camera")
if cam:
    center = sum((mesh.matrix_world @ Vector(c) for c in mesh.bound_box), Vector()) / 8
    scene = bpy.context.scene
    scene.camera = cam
    scene.render.engine = 'BLENDER_EEVEE'
    scene.render.resolution_x = 800
    scene.render.resolution_y = 600
    # back-of-hand beauty shot + palm-side shot (shows the muzzle marker)
    for tag, direction in (("preview", Vector((0.6, -1.0, 0.45))),
                           ("palm", palm + fwd * 0.2)):
        cam.location = center + direction.normalized() * 0.55
        cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Y').to_euler()
        scene.render.filepath = out_path.rsplit('.', 1)[0] + f"_{tag}.png"
        bpy.ops.render.render(write_still=True)
        print("PREVIEW", scene.render.filepath)

# --- export ---
# Materials are exported for their NAMES (the runtime classifies submeshes
# by them) but textures are NOT: the app loads the cooked 2K maps from
# GloveTextures, and packing the 4K sources made each usdz ~30 MB. Strip the
# image nodes so the packager has nothing to chase.
for slot in mesh.material_slots:
    m = slot.material
    if not m or not m.use_nodes: continue
    for n in list(m.node_tree.nodes):
        if n.type == 'TEX_IMAGE':
            m.node_tree.nodes.remove(n)
bpy.ops.object.select_all(action='DESELECT')
arm.select_set(True)
mesh.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.wm.usd_export(
    filepath=out_path,
    selected_objects_only=True,
    export_materials=True,
    export_textures_mode='KEEP',
    export_armatures=True,
)
print("EXPORTED", out_path)
