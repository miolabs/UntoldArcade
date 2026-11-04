//
//  ZombieClothGPU.metal
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// The GPU cloth solver's kernels: an XPBD "small steps" solver over the
// shirt's proxy as a CSR graph — sixteen substeps of 0.625 ms per 10 ms
// headset frame, one Jacobi gather per substep, the slack ball and the
// back-stop applied after the edges so they are exact, the thirteen joints
// slerped per substep, the eleven skin hulls as plane sets, the floor and
// the balls as CoolCloth's plane and spheres — as `Docs/GPUCloth.md`
// section 4 lays them out — and, since phase 2, the drawn shell's
// evaluation (`zcTriangleFrames`, `zcShell`), which moves `RenderShell`'s
// half-millisecond of CPU per frame to two dispatches after the substeps.
// The five kernels run as 1-D dispatches inside one serial compute encoder
// per frame, 32 + 1 + 2 = 35 dispatches at sixteen substeps and one
// gather. This file is excluded from the SwiftPM target
// and compiled by `Scripts/build-cloth-metallib.sh` into the five
// committed metallibs under `Resources/Shaders/`; the kit loads the
// platform's one through `Bundle.module` (the header says how).
//
// The signatures below are the contract with `GPUClothSolver`: every
// buffer is bound by its `ZCBufferIndex` role, never renumbered per
// kernel. The bodies are the kernels' own.
//
// Why the work is split as it is. A substep is two kernels, not three as
// CoolCloth's are (predict, solve, finalize; CC/Shaders/CoolCloth.metal),
// because the finalize — v = (x - prev) / dt, capped — reads nothing the
// last gather does not already hold, so it is folded into the last
// gather of each substep and a frame at sixteen substeps costs 33
// dispatches instead of 49; the design's budget (section 8) puts a
// dispatch at 15-25 us of fixed latency on Apple GPUs, which is the term
// that dominates a 3,995-particle frame, so sixteen dispatches are
// 0.25-0.4 ms a frame saved for nothing. The skinned target is computed in
// the predict kernel rather than the solve kernel so a second gather in a
// substep (`gpuIterations` 2) does not blend the thirteen matrices twice,
// and so the stats kernel can read the frame's final targets without
// recomputing them. The gather is a Jacobi gather over the particle's own
// CSR run — every thread reads its neighbours, writes only itself — so it
// is order-fixed and atomic-free, and two runs on one device are bitwise
// equal, which `testTheGPUStepIsDeterministic` pins; the price is the
// relaxation on the summed corrections (CoolCloth's 0.5 on the raw sum by
// default, the averaged form as the A/B), paid back by the substeps.
//
// Every kernel reads `params.counts.x` and returns past it, because the
// per-particle dispatches are rounded up to whole threadgroups of
// ZCThreadgroupSize (3,995 particles are 63 groups, 4,032 threads).

#include <metal_stdlib>
#include "ZombieClothGPUShaderTypes.h"
using namespace metal;

// ===========================================================================
// Layout guards. The header writes every size, stride and offset down and
// `ZCLayout.mismatches()` holds the Swift side to them; this block holds
// the Metal side, so a drift on either side fails the metallib build or the
// GPU test suite before a kernel reads a lane the CPU wrote elsewhere.
// `__builtin_offsetof` is the one offsetof the Metal front end accepts in a
// constant expression (a cast-based macro is rejected as non-constant).
// ===========================================================================
#define ZC_OFFSET(T, m) __builtin_offsetof(T, m)
static_assert(sizeof(ZCParams) == 256 && alignof(ZCParams) == 16, "ZCParams: 256 B, 16-aligned");
static_assert(ZC_OFFSET(ZCParams, gravityDt) == 0 && ZC_OFFSET(ZCParams, compliance) == 16 && ZC_OFFSET(ZCParams, material) == 32
                  && ZC_OFFSET(ZCParams, floor) == 48 && ZC_OFFSET(ZCParams, pelvis) == 64,
              "ZCParams: lanes 0-4");
static_assert(ZC_OFFSET(ZCParams, counts) == 80 && ZC_OFFSET(ZCParams, substep) == 96 && ZC_OFFSET(ZCParams, flags) == 112
                  && ZC_OFFSET(ZCParams, rings) == 128,
              "ZCParams: lanes 5-8");
static_assert(ZC_OFFSET(ZCParams, regionScale) == 144 && ZC_OFFSET(ZCParams, reserved0) == 208 && ZC_OFFSET(ZCParams, reserved1) == 224
                  && ZC_OFFSET(ZCParams, reserved2) == 240,
              "ZCParams: lanes 9-15");
static_assert(sizeof(ZCEntry) == 8 && alignof(ZCEntry) == 4 && ZC_OFFSET(ZCEntry, packed) == 0 && ZC_OFFSET(ZCEntry, rest) == 4,
              "ZCEntry: 8 B");
static_assert(sizeof(ZCInfluence) == 16 && alignof(ZCInfluence) == 8 && ZC_OFFSET(ZCInfluence, joints) == 0
                  && ZC_OFFSET(ZCInfluence, weights) == 8,
              "ZCInfluence: 16 B");
static_assert(sizeof(ZCHullHeader) == 48 && alignof(ZCHullHeader) == 16 && ZC_OFFSET(ZCHullHeader, range) == 0
                  && ZC_OFFSET(ZCHullHeader, boundsMin) == 16 && ZC_OFFSET(ZCHullHeader, boundsMax) == 32,
              "ZCHullHeader: 48 B");
