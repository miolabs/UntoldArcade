//
//  CoolScan.metal
//  CoolScan
//
// One model-surface fragment (toon) plus four full-screen compute kernels
// (comic, pixel, sketch, edge). The kernels run at .beforeLook: they read the
// scene composite from a scratch copy and write the stylized result back into
// the composite texture, so the engine's look/tonemap chain still applies.

#include <metal_stdlib>
#include <UntoldEngineShaderSupport/UntoldModelSurface.h>
#include "CoolScanShaderTypes.h"

using namespace metal;

// MARK: - Toon surface fragment

fragment float4 coolScanToonFragment(
    UntoldModelSurfaceVertexOut in [[stage_in]],
    constant UntoldModelSurfaceExtensionArguments &arguments
        [[buffer(UntoldModelSurfaceExtensionArgumentBufferIndex)]]
) {
    constant CoolScanToonUniforms &u =
        *reinterpret_cast<constant CoolScanToonUniforms *>(arguments.buffer0);
    constexpr sampler albedoSampler(
        mag_filter::linear, min_filter::linear, address::repeat
    );

    float3 albedo = arguments.texture0.sample(albedoSampler, in.uvCoords).rgb;

    float3 n = normalize(in.normal);
    float3 l = normalize(-u.lightDirection.xyz);
    float bands = max(u.shadeColor.w, 1.0);

    // Quantize diffuse into discrete bands, half-lambert so the dark side
    // keeps a readable base tone instead of going black.
    float ndl = dot(n, l) * 0.5 + 0.5;
    float q = floor(saturate(ndl) * bands) / max(bands - 1.0, 1.0);
    q = saturate(q);

    float3 lit = albedo * mix(u.shadeColor.rgb, float3(1.0), q);

    // Rim highlight from the view-space normal: brightens silhouettes.
    float rimStrength = u.params.x;
    float rimWidth = max(u.params.y, 1e-3);
    float3 viewDir = normalize(-in.verticesInMVSpace.xyz);
    float3 viewNormal = normalize(in.normalVectorInMVSpace);
    float rim = pow(1.0 - saturate(dot(viewDir, viewNormal)), 1.0 / rimWidth);
    // Quantize the rim too so it reads as a cel highlight, not a gradient.
    rim = step(0.5, rim) * rimStrength;

    float3 color = lit + rim * albedo;
    return float4(color, 1.0);
}

// MARK: - Shared helpers

static inline float coolScanLuma(float3 c)
{
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

static inline uint2 coolScanClampCoord(int2 p, uint w, uint h)
{
    return uint2(clamp(p, int2(0, 0), int2(int(w) - 1, int(h) - 1)));
}

/// Combined luminance+depth Sobel edge factor in [0,1].
static float coolScanEdgeFactor(
    texture2d<float, access::read> src,
    depth2d<float, access::read> depth,
    uint2 gid,
    float threshold
) {
    const uint w = src.get_width();
    const uint h = src.get_height();

    float lum[3][3];
    float dep[3][3];
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            uint2 p = coolScanClampCoord(int2(gid) + int2(i, j), w, h);
            lum[j + 1][i + 1] = coolScanLuma(src.read(p).rgb);
            dep[j + 1][i + 1] = depth.read(p);
        }
    }

    float lx = lum[0][0] + 2.0 * lum[1][0] + lum[2][0]
             - lum[0][2] - 2.0 * lum[1][2] - lum[2][2];
    float ly = lum[0][0] + 2.0 * lum[0][1] + lum[0][2]
             - lum[2][0] - 2.0 * lum[2][1] - lum[2][2];
    float lumEdge = sqrt(lx * lx + ly * ly);

    float dx = dep[0][0] + 2.0 * dep[1][0] + dep[2][0]
             - dep[0][2] - 2.0 * dep[1][2] - dep[2][2];
    float dy = dep[0][0] + 2.0 * dep[0][1] + dep[0][2]
             - dep[2][0] - 2.0 * dep[2][1] - dep[2][2];
    // Depth deltas are tiny in reverse-Z; scale before thresholding.
    float depthEdge = sqrt(dx * dx + dy * dy) * 40.0;

    float edge = max(lumEdge, depthEdge);
    return smoothstep(threshold, threshold * 2.0, edge);
}

// MARK: - Comic (posterize + halftone + ink lines)

