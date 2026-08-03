//
//  CoolWeb.metal
//  CoolWeb
//
//  Web-net + impact-splat rendering. All geometry is procedural from the
//  vertex id: the first counts.x quads are thread segments (camera-facing
//  ribbons with a capsule SDF in the fragment), the last COOLWEB_MAX_SPLATS
//  quads are surface-oriented web-pattern decals at attach points. Drawn with
//  premultiplied alpha, depth test on and depth write off, over the engine's
//  HDR scene targets.
//

#include <metal_stdlib>
#include "CoolWebShaderTypes.h"

using namespace metal;

struct WebVertexOut {
    float4 position [[position]];
    float2 local;          // segment: (m along segment, m across)
                           // splat: plane coords in meters, centered
    float4 color [[flat]]; // rgb color, w opacity
    float4 params [[flat]]; // segment: (core radius, seg length, seed, time)
                            // splat: (pattern radius, seed, age, time)
    uint kind [[flat]];    // 0 = segment, 1 = splat
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
    device const CoolWebSegmentGPU *segments [[buffer(CoolWebSegmentIndex)]]
) {
    WebVertexOut out;
    out.position = collapsedVertex();
    out.local = float2(0);
    out.color = float4(0);
    out.params = float4(0);
    out.kind = 0;

    const uint quad = vid / 6;
    const float2 corner = kQuadCorners[vid % 6];
    const float3 cameraPos = u.cameraWorld.xyz;
    const float time = u.cameraWorld.w;

    const uint segmentCount = u.counts.x;
    if (quad < segmentCount) {
        const CoolWebSegmentGPU segment = segments[quad];
        const float opacity = segment.params.x;
        if (opacity <= 0.001) {
            return out;
        }
        const float3 p0 = segment.a.xyz;
        const float3 p1 = segment.b.xyz;
        float3 axis = p1 - p0;
        const float segLength = length(axis);
        if (segLength < 1e-5) {
            return out;
        }
        axis /= segLength;

        const float radius = segment.a.w;
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

        // Silk white, or the tension heatmap (blue at rest → red just before
        // tearing) when the debug flag is set.
        const float tension = saturate(segment.b.w);
        float3 rgb = float3(0.92, 0.95, 1.0);
        if (u.counts.z != 0) {
            const float3 cool = float3(0.25, 0.45, 1.0);
            const float3 hot = float3(1.0, 0.15, 0.10);
            rgb = mix(cool, hot, tension);
        }

        out.position = u.viewProj * float4(world, 1.0);
        out.local = float2(along, across);
        out.color = float4(rgb, opacity);
        out.params = float4(radius, segLength, segment.params.y, time);
        out.kind = 0;
        return out;
    }

    const uint splatIndex = quad - segmentCount;
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

    // Thread segment: capsule SDF in the ribbon's (along, across) space.
    const float radius = in.params.x;
    const float segLength = in.params.y;
    const float seed = in.params.z;
    const float along = clamp(in.local.x, 0.0, segLength);
    const float dist = length(float2(in.local.x - along, in.local.y));

    // Milky silk core with a soft edge; faint banding along the thread
    // suggests wound fibers without any texture fetch.
    const float core = 1.0 - smoothstep(radius * 0.55, radius, dist);
    const float halo = (1.0 - smoothstep(radius, radius * 2.2, dist)) * 0.18;
    const float twist = 0.88 + 0.12 * sin(in.local.x * 900.0 + seed * 7.0);

    const float alpha = saturate(core + halo) * in.color.w;
    if (alpha < 0.005) {
        discard_fragment();
    }
    // Mild HDR lift so the engine bloom gives the silk a subtle sheen.
    const float3 rgb = in.color.rgb * (1.25 * twist) * alpha;
    return float4(rgb, alpha);
}

// MARK: - Spider-Man glove (opaque, depth-writing)

// The glove mesh arrives as world-space vertices rebuilt from the tracked
// hand every frame; the red-fabric + black-webbing suit look is painted here
// procedurally from the tube coordinates (u around the limb, v meters along).

struct GloveVertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 uv;              // x = u (0…1 around), y = v (m along)
    float2 matAndRadius;    // x = material (0 fabric, 1 metal), y = ring radius (m)
    float2 cover;           // x = coverage distance from wrist (m),
                            // y = suit-up front (m); huge = fully covered
};

