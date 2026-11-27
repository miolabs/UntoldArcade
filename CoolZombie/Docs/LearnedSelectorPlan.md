# Zombie Director v0: a small model picks the kind of motion

Paths: DEMO = `/Users/godshadow/Projects/Untold/UntoldArcade-anim/CoolZombie`. ENGINE = a new worktree `/Users/godshadow/Projects/Untold/UntoldEngine-anim` (the shared checkout stays on develop; it has uncommitted edits and other sessions use it). Branch `feature/zombie_learned_animation` in both repos. The engine branch starts at the commit the demo pins today (b2571c37) so step 1 changes one thing; it is rebased onto develop for the PR.

## What the model decides and what stays as it is

- Ten times a second a small network reads the chase situation and says which kind of motion is wanted. Eight families: stand, straight, arc left, arc right, pivot left, pivot right, start, stop.
- Families are tagged per segment of a clip, from the written path the clip was generated from, not per clip. The turn, start and stop clips hold about 41 s of plain straight travel (the second before and after each turn) against 30 s in the six straight clips; tagging whole clips would tax that walking and force a jump out of every turn's tail.
  - stand: k_idle, k_hold_1, k_hold_2, and the standing parts of starts, stops and standing turns
  - straight: the six straight clips and the straight parts of the others
  - arc / pivot / start / stop: the arc, pivot and speed-ramp segments of the 12 arc clips, 8 pivot clips, 2 starts, 2 stops
  - back and side walks: untagged, average bias
- The family probabilities become an additive cost per tagged frame inside the existing search. The matcher still picks the clip, the frame and the moment to jump.
- Unchanged: phase machine, speed ramp, goal, wall contact, arms, ragdoll, inertialization, root motion, hysteresis (0.9 margin, minimum gain, 0.3 s minimum play time), one-shot handling. No hand-written rule is deleted.
- Today nothing makes this decision explicitly; it falls out of a 27-float nearest-neighbour search that sees 1 s ahead. With the selector off the bias is empty and behaviour is identical to today.

## Why this first, and what should look different

- It is "decide which animation" taken literally, kept inside the matcher, and judged by eye before anything is trained (families forced by hand on day 3). The labels come from the clip specs, not from the matcher, so the model cannot simply copy today.
- Honest expectation. The matcher already picks pivots and arcs on this set: in the last measured runs (headless harness, 9 Sept, old rig, shipped settings) the flip shot played k_pivot_l_180 and k_pivot_r_90 and the orbit about 7 s of arcs in 25 s, and the mesh turning under still feet was already cut to 0.3 rad/s. So do not expect "pivots appear". What can change: the turn starting sooner after a flip (1.1 s to face, 18 % of frames more than 30 degrees off), and fewer hops between unlike takes while travelling (1.7-3.4 jumps a second, each a visible pop).
- Nothing has been measured since the rig swap of 27 Oct. Step 1 shows, on the current rig, whether the playing kind and the situation disagree at all. If they rarely do, we know on day 2 and point the model at another decision before training anything.
- Neural Engine: 10 calls a second, asynchronous, a 0.1 s old answer is harmless. That is the kind of call it suits. It buys no speed for a model this small. Apple publishes no call cost for small models, so step 3 measures median and worst and prints them. Judgement, to be confirmed by that number: a per-frame pose model at 90 Hz belongs on the CPU. Core ML may still place this model on the CPU (the setting allows the Neural Engine, it cannot force it); the screen says so.

## Data and labels

- Data: the 36 committed Kimodo clips only (133 s, 4,003 frames, 30 fps, 53 joints; verified). 100STYLE has no turn clips and no written specs to label from. The pack is excluded (binary-only licence, no recorded permission to train, old rig).
- One segment table (clip, start time, family), generated from `DEMO/Tools/runpod/clips.json` and `clips_core.json` minus the cook trims in `cook_options.json` (8 clips are trimmed: start heads 0.7 s, stop tails 1.0 s, standing turns 0.3 s / 0.5 s). The trainer, the engine tags and the on-screen strip all read this one table.
- Label per frame: the lead-in and the defining segment carry that segment's family (wanting the turn before it starts is the point); the tail carries its own (straight or stand).
- Inputs per frame (6 floats), from root position and yaw read with the existing numpy reader `DEMO/Tools/train/read_untold_anim.py`: sin and cos of the turn still to do; planar speed now / 3.5; wanted speed 1 s ahead / 3.5; yaw rate / 3 rad/s; distance left to the stop point clamped to 4 m, / 4.
- Augmentation: mirror left/right, input jitter; about 100k rows.
- Check before training: print each segment's measured yaw and speed against its spec. Catches a left/right sign slip and a trim offset.
- Second label source from step 5: rows logged in the Mac app (`-recordSelector <file>`) while a person holds a family key; weighted above the spec rows.

