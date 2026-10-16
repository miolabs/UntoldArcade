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

// Palette cap of the glove skeleton: 17 deform bones + fingertip and muzzle
// markers, with headroom. The palette upload carries the asset's count.
#define COOLWEB_GLOVE_JOINTS 32

// One static bind-space vertex of the rigged glove. Uploaded once per hand;
// the vertex shader skins it (4 influences) with the per-frame palette.
typedef struct {
    metal::float4 position; // xyz bind-space position,
                            // w = coverage distance from wrist (m)
    metal::float4 normal;   // xyz bind-space normal,
                            // w = material (0 red fabric, 1 shooter metal)
    metal::float4 texJoint; // xy = uv (v already flipped for Metal),
                            // zw = joint indices 0/1, as floats
    metal::float4 weights;  // the four joint weights
    metal::float4 extra;    // xy = joint indices 2/3 as floats, zw unused
} CoolWebSkinnedGloveVertexGPU;

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

// Glove pipeline slots (separate pipeline, separate table). The joint
// palette and the per-hand params ride setVertexBytes — they are tiny.
enum CoolWebGloveBufferIndex {
    CoolWebGloveUniformIndex = 0,
    CoolWebGloveVertexIndex = 1,
    CoolWebGloveJointsIndex = 2,  // float4x4[COOLWEB_GLOVE_JOINTS]
    CoolWebGloveParamsIndex = 3,  // float4: x = suit-up front (m),
                                  //         y = shell inflate along normals (m)
};

#endif /* CoolWebShaderTypes_h */
