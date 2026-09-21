# Authors a looping "flex" action on a prepped character .blend:
#   Blender --background --python author_flex.py -- <in.blend> <axis:X|Y|Z> <sign:+|-> <render_prefix>
# Bicep-curl both elbows + shoulder raise + torso sway + slight knee bend.
# Renders mid-curl frames for visual verification, then saves in place.
import math
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1 :]
blend_path, axis_name, sign_text, render_prefix = argv[0], argv[1], argv[2], argv[3]
axis_index = {"X": 0, "Y": 1, "Z": 2}[axis_name.upper()]
sign = 1.0 if sign_text == "+" else -1.0

bpy.ops.wm.open_mainfile(filepath=blend_path)

armature = next(o for o in bpy.data.objects if o.type == "ARMATURE")


def packed(name):
    return name.lower().replace(" ", "").replace("_", "").replace(":", "")


def side_ok(p, side):
    if side is None:
        return True
    full = "left" if side == "l" else "right"
    other = "right" if side == "l" else "left"
    if other in p:
        return False
    if full in p:
        return True
    # Biped style (Bip01_LForearm -> "bip01lforearm"): the side letter sits
    # right after the rig prefix, immediately before the part name.
    return any(f"{marker}{side}" in p for marker in ("01", "bip", "bone", ".")) or p.startswith(side)


def find_bone(fragments, side=None, exclude=()):
    for bone in armature.pose.bones:
        p = packed(bone.name)
        if any(x in p for x in exclude):
            continue
        if not side_ok(p, side):
            continue
        if any(f in p for f in fragments):
            return bone
    return None


targets = {
    "forearmL": find_bone(["forearm"], side="l", exclude=["twist", "roll"]),
    "forearmR": find_bone(["forearm"], side="r", exclude=["twist", "roll"]),
    "upperarmL": find_bone(["uparm", "upperarm", "arm"], side="l", exclude=["twist", "roll", "forearm"]),
    "upperarmR": find_bone(["uparm", "upperarm", "arm"], side="r", exclude=["twist", "roll", "forearm"]),
    "spine": find_bone(["spine1", "spine"], exclude=["twist"]),
    "calfL": find_bone(["calf", "leg"], side="l", exclude=["twist", "upleg", "thigh", "foot"]),
    "calfR": find_bone(["calf", "leg"], side="r", exclude=["twist", "upleg", "thigh", "foot"]),
}
for label, bone in targets.items():
    print(f"[flex] {label}: {bone.name if bone else 'NOT FOUND'}")

scene = bpy.context.scene
scene.frame_start = 1
scene.frame_end = 96
scene.render.fps = 24

if armature.animation_data is None:
    armature.animation_data_create()
for stale in [a for a in bpy.data.actions if a.name.startswith("flex")]:
    bpy.data.actions.remove(stale)
action = bpy.data.actions.new("flex")
armature.animation_data.action = action


def key_rotation(bone, frame, angle_degrees, axis=axis_index, bone_sign=1.0):
    bone.rotation_mode = "XYZ"
    euler = [0.0, 0.0, 0.0]
    euler[axis] = math.radians(angle_degrees) * sign * bone_sign
    bone.rotation_euler = euler
    bone.keyframe_insert(data_path="rotation_euler", frame=frame)


# Two curl cycles over 96 frames: rest(1) -> curl(24) -> rest(48) -> curl(72) -> rest(96)
for frame, amount in ((1, 0.0), (24, 1.0), (48, 0.0), (72, 1.0), (96, 0.0)):
    for side_key, bone_sign in (("forearmL", 1.0), ("forearmR", 1.0)):
        bone = targets[side_key]
        if bone:
            key_rotation(bone, frame, 110.0 * amount, bone_sign=bone_sign)
    for side_key in ("upperarmL", "upperarmR"):
        bone = targets[side_key]
        if bone:
            key_rotation(bone, frame, 25.0 * amount)
    if targets["spine"]:
        key_rotation(targets["spine"], frame, 12.0 * amount)
    for side_key in ("calfL", "calfR"):
        bone = targets[side_key]
        if bone:
            key_rotation(bone, frame, 20.0 * amount)

# ── verification renders at rest and mid-curl ─────────────────────────────
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
top = max((o.matrix_world @ Vector(v)).z for o in meshes for v in o.bound_box)
bottom = min((o.matrix_world @ Vector(v)).z for o in meshes for v in o.bound_box)
center = sum((o.matrix_world.translation for o in meshes), Vector()) / len(meshes)
mid = Vector((center.x, center.y, (top + bottom) / 2))
size = max(top - bottom, 0.5)

cam_data = bpy.data.cameras.new("VerifyCam")
cam = bpy.data.objects.new("VerifyCam", cam_data)
scene.collection.objects.link(cam)
cam.location = mid + Vector((0, -size * 1.9, 0))
cam.rotation_euler = (1.5708, 0, 0)
scene.camera = cam
sun_data = bpy.data.lights.new("VerifySun", type="SUN")
sun_data.energy = 3.0
sun = bpy.data.objects.new("VerifySun", sun_data)
scene.collection.objects.link(sun)
sun.rotation_euler = (0.9, 0.2, 0.5)
scene.render.resolution_x = 720
scene.render.resolution_y = 960
try:
    scene.render.engine = "BLENDER_EEVEE_NEXT"
except TypeError:
    pass

scene.frame_set(24)
scene.render.filepath = f"{render_prefix}_curl.png"
bpy.ops.render.render(write_still=True)
print(f"[flex] rendered {render_prefix}_curl.png")

bpy.data.objects.remove(cam)
bpy.data.objects.remove(sun)
bpy.ops.wm.save_mainfile()
print(f"[flex] saved {blend_path}")
