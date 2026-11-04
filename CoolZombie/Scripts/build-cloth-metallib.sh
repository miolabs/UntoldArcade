#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
shader_dir="$package_root/Sources/CoolZombieKit/Shaders"
resource_dir="$package_root/Sources/CoolZombieKit/Resources/Shaders"
source_file="$shader_dir/ZombieClothGPU.metal"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ZombieCloth.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# The target OS must match the oldest OS Package.swift supports (macOS 14,
# iOS 17, visionOS 2). Without -mtargetos the compiler targets the SDK's own
# OS and emits that OS's AIR version (air64_v29 for OS 27), which an older OS
# rejects at makeLibrary time ("This library is using a deployment target
# ... that is not supported on this ...").
# Xcode 27.2's xcrun answers "cannot execute tool 'metal' due to missing
# Metal Toolchain" in some shells even with the toolchain installed (it
# lives on a cryptex mount, not in Xcode.app); the compiler and the
# linker are found there directly when xcrun refuses, with the SDK given
# by -isysroot. `xcodebuild -downloadComponent MetalToolchain` installs
# the mount when there is none.
metal_bin_dir=""
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    for candidate in /private/var/run/com.apple.security.cryptexd/mnt/*MetalToolchain*/Metal.xctoolchain/usr/bin; do
        if [ -x "$candidate/metal" ]; then
            metal_bin_dir="$candidate"
            break
        fi
    done
    if [ -z "$metal_bin_dir" ]; then
        echo "build-cloth-metallib: no Metal toolchain; run: xcodebuild -downloadComponent MetalToolchain" >&2
        exit 1
    fi
fi

build_library() {
    sdk=$1
    target_os=$2
    output_name=$3
    sdk_work_dir="$work_dir/$sdk"
    mkdir -p "$sdk_work_dir"

    if [ -n "$metal_bin_dir" ]; then
        "$metal_bin_dir/metal" \
            -isysroot "$(xcrun -sdk "$sdk" --show-sdk-path)" \
            -mtargetos="$target_os" \
            -c "$source_file" \
            -I "$shader_dir" \
            -fmodules-cache-path="$sdk_work_dir/ModuleCache" \
            -o "$sdk_work_dir/ZombieCloth.air"
        "$metal_bin_dir/metallib" \
            "$sdk_work_dir/ZombieCloth.air" \
            -o "$resource_dir/$output_name"
    else
        xcrun -sdk "$sdk" metal \
            -mtargetos="$target_os" \
            -c "$source_file" \
            -I "$shader_dir" \
            -fmodules-cache-path="$sdk_work_dir/ModuleCache" \
            -o "$sdk_work_dir/ZombieCloth.air"
        xcrun -sdk "$sdk" metallib \
            "$sdk_work_dir/ZombieCloth.air" \
            -o "$resource_dir/$output_name"
    fi
}

mkdir -p "$resource_dir"

build_library macosx macosx14.0 ZombieCloth-macos.metallib
build_library iphoneos ios17.0 ZombieCloth-ios.metallib
build_library iphonesimulator ios17.0-simulator ZombieCloth-iossim.metallib
build_library xros xros2.0 ZombieCloth-xros.metallib
build_library xrsimulator xros2.0-simulator ZombieCloth-xrossim.metallib
