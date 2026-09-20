# Keep one group of objects from the scene, drop the world lighting, move the
# group so its footprint centre sits at the origin with its base on z = 0
# (or its centre, for balls), optionally decimate, save as a new .blend.
import bpy, sys, re
from mathutils import Vector
args = sys.argv[sys.argv.index('--') + 1:]
out, mode, pattern = args[0], args[1], args[2]          # mode: collection | regex
anchor = args[3]                                       # base | center
target_polys = int(args[4]) if len(args) > 4 else 0
if mode == 'collection':
    coll = bpy.data.collections[pattern]
    keep = {o.name for o in coll.all_objects if o.type == 'MESH'}
else:
    keep = {o.name for o in bpy.data.objects if o.type == 'MESH' and re.search(pattern, o.name)}
for o in list(bpy.data.objects):
    if o.name not in keep:
        bpy.data.objects.remove(o, do_unlink=True)
bpy.context.scene.world = None
objs = [o for o in bpy.data.objects if o.type == 'MESH']
for o in objs:
    if o.parent and o.parent.name not in keep:
        mw = o.matrix_world.copy(); o.parent = None; o.matrix_world = mw
bpy.context.view_layer.update()
pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
mid = (lo + hi) / 2
shift = Vector((0, 0, 0)) if anchor == 'scene' else Vector((-mid.x, -mid.y, -(lo.z if anchor == 'base' else mid.z)))
for o in objs:
    if o.parent is None:
        o.location += shift
bpy.context.view_layer.update()
if target_polys:
    for o in objs:
        n = len(o.data.polygons)
        if n > target_polys:
            bpy.ops.object.select_all(action='DESELECT')
            bpy.context.view_layer.objects.active = o; o.select_set(True)
            m = o.modifiers.new('Decimate', 'DECIMATE'); m.ratio = target_polys / n; m.use_collapse_triangulate = True
            bpy.ops.object.modifier_apply(modifier='Decimate')
polys = sum(len(o.data.polygons) for o in objs)
print(f'GROUP {out.split("/")[-1]}: objects={len(objs)} polys={polys} size=({hi.x-lo.x:.3f},{hi.y-lo.y:.3f},{hi.z-lo.z:.3f})')
bpy.ops.wm.save_as_mainfile(filepath=out)