static_assert(sizeof(ZCSphere) == 32 && alignof(ZCSphere) == 16 && ZC_OFFSET(ZCSphere, center) == 0 && ZC_OFFSET(ZCSphere, velocity) == 16,
              "ZCSphere: 32 B");
static_assert(sizeof(ZCStats) == 64 && alignof(ZCStats) == 16 && ZC_OFFSET(ZCStats, boundsMin) == 0 && ZC_OFFSET(ZCStats, boundsMax) == 16
                  && ZC_OFFSET(ZCStats, counts) == 32 && ZC_OFFSET(ZCStats, reserved) == 48,
              "ZCStats: 64 B");
static_assert(sizeof(ZCShellParams) == 128 && alignof(ZCShellParams) == 16 && ZC_OFFSET(ZCShellParams, toMesh) == 0
                  && ZC_OFFSET(ZCShellParams, origin) == 64 && ZC_OFFSET(ZCShellParams, counts) == 80
                  && ZC_OFFSET(ZCShellParams, reserved0) == 96 && ZC_OFFSET(ZCShellParams, reserved1) == 112,
              "ZCShellParams: 128 B");
static_assert(sizeof(ZCTriangleFrame) == 48 && alignof(ZCTriangleFrame) == 16 && ZC_OFFSET(ZCTriangleFrame, e1) == 0
                  && ZC_OFFSET(ZCTriangleFrame, n) == 16 && ZC_OFFSET(ZCTriangleFrame, t) == 32,
              "ZCTriangleFrame: 48 B");
static_assert(sizeof(ZCShellBinding) == 48 && alignof(ZCShellBinding) == 16 && ZC_OFFSET(ZCShellBinding, barycentric) == 0
                  && ZC_OFFSET(ZCShellBinding, offset) == 16 && ZC_OFFSET(ZCShellBinding, normal) == 32,
              "ZCShellBinding: 48 B");
#undef ZC_OFFSET

// ===========================================================================
// Helpers
// ===========================================================================

/// A point into a hull's frame through its world-from-hull transform. The
/// hull transforms are rigid — a joint's rotation and translation, the
/// product `moveSkinColliders` took on the Jolt arm — so the inverse is the
/// rotation's transpose over the translated point, 9 multiplies instead of
/// a 4x4 inverse per hull per particle per substep (11 hulls x 3,995 x 16).
static inline float3 zcHullLocal(float4x4 world, float3 p) {
    const float3x3 rotation = float3x3(world[0].xyz, world[1].xyz, world[2].xyz);
    return transpose(rotation) * (p - world[3].xyz);
}

/// A point out of a hull's frame.
static inline float3 zcHullWorld(float4x4 world, float3 p) {
    return (world * float4(p, 1.0f)).xyz;
}

/// A direction out of a hull's frame (no translation).
static inline float3 zcHullRotate(float4x4 world, float3 v) {
    return (world * float4(v, 0.0f)).xyz;
}

