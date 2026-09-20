import bpy
seen=set()
for o in bpy.data.objects:
    if o.type!='MESH': continue
    for slot in o.material_slots:
        m=slot.material
        if not m or m.name in seen: continue
        seen.add(m.name)
        pr=next((n for n in m.node_tree.nodes if n.type=='BSDF_PRINCIPLED'), None) if m.use_nodes else None
        if pr:
            c=pr.inputs['Base Color'].default_value; linked=pr.inputs['Base Color'].is_linked
            print('MAT %-45s base (%.3f %.3f %.3f)%s metal %.2f rough %.2f' % (m.name, c[0],c[1],c[2], ' [linked]' if linked else '', pr.inputs['Metallic'].default_value, pr.inputs['Roughness'].default_value))
