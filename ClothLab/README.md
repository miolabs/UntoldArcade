# ClothLab

A bench for cloth. One piece of fabric, hung in front of a wall, one light,
a close-up orbit camera. Each step adds one thing and nothing else, and each
step is judged by eye before the next one is built.

It exists because the shirt on the CoolZombie character was built all at
once (proxy mesh, skin targets, back-stop, hull colliders, render shell, on
a moving character) and never looked like a shirt; two different solvers
showed the same defects, so the cause is in what they share. Here those
shared parts come in one at a time.

## Steps

| Step | What is on the bench | The question |
| --- | --- | --- |
| 1a Sheet | A plain 1.0 x 1.2 m sheet at the shirt proxy's particle spacing, hung by five hooks, two corners or its whole top edge | Does it hang and fold like fabric? |
| 1b Shirt alone | The shirt's simulation mesh, hung by its collar and shoulders. No body, no skin targets, no back-stop, no colliders, cuffs free. Three meshes to switch between: the cooked 3,995 proxy, the cooked 15,979 proxy, and the artist's own simulation mesh | Does the shirt hang and fold like fabric? Does the mesh change the answer? |

Later steps (not built): one collider under the cloth (sphere, box, capsule,
cylinder, one at a time), several colliders touching, a static human form
built shape by shape, slow motion, one bending joint, and only at the end
the animated character and the render shell.

## Run it

```bash
env -u TOOLCHAINS xcrun --toolchain XcodeDefault swift run -c release ClothLab
```

Launch arguments: `-step sheet|shirt`, `-sheetPin hooks|corners|edge`,
`-mesh 4k|16k|artist|artist4`, `-shirtPin shoulders|collar`, `-wire`, `-pins`,
`-substeps <n>`, `-stretch <compliance>`, `-bend <compliance>`,
`-damping <per second>`, `-rest draped|flat|pattern`, `-fabric soft|medium|crisp`, `-interfacing`.

In the window: drag orbits, Shift-drag or right-drag slides the view, scroll
or pinch zooms. `W` wireframe, `P` pins, `Space` pause, `R` hang again,
`F` frame the whole cloth, `B` hide or show the wall (to look at the cloth's
back), `L` let the light follow the view (the default: high and from the
viewer's left, so the side looked at is the lit one) or stay where it is. The menus along the top pick the step, the mesh and how it is hung.

Two aids for scripted looks, neither a judge of how the cloth looks:

- `-control <file>`: commands read from a text file whenever its text
  changes (`cam <yaw> <pitch> <distance>`, `target <x> <y> <z>`,
  `wire on|off`, `wall on|off`, `pause on|off`, `mesh 4k|16k|artist|artist4`, ...; the
  list is in `LabScene.readControl`). The app prints its window id at
  launch (`ClothLab: window <id>`) for `screencapture -l <id>`.
- `-headless <seconds>`: the solver alone, no window, a line of figures
  every half second (stretch, mean speed, bounds). It found the two faults
  of the first build: sweeping the constraints in alternating directions
  pumps energy in, and under about 30 substeps the stiff sheet never comes
  to rest.

## How it is built

- `ClothSolver.swift`: XPBD on the CPU, small steps, Gauss-Seidel. Two
  constraint families only: every edge keeps its length, and across every
  shared edge the two far vertices keep their distance (bending). Plain
  Swift, a few hundred lines, so every later layer is readable where it is
  added.
- `ClothMesh.swift`: the sheet generator, the garment loader, the pins, and
  the mesh's edges and bend pairs.
- `ClothDrawing.swift`: the simulated mesh drawn by the engine as a runtime
  mesh whose vertex buffers are rewritten every frame; drawn twice (front
  and back) because the engine culls back faces. Wireframe and pins are
  debug lines.
- `LabScene.swift`: the room, the light, the orbit camera, the steps.

## Garment data

`Resources/Garments/shirt4k.json` and `shirt16k.json` are the shirt of the
CoolZombie cloth sidecars with everything but the particles, the triangles
and the cook's pins removed (`Tools/extract_garment.py`).
`shirtArtist.json` is the artist's own "Clean shirt - XPBD simulation" mesh
from `Zombie_new_cloth.blend`, written untouched in the proxies' frame
(`Tools/blender/export_sim_mesh.py`). The blend holds four such meshes; this
one is whole (hem, collar, two cuffs, and the five slits between the
buttons of the front). "MD Shirt - XPBD simulation" is the same mesh with two
holes torn in the chest and shoulder, "Refined" comes in three loose pieces
and "Damaged" is the torn one.