// ===========================================================================
// zcPredict — per substep k, N threads in groups of ZCThreadgroupSize.
//
// In: positionIn (posSrc, w = inverse mass), velocity, rest, restNormal,
// influences, skinMatrices (this substep's thirteen at params.rings.x),
// params. Out: previous = positionIn, positionOut = the prediction
// (v += g dt, v *= max(0, 1 - damping dt), x += v dt, Jolt's integrator),
// target = the blend of the influences' skin matrices over rest,
// targetNormal = the normalised blend of their rotations over restNormal.
// A pin (w == 0) writes positionOut = previous = target and velocity = 0.
//
// Per particle, in this order and why: the skinned target first, because
// every particle — pin or free — needs it and the pin's whole substep is
// "sit on it"; the target is the linear blend of the up-to-four skin
// matrices (joint world x inverse bind world, already slerped to this
// substep by the CPU, so the thirteen joints move continuously inside the
// frame rather than jumping once per feed as Jolt's did after its first
// collision step) applied to the bind-pose position, and the back-stop
// normal is the same blend's rotation applied to the particle's
// area-weighted rest normal, re-normalised, which differs from Jolt's
// face-normal sum only where the fabric has stretched or folded since the
// bind pose. Then the previous position is snapshotted — the velocity
// finalize at the substep's end is (x - previous) / dt, so it must be the
// position before the prediction, not after — and the free particle is
// integrated as Jolt integrates it (SoftBodyMotionProperties.cpp:329-349):
// gravity over the substep, then the linear damping as the factor
// max(0, 1 - damping dt) rather than CoolCloth's exp(-damping dt), so the
// Jolt arm's 4 1/s tuning carries over to the A/B exactly (both forms
// lose about 98 % of a velocity per second at 4; the design's day-4 sweep
// asks whether that damping is what keeps the crumples from falling), then
// x += v dt. The velocity buffer is not written for a free particle here:
// the damped, gravity-added velocity is implied by the predicted position,
// and the last gather of the substep writes v = (x - previous) / dt, which
// carries the damping through the constraints as XPBD intends.
// ===========================================================================
kernel void zcPredict(constant ZCParams &params [[buffer(ZCParamsIndex)]],
                      device const float4 *positionIn [[buffer(ZCPositionInIndex)]],
                      device float4 *positionOut [[buffer(ZCPositionOutIndex)]],
                      device float4 *previous [[buffer(ZCPreviousIndex)]],
                      device float4 *velocity [[buffer(ZCVelocityIndex)]],
                      device const float4 *rest [[buffer(ZCRestIndex)]],
                      device const float4 *restNormal [[buffer(ZCRestNormalIndex)]],
                      device const ZCInfluence *influences [[buffer(ZCInfluencesIndex)]],
                      device const float4x4 *skinMatrices [[buffer(ZCSkinMatricesIndex)]],
                      device float4 *target [[buffer(ZCTargetIndex)]],
                      device float4 *targetNormal [[buffer(ZCTargetNormalIndex)]],
                      uint gid [[thread_position_in_grid]]) {
    const uint particleCount = params.counts.x;
    if (gid >= particleCount) {
        return;
    }

    const float4 x4 = positionIn[gid];
    const float3 bindPosition = rest[gid].xyz;
    const float3 bindNormal = restNormal[gid].xyz;
    const ZCInfluence influence = influences[gid];
    const uint matrixBase = params.rings.x;

    // The skinned target: the linear blend of the influences' skin
    // matrices (one to four, 2.60 on average on the shirt) over the bind
    // pose. A zero weight skips its 64 B matrix read; the unused slots
    // carry weight 0 on joint 0. The weights travel as `half4`
    // (`ZCInfluence`, 16 B), and a half's 2^-11 rounding leaves their sum
    // off 1 by up to 3.5e-4 on the shirt's 260 multi-influence pins, which
    // times a garment-frame position a metre or two from the origin put
    // the kernel's pins 0.50 mm off the CPU's float targets on 2026-11-03;
    // dividing the blended matrix by the sum of the rounded weights takes
    // the error back to the rounding of the weights' ratios, 2.9e-6 m on
    // the same pins, so the design's "pins on their targets" holds to the
    // float arithmetic without widening the influence to 32 B.
    float4x4 skin = float4x4(0.0f);
    float weightSum = 0.0f;
    for (uint j = 0; j < ZCMaxInfluences; j++) {
        const float weight = float(influence.weights[j]);
        if (weight == 0.0f) {
            continue;
        }
        skin += weight * skinMatrices[matrixBase + uint(influence.joints[j])];
        weightSum += weight;
    }
    if (weightSum > 0.0f) {
        skin *= 1.0f / weightSum;
    }
    const float3 skinned = (skin * float4(bindPosition, 1.0f)).xyz;
    float3 skinnedNormal = (skin * float4(bindNormal, 0.0f)).xyz;
    const float normalLength2 = length_squared(skinnedNormal);
    skinnedNormal = normalLength2 > 1e-12f ? skinnedNormal * rsqrt(normalLength2) : bindNormal;
    target[gid] = float4(skinned, 0.0f);
    targetNormal[gid] = float4(skinnedNormal, 0.0f);

    const float inverseMass = x4.w;
    if (inverseMass == 0.0f) {
        // A pin: on its target for the whole substep, at rest.
        previous[gid] = float4(skinned, 0.0f);
        positionOut[gid] = float4(skinned, 0.0f);
        velocity[gid] = float4(0.0f);
        return;
    }

    // Jolt's integrator: gravity, the linear damping factor, the step.
    const float dt = params.gravityDt.w;
    float3 v = velocity[gid].xyz;
    v += params.gravityDt.xyz * dt;
    v *= max(0.0f, 1.0f - params.material.x * dt);
    previous[gid] = x4;
    positionOut[gid] = float4(x4.xyz + v * dt, inverseMass);
}

