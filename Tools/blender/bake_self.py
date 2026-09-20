# Bake each mesh's procedural materials (base colour, roughness, normal)
# into one image set per object on its 0-1 'Bake' UV layer, then replace
# the materials with plain textured Principled BSDFs the exporter reads.
import bpy, sys, os
args = sys.argv[sys.argv.index('--') + 1:]
res, outdir = int(args[0]), args[1]
os.makedirs(outdir, exist_ok=True)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 16
scene.render.bake.margin = 8
scene.render.bake.use_pass_direct = False
scene.render.bake.use_pass_indirect = False
scene.render.bake.use_pass_color = True

def safe(name):
    return ''.join(c if c.isalnum() else '_' for c in name)

meshes = [o for o in bpy.data.objects if o.type == 'MESH' and o.data.materials]
for o in meshes:
    # Own copies of the materials, so an active image node per object is possible.
    for i, m in enumerate(o.data.materials):
        if m is not None and m.users > 1:
            o.data.materials[i] = m.copy()
    uv = o.data.uv_layers.get('Bake') or o.data.uv_layers.active
    o.data.uv_layers.active = uv
    images = {}
    for kind, btype, srgb in (('basecolor', 'DIFFUSE', True), ('roughness', 'ROUGHNESS', False), ('normal', 'NORMAL', False)):
        img = bpy.data.images.new(f'{safe(o.name)}_{kind}', res, res, alpha=False, float_buffer=False)
        img.colorspace_settings.name = 'sRGB' if srgb else 'Non-Color'
        nodes_added = []
        for m in o.data.materials:
            if m is None: continue
            m.use_nodes = True
            n = m.node_tree.nodes.new('ShaderNodeTexImage'); n.image = img
            m.node_tree.nodes.active = n
            nodes_added.append((m, n))
        bpy.ops.object.select_all(action='DESELECT')
        bpy.context.view_layer.objects.active = o
        o.select_set(True)
        bpy.ops.object.bake(type=btype)
        path = os.path.join(outdir, f'{img.name}.png')
        img.filepath_raw = path; img.file_format = 'PNG'; img.save()
        for m, n in nodes_added:
            m.node_tree.nodes.remove(n)
        images[kind] = img
        print('BAKED', o.name, kind)
    # One plain material per object, textured from the bakes.
    mat = bpy.data.materials.new(f'{safe(o.name)}_baked'); mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes): nt.nodes.remove(n)
    out = nt.nodes.new('ShaderNodeOutputMaterial'); pr = nt.nodes.new('ShaderNodeBsdfPrincipled')
    nt.links.new(pr.outputs['BSDF'], out.inputs['Surface'])
    uvn = nt.nodes.new('ShaderNodeUVMap'); uvn.uv_map = uv.name
    for kind, sock in (('basecolor', 'Base Color'), ('roughness', 'Roughness')):
        t = nt.nodes.new('ShaderNodeTexImage'); t.image = images[kind]
        nt.links.new(uvn.outputs['UV'], t.inputs['Vector'])
        nt.links.new(t.outputs['Color'], pr.inputs[sock])
    t = nt.nodes.new('ShaderNodeTexImage'); t.image = images['normal']
    nm = nt.nodes.new('ShaderNodeNormalMap'); nm.uv_map = uv.name
    nt.links.new(uvn.outputs['UV'], t.inputs['Vector'])
    nt.links.new(t.outputs['Color'], nm.inputs['Color']); nt.links.new(nm.outputs['Normal'], pr.inputs['Normal'])
    o.data.materials.clear(); o.data.materials.append(mat)
    for p in o.data.polygons: p.material_index = 0
    # The bake layer becomes the only UV layer the exporter will see first.
    for layer in list(o.data.uv_layers):
        if layer.name != uv.name: o.data.uv_layers.remove(layer)
bpy.ops.wm.save_mainfile()
print('DONE', len(meshes))
