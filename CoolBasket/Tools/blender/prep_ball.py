import bpy, sys
out = sys.argv[sys.argv.index('--') + 1]
keep = {'Ball | sculpted eight-panel surface', 'Valve | needle aperture', 'Valve | recessed rubber seat'}
for o in list(bpy.data.objects):
    if o.name not in keep:
        bpy.data.objects.remove(o, do_unlink=True)
ball = bpy.data.objects['Ball | sculpted eight-panel surface']
bpy.ops.object.select_all(action='DESELECT')
bpy.context.view_layer.objects.active = ball
ball.select_set(True)
mod = ball.modifiers.new('Decimate', 'DECIMATE')
mod.ratio = 24000 / len(ball.data.polygons)
mod.use_collapse_triangulate = True
bpy.ops.object.modifier_apply(modifier='Decimate')
ball.name = 'Basketball'
print('BALL polys', len(ball.data.polygons), 'dims', tuple(round(x, 3) for x in ball.dimensions))
bpy.ops.wm.save_as_mainfile(filepath=out)
