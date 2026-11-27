"""Export one of the artist's own simulation meshes for the lab, untouched.

The artist's .blend carries, beside each render shirt, a mesh named
"... - XPBD simulation". The CoolZombie cook never used it: its proxies are
decimated from the render shirt. This script writes that mesh as it is
(triangulated, nothing merged, nothing moved) in the frame and scale of the
cooked proxies, so the lab can hang it beside them.

    SRC=<Zombie_new_cloth.blend> OBJECT="Clean shirt - XPBD simulation" \
    REFERENCE=<shirt4k.json> OUT=<shirtArtist.json> \
    /Applications/Blender.app/Contents/MacOS/Blender -b --python-exit-code 1 \
        --python Tools/blender/export_sim_mesh.py

The frame is found, not assumed: Blender's (x, y, z) goes to the engine's
(+-x, z, +-y), scaled and moved so the bounding boxes match, and of the four
sign choices the one whose vertices land nearest the reference proxy wins.
A vertex is marked as a cooked pin when the nearest reference particle is
one (the collar and the cuffs).

The mesh's UV map is written too, as the garment's flat sewing pattern: per
triangle, its three corners in the pattern, in metres. It is the pattern
only if it is isometric, which the script measures (each edge's length on
the body against its length in the UV map) and logs.
"""
import json
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils.kdtree import KDTree

SRC = os.path.expanduser(os.environ.get("SRC", "~/Downloads/Zombie_new_cloth/Zombie_new_cloth.blend"))
OBJECT = os.environ.get("OBJECT", "Clean shirt - XPBD simulation")
REFERENCE = os.environ["REFERENCE"]
OUT = os.environ["OUT"]


def log(*a):
    print("export_sim_mesh:", *a, flush=True)


bpy.ops.wm.open_mainfile(filepath=SRC)
obj = bpy.data.objects.get(OBJECT)
if obj is None or obj.type != "MESH":
    log("FAIL no mesh object named", OBJECT)
    sys.exit(1)
if obj.modifiers:
    log("modifiers ignored:", [(m.type, m.name) for m in obj.modifiers])

bm = bmesh.new()
bm.from_mesh(obj.data)
bmesh.ops.triangulate(bm, faces=bm.faces[:])
bm.verts.ensure_lookup_table()
world = obj.matrix_world
blender = np.array([tuple(world @ v.co) for v in bm.verts], dtype=np.float64)
triangles = [[v.index for v in f.verts] for f in bm.faces]
uv_layer = bm.loops.layers.uv.active
corner_uvs = [[tuple(l[uv_layer].uv) for l in f.loops] for f in bm.faces] if uv_layer else None

# ---- mesh facts, as found
edge_faces = {}
for f in bm.faces:
    for e in f.edges:
        edge_faces.setdefault(e.index, 0)
        edge_faces[e.index] += 1
boundary = sum(1 for n in edge_faces.values() if n == 1)
non_manifold = sum(1 for n in edge_faces.values() if n > 2)
seen, pieces = set(), []
for v in bm.verts:
    if v.index in seen:
        continue
    stack, size = [v], 0
    seen.add(v.index)
    while stack:
        u = stack.pop()
        size += 1
        for e in u.link_edges:
            w = e.other_vert(u)
            if w.index not in seen:
                seen.add(w.index)
                stack.append(w)
    pieces.append(size)
pieces.sort(reverse=True)
lengths = np.array([e.calc_length() for e in bm.edges]) * 1000
log(f"{OBJECT}: {len(bm.verts)} vertices, {len(triangles)} triangles, {len(pieces)} piece(s) {pieces[:10]}, "
    f"{boundary} boundary edges, {non_manifold} non-manifold edges")

# ---- into the proxies' frame
with open(REFERENCE) as f:
    reference = json.load(f)
ref = np.array(reference["particles"], dtype=np.float64)
ref_pins = set(reference["cookedPins"])
tree = KDTree(len(ref))
for i, p in enumerate(ref):
    tree.insert(p, i)
tree.balance()