vertex GloveVertexOut coolWebGloveVertex(
    uint vid [[vertex_id]],
    constant CoolWebUniforms &u [[buffer(CoolWebGloveUniformIndex)]],
    device const CoolWebGloveVertexGPU *vertices [[buffer(CoolWebGloveVertexIndex)]]
) {
    const CoolWebGloveVertexGPU v = vertices[vid];
    GloveVertexOut out;
    out.worldPos = v.position.xyz;
    out.position = u.viewProj * float4(v.position.xyz, 1.0);
    out.normal = v.normal.xyz;
    out.uv = float2(v.position.w, v.normal.w);
    out.matAndRadius = float2(v.params.x, v.params.y);
    out.cover = float2(v.params.z, v.params.w);
    return out;
}

fragment float4 coolWebGloveFragment(
    GloveVertexOut in [[stage_in]],
    constant CoolWebUniforms &u [[buffer(CoolWebGloveUniformIndex)]]
) {
    const float3 normal = normalize(in.normal);
    const float3 view = normalize(u.cameraWorld.xyz - in.worldPos);
    const float3 key = normalize(float3(0.30, 0.85, 0.35));

    // Suit-up: the fabric weaves on from the wrist outward. A hash raggs the
    // sweeping front so it isn't a clean circle, everything beyond it is not
    // built yet, and a hot band right behind it reads as the material
    // assembling. When fully covered the front sits at +1e6 and this whole
    // block is a no-op.
    const float2 cell = floor(float2(in.uv.x * 48.0, in.uv.y * 420.0));
    const float ragged = fract(
        sin(dot(cell, float2(12.9898, 78.233))) * 43758.5453
    );
    const float localFront = in.cover.y + (ragged - 0.5) * 0.010;
    if (in.cover.x > localFront) {
        discard_fragment();
    }
    const float bandDist = localFront - in.cover.x;
    const float buildGlow = 1.0 - smoothstep(0.0, 0.012, bandDist);

    float3 color;
    if (in.matAndRadius.x > 0.5) {
        // Web-shooter barrel: brushed metal with a hot Blinn glint.
        const float3 albedo = float3(0.30, 0.31, 0.34);
        const float diffuse = saturate(dot(normal, key)) * 0.6 + 0.30;
        const float3 half_ = normalize(key + view);
        const float spec = pow(saturate(dot(normal, half_)), 60.0) * 1.1;
        const float fresnel = pow(1.0 - saturate(dot(normal, view)), 3.0);
        color = albedo * diffuse + spec + fresnel * 0.25;
    } else {
        // Suit fabric: red with black webbing — fixed spokes along the limb,
        // rings across it that sag between spokes like sewn web threads.
        const float ringRadius = max(in.matAndRadius.y, 0.004);
        const float circumference = 6.28318530718 * ringRadius;
        const float spokes = 8.0;

        const float uWrapped = fract(in.uv.x * spokes) - 0.5;
        const float spokeDist = abs(uWrapped) / spokes * circumference;

        const float spacing = 0.0105;
        const float sag = 0.28 * (0.5 - 0.5 * cos(uWrapped * 6.28318530718));
        const float phase = fract(in.uv.y / spacing + sag);
        const float ringDist = min(phase, 1.0 - phase) * spacing;

        const float lineWidth = 0.0016;
        const float lineDist = min(spokeDist, ringDist);
        const float web = 1.0 - smoothstep(lineWidth * 0.45, lineWidth, lineDist);

        // Subtle woven-fabric shimmer, no texture fetch.
        const float weave = 0.96
            + 0.04 * sin(in.uv.x * 380.0) * sin(in.uv.y * 2400.0);

        const float3 red = float3(0.58, 0.045, 0.06) * weave;
        const float3 webbing = float3(0.020, 0.016, 0.018);
        float3 albedo = mix(red, webbing, web);

        // Wrap diffuse + headlight fill keeps the dark side readable indoors.
        const float diffuse = saturate(dot(normal, key) * 0.5 + 0.5);
        const float fill = saturate(dot(normal, view)) * 0.22;
        const float rim = pow(1.0 - saturate(dot(normal, view)), 3.0) * 0.10;
        color = albedo * (0.28 + 0.72 * diffuse + fill) + rim * float3(0.4, 0.05, 0.05);
        // Faint sheen so the webbing reads as raised vinyl.
        const float3 half_ = normalize(key + view);
        color += pow(saturate(dot(normal, half_)), 24.0) * 0.08 * (0.4 + 0.6 * web);
    }
    // Hot ember edge where the suit is materializing — HDR lift so the
    // engine bloom makes the front sizzle.
    color = mix(color, float3(2.4, 0.55, 0.12), buildGlow * 0.9);
    return float4(color, 1.0);
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
