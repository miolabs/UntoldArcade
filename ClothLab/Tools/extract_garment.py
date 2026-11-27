"""Copy one garment's simulation mesh out of a CoolZombie cloth sidecar.

The lab keeps only what a bare cloth needs: the particles, the triangles and
which particles the cook pinned (maxDistance 0: collar and cuffs). No skin
targets, no colliders, no render shell.

    python3 Tools/extract_garment.py <Zombie.cloth.json> shirt <out.json>
"""
import json
import sys

source, garment_name, out = sys.argv[1:4]
with open(source) as f:
    sidecar = json.load(f)
garment = next(g for g in sidecar["garments"] if g["name"] == garment_name)
result = {
    "name": garment_name,
    "source": source.split("/")[-1],
    "particles": [[round(c, 6) for c in p] for p in garment["particles"]],
    "triangles": garment["triangles"],
    "cookedPins": [i for i, d in enumerate(garment["maxDistance"]) if d == 0],
}
with open(out, "w") as f:
    json.dump(result, f, separators=(",", ":"))
print(f"{out}: {len(result['particles'])} particles, {len(result['triangles'])} triangles, {len(result['cookedPins'])} cooked pins")
