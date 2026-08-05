//
//  CoolScanShaderTypes.h
//  CoolScan
//
// Shared between CoolScan.metal and the hand-maintained Swift mirror in
// CoolScanShaderABI.swift. Keep both in sync; CoolScanABITests checks strides.

#ifndef CoolScanShaderTypes_h
#define CoolScanShaderTypes_h

#include <simd/simd.h>

typedef struct {
    // xyz: normalized world direction the light shines toward; w unused.
    simd_float4 lightDirection;
    // rgb: darkest-band color multiplier; w: band count.
    simd_float4 shadeColor;
    // x: rim strength, y: rim width, z/w reserved.
    simd_float4 params;
} CoolScanToonUniforms;

typedef struct {
    // comic:  x levels, y halftone amount, z outline strength, w outline threshold
    // pixel:  x pixel size, y color levels, z outline strength (unused), w unused
    // sketch: x stroke scale, y unused, z outline strength, w outline threshold
    // edge:   x unused, y unused, z outline strength, w outline threshold
    simd_float4 paramsA;
    // Reserved for per-style extras.
    simd_float4 paramsB;
} CoolScanScreenUniforms;

#endif /* CoolScanShaderTypes_h */
