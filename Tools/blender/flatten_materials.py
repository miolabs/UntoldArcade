# Collapse "Mix Shader of two Principled BSDFs" materials into one Principled
# with per-channel mixes, which the Untold exporter's baker can evaluate
# (it refuses shader-level mixing above the Principled node).
import bpy, sys
out = sys.argv[sys.argv.index('--') + 1]

def socket_source(sock):
    return sock.links[0].from_socket if sock.is_linked else None

def flatten(material):
    tree = material.node_tree
    nodes, links = tree.nodes, tree.links
    output = next((n for n in nodes if n.type == 'OUTPUT_MATERIAL' and n.is_active_output), None) or next((n for n in nodes if n.type == 'OUTPUT_MATERIAL'), None)
    if output is None: return False
    src = socket_source(output.inputs['Surface'])
    if src is None or src.node.type != 'MIX_SHADER': return False
    mix = src.node
    a = socket_source(mix.inputs[1]); b = socket_source(mix.inputs[2])
    if a is None or b is None or a.node.type != 'BSDF_PRINCIPLED' or b.node.type != 'BSDF_PRINCIPLED': return False
    A, Bn = a.node, b.node
    fac_src = socket_source(mix.inputs['Fac'])
    fac_val = mix.inputs['Fac'].default_value
    def mixed(channel, data_type):
        ia, ib = A.inputs[channel], Bn.inputs[channel]
        sa, sb = socket_source(ia), socket_source(ib)
        same_default = (sa is None and sb is None and (tuple(ia.default_value) if data_type == 'RGBA' else ia.default_value) == (tuple(ib.default_value) if data_type == 'RGBA' else ib.default_value))
        if same_default: return
        m = nodes.new('ShaderNodeMix'); m.data_type = data_type; m.label = f'flattened {channel}'
        ain = m.inputs[6] if data_type == 'RGBA' else m.inputs[2]
        bin_ = m.inputs[7] if data_type == 'RGBA' else m.inputs[3]
        if fac_src is not None: links.new(fac_src, m.inputs['Factor'])
        else: m.inputs['Factor'].default_value = fac_val
        for sock, srcsock, orig in ((ain, sa, ia), (bin_, sb, ib)):
            if srcsock is not None: links.new(srcsock, sock)
            else: sock.default_value = orig.default_value
        for l in list(ia.links): links.remove(l)
        links.new(m.outputs[2] if data_type == 'RGBA' else m.outputs[0], ia)
    mixed('Base Color', 'RGBA')
    for ch in ('Roughness', 'Metallic', 'Specular IOR Level'):
        if ch in A.inputs: mixed(ch, 'FLOAT')
    # Normal: keep A's (B usually shares it).
    links.remove(src.links[0]) if False else None
    for l in list(output.inputs['Surface'].links): links.remove(l)
    links.new(A.outputs['BSDF'], output.inputs['Surface'])
    nodes.remove(mix); nodes.remove(Bn)
    return True

changed = [m.name for m in bpy.data.materials if m.use_nodes and m.users and flatten(m)]
print('FLATTENED', changed)
bpy.context.scene.world = None
bpy.ops.wm.save_as_mainfile(filepath=out)
