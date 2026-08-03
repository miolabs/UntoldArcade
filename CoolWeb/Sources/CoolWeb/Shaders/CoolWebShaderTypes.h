//
//  CoolWebShaderTypes.h
//  CoolWeb
//
//  Shared GPU data layout for the web-net renderer.
//  Every member is padded into float4/uint4 lanes so the hand-maintained Swift
//  mirror in CoolWebShaderABI.swift matches with zero padding surprises.
//

#ifndef CoolWebShaderTypes_h
#define CoolWebShaderTypes_h

#include <metal_stdlib>

#define COOLWEB_MAX_SEGMENTS 4096
#define COOLWEB_MAX_SPLATS 4

// One drawable thread segment. Everything on screen — flying cone threads,
// cross-links, wall residue, torn dangles — is a list of these.
typedef struct {
    metal::float4 a;      // xyz world endpoint A, w = core radius (m)
    metal::float4 b;      // xyz world endpoint B, w = tension (0 rest … 1 tearing)
    metal::float4 params; // x = opacity, y = seed, zw unused
} CoolWebSegmentGPU;

typedef struct {
    metal::float4 center; // xyz world impact point, w = pattern radius (m)
    metal::float4 normal; // xyz unit surface normal, w = opacity
    metal::float4 params; // x = seed, y = age (s), zw unused
} CoolWebSplatGPU;

// One skinned glove vertex, regenerated from the tracked hand every frame.
typedef struct {
    metal::float4 position; // xyz world, w = u (0…1 around the limb)
    metal::float4 normal;   // xyz world normal, w = v (m along the limb)
    metal::float4 params;   // x = material (0 fabric, 1 metal),
                            // y = ring radius (m),
                            // z = coverage distance from wrist (m),
                            // w = suit-up front (m); huge = fully covered
} CoolWebGloveVertexGPU;

typedef struct {
    metal::float4x4 viewProj;    // per-eye view-projection
    metal::float4   cameraWorld; // xyz camera position, w = time (s)
    metal::uint4    counts;      // x = segments, y = splats,
                                 // z = tension heatmap flag, w unused
    CoolWebSplatGPU splats[COOLWEB_MAX_SPLATS];
} CoolWebUniforms;

// Segments live in a separate buffer: CoolWebSegmentGPU[count].
enum CoolWebBufferIndex {
    CoolWebUniformIndex = 0,
    CoolWebSegmentIndex = 1,
};

// Glove pipeline slots (separate pipeline, separate table).
enum CoolWebGloveBufferIndex {
    CoolWebGloveUniformIndex = 0,
    CoolWebGloveVertexIndex = 1,
};

#endif /* CoolWebShaderTypes_h */
