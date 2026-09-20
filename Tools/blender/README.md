# Blender → `.untold` tools

Scripts shared by the demos for turning artist `.blend` files into the
`.untold` assets bundled under each demo's `Resources/Models/<name>/`. Each
runs headless inside Blender (5.x) on a copy of the source file:

```bash
/Applications/Blender.app/Contents/MacOS/Blender -b source.blend --python <script>.py -- <args>
```

then the engine's exporter cooks the prepared file:

```bash
~/Projects/Untold/UntoldEngine/Scripts/export-untold --input prepared.blend --output out/<name>/<name>.untold --convert-orientation [--bake-materials --bake-resolution N] [--validate]
```

`--convert-orientation` maps Blender's z-up scene to the engine's y-up:
(x, y, z) → (x, z, −y). The output folder holds `<name>.untold`, a
`Textures/` folder when materials are baked, and an `HDR/` folder of the
viewport's studio lights — never bundle `HDR/`. Copy `<name>.untold` (and
`Textures/`) to the demo's `Resources/Models/<name>/`; the engine finds the
model by that folder name.

## Scripts

| Script | Args (after `--`) | What it does |
|---|---|---|
| `prep_group.py` | `<out.blend> collection\|regex <name-or-pattern> base\|center\|scene [target_polys]` | Keeps one group of meshes (a collection, or objects whose name matches), drops the world lighting, re-anchors the group's origin (footprint centre with the base on z = 0, its centre, or leaves it in scene coordinates), decimates to a polygon budget, saves. |
| `flatten_materials.py` | `<out.blend>` | Collapses "Mix Shader of two Principled BSDFs" materials into one Principled with per-channel mixes: the exporter's baker refuses shader-level mixing above the Principled node. |
| `unwrap.py` | — (saves in place) | Gives every mesh a 0–1 `Bake` UV layer (smart projection). The baker writes into 0–1 UVs; meshes whose UVs tile far outside that range, or whose materials use object/generated coordinates, bake black without it. |
| `bake_self.py` | `<resolution> <outdir>` (saves in place) | Where the exporter's own baker gives black: per mesh, bakes base colour, roughness and normal with Cycles into one image set on the `Bake` layer and rebuilds the material as a textured Principled. Export afterwards **without** `--bake-materials`. |

## Things learned the hard way

- Only materials that differ from a plain Principled get baked, per (object,
  material): a shared material on 60 parts bakes 60 textures. Skip
  `--bake-materials` for hardware-like assets; use it for sculpted or
  procedural surfaces.
- Without a bake, procedural base colours export white; constant colours
  export as factors and are fine.
- Curves (bevelled cords, seams, hooks) are dropped by the exporter: convert
  them to meshes first (`bpy.ops.object.convert(target='MESH')`).
- Coplanar inlays z-fight in the engine: raise decals about 1.5 mm and drop
  subfloors that sit flush under a surface.
- Scaling a thin part with "keep the bottom" arithmetic can flip it: only
  scale parts taller than the change, and move separate decorations with
  the part they sit on. Read the export back to check — see
  `CoolBasket/Tests/CoolBasketTests/CoolBasketModelTests.swift` for a test
  that loads a `.untold` with `NativeFormatLoader` and pins node bounds to
  the scene's constants.
- Near-black materials (albedo around 1 %) render as silhouettes under any
  light; lift them to dark greys in the prep script rather than fighting the
  lighting.
