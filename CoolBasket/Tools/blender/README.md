# CoolBasket models

How `Resources/Models/basketball` and `Resources/Models/hoop` were made from
the artist's `basketball.blend` and `basketball_hoop.blend`. The shared
scripts and the exporter recipe are in [`Tools/blender`](../../../Tools/blender)
at the repository root; the ones here are specific to these two models.

```bash
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
EXPORT=~/Projects/Untold/UntoldEngine/Scripts/export-untold
```

## Basketball

A 295k-polygon sculpt with a procedural Mix-Shader material.

```bash
$BLENDER -b basketball.blend --python prep_ball.py -- basketball_prep.blend       # keep the ball and valve, decimate to ~24k faces (48k tris)
$BLENDER -b basketball_prep.blend --python ../../../Tools/blender/flatten_materials.py -- basketball_flat.blend
$EXPORT --input basketball_flat.blend --output out/basketball/basketball.untold --convert-orientation --bake-materials --bake-resolution 1024
```

Bakes the seams and pebbling into base colour, normal and ORM textures. The
model's origin is the ball's centre; `CoolBasketModelTests` checks its bounds
against `CoolBasketScene.ballRadius`.

## Hoop

A 125-part regulation unit. `prep_hoop.py` converts the net cords, hooks and
padding seams (bevelled curves) to meshes, removes the 26 screw-thread meshes
(53k polygons of thread), makes the backboard glass translucent, lifts the
near-black paint to dark greys that take light, and lowers the whole board
assembly by `DROP` metres — shortening the post, its padding and the padding's
seams with it, leaving the straps alone.

```bash
$BLENDER -b basketball_hoop.blend --python prep_hoop.py -- hoop_prep.blend
$EXPORT --input hoop_prep.blend --output out/hoop/hoop.untold --convert-orientation   # no bake: constant colours
```

The script prints the rim centre, glass, post and padding heights it produced.

### Changing the rim height

The scene reads the model, not the other way round: `CoolBasketScene.rimHeight`
is the model's rim height, `modelDrop = 3.05 − rimHeight` derives the post,
and the net's lattice heights (`CoolBasketNetLattice`) are offsets from the
rim. To move the rim:

1. Set `DROP = 3.05 − <new rim height>` in `prep_hoop.py`, run the two
   commands above and copy `hoop.untold` over `Resources/Models/hoop/hoop.untold`.
2. Set `rimHeight` in `CoolBasketScene.swift`.
3. Run `swift test`: `CoolBasketModelTests` reads the shipped model and fails
   if the rim, glass, post, hooks, knots, scallops or padding disagree with
   the constants.

### Diagnostics

- `dump_net.py` — writes `net_geometry.json` next to the prepared `.blend`:
  the rim centre, the 12 hook attachment points, the 60 knot centres by row,
  the scallop bottoms and cord endpoints, in engine coordinates. The lattice
  in `CoolBasketNet.swift` was read from it.
- `list_colors.py` — prints every material's base colour, metalness and
  roughness (how the near-black paint was found).
- `list_padding.py` — prints the height range of the post, padding, support
  and adjustment parts (which parts a drop must move or shorten).

```bash
$BLENDER -b hoop_prep.blend --python dump_net.py
$BLENDER -b basketball_hoop.blend --python list_colors.py | grep ^MAT
$BLENDER -b basketball_hoop.blend --python list_padding.py | grep ^OBJ
```
