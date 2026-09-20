# CoolBowling models

How the assets under `Resources/Models` were cut out of the artist's
`Bowling_Lane_01.blend` (a regulation 19 m lane, ten 20k-polygon pins, four
balls, the ball-return unit and the pit cover, all with procedural
materials, organised in collections `01 Lane` … `05 Bowling balls`). Every
step uses the shared scripts in [`Tools/blender`](../../../Tools/blender) at
the repository root; nothing here is specific to one part.

```bash
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
EXPORT=~/Projects/Untold/UntoldEngine/Scripts/export-untold
PREP=../../../Tools/blender
```

## Free-standing parts (own origin)

`prep_group.py` keeps one collection, or the objects matching a name pattern,
re-anchors the group and decimates. Budgets used: pin 12k polygons, ball
10k, dispenser 1.8k, pit cover 170.

```bash
$BLENDER -b Bowling_Lane_01.blend --python $PREP/prep_group.py -- pin.blend regex '<one pin>' base 12000
$BLENDER -b Bowling_Lane_01.blend --python $PREP/prep_group.py -- bowlingball.blend regex 'Return ball 01' center 10000
$BLENDER -b Bowling_Lane_01.blend --python $PREP/prep_group.py -- dispenser.blend collection '<return unit>' base 1800
$BLENDER -b Bowling_Lane_01.blend --python $PREP/prep_group.py -- pitcover.blend collection '<pit cover>' base 170
$EXPORT --input pin.blend --output out/pin/pin.untold --convert-orientation
$EXPORT --input bowlingball.blend --output out/bowlingball/bowlingball.untold --convert-orientation --bake-materials --bake-resolution 512
$EXPORT --input dispenser.blend --output out/dispenser/dispenser.untold --convert-orientation --bake-materials --bake-resolution 512
$EXPORT --input pitcover.blend --output out/pitcover/pitcover.untold --convert-orientation
```

`base` puts the footprint centre at the origin with the bottom on the floor
(pins, the unit, the cover); `center` puts the centre at the origin (balls).
The exact collection and object names are the ones in the `.blend`'s
outliner.

## Alley parts (scene coordinates)

The approach, lane, arrows and deck spots are exported **in the scene's own
coordinates** (`scene` anchor: foul line at the origin, x right, y toward the
pins) so that `CoolBowlingScene` places them exactly as the Blender scene
does; the lane entity is then scaled along its length to the alley the room
allows.

The maple strips and parquet use procedural materials with UVs tiling far
outside 0–1, which the exporter's baker renders black; they are unwrapped
and baked in Blender first, then exported without `--bake-materials`.
Subfloors flush under the surfaces were excluded (z-fighting) and the inlays
(dots, foul line, arrows, spots) raised 1.5 mm.

```bash
$BLENDER -b Bowling_Lane_01.blend --python $PREP/prep_group.py -- lane.blend collection '01 Lane' scene
$BLENDER -b lane.blend --python $PREP/unwrap.py
$BLENDER -b lane.blend --python $PREP/bake_self.py -- 2048 lane_textures
$EXPORT --input lane.blend --output out/lane/lane.untold --convert-orientation

$BLENDER -b Bowling_Lane_01.blend --python $PREP/prep_group.py -- approach.blend collection '<approach>' scene
$BLENDER -b approach.blend --python $PREP/unwrap.py
$BLENDER -b approach.blend --python $PREP/bake_self.py -- 1024 approach_textures
$EXPORT --input approach.blend --output out/approach/approach.untold --convert-orientation

$BLENDER -b Bowling_Lane_01.blend --python $PREP/prep_group.py -- arrows.blend regex '<arrows>' scene
$BLENDER -b Bowling_Lane_01.blend --python $PREP/prep_group.py -- deckspots.blend regex '<deck spots>' scene
$EXPORT --input arrows.blend --output out/arrows/arrows.untold --convert-orientation
$EXPORT --input deckspots.blend --output out/deckspots/deckspots.untold --convert-orientation
```

The scene's measurements the code relies on (lane length 19.16 m, rails at
±0.865, the return unit's spot on the approach, the pit cover behind the
lane end) are constants in `CoolBowlingScene.swift`; re-measure them in
Blender if the source scene changes.