// ===========================================================================
// zcSolve — per substep, params.substep.w times, N threads in groups of
// ZCThreadgroupSize.
//
// In: positionIn (the prediction, or the previous gather's output),
// previous, target, targetNormal, slack, csrOffsets, csrEntries,
// hullHeaders, hullPlanes, hullWorld (this substep's hulls at
// params.rings.y, the previous substep's at .z), spheres (this frame's at
// params.rings.w), params. Out: positionOut; velocity on the last gather
// (params.substep.z == params.substep.w - 1): v = (x - previous) / dt
// capped at params.material.y, 0 for a pin.
//
// Per particle, in this order and why. A pin (w == 0) is put on its target
// and done, as `zcPredict` left it. A free particle whose slack radius for
// the substep is nought — r = slack.x x params.floor.z, so every particle
// while the ramp's multiplier is 0 right after a hard skin — is also put on
// its target and done, as Jolt's kinematic placement does
// (SoftBodyMotionProperties.cpp:565-569); nothing else could move it, since
// the clamp below would put it back. Otherwise:
//
// 1. The CSR gather: for every constraint end under the particle's run
//    (10.44 on average, 22 at most on the shirt) d = x_i - x_j over the
//    PREDICTED positions of both ends, alpha = compliance[family] x
//    regionScale[region] / dt^2, delta_lambda = -(|d| - rest) / (w_i + w_j
//    + alpha), correction += w_i delta_lambda d/|d| — CoolCloth's gather
//    (CoolCloth.metal:152-193) re-indexed over the CSR, with its |d| < 1e-7
//    and denominator < 1e-8 guards — and the summed correction is applied
//    once, times the relaxation: CoolCloth's raw sum x 0.5 by default, or
//    omega x sum / count under the averaged flag, three and a half times
//    weaker per pass at the proxy's mean degree, the A/B that
//    `testStretchResidualAtRest` decides. The formula is Jolt's own edge
//    correction (SoftBodyMotionProperties.cpp:594-599) so Jolt's 1e-2 /
//    2e-2 / 0.3 m/N carry over unchanged; at dt 0.625 ms a stretch edge
//    gives back 61 % of its violation per pass, a bend pair 4.9 %.
// 2. The back-stop plane: s = dot(x - target, n) and if s < -backstop then
//    x -= n (s + backstop), the plane `backstop` metres behind the target
//    along the rotated rest normal, which is Jolt's 40 m back-stop sphere
//    within 0.28 mm at the largest slack; a body-facing particle (the
//    rolled cuffs, the collar's inside) carries +inf and the test never
//    fires. After the edges, not before as Jolt has it, so the edges do
//    not get the last word and leave the cuff 3 mm behind its target
//    (README "Cloth").
// 3. The hulls: the particle enters each hull's frame (a rigid inverse),
//    tests the hull's box inflated by twice the vertex radius (which culls
//    all but the particles within 6 mm of the hull's extent; the design's
//    bounding sphere held most of the shirt for a torso hull, and a
//    simdgroup runs the plane loop until its last lane leaves, so the
//    sphere left the eleven hulls at 3 ms of a Mac frame), and inside it
//    finds the most-facing plane — the largest signed distance
//    over the hull's plane set, as `ConvexHullShape::CollideSoftBodyVertices`
//    picks it (ConvexHullShape.cpp:1060-1090) — and is inside iff that
//    distance is below `vertexRadius`, pushed along that plane's normal by
//    radius minus distance; the plane loop leaves at the first plane that
//    reads the particle outside, since one such plane decides it. Friction is the one thing the Jolt arm could
//    not have (Jolt reads a collider's velocity only from a dynamic body):
//    with the hull's frame now and at the previous substep both bound, the
//    pushed point's motion with the hull over the substep is known, and
//    the tangential part of the particle's displacement relative to that
//    motion is scaled by 1 - `gpuHullFriction`, so a moving hull carries a
//    resting patch along; 0 by default to match the Jolt arm, 0.2 the A/B.
// 4. The floor: y clamped to the floor's top plus the radius, and the xz
//    motion mixed 0.4 of the way back toward the previous position,
//    CoolCloth's contact friction (CoolCloth.metal:199-203).
// 5. The spheres: each ball's centre backed along its velocity to the
//    substep's time, c_k = c - v (1 - (k + 1) / S) delta, so a 5 m/s ball
//    that crosses 5 cm inside a frame meets the fabric at every substep
//    where it is, then CoolCloth's push-out to radius + vertexRadius
//    (CoolCloth.metal:204-211).
// 6. The slack ball, last: |x - target| <= r, Jolt's clamp
//    (SoftBodyMotionProperties.cpp:556-563). Last so a free particle is
//    never past its slack at a substep's end, where Jolt's edge pass after
//    the skin leaves it inexact; the clamp scales toward the target, so a
//    particle the back-stop put in front of its plane stays in front, and
//    the `onClamp` share the stats kernel counts is exact. A hull push-out
//    beyond the slack is undone by the clamp, by this choice — the ball is
//    centred on the skin, 2 mm off the hull, so the clamp lands on or
//    outside the hull's surface for any slack above that.
//
// Then, on the last gather of the substep only, v = (x - previous) / dt
// capped at `maxLinearVelocity` (Jolt caps at the end of each collision
// step, SoftBodyMotionProperties.cpp:849-861), 0 for a pin.
// ===========================================================================
kernel void zcSolve(constant ZCParams &params [[buffer(ZCParamsIndex)]],
                    device const float4 *positionIn [[buffer(ZCPositionInIndex)]],
                    device float4 *positionOut [[buffer(ZCPositionOutIndex)]],
                    device const float4 *previous [[buffer(ZCPreviousIndex)]],
                    device float4 *velocity [[buffer(ZCVelocityIndex)]],
                    device const float4 *target [[buffer(ZCTargetIndex)]],
                    device const float4 *targetNormal [[buffer(ZCTargetNormalIndex)]],
                    device const float2 *slack [[buffer(ZCSlackIndex)]],
                    device const uint *csrOffsets [[buffer(ZCCSROffsetsIndex)]],
                    device const ZCEntry *csrEntries [[buffer(ZCCSREntriesIndex)]],
                    constant ZCHullHeader *hullHeaders [[buffer(ZCHullHeadersIndex)]],
                    constant float4 *hullPlanes [[buffer(ZCHullPlanesIndex)]],
                    constant float4x4 *hullWorld [[buffer(ZCHullWorldIndex)]],
                    device const ZCSphere *spheres [[buffer(ZCSpheresIndex)]],
                    uint gid [[thread_position_in_grid]]) {
    const uint particleCount = params.counts.x;
    if (gid >= particleCount) {
        return;
    }

    const float4 x4 = positionIn[gid];
    const float inverseMass = x4.w;
    const float3 skinned = target[gid].xyz;
    const float dt = params.gravityDt.w;
    const bool lastGather = params.substep.z + 1 >= params.substep.w;

    if (inverseMass == 0.0f) {
        // A pin sits on its target; `zcPredict` already put previous there.
        positionOut[gid] = float4(skinned, 0.0f);
        if (lastGather) {
            velocity[gid] = float4(0.0f);
        }
        return;
    }

    float3 x = x4.xyz;
    const float3 xPrevious = previous[gid].xyz;
    const float2 slackEntry = slack[gid];
    const float slackRadius = slackEntry.x * params.floor.z;

    if (slackRadius <= 0.0f) {
        // Held as a pin for this substep: the ramp's multiplier is 0 (a
        // hard skin just happened) or the particle's slack is 0.
        x = skinned;
    } else {
        // 1. The CSR gather over the predicted positions.
        const float dt2 = max(dt * dt, 1e-12f);
        const float3 alphaByFamily = params.compliance.xyz / dt2;
        float3 correction = float3(0.0f);
        uint constraintCount = 0;
        const uint firstEntry = csrOffsets[gid];
        const uint endEntry = csrOffsets[gid + 1];
        for (uint e = firstEntry; e < endEntry; e++) {
            const ZCEntry entry = csrEntries[e];
            const uint neighbour = entry.packed & ZCEntryNeighbourMask;
            const uint family = min((entry.packed >> ZCEntryFamilyShift) & ZCEntryFamilyMask, uint(ZCFamilyBend));
            const uint region = (entry.packed >> ZCEntryRegionShift) & ZCEntryRegionMask;
            const float4 q4 = positionIn[neighbour];
            const float3 d = x4.xyz - q4.xyz;
            const float len = length(d);
            if (len < 1e-7f) {
                continue;
            }
            const float alpha = alphaByFamily[family] * params.regionScale[region >> 2][region & 3];
            const float denominator = inverseMass + q4.w + alpha;
            if (denominator < 1e-8f) {
                continue;
            }
            const float deltaLambda = -(len - entry.rest) / denominator;
            correction += inverseMass * deltaLambda * (d / len);
            constraintCount++;
        }
        if (constraintCount > 0) {
            const float relaxation = params.compliance.w;
            x += correction * (params.flags.x != 0 ? relaxation / float(constraintCount) : relaxation);
        }

        // 2. The back-stop plane behind the skinned target (+inf on a
        // body-facing particle, so the test never fires there).
        {
            const float3 normal = targetNormal[gid].xyz;
            const float backstop = slackEntry.y;
            const float s = dot(x - skinned, normal);
            if (s < -backstop) {
                x -= normal * (s + backstop);
            }
        }

        // 3. The hulls: the hull-frame box, planes, most-facing push-out,
        // and the optional friction against the hull's own motion.
        const float vertexRadius = params.material.z;
        const uint hullCount = params.counts.z;
        const bool hullFriction = params.flags.z != 0 && params.material.w > 0.0f;
        for (uint h = 0; h < hullCount; h++) {
            const ZCHullHeader header = hullHeaders[h];
            const float4x4 world = hullWorld[params.rings.y + h];
            const float3 local = zcHullLocal(world, x);
            if (any(local < header.boundsMin.xyz) || any(local > header.boundsMax.xyz) || header.range.y == 0) {
                continue;
            }
            // The most-facing plane, with an early out: a particle is
            // inside iff EVERY plane's signed distance is below the vertex
            // radius, so the first plane that reads at or past it settles
            // the particle as outside and the rest of the hull's 60-88
            // planes are not read. Without it every particle inside a
            // bounding sphere paid the whole plane set — 2.7-7.0 ms of GPU
            // per Mac frame against 0.7-1.6 ms with the hulls off, measured
            // 2026-11-03 in the release host — where nearly all of them sit
            // outside the hull by construction (the slack ball is centred
            // on the skin, 2 mm off the hull), and leave after a few planes.
            float maxDistance = -INFINITY;
            float3 maxNormal = float3(0.0f);
            const uint firstPlane = header.range.x;
            const uint endPlane = firstPlane + header.range.y;
            for (uint p = firstPlane; p < endPlane; p++) {
                const float4 plane = hullPlanes[p];
                const float distance = dot(plane.xyz, local) + plane.w;
                if (distance > maxDistance) {
                    maxDistance = distance;
                    maxNormal = plane.xyz;
                    if (distance >= vertexRadius) {
                        break;
                    }
                }
            }
            if (maxDistance >= vertexRadius) {
                continue;
            }
            const float3 pushedLocal = local + maxNormal * (vertexRadius - maxDistance);
            float3 pushed = zcHullWorld(world, pushedLocal);
            if (hullFriction) {
                // The contact point's motion with the hull over the substep,
                // from the hull's frame at the previous substep; the
                // particle's displacement relative to it, less its normal
                // part, is what slides, and the friction takes that share.
                const float3 before = zcHullWorld(hullWorld[params.rings.z + h], pushedLocal);
                const float3 hullMotion = pushed - before;
                const float3 relative = (pushed - xPrevious) - hullMotion;
                const float3 worldNormal = zcHullRotate(world, maxNormal);
                const float3 tangential = relative - worldNormal * dot(relative, worldNormal);
                pushed -= tangential * params.material.w;
            }
            x = pushed;
        }

        // 4. The floor, with CoolCloth's xz mix toward the previous position.
        if (params.flags.y != 0) {
            const float floorTop = params.floor.x + vertexRadius;
            if (x.y < floorTop) {
                x.y = floorTop;
                x.xz = mix(x.xz, xPrevious.xz, params.floor.y);
            }
        }

        // 5. The spheres, each centre backed along its velocity to this
        // substep's time.
        const uint sphereCount = min(params.counts.w, uint(ZCSphereCapacity));
        if (sphereCount > 0) {
            const float k = float(params.substep.x);
            const float substepCount = float(max(params.substep.y, 1u));
            const float backTime = (1.0f - (k + 1.0f) / substepCount) * params.floor.w;
            for (uint i = 0; i < sphereCount; i++) {
                const ZCSphere sphere = spheres[params.rings.w + i];
                const float3 centre = sphere.center.xyz - sphere.velocity.xyz * backTime;
                const float radius = sphere.center.w + vertexRadius;
                const float3 d = x - centre;
                const float len = length(d);
                if (len < radius && len > 1e-6f) {
                    x += d / len * (radius - len);
                }
            }
        }

        // 6. The slack ball, last, so it is exact at the substep's end.
        {
            const float3 delta = x - skinned;
            const float distance2 = length_squared(delta);
            if (distance2 > slackRadius * slackRadius) {
                x = skinned + delta * sqrt(slackRadius * slackRadius / distance2);
            }
        }
    }

    positionOut[gid] = float4(x, inverseMass);

    if (lastGather) {
        // The XPBD velocity, capped as Jolt caps it at a collision step's end.
        float3 v = (x - xPrevious) / max(dt, 1e-6f);
        const float speed2 = length_squared(v);
        const float cap = params.material.y;
        if (speed2 > cap * cap) {
            v *= cap * rsqrt(speed2);
        }
        velocity[gid] = float4(v, 0.0f);
    }
}