## Training

- Network: 6 -> 64 -> 64 -> 8, ELU, softmax, about 5,000 parameters, fixed shape (1,6).
- One PyTorch script, `DEMO/Tools/train/train_selector.py`: cross-entropy, Adam, a few thousand steps; seconds to two minutes.
- Written and first run on the Mac CPU so NVIDIA access never blocks a visible step. The same script then runs on the NVIDIA box and the shipped weights come from that run. This proves the link for later models; it adds no capacity here.
- NVIDIA box: a studio machine if a host is given; otherwise a fresh small RunPod pod (the account has none today, checked), price stated before creating it. Stock PyTorch image; no version pin needed there.
- Outputs: weights, a confusion matrix by family, and a JSON sidecar (family table, input layout, hash of the segment table) so a model is never used with a different clip set.

## Runtime

- Export, on the Mac, in a venv with torch 2.7 (the ceiling coremltools 9.0 supports): `torch.jit.trace` -> coremltools 9.0 -> ML program, fp16, fixed (1,6), `minimum_deployment_target=ct.target.macOS14` (the package minimum; same model spec as iOS 17, loads on visionOS 2). Two variants from the same weights: plain linear layers, and Apple's Conv2d form. `xcrun coremlcompiler compile` to `.mlmodelc`, bundled as a copied resource beside `Resources/Animations` (`DEMO/Package.swift:46`).
- Compute unit: `.cpuAndNeuralEngine`, with `-selectorUnits ane|cpu`. Placement is read, not assumed: the Xcode Performance tab (layer dispatch), `MLComputePlan` at load (planned device per operation, macOS 14.4+), and the on-screen line.
- Call: one `MLModel` loaded once in the background, owned by one serial queue in a new `DEMO/Sources/CoolZombieKit/ZombieClipSelector.swift`. `update()` never calls predict: it posts the six inputs every 0.1 s (dropped if one is in flight) and reads the latest result under the existing lock. A result older than 0.5 s gives an empty bias.
- Bias: `bias(family) = k * (1 - p[family] / p_max)`, clamped to 0..k. k is set by eye in step 2 with `-selectorStrength` (sweep 3 to 30; the runway penalty is 3 but feature costs run to tens). A family must lead for two predictions before the bias moves.
- Engine seam (about 60 lines plus tests, no Core ML in the engine):
  1. Frame tags set once from the segment table, and eight bias floats set each tick, clamped to non-negative; both beside `setMotionMatchingGoal` (`Sources/UntoldEngine/Systems/AnimationSystem.swift:916-931`).
  2. Passed at the single search call, `Sources/UntoldEngine/Animation/MotionMatching.swift:363`.
  3. Added where the cost already starts from `runwayPenalties`: `Sources/UntoldEngine/Animation/MotionDatabase.swift:418` and `:430`. No other line of `search` changes.
  4. A public read of the playing clip name (`currentAnimation` is internal, `Sources/UntoldEngine/ECS/Components.swift:660`; the time is already public).
  5. Tests in `Tests/UntoldEngineTests/AnimationMotionMatchingTests.swift`: empty bias gives the same winner; a biased frame loses; a negative bias is clamped.
