//
//  SpikeShaders.metal
//  RealityKitPresenter spike
//
//  Two things the engine would normally do: fill the grid vertices from a depth
//  (here a synthetic scene) and render the eye textures (here a test pattern).
//

#include <metal_stdlib>
#include "SpikeShaderTypes.h"
using namespace metal;

// MARK: - Grid vertex (EyeGrid.swift writes the same layout: 24 bytes)

struct GridVertex {
    packed_float3 position;   // ARKit origin space
    packed_float2 uv;         // see the note below
    half2 mask;               // x: tear mask (a depth jump to a neighbour), y: unused
    // uv: v = 0 at the first row of the eye texture (the top of the view). RealityKit samples a
    // LowLevelTexture in Metal's row order; writing 1 - v showed the frame upside down (simulator, 2026-10-16).
};

// MARK: - Colour helpers

// The eye textures are bgra8Unorm_srgb: the shader writes linear values and the store
// encodes them, so a colour meant to read as the sRGB value s is written as srgbToLinear(s).
static inline float srgbToLinear1(float c) {
    return (c <= 0.04045f) ? c / 12.92f : pow((c + 0.055f) / 1.055f, 2.4f);
}

static inline float3 srgbToLinear(float3 c) {
    return float3(srgbToLinear1(c.x), srgbToLinear1(c.y), srgbToLinear1(c.z));
}

// MARK: - Rays

// Eye-space direction of a view position; uv (0,0) is the top-left of the eye image.
static inline float3 eyeRay(float2 uv, float4 tangents) {
    float x = mix(-tangents.x, tangents.y, uv.x);
    float y = mix(tangents.z, -tangents.w, uv.y);
    return normalize(float3(x, y, -1.0f));
}

static inline float3 worldDirection(float3 eyeDirection, constant SpikeFrameUniforms &u) {
    return normalize((u.originFromEye * float4(eyeDirection, 0.0f)).xyz);
}

// MARK: - The synthetic scene (ARKit origin space, metres)
//
// A floor at y = 0, a wall 2.5 m ahead (-z) with a round hole at head height, sky beyond.
// With the origin on the floor under the user (visionOS), the wall is in front of where
// the session started.

constant float kFloorY = 0.0f;
constant float kFloorHalfExtent = 6.0f;
constant float kWallZ = -2.5f;
constant float kWallHalfWidth = 2.0f;
constant float kWallHeight = 3.0f;
constant float2 kHoleCentre = float2(0.0f, 1.5f);
constant float kHoleRadius = 0.3f;   // 6.9 degrees from 2.5 m: clear of the 10-degree ring

struct SceneHit {
    float t;        // distance along the normalised ray; farShell when nothing was hit
    int surface;    // 0 sky, 1 floor, 2 wall, 3 head-locked plane
    float3 p;       // the point, origin space
};

static SceneHit intersectScene(float3 ro, float3 rd, float farShell) {
    SceneHit hit;
    hit.t = farShell;
    hit.surface = 0;
    if (rd.y < -1e-5f) {
        float t = (kFloorY - ro.y) / rd.y;
        if (t > 0.0f && t < hit.t) {
            float3 p = ro + rd * t;
            if (fabs(p.x) < kFloorHalfExtent && fabs(p.z) < kFloorHalfExtent) {
                hit.t = t;
                hit.surface = 1;
            }
        }
    }
    if (rd.z < -1e-5f) {
        float t = (kWallZ - ro.z) / rd.z;
        if (t > 0.0f && t < hit.t) {
            float3 p = ro + rd * t;
            bool onWall = fabs(p.x) <= kWallHalfWidth && p.y >= 0.0f && p.y <= kWallHeight;
            bool inHole = distance(p.xy, kHoleCentre) < kHoleRadius;
            if (onWall && !inHole) {
                hit.t = t;
                hit.surface = 2;
            }
        }
    }
    hit.p = ro + rd * hit.t;
    return hit;
}

