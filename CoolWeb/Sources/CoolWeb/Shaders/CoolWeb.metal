//
//  CoolWeb.metal
//  CoolWeb
//
//  Web-strand + impact-splat rendering. All geometry is procedural from the
//  vertex id: the first COOLWEB_MAX_STRANDS * COOLWEB_STRAND_SEGMENTS quads are
//  strand segments (camera-facing ribbons around each rope segment, capsule SDF
//  in the fragment), the last COOLWEB_MAX_SPLATS quads are surface-oriented
//  web-pattern decals at attach points. Drawn with straight alpha blending,
//  depth test on and depth write off, over the engine's HDR scene targets.
//

#include <metal_stdlib>
#include "CoolWebShaderTypes.h"

using namespace metal;

struct WebVertexOut {
    float4 position [[position]];
    float2 local;          // strand: (m along segment, m across)
                           // splat: plane coords in meters, centered
    float2 extra;          // strand: (normalized distance along strand, 0)
    float4 color [[flat]]; // rgb color, w opacity
    float4 params [[flat]]; // strand: (core radius, glow margin, seed, time)
                            // splat: (pattern radius, seed, age, time)
    uint kind [[flat]];    // 0 = strand, 1 = splat
};

// Two CCW triangles covering the unit quad, as (u, v) in [0, 1]².
constant float2 kQuadCorners[6] = {
    float2(0, 0), float2(1, 0), float2(1, 1),
    float2(0, 0), float2(1, 1), float2(0, 1),
};

static float4 collapsedVertex() {
    // Degenerate position: all three triangle corners coincide, nothing rasterizes.
    return float4(0, 0, 0, 1);
}

vertex WebVertexOut coolWebStrandVertex(
    uint vid [[vertex_id]],
    constant CoolWebUniforms &u [[buffer(CoolWebUniformIndex)]],
    device const float4 *particles [[buffer(CoolWebParticleIndex)]]
) {
    WebVertexOut out;
    out.position = collapsedVertex();
    out.local = float2(0);
    out.extra = float2(0);
    out.color = float4(0);
    out.params = float4(0);
    out.kind = 0;

    const uint quad = vid / 6;
    const float2 corner = kQuadCorners[vid % 6];
    const float3 cameraPos = u.cameraWorld.xyz;
    const float time = u.cameraWorld.w;

    const uint segmentQuadCount = COOLWEB_MAX_STRANDS * COOLWEB_STRAND_SEGMENTS;
    if (quad < segmentQuadCount) {
        const uint strandIndex = quad / COOLWEB_STRAND_SEGMENTS;
        const uint segment = quad % COOLWEB_STRAND_SEGMENTS;
        if (strandIndex >= u.counts.x) {
            return out;
        }
        const CoolWebStrandGPU strand = u.strands[strandIndex];
        const float opacity = strand.color.w;
        const uint particleCount = uint(strand.params.y);
        if (opacity <= 0.001 || segment + 1 >= particleCount) {
            return out;
        }

        const uint base = strandIndex * COOLWEB_STRAND_PARTICLES;
        const float3 p0 = particles[base + segment].xyz;
        const float3 p1 = particles[base + segment + 1].xyz;
        float3 axis = p1 - p0;
        const float segLength = length(axis);
        if (segLength < 1e-5) {
            return out;
        }
        axis /= segLength;

        const float radius = strand.params.x;
        // Halo containment margin: the fragment windows the edge to exactly
        // zero at this distance and it also pads segment joints shut.
        const float margin = radius * 2.5 + 0.001;
        const float halfWidth = radius + margin;

        // Rotate the ribbon about the segment axis so it faces the camera.
        const float3 mid = (p0 + p1) * 0.5;
        float3 side = cross(axis, cameraPos - mid);
        const float sideLen = length(side);
        if (sideLen < 1e-4) {
            side = normalize(cross(axis, abs(axis.y) < 0.9 ? float3(0, 1, 0) : float3(1, 0, 0)));
        } else {
            side = side / sideLen;
        }

        const float along = mix(-margin, segLength + margin, corner.x);
        const float across = (corner.y * 2.0 - 1.0) * halfWidth;
        const float3 world = p0 + axis * along + side * across;

        out.position = u.viewProj * float4(world, 1.0);
        out.local = float2(along, across);
        out.extra = float2(
            (float(segment) + corner.x) / float(COOLWEB_STRAND_SEGMENTS),
            segLength
        );
        out.color = strand.color;
        out.params = float4(radius, segLength, strand.params.z, time);
        out.kind = 0;
        return out;
    }

    const uint splatIndex = quad - segmentQuadCount;
    if (splatIndex >= u.counts.y) {
        return out;
    }
    const CoolWebSplatGPU splat = u.splats[splatIndex];
    const float radius = splat.center.w;
    const float opacity = splat.normal.w;
    if (radius < 1e-4 || opacity <= 0.001) {
        return out;
    }

    // Quad in the surface plane, lifted 2 mm along the normal so it never
    // z-fights the real-scene occlusion depth it sits on.
    const float3 normal = normalize(splat.normal.xyz);
    const float3 upRef = abs(normal.y) < 0.95 ? float3(0, 1, 0) : float3(1, 0, 0);
    const float3 tangent = normalize(cross(upRef, normal));
    const float3 bitangent = cross(normal, tangent);
    const float2 uv = corner * 2.0 - 1.0;
    const float3 world = splat.center.xyz
        + normal * 0.002
        + (tangent * uv.x + bitangent * uv.y) * radius;

    out.position = u.viewProj * float4(world, 1.0);
    out.local = uv * radius;
    out.extra = float2(0);
    out.color = float4(0.92, 0.95, 1.0, opacity);
    out.params = float4(radius, splat.params.x, splat.params.y, time);
    out.kind = 1;
    return out;
}

