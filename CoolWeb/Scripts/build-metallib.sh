#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
shader_dir="$package_root/Sources/CoolWeb/Shaders"
resource_dir="$package_root/Sources/CoolWeb/Resources"
source_file="$shader_dir/CoolWeb.metal"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/CoolWeb.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# The target OS must match the oldest OS Package.swift supports (macOS 14,
# iOS 17, visionOS 2). Without -mtargetos the compiler targets the SDK's own
# OS and emits that OS's AIR version (air64_v29 for OS 27), which an older OS
# rejects at makeLibrary time ("This library is using a deployment target
# ... that is not supported on this ...").
build_library() {
    sdk=$1
    target_os=$2
    output_name=$3
    sdk_work_dir="$work_dir/$sdk"
    mkdir -p "$sdk_work_dir"

    xcrun -sdk "$sdk" metal \
        -mtargetos="$target_os" \
        -c "$source_file" \
        -I "$shader_dir" \
        -fmodules-cache-path="$sdk_work_dir/ModuleCache" \
        -o "$sdk_work_dir/CoolWeb.air"

    xcrun -sdk "$sdk" metallib \
        "$sdk_work_dir/CoolWeb.air" \
        -o "$resource_dir/$output_name"
}

mkdir -p "$resource_dir"

build_library macosx macosx14.0 CoolWeb-macos.metallib
build_library iphoneos ios17.0 CoolWeb-ios.metallib
build_library iphonesimulator ios17.0-simulator CoolWeb-iossim.metallib
build_library xros xros2.0 CoolWeb-xros.metallib
build_library xrsimulator xros2.0-simulator CoolWeb-xrossim.metallib