// The surface a view position lands on, in either pattern mode.
static SceneHit surfaceAt(float2 uv, constant SpikeFrameUniforms &u) {
    float3 eyeDirection = eyeRay(uv, u.tangents);
    float3 rd = worldDirection(eyeDirection, u);
    float3 ro = u.originFromEye[3].xyz;
    if (u.patternMode == 1) {
        // Head-locked: a plane perpendicular to the view axis, headLockedDistance ahead.
        SceneHit hit;
        hit.t = u.headLockedDistance / max(-eyeDirection.z, 1e-3f);
        hit.surface = 3;
        hit.p = ro + rd * hit.t;
        return hit;
    }
    return intersectScene(ro, rd, u.farShell);
}

// MARK: - Grid fill (one thread per vertex)

kernel void fillGrid(device GridVertex *vertices [[buffer(0)]],
                     constant SpikeFrameUniforms &u [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    uint columns = uint(u.gridSize.x);
    uint rows = uint(u.gridSize.y);
    if (gid.x >= columns || gid.y >= rows) { return; }

    float2 step = 1.0f / float2(columns - 1, rows - 1);
    float2 uv = float2(gid) * step;
    SceneHit hit = surfaceAt(uv, u);

    // Tear mask: a depth jump to any of the four neighbours above the threshold.
    float mask = 0.0f;
    const float2 offsets[4] = { float2(step.x, 0.0f), float2(-step.x, 0.0f), float2(0.0f, step.y), float2(0.0f, -step.y) };
    for (int i = 0; i < 4; ++i) {
        float2 nuv = clamp(uv + offsets[i], 0.0f, 1.0f);
        SceneHit neighbour = surfaceAt(nuv, u);
        if (fabs(neighbour.t - hit.t) > u.tearThreshold) { mask = 1.0f; }
    }

    device GridVertex &v = vertices[gid.y * columns + gid.x];
    v.position = hit.p;
    v.uv = uv;
    v.mask = half2(half(mask), 0.0h);
}

// MARK: - Test pattern (a fullscreen triangle per eye texture)

struct FullscreenVertex {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 ndc = float2((vertexID == 2) ? 3.0f : -1.0f, (vertexID == 1) ? 3.0f : -1.0f);
    FullscreenVertex out;
    out.position = float4(ndc, 0.0f, 1.0f);
    out.uv = float2(ndc.x * 0.5f + 0.5f, 1.0f - (ndc.y * 0.5f + 0.5f));
    return out;
}

static inline float checker(float2 p, float cell) {
    float2 c = floor(p / cell);
    return fmod(fabs(c.x + c.y), 2.0f);
}

static inline bool inRect(float2 uv, float2 lo, float2 hi) {
    return all(uv >= lo) && all(uv <= hi);
}

fragment float4 patternFragment(FullscreenVertex in [[stage_in]],
                                constant SpikeFrameUniforms &u [[buffer(0)]])
{
    float2 uv = in.uv;
    SceneHit hit = surfaceAt(uv, u);
    float3 eyeDirection = eyeRay(uv, u.tangents);

    float3 srgb;            // colours are given as sRGB values, converted at the end
    float alpha = 1.0f;

    switch (hit.surface) {
        case 1: {
            // Floor: 0.25 m checker; a red line along +x and a blue line along -z from the
            // origin, a yellow dot on the origin (the native origin marker must sit on it).
            float k = checker(hit.p.xz, 0.25f);
            srgb = mix(float3(0.32f, 0.34f, 0.38f), float3(0.55f, 0.57f, 0.60f), k);
            if (fabs(hit.p.z) < 0.012f && hit.p.x > 0.0f && hit.p.x < 1.0f) { srgb = float3(0.90f, 0.10f, 0.10f); }
            if (fabs(hit.p.x) < 0.012f && hit.p.z < 0.0f && hit.p.z > -1.0f) { srgb = float3(0.10f, 0.30f, 0.95f); }
            if (length(hit.p.xz) < 0.06f) { srgb = float3(1.00f, 0.85f, 0.10f); }
            break;
        }
        case 2: {
            // Wall: 0.25 m checker in warm greys, a green ring around the hole.
            float k = checker(hit.p.xy, 0.25f);
            srgb = mix(float3(0.40f, 0.36f, 0.32f), float3(0.62f, 0.58f, 0.52f), k);
            float r = distance(hit.p.xy, kHoleCentre);
            if (r < kHoleRadius + 0.03f) { srgb = float3(0.15f, 0.90f, 0.30f); }
            break;
        }
        case 3: {
            // Head-locked plane: a 10-degree angular checker.
            float2 angles = atan(eyeDirection.xy / -eyeDirection.z) * (180.0f / M_PI_F);
            float k = checker(angles, 10.0f);
            srgb = mix(float3(0.30f), float3(0.50f), k);
            break;
        }
        default: {
            // Sky: passthrough when asked (alpha under the material's threshold), else dark blue.
            srgb = float3(0.05f, 0.07f, 0.14f);
            alpha = (u.flags & 1u) ? 0.0f : 1.0f;
            break;
        }
    }

    if (u.flags & 2u) {
        // View-space overlays, identical in both pattern modes.
        float2 axis = float2(u.tangents.x / (u.tangents.x + u.tangents.y),
                             u.tangents.z / (u.tangents.z + u.tangents.w));
        float2 px = 1.0f / u.textureSize;

        // Crosshair on the view axis (2 px lines, 3 % long) and a ring 10 degrees off it.
        bool onCross = (fabs(uv.x - axis.x) < px.x && fabs(uv.y - axis.y) < 0.03f)
                    || (fabs(uv.y - axis.y) < px.y && fabs(uv.x - axis.x) < 0.03f);
        float offAxis = atan(length(eyeDirection.xy) / -eyeDirection.z) * (180.0f / M_PI_F);
        if (onCross || fabs(offAxis - 10.0f) < 0.12f) { srgb = float3(1.0f, 1.0f, 0.2f); alpha = 1.0f; }

        // A bar that sweeps the width in 4 s: judder and dropped frames show on it.
        float bar = fract(u.time * 0.25f);
        if (uv.x > bar && uv.x < bar + 0.008f && uv.y > 0.15f && uv.y < 0.80f) { srgb = float3(1.0f); alpha = 1.0f; }

        // The colour ramp: 14 swatches with the sRGB values the control window shows.
        if (inRect(uv, float2(0.15f, 0.03f), float2(0.85f, 0.09f))) {
            int i = clamp(int((uv.x - 0.15f) / 0.05f), 0, 13);
            if (i < 10) { srgb = float3(float(i) * 0.1f); }
            else if (i == 10) { srgb = float3(1.0f, 0.0f, 0.0f); }
            else if (i == 11) { srgb = float3(0.0f, 1.0f, 0.0f); }
            else if (i == 12) { srgb = float3(0.0f, 0.0f, 1.0f); }
            else { srgb = float3(1.0f); }
            alpha = 1.0f;
        }

        // Eye marks: the left eye one green square bottom-left, the right eye two magenta
        // squares bottom-right. Seeing both in one eye means the eye switch failed.
        if (u.eye == 0) {
            if (inRect(uv, float2(0.05f, 0.85f), float2(0.11f, 0.91f))) { srgb = float3(0.1f, 0.9f, 0.2f); alpha = 1.0f; }
        } else {
            if (inRect(uv, float2(0.81f, 0.85f), float2(0.87f, 0.91f)) || inRect(uv, float2(0.89f, 0.85f), float2(0.95f, 0.91f))) {
                srgb = float3(0.9f, 0.1f, 0.9f);
                alpha = 1.0f;
            }
        }
    }

    return float4(srgbToLinear(srgb), alpha);
}
