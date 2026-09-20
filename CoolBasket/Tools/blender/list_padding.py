import bpy
from mathutils import Vector
for o in sorted(bpy.data.objects, key=lambda o: o.name):
    if o.type != 'MESH': continue
    n=o.name
    if n.startswith('Padding') or n.startswith('Post') or n.startswith('Adjustment') or n.startswith('Support') or n.startswith('Crank') or n.startswith('Arm') or n.startswith('Bracket'):
        zs=[(o.matrix_world @ Vector(c)).z for c in o.bound_box]
        print('OBJ %-52s z %.3f %.3f' % (n, min(zs), max(zs)))
