//
//  SpikeShaderTypes.h
//  RealityKitPresenter spike
//
//  The uniforms both the Swift side and the Metal shaders see (bridging header).
//

#ifndef SpikeShaderTypes_h
#define SpikeShaderTypes_h

#include <simd/simd.h>

/// Per eye, per ticket. 128 bytes.
typedef struct {
    /// The eye's pose in the ARKit origin space (column-major): device anchor x nominal eye offset.
    matrix_float4x4 originFromEye;
    /// Tangents of the half angles of the eye frustum: left, right, up, down (all positive).
    vector_float4 tangents;
    /// Grid vertices per row and rows.
    vector_float2 gridSize;
    /// Eye texture size in pixels.
    vector_float2 textureSize;
    /// Seconds since the renderer started (drives the moving bar).
    float time;
    /// 0 left, 1 right.
    unsigned int eye;
    /// 0 world-locked (the synthetic scene), 1 head-locked (a plane in front of the eye).
    unsigned int patternMode;
    /// Distance of the head-locked plane, metres.
    float headLockedDistance;
    /// Where rays that hit nothing end, metres.
    float farShell;
    /// A depth jump above this between neighbouring grid vertices sets the tear mask, metres.
    float tearThreshold;
    /// Bit 0: the sky is written with alpha 0 (passthrough below the material's threshold).
    /// Bit 1: draw the view-space overlays (crosshair, ring, moving bar, colour ramp, eye marks).
    unsigned int flags;
    float padding;
} SpikeFrameUniforms;

#endif /* SpikeShaderTypes_h */
