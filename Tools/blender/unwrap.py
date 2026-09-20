# Give every mesh a 0-1 UV layout (smart projection) so procedural
# materials can be baked into a square image; keep the original UVs aside.
import bpy, math
bpy.ops.object.select_all(action='DESELECT')
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
for o in meshes:
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    uv = o.data.uv_layers.new(name='Bake')
    o.data.uv_layers.active = uv
    uv.active_render = True
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.003, scale_to_bounds=True)
    bpy.ops.object.mode_set(mode='OBJECT')
    o.select_set(False)
print('UNWRAPPED', len(meshes))
bpy.ops.wm.save_mainfile()