// ===========================================================================
// zcStats — once per frame, ONE threadgroup of ZCStatsThreadgroupSize
// threads, each striding over the particles (four each at 3,995), simd
// reductions then a threadgroup reduction.
//
// In: positionIn (the frame's final positions), previous, target, slack,
// params. Out: stats (the frame's slot, bound at its ring offset):
// boundsMin/Max with the top speed and the largest pelvis distance in w,
// the NaN count, the on-clamp count and its denominator, and N as the
// written mark.
//
// Per particle, and why these figures: a particle with a non-finite
// coordinate is counted and kept out of every other figure, because a NaN
// folded into a min or a max poisons the bounds and the runaway rule needs
// the count on its own (the CPU scan at ZombieCloth.swift:1462-1464 stays
// the guard in phase 1, this count takes over in phase 2 when the positions
// stop coming back); the bounds feed the swept-AABB wake test while the
// shirt sleeps; the top speed is |x - previous| / dt over the last substep
// (the velocity buffer is not bound here; this is the uncapped figure the
// cap acted on) and the pelvis distance the runaway rule's other face; and
// the on-clamp count is the free particles within 1e-6 m of their slack
// radius — the number that says whether the look is bounded by the
// schedule or by the solver, which the `-clothSlack 3` experiment could
// only guess at on Jolt's inexact clamp. A particle counts as free when
// its inverse mass is above 0 AND its slack radius for the frame is above
// 0: while the ramp holds the multiplier at 0 every particle is held as a
// pin by the design's own words, and counting those as "on the clamp"
// would read 100 % after every hard skin.
//
// The reduction: each thread folds its stride of particles into
// registers, each simdgroup folds its lanes with the simd_* reductions,
// lane 0 of each writes threadgroup memory, and after one barrier thread 0
// folds the simdgroups and writes the slot. No atomics, so the result is
// bitwise repeatable. The threadgroup arrays hold 128 simdgroups so a
// 1,024-thread group reduces correctly at any simdgroup width down to 8
// (an Intel Mac's integrated GPU under macOS 14), not only Apple silicon's
// 32. The kernel needs exactly one threadgroup — a second would write the
// same slot — of any size up to ZCStatsThreadgroupSize; it strides by the
// group's real size.
// ===========================================================================
kernel void zcStats(constant ZCParams &params [[buffer(ZCParamsIndex)]],
                    device const float4 *positionIn [[buffer(ZCPositionInIndex)]],
                    device const float4 *previous [[buffer(ZCPreviousIndex)]],
                    device const float4 *target [[buffer(ZCTargetIndex)]],
                    device const float2 *slack [[buffer(ZCSlackIndex)]],
                    device ZCStats *stats [[buffer(ZCStatsIndex)]],
                    uint tid [[thread_position_in_threadgroup]],
                    uint threads [[threads_per_threadgroup]],
                    uint lane [[thread_index_in_simdgroup]],
                    uint simdIndex [[simdgroup_index_in_threadgroup]],
                    uint simdCount [[simdgroups_per_threadgroup]]) {
    constexpr uint maxSimdgroups = ZCStatsThreadgroupSize / 8;
    threadgroup float3 groupMin[maxSimdgroups];
    threadgroup float3 groupMax[maxSimdgroups];
    threadgroup float groupSpeed[maxSimdgroups];
    threadgroup float groupPelvis[maxSimdgroups];
    threadgroup uint groupNaN[maxSimdgroups];
    threadgroup uint groupOnClamp[maxSimdgroups];
    threadgroup uint groupFree[maxSimdgroups];

    const uint particleCount = params.counts.x;
    const float dt = max(params.gravityDt.w, 1e-6f);
    const float multiplier = params.floor.z;
    const float3 pelvis = params.pelvis.xyz;

    float3 boundsMin = float3(INFINITY);
    float3 boundsMax = float3(-INFINITY);
    float maxSpeed = 0.0f;
    float maxPelvisDistance = 0.0f;
    uint nanCount = 0;
    uint onClampCount = 0;
    uint freeCount = 0;

    for (uint i = tid; i < particleCount; i += threads) {
        const float4 x4 = positionIn[i];
        const float3 x = x4.xyz;
        if (!all(isfinite(x))) {
            nanCount++;
            continue;
        }
        boundsMin = min(boundsMin, x);
        boundsMax = max(boundsMax, x);
        maxSpeed = max(maxSpeed, length(x - previous[i].xyz) / dt);
        maxPelvisDistance = max(maxPelvisDistance, length(x - pelvis));
        if (x4.w > 0.0f) {
            const float slackRadius = slack[i].x * multiplier;
            if (slackRadius > 0.0f) {
                freeCount++;
                if (length(x - target[i].xyz) >= slackRadius - 1e-6f) {
                    onClampCount++;
                }
            }
        }
    }

    boundsMin = simd_min(boundsMin);
    boundsMax = simd_max(boundsMax);
    maxSpeed = simd_max(maxSpeed);
    maxPelvisDistance = simd_max(maxPelvisDistance);
    nanCount = simd_sum(nanCount);
    onClampCount = simd_sum(onClampCount);
    freeCount = simd_sum(freeCount);

    if (lane == 0 && simdIndex < maxSimdgroups) {
        groupMin[simdIndex] = boundsMin;
        groupMax[simdIndex] = boundsMax;
        groupSpeed[simdIndex] = maxSpeed;
        groupPelvis[simdIndex] = maxPelvisDistance;
        groupNaN[simdIndex] = nanCount;
        groupOnClamp[simdIndex] = onClampCount;
        groupFree[simdIndex] = freeCount;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid == 0) {
        const uint groups = min(simdCount, maxSimdgroups);
        for (uint s = 1; s < groups; s++) {
            boundsMin = min(boundsMin, groupMin[s]);
            boundsMax = max(boundsMax, groupMax[s]);
            maxSpeed = max(maxSpeed, groupSpeed[s]);
            maxPelvisDistance = max(maxPelvisDistance, groupPelvis[s]);
            nanCount += groupNaN[s];
            onClampCount += groupOnClamp[s];
            freeCount += groupFree[s];
        }
        ZCStats out;
        out.boundsMin = float4(boundsMin, maxSpeed);
        out.boundsMax = float4(boundsMax, maxPelvisDistance);
        out.counts = uint4(nanCount, onClampCount, freeCount, particleCount);
        out.reserved = uint4(0u);
        stats[0] = out;
    }
}

