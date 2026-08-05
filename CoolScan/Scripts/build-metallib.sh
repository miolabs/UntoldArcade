#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
shader_dir="$package_root/Sources/CoolScan/Shaders"
resource_dir="$package_root/Sources/CoolScan/Resources"
source_file="$shader_dir/CoolScan.metal"

# The toon fragment includes <UntoldEngineShaderSupport/UntoldModelSurface.h>
# from the engine checkout. Override with UNTOLD_ENGINE_DIR when the engine
# lives somewhere else.
engine_dir="${UNTOLD_ENGINE_DIR:-$package_root/../../UntoldEngine}"
engine_include_dir="$engine_dir/Sources/UntoldEngineShaderSupport/include"

if [ ! -d "$engine_include_dir" ]; then
    echo "error: UntoldEngine shader headers not found at $engine_include_dir" >&2
    echo "       set UNTOLD_ENGINE_DIR to the engine checkout" >&2
    exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/CoolScan.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

build_library() {
    sdk=$1
    output_name=$2
    sdk_work_dir="$work_dir/$sdk"
    mkdir -p "$sdk_work_dir"

    xcrun -sdk "$sdk" metal \
        -c "$source_file" \
        -I "$shader_dir" \
        -I "$engine_include_dir" \
        -fmodules-cache-path="$sdk_work_dir/ModuleCache" \
        -o "$sdk_work_dir/CoolScan.air"

    xcrun -sdk "$sdk" metallib \
        "$sdk_work_dir/CoolScan.air" \
        -o "$resource_dir/$output_name"
}

mkdir -p "$resource_dir"

build_library macosx CoolScan-macos.metallib
build_library iphoneos CoolScan-ios.metallib
build_library iphonesimulator CoolScan-iossim.metallib
build_library xros CoolScan-xros.metallib
build_library xrsimulator CoolScan-xrossim.metallib
