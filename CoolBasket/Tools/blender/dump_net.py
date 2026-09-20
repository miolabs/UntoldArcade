import bpy, json, math
from mathutils import Vector
def world_verts(o):
    return [o.matrix_world @ v.co for v in o.data.vertices]
def eng(v):  # Blender (x,y,z) -> engine (x, z, -y)
    return [round(v.x,4), round(v.z,4), round(-v.y,4)]
rim = bpy.data.objects['Rim | 457 mm clear opening']
bb = [rim.matrix_world @ Vector(c) for c in rim.bound_box]
rc = Vector([sum(v[i] for v in bb)/8 for i in range(3)])
out = {'rim_center': eng(rc), 'rim_radius': round((max(v.x for v in bb)-min(v.x for v in bb))/4,4)}
# hooks: attachment = lowest vertex
hooks=[]
for i in range(1,13):
    o = bpy.data.objects['Rim | welded net hook %02d' % i]
    vs = world_verts(o); low = min(vs, key=lambda v: v.z)
    ang = math.degrees(math.atan2(low.y-rc.y, low.x-rc.x)) % 360
    r = math.hypot(low.x-rc.x, low.y-rc.y)
    hooks.append({'i': i, 'p': eng(low), 'angle': round(ang,1), 'r': round(r,4), 'zmin': round(low.z,4)})
out['hooks']=hooks
def clusters(vs, cell):
    bins={}
    for v in vs:
        k=(round(v.x/cell), round(v.y/cell), round(v.z/cell)); bins.setdefault(k,[]).append(v)
    # merge adjacent bins greedily
    keys=list(bins); merged=[]; used=set()
    for k in keys:
        if k in used: continue
        group=list(bins[k]); used.add(k); stack=[k]
        while stack:
            c=stack.pop()
            for dx in (-1,0,1):
                for dy in (-1,0,1):
                    for dz in (-1,0,1):
                        n=(c[0]+dx,c[1]+dy,c[2]+dz)
                        if n in bins and n not in used:
                            used.add(n); group+=bins[n]; stack.append(n)
        merged.append(Vector([sum(v[i] for v in group)/len(group) for i in range(3)]))
    return merged
knots = clusters(world_verts(bpy.data.objects['Net_Knots']), 0.012)
kn=[]
for c in knots:
    ang = math.degrees(math.atan2(c.y-rc.y, c.x-rc.x)) % 360
    kn.append({'p': eng(c), 'angle': round(ang,1), 'r': round(math.hypot(c.x-rc.x,c.y-rc.y),4), 'z': round(c.z,4)})
kn.sort(key=lambda k:(-k['z'], k['angle']))
out['knots']=kn; out['knot_count']=len(kn)
sc = world_verts(bpy.data.objects['Net_Open_Bottom_Scallops'])
# scallop bottoms: lowest vertices per 30-degree sector
sect={}
for v in sc:
    ang = math.degrees(math.atan2(v.y-rc.y, v.x-rc.x)) % 360
    s=int(ang//30)
    if s not in sect or v.z < sect[s].z: sect[s]=v
out['scallop_bottoms']=[{'sector':s,'p':eng(v),'angle':round(math.degrees(math.atan2(v.y-rc.y, v.x-rc.x))%360,1),'r':round(math.hypot(v.x-rc.x,v.y-rc.y),4)} for s,v in sorted(sect.items())]
out['scallop_z']=[round(min(v.z for v in sc),4), round(max(v.z for v in sc),4)]
for name in ['Net_Clockwise_Cords','Net_Counterclockwise_Cords','Net_Rim_Attachment_Loops','Net_Knots','Net_Open_Bottom_Scallops']:
    o=bpy.data.objects[name]; vs=world_verts(o)
    out[name]={'verts':len(vs),'z':[round(min(v.z for v in vs),4),round(max(v.z for v in vs),4)],'r':[round(min(math.hypot(v.x-rc.x,v.y-rc.y) for v in vs),4),round(max(math.hypot(v.x-rc.x,v.y-rc.y) for v in vs),4)]}
# cord endpoints: cluster cord vertices near the top (z>3.0) and bottom (z<2.68)
cw = world_verts(bpy.data.objects['Net_Clockwise_Cords'])
top = [v for v in cw if v.z > 3.02]; bot=[v for v in cw if v.z < 2.68]
out['cw_top_clusters']=[{'angle':round(math.degrees(math.atan2(c.y-rc.y,c.x-rc.x))%360,1),'r':round(math.hypot(c.x-rc.x,c.y-rc.y),4),'z':round(c.z,4)} for c in clusters(top,0.01)]
out['cw_bot_clusters']=[{'angle':round(math.degrees(math.atan2(c.y-rc.y,c.x-rc.x))%360,1),'r':round(math.hypot(c.x-rc.x,c.y-rc.y),4),'z':round(c.z,4)} for c in clusters(bot,0.01)]
json.dump(out, open(bpy.path.abspath('//net_geometry.json'),'w'), indent=1)
print('DUMP ok knots', len(kn))