// ===========================================================================
// The GPU shell (phase 2). Two kernels after the frame's last substep and
// the stats, in the same serial encoder, reading the frame's final
// positions at ZCPositionInIndex, that are `ZombieCloth.RenderShell` moved
// off the cores: `frames(of:particles:into:)` becomes `zcTriangleFrames`
// and `evaluate(particles:)` becomes `zcShell`, each line kept, so the
// 29,402 shell vertices (32,530 driven exported copies in the game) come
// out where the CPU put them to the float arithmetic — the design's
// `testTheGPUShellMatchesTheCPUShell` holds them within 1e-5 m and 0.05
// degrees at the bind pose and in a swayed frame — and the CPU's part of
// the shirt's frame shrinks from the shell's 503 us median (1,008 max,
// M4 Max; about a millisecond on the headset) to a copy of the two
// `float4` streams into the override arrays, 100-150 us, until phase 3
// hands the engine the buffers themselves.
//
// Spaces: the solver simulates in the garment frame (world minus the
// origin) and the shell is drawn in MESH space, because the engine's
// deformation pass applies the override after the skin in the mesh's own
// space; `expandOverride` converted every particle with `toMesh * (p + origin, 1)`
// before the CPU shell saw it, and the kernels do the same per corner
// (three conversions per slot, 32,530 x 3, cached since a triangle's
// corners serve its four slots) rather than carrying the converted corners
// in the frame buffer, which the design sized at three lanes. The frame is
// built in mesh space, not built in the garment frame and rotated, because
// `toMesh` may scale (an entity scaled at the attach) and the rest offsets
// were expressed in the mesh-space frame by the prep.
// ===========================================================================

