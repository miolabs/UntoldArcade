import bpy, sys, re
from mathutils import Vector
out = sys.argv[sys.argv.index('--') + 1]
DROP = 0.30  # lower the regulation 3.05 m rim to 2.75 m (3.05 is too high to play under in a room); CoolBasketScene.rimHeight = 3.05 − DROP
def zrange(o):
    zs = [(o.matrix_world @ Vector(c)).z for c in o.bound_box]
    return min(zs), max(zs)
removed = 0
# The net cords, hooks and padding seams are bevelled curves: make them meshes
# so the exporter (meshes only) keeps them.
curves = [o for o in bpy.data.objects if o.type == 'CURVE']
bpy.ops.object.select_all(action='DESELECT')
for o in curves:
    o.select_set(True)
if curves:
    bpy.context.view_layer.objects.active = curves[0]
    bpy.ops.object.convert(target='MESH')
print('converted curves', len(curves))
for o in list(bpy.data.objects):
    n = o.name
    if o.type in ('LIGHT', 'CAMERA') or (o.type == 'MESH' and (n.startswith('Studio') or n.startswith('Adjustment | screw thread'))):
        bpy.data.objects.remove(o, do_unlink=True); removed += 1
print('removed', removed)
# The glass: translucent in the engine (the exporter reads Alpha + the
# blended render method), not a solid pale slab.
glass = bpy.data.materials.get('Backboard | clear tempered glass')
if glass:
    pr = next(n for n in glass.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
    pr.inputs['Alpha'].default_value = 0.35
    pr.inputs['Transmission Weight'].default_value = 0.0
    pr.inputs['Roughness'].default_value = 0.05
    try: glass.surface_render_method = 'BLENDED'
    except Exception as e: print('render method', e)
    try: glass.blend_method = 'BLEND'
    except Exception as e: print('blend_method', e)
def scale_z_keep_bottom(o, new_top):
    z0, z1 = zrange(o)
    f = (new_top - z0) / (z1 - z0)
    o.scale.z *= f
    bpy.context.view_layer.update()
    nz0, _ = zrange(o)
    o.location.z += z0 - nz0
upper = []
for o in bpy.data.objects:
    if o.type != 'MESH': continue
    z0, z1 = zrange(o)
    if z0 >= 1.85:
        upper.append(o)
for o in upper:
    o.location.z -= DROP
if DROP > 0:
    pass
bpy.context.view_layer.update()
post = bpy.data.objects['Post | main 230 mm square column']
if DROP > 0: scale_z_keep_bottom(post, 2.88 - DROP)
# The post padding: the tall front protector (0.44-1.655) would run into the
# lowered pivot cheeks, so it is shortened by the drop with its vertical
# stitched seams (bevelled curves, converted above); the horizontal seam ring
# near its top comes down with it; the straps and clasps (thin bands lower on
# the post) stay where they are.
if DROP > 0:
    for o in bpy.data.objects:
        if o.type != 'MESH' or not o.name.startswith('Padding |'): continue
        z0, z1 = zrange(o)
        if z0 >= 1.85: continue
        if 'tall front post protector' in o.name or 'vertical stitched seam' in o.name:
            scale_z_keep_bottom(o, z1 - DROP)
        elif z1 > 1.5:
            o.location.z -= DROP
    bpy.context.view_layer.update()
for o in bpy.data.objects:
    if o.type == 'MESH' and o.name.startswith('Padding |'):
        z0, z1 = zrange(o); print('PADDING %-45s z %.3f %.3f' % (o.name, z0, z1))
bpy.context.view_layer.update()
polys = sum(len(o.data.polygons) for o in bpy.data.objects if o.type == 'MESH')
for o in bpy.data.objects:
    if o.type == 'MESH' and ('Net' in o.name or 'hook' in o.name):
        print('NETPART', o.name, len(o.data.polygons))
rim = bpy.data.objects['Rim | 457 mm clear opening']
bb = [rim.matrix_world @ Vector(c) for c in rim.bound_box]
print('HOOP objects', len([o for o in bpy.data.objects if o.type=='MESH']), 'polys', polys, 'lowered', len(upper))
print('RIM center', tuple(round(sum(v[i] for v in bb)/8, 3) for i in range(3)), 'z', round(min(v.z for v in bb),3), round(max(v.z for v in bb),3))
glass = bpy.data.objects['Backboard | 12 mm tempered glass']; bb = [glass.matrix_world @ Vector(c) for c in glass.bound_box]
print('GLASS x', round(min(v.x for v in bb),3), round(max(v.x for v in bb),3), 'y', round(min(v.y for v in bb),3), round(max(v.y for v in bb),3), 'z', round(min(v.z for v in bb),3), round(max(v.z for v in bb),3))
post_bb = [post.matrix_world @ Vector(c) for c in post.bound_box]
print('POST x', round(min(v.x for v in post_bb),3), round(max(v.x for v in post_bb),3), 'y', round(min(v.y for v in post_bb),3), round(max(v.y for v in post_bb),3), 'z', round(min(v.z for v in post_bb),3), round(max(v.z for v in post_bb),3))
# The unit is painted near-black (powder coat 0.01, charcoal vinyl 0.004):
# under the engine's light it renders as a silhouette. Lift the dark
# materials to dark greys that still read as black paint but take light.
LIFT = {
    'Steel | graphite powder coat': ((0.11, 0.115, 0.125), 0.25, 0.38),
    'Padding | charcoal vinyl': ((0.075, 0.075, 0.08), 0.0, 0.7),
    'Padding | seam piping': ((0.09, 0.09, 0.095), 0.0, 0.72),
    'Hardware | black oxide': ((0.13, 0.135, 0.145), 0.6, 0.36),
}
for name, (rgb, metal, rough) in LIFT.items():
    m = bpy.data.materials.get(name)
    if not m or not m.use_nodes: continue
    pr = next((n for n in m.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
    if not pr: continue
    pr.inputs['Base Color'].default_value = (rgb[0], rgb[1], rgb[2], 1.0)
    pr.inputs['Metallic'].default_value = metal
    pr.inputs['Roughness'].default_value = rough
    print('LIFTED', name, rgb)
bpy.context.scene.world = None
bpy.ops.wm.save_as_mainfile(filepath=out)