- Demo seam: inputs built and bias pushed beside the goal call at `DEMO/Sources/CoolZombieKit/ZombieChaseGame.swift:1194-1198`. The switch copies the clip-set one (`setClipSet` at 321-323, applied at 968-978). Menu beside Clips (`DEMO/Sources/CoolZombie/AppDelegate.swift:143`). Keys: F1-F8 hold a family, F9 toggles (the engine's key state has these; it has no M or number keys). Cube mode Flip beside orbit and behindWall (`DEMO/Sources/CoolZombie/ZombieScene.swift:470-485`).
- Sources checked: coremltools 9.0 release notes and source (PyTorch 2.7); Apple docs for MLComputeUnits, MLComputePlan and MLModel (one thread or queue at a time); Apple's "Deploying Transformers on the Apple Neural Engine" (Linear to Conv2d, Performance tab); Apple developer forum threads 758222 and 729942 (eligible models running on CPU).

## Steps

All eye checks: `swift run -c release CoolZombie -play -clipSet kimodo`.

1. **See what plays. Days 1-2.** Engine worktree and branch from the pin, with only the playing-clip read. Demo: one text line (playing clip, its segment family, heading error, speed), a 10 s strip (family by colour, a tick at every jump, a red row while more than 30 degrees off heading), cube mode Flip (the cube jumps behind, left and right every 6 s). Day 1 also: ask for the NVIDIA host.
   *The owner sees:* which kind of motion plays at each moment, for the first time, in Flip, Orbit and a straight approach. This answers whether the choice is wrong often enough to be worth a model.
2. **Move it by hand. Day 3.** Engine tags, bias and tests. Selector menu Off / Keys; F1-F8 favour a family; `-selectorStrength`.
   *The owner sees:* holding a pivot or arc key as the cube flips starts the turn sooner, or it does not; holding "straight" on the approach removes the hops, or it does not; F9 returns to today mid-run. Go/no-go for the idea.
3. **The whole chain, in shadow. Days 4-6.** Segment table and dataset script, trainer on the Mac CPU then on NVIDIA, Core ML export in both variants, Xcode Performance report, model loaded and called at 10 Hz. The model drives nothing.
   *The owner sees:* a second line, for example "playing straight | model wants pivot-left 0.81 | Neural Engine 0.4 ms, worst 2.1", changing colour when model and zombie disagree, plus the Xcode page showing where each layer ran.
4. **The model drives. Days 7-8.** Selector menu Off / Keys / Model.
   *The owner sees:* the zombie choosing by itself in three fixed shots (Flip; Orbit; Open layout with Cube = Behind wall), eight probability bars beside the strip, F9 flipping between today and the model mid-chase, and recordings against step 1.
5. **One retrain from what the eye caught. Days 9-10.** Take his worst remark from step 4. Pause, replay in Keys mode holding the right family; the app logs the rows. Retrain on NVIDIA, ship as v2. Target: under 30 minutes from remark to new model in the app.
   *The owner sees:* Selector Off / v1 / v2; the wrong choice he pointed at is right in v2, and he can flip back to confirm.
6. **Headset last, then the verdict. Days 11-12.** Same model file and switch in the visionOS host; compute unit and call time in the debug log.
   *The owner sees:* the same behaviour in the room with no hitch at load. Back on the Mac: one page with the by-eye verdict per shot, where the model ran on each device, and the proposal for the next model.

## How it is judged

- By eye first: the three fixed shots, Kimodo set, release build, F9 flipped mid-run and recordings side by side. The owner says better, same or worse per shot. Off must look exactly like today.
- Supporting numbers, on the text line only: share of frames more than 30 degrees off heading; time to face after a flip; jumps per second moving (must not rise); how often the playing family differs from the model's; prediction median and worst; compute unit.
- A number never passes a step the eye has failed.

## Risks and the fallback for each

- The matcher may already choose well, so there is nothing to see. Known on day 2 from the strip. Fallback: still finish step 3 in shadow so the train, Core ML, Neural Engine chain is proven, then point the same model at another decision (arm posture, or which hold idle).
- Forcing a family may pop instead of looking better. Step 2 tests it by hand. Fallback: lower strength, gate on current speed.
- The model is close to a lookup table at 133 s of data. It proves the chain; it is not evidence that a larger model will work.
- Core ML may keep a 5,000-parameter model on the CPU. Fallback in order: the Conv2d variant, then 3x256 (harmless at 10 Hz); if still CPU, the line says CPU.
- Slow first load and call jitter on the Neural Engine. Covered by design: background load, asynchronous call, 0.5 s staleness rule. Headset contention is only answered in step 6; if the Mac-compiled model does not load there, compile on device with `MLModel.compileModel(at:)`.
- Left/right sign and trim offsets between spec, clips, engine and demo. Caught by the per-segment print and by the hand keys.
- NVIDIA access is unknown. Fallback: Mac CPU first, RunPod for the repeat.
- Holding the right key in a fast chase is hard. Fallback: pause plus Flip.
- Kimodo outputs as training data: the notes record them as ours to use but hold no explicit ruling on training. Confirm before anything trained on them leaves the studio.
- While the engine PR is open the demo uses a local package edit. It must not be merged.

## Not in this milestone

- Any model that writes poses or runs per frame. Not enough data, and no measured case for the Neural Engine.
- The hold idle alternating between k_hold_1 and k_hold_2 (same family, a family bias cannot change it) and the chase-start pop (the idle's stance does not match the start clip's first frame; a data fix).
- A model that copies the search, or one trained on an offline teacher search. Parked as the next label source.
- The 100STYLE and Mixed sets, and retargeting the 120 unpicked Kimodo takes.
- Foot slide and time-warp, the wall restart, arms and elbows, a get-up animation.
- Reviving the headless harness, Core AI, and anything cloth.