kernel void coolScanComicKernel(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    depth2d<float, access::read> depth [[texture(2)]],
    constant CoolScanScreenUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    float levels = max(u.paramsA.x, 2.0);
    float halftone = saturate(u.paramsA.y);
    float outlineStrength = saturate(u.paramsA.z);
    float outlineThreshold = max(u.paramsA.w, 1e-3);

    float3 color = src.read(gid).rgb;
    float lumaBefore = coolScanLuma(color);

    // Posterize each channel.
    float3 poster = floor(color * levels) / (levels - 1.0);
    poster = clamp(poster, 0.0, 1.0);

    // Halftone shading: dark areas grow ink dots on a 45-degree grid.
    if (halftone > 0.0) {
        const float cell = 7.0;
        float2 p = float2(gid);
        float2 r = float2(p.x + p.y, p.y - p.x) * 0.70710678;
        float2 f = fract(r / cell) - 0.5;
        float dot2 = length(f) * 2.0;
        float darkness = 1.0 - saturate(lumaBefore * 1.4);
        float ink = step(dot2, darkness) * halftone;
        poster = mix(poster, poster * 0.25, ink);
    }

    // Ink contour lines.
    float edge = coolScanEdgeFactor(src, depth, gid, outlineThreshold);
    poster = mix(poster, float3(0.02), edge * outlineStrength);

    dst.write(float4(poster, 1.0), gid);
}

// MARK: - Pixel art (downsample + palette quantize + dither)

kernel void coolScanPixelKernel(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    depth2d<float, access::read> depth [[texture(2)]],
    constant CoolScanScreenUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    float pixelSize = max(u.paramsA.x, 1.0);
    float levels = max(u.paramsA.y, 2.0);

    // Snap to the center of the containing art pixel.
    uint2 cell = uint2(floor(float2(gid) / pixelSize) * pixelSize
                       + pixelSize * 0.5);
    cell = coolScanClampCoord(int2(cell), src.get_width(), src.get_height());
    float3 color = src.read(cell).rgb;

    // 4x4 Bayer ordered dithering inside the art-pixel grid hides banding.
    constexpr float bayer[16] = {
        0.0,  8.0,  2.0, 10.0,
       12.0,  4.0, 14.0,  6.0,
        3.0, 11.0,  1.0,  9.0,
       15.0,  7.0, 13.0,  5.0,
    };
    uint2 artPixel = uint2(floor(float2(gid) / pixelSize));
    uint bayerIndex = (artPixel.y % 4) * 4 + (artPixel.x % 4);
    float dither = (bayer[bayerIndex] / 16.0 - 0.5) / levels;

    float3 quantized = floor((color + dither) * levels) / (levels - 1.0);
    dst.write(float4(clamp(quantized, 0.0, 1.0), 1.0), gid);
}

// MARK: - Pencil sketch (hatching + paper tint + graphite lines)

kernel void coolScanSketchKernel(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    depth2d<float, access::read> depth [[texture(2)]],
    constant CoolScanScreenUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    float strokeScale = max(u.paramsA.x, 0.25);
    float outlineStrength = saturate(u.paramsA.z);
    float outlineThreshold = max(u.paramsA.w, 1e-3);

    float3 color = src.read(gid).rgb;
    float luma = coolScanLuma(color);

    const float3 paper = float3(0.96, 0.945, 0.90);
    const float3 graphite = float3(0.16, 0.16, 0.19);

    float2 p = float2(gid) / (6.0 * strokeScale);

    // Three hatching layers at different angles; darker areas accumulate more.
    float stroke1 = 0.5 + 0.5 * sin((p.x + p.y) * 3.14159);
    float stroke2 = 0.5 + 0.5 * sin((p.x - p.y) * 3.14159);
    float stroke3 = 0.5 + 0.5 * sin(p.y * 2.0 * 3.14159);

    float shade = 0.0;
    if (luma < 0.85) { shade += step(0.5, stroke1) * 0.35; }
    if (luma < 0.55) { shade += step(0.5, stroke2) * 0.35; }
    if (luma < 0.30) { shade += step(0.5, stroke3) * 0.30; }
    shade *= (1.0 - saturate(luma));

    float edge = coolScanEdgeFactor(src, depth, gid, outlineThreshold);
    float ink = max(shade, edge * outlineStrength);

    float3 sketch = mix(paper, graphite, saturate(ink));
    dst.write(float4(sketch, 1.0), gid);
}

// MARK: - Edge (toon contour overlay)

kernel void coolScanEdgeKernel(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    depth2d<float, access::read> depth [[texture(2)]],
    constant CoolScanScreenUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    float outlineStrength = saturate(u.paramsA.z);
    float outlineThreshold = max(u.paramsA.w, 1e-3);

    float3 color = src.read(gid).rgb;
    float edge = coolScanEdgeFactor(src, depth, gid, outlineThreshold);
    float3 outlined = mix(color, float3(0.02), edge * outlineStrength);
    dst.write(float4(outlined, 1.0), gid);
}