fragment float4 coolWebStrandFragment(WebVertexOut in [[stage_in]]) {
    if (in.kind == 1) {
        // Impact splat: procedural web pattern — radial spokes + a sagging
        // archimedean spiral — that draws itself outward over the first
        // fraction of a second.
        const float radius = in.params.x;
        const float seed = in.params.y;
        const float age = in.params.z;
        const float r = length(in.local);
        const float rNorm = r / radius;
        if (rNorm > 1.0) {
            discard_fragment();
        }
        const float theta = atan2(in.local.y, in.local.x);

        const float spokes = 9.0;
        const float twoPi = 6.28318530718;
        // Perpendicular distance to the nearest spoke line.
        const float angToSpoke = (fract(theta / twoPi * spokes + seed) - 0.5)
            * (twoPi / spokes);
        const float spokeDist = abs(sin(angToSpoke)) * r;

        // Spiral rings that sag between spokes like real web threads.
        const float spacing = radius * 0.16;
        const float sag = 0.10 * (0.5 - 0.5 * cos(angToSpoke * spokes));
        const float phase = fract(r / spacing - theta / twoPi + sag + seed);
        const float ringDist = min(phase, 1.0 - phase) * spacing;

        const float lineWidth = radius * 0.022 + 0.0006;
        const float lineDist = min(spokeDist, ringDist);
        float webLine = 1.0 - smoothstep(lineWidth * 0.4, lineWidth, lineDist);

        // Draw-in animation: threads appear from the center outward.
        const float grow = saturate(age * 4.0);
        webLine *= 1.0 - smoothstep(grow - 0.12, grow, rNorm);
        // Rim fade + solid hit core.
        webLine *= 1.0 - smoothstep(0.75, 1.0, rNorm);
        const float core = 1.0 - smoothstep(0.0, 0.10, rNorm);
        const float intensity = saturate(webLine + core);
        if (intensity < 0.01) {
            discard_fragment();
        }
        const float alpha = intensity * in.color.w;
        return float4(in.color.rgb * 1.1 * alpha, alpha);
    }

    // Strand segment: capsule SDF in the ribbon's (along, across) space.
    const float radius = in.params.x;
    const float segLength = in.params.y;
    const float seed = in.params.z;
    const float along = clamp(in.local.x, 0.0, segLength);
    const float dist = length(float2(in.local.x - along, in.local.y));

    // Milky silk core with a soft edge; a faint twist banding along the strand
    // suggests wound fibers without any texture fetch.
    const float core = 1.0 - smoothstep(radius * 0.55, radius, dist);
    const float halo = (1.0 - smoothstep(radius, radius * 2.2, dist)) * 0.18;
    const float twist = 0.88 + 0.12 * sin(in.extra.x * 240.0 + seed * 7.0);

    const float alpha = saturate(core + halo) * in.color.w;
    if (alpha < 0.005) {
        discard_fragment();
    }
    // Mild HDR lift so the engine bloom gives the silk a subtle sheen.
    const float3 rgb = in.color.rgb * (1.25 * twist) * alpha;
    return float4(rgb, alpha);
}

// MARK: - Real-scene occlusion (depth-only)

struct WebOcclusionOut {
    float4 position [[position]];
};

vertex WebOcclusionOut coolWebOcclusionVertex(
    uint vid [[vertex_id]],
    device const uchar *vertexBytes [[buffer(0)]],
    constant uint &stride [[buffer(1)]],
    constant uint &offset [[buffer(2)]],
    constant float4x4 &mvp [[buffer(3)]]
) {
    device const float *p = (device const float *)(vertexBytes + offset + vid * stride);
    WebOcclusionOut out;
    out.position = mvp * float4(p[0], p[1], p[2], 1.0);
    return out;
}

// Depth-only: no color is written (empty write mask), depth occludes the web.
fragment void coolWebOcclusionFragment(WebOcclusionOut in [[stage_in]]) {
}