best = None
for sx in (1, -1):
    for sz in (1, -1):
        candidate = np.stack([sx * blender[:, 0], blender[:, 2], sz * blender[:, 1]], axis=1)
        lo, hi = candidate.min(0), candidate.max(0)
        rlo, rhi = ref.min(0), ref.max(0)
        scale = (rhi[0] - rlo[0]) / (hi[0] - lo[0])
        placed = (candidate - (lo + hi) / 2) * scale + (rlo + rhi) / 2
        sample = placed[:: max(1, len(placed) // 1500)]
        distance = float(np.mean([tree.find(p)[2] for p in sample]))
        if best is None or distance < best[0]:
            best = (distance, sx, sz, scale, placed)
distance, sx, sz, scale, placed = best
log(f"frame: engine = ({'+' if sx > 0 else '-'}x, z, {'+' if sz > 0 else '-'}y) x {scale:.4f}; "
    f"mean distance to the reference proxy {distance * 1000:.1f} mm")
edge_mm = lengths * scale
log(f"edges {edge_mm.min():.1f}/{np.percentile(edge_mm, 10):.1f}/{np.median(edge_mm):.1f}/"
    f"{np.percentile(edge_mm, 90):.1f}/{edge_mm.max():.1f} mm (min/p10/median/p90/max)")
# A mirrored frame turns the triangles inside out; turn them back.
if sx * sz < 0:
    triangles = [[a, c, b] for a, b, c in triangles]
    if corner_uvs:
        corner_uvs = [[a, c, b] for a, b, c in corner_uvs]

# ---- the flat pattern: the UV map at the scale of the body
pattern = None
if corner_uvs:
    ratios = []
    for tri, uvs in zip(triangles, corner_uvs):
        for k in range(3):
            on_body = float(np.linalg.norm(placed[tri[k]] - placed[tri[(k + 1) % 3]]))
            in_uv = float(np.hypot(uvs[k][0] - uvs[(k + 1) % 3][0], uvs[k][1] - uvs[(k + 1) % 3][1]))
            if in_uv > 1e-12:
                ratios.append(on_body / in_uv)
    ratios = np.array(ratios)
    metres_per_uv = float(np.median(ratios))
    strain = np.abs(ratios / metres_per_uv - 1) * 100
    log(f"pattern: 1 UV unit = {metres_per_uv:.6f} m; the body's edges differ from the pattern's by "
        f"{strain.mean():.2f}% on average, {np.percentile(strain, 90):.2f}% at p90, {np.percentile(strain, 99):.2f}% at p99")
    pattern = [[round(c * metres_per_uv, 6) for uv in uvs for c in uv] for uvs in corner_uvs]

# ---- the panels: triangles joined in the pattern are one cut piece of fabric
panels, interfaced = None, []
if corner_uvs:
    at = {}
    for ti, (tri, uvs) in enumerate(zip(triangles, corner_uvs)):
        for v, uv in zip(tri, uvs):
            at.setdefault((v, round(uv[0], 4), round(uv[1], 4)), []).append(ti)
    panels = [-1] * len(triangles)
    count = 0
    for start in range(len(triangles)):
        if panels[start] >= 0:
            continue
        panels[start] = count
        stack = [start]
        while stack:
            t = stack.pop()
            for v, uv in zip(triangles[t], corner_uvs[t]):
                for other in at[(v, round(uv[0], 4), round(uv[1], 4))]:
                    if panels[other] < 0:
                        panels[other] = count
                        stack.append(other)
        count += 1
    # A shirt's cuffs and collar are interfaced: a second, stiff layer is
    # fused inside them. Here they are the panels far out along the arms
    # and the ones up at the neck.
    centre_x = (placed[:, 0].min() + placed[:, 0].max()) / 2
    for p in range(count):
        vertices = sorted({v for t, tri in enumerate(triangles) if panels[t] == p for v in tri})
        centre = placed[vertices].mean(0)
        kind = "cuff" if abs(centre[0] - centre_x) > 0.40 else "collar" if centre[1] > 1.40 else None
        if kind:
            interfaced.append(p)
        log(f"panel {p}: {sum(1 for q in panels if q == p)} triangles, centre {np.round(centre, 2)}" + (f" -> interfaced ({kind})" if kind else ""))

pins = []
for i, p in enumerate(placed):
    _, index, d = tree.find(p)
    if index in ref_pins and d < 0.02:
        pins.append(i)

with open(OUT, "w") as f:
    json.dump({
        "name": "shirt",
        "source": f"{os.path.basename(SRC)}: {OBJECT}",
        "particles": [[round(float(c), 6) for c in p] for p in placed],
        "triangles": triangles,
        "cookedPins": pins,
        **({"pattern": pattern, "panels": panels, "interfacedPanels": interfaced} if pattern else {}),
    }, f, separators=(",", ":"))
log(f"{OUT}: {len(placed)} particles, {len(triangles)} triangles, {len(pins)} cooked pins")