/// A particle out of the garment frame into mesh space, the CPU's order:
/// the origin added first (that is the world position `readPositions`
/// returns), the matrix second. The product is written out by hand with
/// contraction and reassociation off, because the frames kernel's
/// collapse test is a difference of two such conversions: under the
/// default fast math the compiler contracted the three corners' products
/// into fused multiply-adds differently after inlining, and two corners
/// with the SAME garment position came out 1e-8 m apart in mesh space
/// under a scaled `toMesh` — over the 1e-9 m line the CPU rule draws — so
/// an exactly collapsed triangle got a frame built from rounding instead of
/// keeping its last one (the scratch check, 2026-11-04; exact under the
/// identity, where no grouping changes a rounding). The pragma does not
/// reach the standard library's `float4x4 * float4`, whose inlined
/// instructions keep their own flags, which is why the four columns are
/// summed here; with the flags off identical inputs give identical outputs
/// and the rule matches the CPU's. The cost is nothing measurable on
/// 32,530 x 3 conversions.
static inline float3 zcMeshPoint(constant ZCShellParams &shell, float3 p) {
#pragma clang fp reassociate(off) contract(off)
    const float3 world = p + shell.origin.xyz;
    const float4 mesh = shell.toMesh[0] * world.x + shell.toMesh[1] * world.y + shell.toMesh[2] * world.z + shell.toMesh[3];
    return mesh.xyz;
}

