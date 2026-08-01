//
//  CoolWebShaderTypes.h
//  CoolWeb
//
//  Shared GPU data layout for the web-strand renderer.
//  Every member is padded into float4/uint4 lanes so the hand-maintained Swift
//  mirror in CoolWebShaderABI.swift matches with zero padding surprises.
//

#ifndef CoolWebShaderTypes_h
#define CoolWebShaderTypes_h

#include <metal_stdlib>

#define COOLWEB_MAX_STRANDS 4
#define COOLWEB_STRAND_PARTICLES 64
#define COOLWEB_STRAND_SEGMENTS (COOLWEB_STRAND_PARTICLES - 1)
#define COOLWEB_MAX_SPLATS 4

typedef struct {
    metal::float4 color;  // rgb strand color, w = opacity (dissolve fade)
    metal::float4 params; // x = core radius (m), y = live particle count,
                          // z = seed, w unused
} CoolWebStrandGPU;

typedef struct {
    metal::float4 center; // xyz world impact point, w = pattern radius (m)
    metal::float4 normal; // xyz unit surface normal, w = opacity
    metal::float4 params; // x = seed, y = age (s), zw unused
} CoolWebSplatGPU;

typedef struct {
    metal::float4x4 viewProj;    // per-eye view-projection
    metal::float4   cameraWorld; // xyz camera position, w = time (s)
    metal::uint4    counts;      // x = strand slots, y = splat count, zw unused
    CoolWebStrandGPU strands[COOLWEB_MAX_STRANDS];
    CoolWebSplatGPU  splats[COOLWEB_MAX_SPLATS];
} CoolWebUniforms;

// Particle positions live in a separate buffer:
// float4[COOLWEB_MAX_STRANDS * COOLWEB_STRAND_PARTICLES], xyz world, w unused.
enum CoolWebBufferIndex {
    CoolWebUniformIndex = 0,
    CoolWebParticleIndex = 1,
};

#endif /* CoolWebShaderTypes_h */
