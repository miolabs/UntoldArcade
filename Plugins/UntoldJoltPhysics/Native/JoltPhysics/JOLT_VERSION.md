# Vendored Jolt Physics

- Upstream: https://github.com/jrouwe/JoltPhysics
- Version: v5.6.0 (commit e77f175595e64cb44218cc9d9d56fc365ad0e36a)
- License: MIT (see LICENSE in this directory)

This directory is a verbatim copy of the upstream `Jolt/` source tree, minus
`Jolt.cmake` and `Jolt.natvis`. It is compiled directly by SwiftPM as a C++17
target — no CMake, no prebuilt binaries. The `Shaders/*.hlsl` files are
excluded in `Package.swift`; the `Shaders/*.h` headers must stay because the
hair simulation headers include them.

## Updating

```bash
git clone --depth 1 --branch vX.Y.Z https://github.com/jrouwe/JoltPhysics.git /tmp/JoltPhysics
rm -rf Native/JoltPhysics/Jolt
cp -R /tmp/JoltPhysics/Jolt Native/JoltPhysics/Jolt
rm -f Native/JoltPhysics/Jolt/Jolt.cmake Native/JoltPhysics/Jolt/Jolt.natvis
cp /tmp/JoltPhysics/LICENSE Native/JoltPhysics/LICENSE
```

Then regenerate the `.hlsl` exclude list in `Package.swift` (see the comment
there) and update this file.
