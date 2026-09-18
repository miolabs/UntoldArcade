#!/bin/sh
# Refreshes the vendored Jolt Physics source tree from an upstream release tag.
#
#   Scripts/update-jolt.sh v5.6.0
#
# Copies upstream's Jolt/ tree verbatim into Native/JoltPhysics/Jolt (dropping
# Jolt.cmake and Jolt.natvis), refreshes LICENSE and JOLT_VERSION.md, and prints
# the `.hlsl` exclude list to paste into Package.swift. No binaries are built:
# SwiftPM compiles the tree as a C++17 target.
set -eu

TAG="${1:?usage: Scripts/update-jolt.sh <tag>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone -q --depth 1 --branch "$TAG" https://github.com/jrouwe/JoltPhysics.git "$WORK/JoltPhysics"
SHA="$(git -C "$WORK/JoltPhysics" rev-parse HEAD)"

rm -rf "$ROOT/Native/JoltPhysics/Jolt"
cp -R "$WORK/JoltPhysics/Jolt" "$ROOT/Native/JoltPhysics/Jolt"
rm -f "$ROOT/Native/JoltPhysics/Jolt/Jolt.cmake" "$ROOT/Native/JoltPhysics/Jolt/Jolt.natvis"
cp "$WORK/JoltPhysics/LICENSE" "$ROOT/Native/JoltPhysics/LICENSE"

sed -i '' "s|^- Version: .*|- Version: $TAG (commit $SHA)|" "$ROOT/Native/JoltPhysics/JOLT_VERSION.md"
sed -i '' "s|^- Version: v.*|- Version: $TAG (commit $SHA)|" "$ROOT/THIRD_PARTY_LICENSES.md"
sed -i '' "s|Vendored Jolt Physics v[0-9.]*|Vendored Jolt Physics $TAG|" "$ROOT/README.md"

echo "Vendored Jolt $TAG ($SHA)."
echo "Paste this into the JoltPhysics target's exclude list in Package.swift:"
(cd "$ROOT/Native/JoltPhysics" && find Jolt/Shaders -name '*.hlsl' | sort | sed 's/.*/                "&",/')