// ===========================================================================
// zcTriangleFrames — once per frame, T threads in groups of
// ZCThreadgroupSize.
//
// In: positionIn (the frame's final positions, garment frame), triangles,
// shell params (toMesh, origin, counts.y = T). Out: frames[t] = (e1, n, t)
// of triangle t in mesh space, w lanes 0, for every triangle that is not
// collapsed; a collapsed one is left as it was.
//
// Per triangle, `RenderShell.frames(of:particles:into:)` line for line:
// the three corners into mesh space, ab = b - a, cross = ab x (c - a) (the
// un-normalised edge, so the normal's direction is the face's winding and
// its length the parallelogram's area), and unless |ab| > 1e-9 m and
// |cross| > 1e-12 m^2 the thread returns without writing, which keeps the
// frame the buffer held — the CPU's `guard ... else { continue }` on a
// triangle collapsed to a line or a point, which never happens on the
// shirt (the proxy's angles are 8 degrees and more at rest, 10.2 on the
// 16k cook) but must not turn into a NaN frame that NaNs its slots; the
// comparison is written so a NaN corner also fails it and keeps the
// frame. Then e1 = ab / |ab|, n = cross / |cross|, t = n x e1: a
// right-handed orthonormal frame, which is why a shell vertex rides it
// rigidly and a button keeps its shape. The CPU also stores the corners
// in its `Frame`; here `zcShell` reads them from the positions itself.
// ===========================================================================
kernel void zcTriangleFrames(constant ZCShellParams &shell [[buffer(ZCShellParamsIndex)]],
                             device const float4 *positionIn [[buffer(ZCPositionInIndex)]],
                             device const uint4 *triangles [[buffer(ZCTrianglesIndex)]],
                             device ZCTriangleFrame *frames [[buffer(ZCTriangleFramesIndex)]],
                             uint gid [[thread_position_in_grid]]) {
    if (gid >= shell.counts.y) {
        return;
    }
    const uint4 tri = triangles[gid];
    const float3 a = zcMeshPoint(shell, positionIn[tri.x].xyz);
    const float3 b = zcMeshPoint(shell, positionIn[tri.y].xyz);
    const float3 c = zcMeshPoint(shell, positionIn[tri.z].xyz);
    const float3 ab = b - a;
    const float3 crossProduct = cross(ab, c - a);
    const float lab = length(ab);
    const float lcross = length(crossProduct);
    if (!(lab > 1e-9f && lcross > 1e-12f)) {
        // Collapsed (or not a number): the last frame stands.
        return;
    }
    const float3 e1 = ab / lab;
    const float3 n = crossProduct / lcross;
    ZCTriangleFrame frame;
    frame.e1 = float4(e1, 0.0f);
    frame.n = float4(n, 0.0f);
    frame.t = float4(cross(n, e1), 0.0f);
    frames[gid] = frame;
}

// ===========================================================================
// zcShell — once per frame after zcTriangleFrames, slots threads in groups
// of ZCThreadgroupSize.
//
// In: positionIn (the frame's final positions, garment frame), triangles,
// frames (this frame's, from zcTriangleFrames), bindings, shell params
// (toMesh, origin, counts.x = slots, counts.y = T). Out: shellOut[s] =
// (position, 1) and shellOut[slots + s] = (normal, 0) for slot s, mesh
// space — the planar pair `deformOverride` consumes.
//
// Per slot, `RenderShell.evaluate` line for line: the binding's triangle
// (from `barycentric.w`), its three corners into mesh space as the frames
// kernel converted them, its frame, then pos = w.x a + w.y b + w.z c + o.x
// e1 + o.y n + o.z t and normal = r.x e1 + r.y n + r.z t, with w the
// barycentric weights, o the rest offset and r the exported copy's unit
// rest normal, both in the bind frame. The normal is not re-normalised,
// as the CPU's is not: r is unit and the frame orthonormal, so the result
// is unit to the arithmetic, and a re-normalisation would move it off the
// CPU's by a rounding the equality test need not absorb. The position's w
// is 1 and the normal's 0 because `deformOverride` writes `float4(p.xyz,
// 1)` and `float4(n.xyz, 0)` and phase 3 hands it these streams as they
// are. A binding whose triangle is past T (the asset's `isConsistent`
// refuses one before the attach) leaves its slot as it was rather than
// read past the buffer.
//
// Why the corners come from the positions and not the frame buffer: a
// frame of three lanes is the design's size; the three corner reads are
// 48 B a slot against 48 more a triangle, and the corners of a triangle
// serve its four slots on average from the cache. The rigid islands need
// no branch here either (the header says why): every vertex of a button
// binds to one triangle, so the formula carries the island whole.
// ===========================================================================
kernel void zcShell(constant ZCShellParams &shell [[buffer(ZCShellParamsIndex)]],
                    device const float4 *positionIn [[buffer(ZCPositionInIndex)]],
                    device const uint4 *triangles [[buffer(ZCTrianglesIndex)]],
                    device const ZCTriangleFrame *frames [[buffer(ZCTriangleFramesIndex)]],
                    device const ZCShellBinding *bindings [[buffer(ZCShellBindingsIndex)]],
                    device float4 *shellOut [[buffer(ZCShellOutIndex)]],
                    uint gid [[thread_position_in_grid]]) {
    const uint slotCount = shell.counts.x;
    if (gid >= slotCount) {
        return;
    }
    const ZCShellBinding binding = bindings[gid];
    const uint triangle = uint(binding.barycentric.w);
    if (triangle >= shell.counts.y) {
        return;
    }
    const uint4 tri = triangles[triangle];
    const float3 a = zcMeshPoint(shell, positionIn[tri.x].xyz);
    const float3 b = zcMeshPoint(shell, positionIn[tri.y].xyz);
    const float3 c = zcMeshPoint(shell, positionIn[tri.z].xyz);
    const ZCTriangleFrame frame = frames[triangle];
    const float3 e1 = frame.e1.xyz, n = frame.n.xyz, t = frame.t.xyz;
    const float3 w = binding.barycentric.xyz;
    const float3 o = binding.offset.xyz;
    const float3 r = binding.normal.xyz;
    const float3 position = w.x * a + w.y * b + w.z * c + o.x * e1 + o.y * n + o.z * t;
    const float3 normal = r.x * e1 + r.y * n + r.z * t;
    shellOut[gid] = float4(position, 1.0f);
    shellOut[slotCount + gid] = float4(normal, 0.0f);
}
