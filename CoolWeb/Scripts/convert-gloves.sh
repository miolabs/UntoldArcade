#!/bin/sh
# Cooks the CoolWeb glove usdz assets from their Blender sources.
# Sources:  Sources/CoolWeb/Resources/Models/hand_R.blend / hand_L.blend
#           (Mixamo-rigged suit hands; see Scripts/convert_hand.py for the
#           bone pruning/renaming, influence capping, and material fixes)
# Outputs:  Examples/CoolWebVisionOS/.../Resources/Models/hand_{right,left}.usdz
#           plus *_preview.png renders next to them (git-ignored, not bundled).

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
blender=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
src="$package_root/Sources/CoolWeb/Resources/Models"
out="$package_root/Examples/CoolWebVisionOS/CoolWebVisionOS/visionOS/Resources/Models"

"$blender" --background "$src/hand_R.blend" --python "$script_dir/convert_hand.py" \
    -- Right "$out/hand_right.usdz" "$package_root/Sources/CoolWeb/Resources/Models/textures"
"$blender" --background "$src/hand_L.blend" --python "$script_dir/convert_hand.py" \
    -- Left "$out/hand_left.usdz" "$package_root/Sources/CoolWeb/Resources/Models/textures"
# previews live next to the sources for eyeballing — never in the app bundle
for side in right left; do
    for tag in preview palm; do
        mv -f "$out/hand_${side}_${tag}.png" \
            "$package_root/Sources/CoolWeb/Resources/Models/${tag}_${side}.png" 2>/dev/null || true
    done
done
echo "gloves cooked"
