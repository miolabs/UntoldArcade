//
//  CoolWebGlove.swift
//  CoolWeb
//
//  Spider-Man glove, driven from the tracked hand skeleton every frame. The
//  geometry is the rigged movie-suit extraction loaded by
//  `CoolWebGloveAssetLoader` (17-bone ARKit-named skeleton, PBR textures);
//  this file owns the per-frame retarget (pose → joint palette via
//  `CoolWebGloveRig`) and the suit-up state machine (gaze gating, progress,
//  tracking-blip grace) whose output the render extension draws.
//
//  Pure math over `CoolWebHandPose` — deliberately free of ARKit and Metal
//  types so everything can be asserted on in host unit tests.
//

import Foundation
import simd

/// Tunables for the glove system. Distances are meters.
public struct CoolWebGloveConfig: Sendable, Equatable {
    /// Palm half-thickness at the wrist — fallback web-shooter muzzle offset
    /// off the inner wrist when the glove asset carries no muzzle marker.
    public var palmHalfThicknessWrist: Float = 0.018
    /// How the asset's proportions are stretched over the tracked hand.
    public var fit = CoolWebGloveFit()
    /// Seconds the suit-up animation takes to sweep from the wrist to the
    /// fingertips (and back when reversing). 0 makes it instant.
    public var buildDuration: Float = 0.9
    /// Seconds the user must keep looking at a hand before its suit-up
    /// starts — gives the eyes time to settle on the hand after flipping
    /// the Suit-Up toggle.
    public var suitUpGazeDelay: Float = 0.35

    public init() {}
}

/// Per-region fit of the glove mesh over the tracked hand. Bone LENGTHS
/// always follow the tracked joints, and every cross-section is first
/// scaled by the tracked hand's size (knuckle-span ratio vs the asset —
/// thickness tracks hand size closely and tracking can't measure it
/// directly). These knobs are relative corrections on top, plus the
/// fingertip overshoot, so the glove fully envelops the real hand (the
/// real hand shows through wherever the glove doesn't cover it). Tune live
/// from the example app's Glove fit sliders.
public struct CoolWebGloveFit: Sendable, Equatable {
    // Defaults: the values dialed in on device against the Mixamo suit
    // hands (2026-09-11) — the asset runs thick, the shell inflate does the
    // covering instead.
    /// Meters the glove's fingertips reach past the tracked tips.
    public var fingertipPadding: Float = 0.010
    /// Finger cross-section multiplier (1 = size-scaled asset thickness).
    public var fingerGirth: Float = 0.76
    /// Palm scale across the back-normal (1 = size-scaled asset thickness);
    /// width always follows the tracked knuckle span.
    public var palmThickness: Float = 0.5
    /// Cuff/forearm cross-section multiplier (width and thickness).
    public var cuffGirth: Float = 0.97
    /// Meters every vertex is pushed out along its normal — a uniform shell
    /// thickening that closes the gaps no bone scale reaches (finger
    /// crotches, the glove/gauntlet seam).
    public var inflate: Float = 0.0087

    public init() {}

    /// Exactly the asset's proportions, no overshoot — what tests use to
    /// prove the retarget reproduces the bind pose.
    public static var neutral: CoolWebGloveFit {
        var fit = CoolWebGloveFit()
        fit.fingertipPadding = 0
        fit.fingerGirth = 1
        fit.palmThickness = 1
        fit.cuffGirth = 1
        fit.inflate = 0
        return fit
    }
}

/// Orthonormal palm frame derived from the joint cloud (the pose carries no
/// orientation data). Shared by the retarget solver and the web-shooter
/// origin so the strand fires exactly out of the drawn barrel.
struct CoolWebHandFrame {
    var wrist: SIMD3<Float>
    var knuckleCenter: SIMD3<Float>
    /// Wrist → knuckle line.
    var forward: SIMD3<Float>
    /// Index → little knuckles, orthogonalized against forward.
    var lateral: SIMD3<Float>
    /// Out of the back of the hand.
    var backNormal: SIMD3<Float>
    var palmNormal: SIMD3<Float> { -backNormal }
    var palmLength: Float { simd_length(knuckleCenter - wrist) }

    init?(pose: CoolWebHandPose, side: CoolWebHandSide) {
        guard pose.index.points.count >= 5,
              pose.little.points.count >= 5,
              pose.middle.points.count >= 5,
              pose.ring.points.count >= 5,
              pose.thumb.points.count >= 5
        else { return nil }

        wrist = pose.wrist
        let indexKnuckle = pose.index.points[1]
        let littleKnuckle = pose.little.points[1]
        knuckleCenter = (indexKnuckle + littleKnuckle) * 0.5

        forward = safeNormalize(
            knuckleCenter - wrist, fallback: SIMD3<Float>(0, 0, -1)
        )
        var side0 = safeNormalize(
            littleKnuckle - indexKnuckle, fallback: SIMD3<Float>(1, 0, 0)
        )
        side0 = safeNormalize(
            side0 - forward * simd_dot(side0, forward),
            fallback: perpendicular(to: forward)
        )
        lateral = side0
        backNormal = safeNormalize(
            side == .right
                ? simd_cross(lateral, forward)
                : simd_cross(forward, lateral),
            fallback: SIMD3<Float>(0, 1, 0)
        )
    }
}

public enum CoolWebGloveBuild {
    /// Front value meaning "fully covered, no animation": far beyond any real
    /// coverage distance, so the shader's front test never trips.
    public static let coveredFront: Float = 1_000_000
}

// MARK: - Web-shooter muzzle

public enum CoolWebGloveBuilder {
    /// Where the glove's emitter sits — strands should fire from here so the
    /// web visually leaves the device on the inner wrist. Uses the loaded
    /// asset's skinned `webMuzzle` marker; falls back to a fitted offset off
    /// the wrist when no asset (or no marker) is available.
    public static func webShooterMuzzle(
        pose: CoolWebHandPose,
        side: CoolWebHandSide,
        config: CoolWebGloveConfig = CoolWebGloveConfig()
    ) -> SIMD3<Float>? {
        if let asset = CoolWebGloveAssetStore.shared.asset(for: side),
           let matrices = CoolWebGloveRig.skinningMatrices(
               skeleton: asset.skeleton, pose: pose, side: side,
               fit: config.fit
           ),
           let muzzle = CoolWebGloveRig.muzzlePosition(
               skeleton: asset.skeleton, matrices: matrices
           ) {
            return muzzle
        }
        guard let frame = CoolWebHandFrame(pose: pose, side: side) else {
            return nil
        }
        return muzzlePosition(frame: frame, config: config)
    }

    static func barrelCenter(
        frame: CoolWebHandFrame,
        config: CoolWebGloveConfig
    ) -> SIMD3<Float> {
        // Behind the wrist joint, over the cuff — on device the wrist joint
        // itself already reads as the start of the palm.
        frame.wrist - frame.forward * 0.018
            + frame.palmNormal * (config.palmHalfThicknessWrist + 0.006)
    }

    static func muzzlePosition(
        frame: CoolWebHandFrame,
        config: CoolWebGloveConfig
    ) -> SIMD3<Float> {
        barrelCenter(frame: frame, config: config) + frame.forward * 0.026
    }
}

// MARK: - Small math helpers

private func safeNormalize(
    _ vector: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let lengthSq = simd_length_squared(vector)
    guard lengthSq.isFinite, lengthSq > 1e-10 else { return fallback }
    return vector / sqrt(lengthSq)
}

private func perpendicular(to axis: SIMD3<Float>) -> SIMD3<Float> {
    let reference = abs(axis.y) < 0.9
        ? SIMD3<Float>(0, 1, 0)
        : SIMD3<Float>(1, 0, 0)
    return safeNormalize(
        simd_cross(axis, reference), fallback: SIMD3<Float>(1, 0, 0)
    )
}

// MARK: - Draw data

/// One hand's worth of glove drawing input for the render extension.
public struct CoolWebGloveDrawData: Sendable {
    public var side: CoolWebHandSide
    /// Skinning matrices ordered like the asset skeleton's joints.
    public var joints: [simd_float4x4]
    /// Suit-up front distance (m); `CoolWebGloveBuild.coveredFront` when the
    /// glove is fully on.
    public var front: Float
    /// Shell thickening along the normals (m), from the fit.
    public var inflate: Float
}

// MARK: - Shared state (game thread writes, render thread reads)

final class CoolWebGloveState: @unchecked Sendable {
    static let shared = CoolWebGloveState()

    /// A tracking blip shorter than this keeps the hand's suit-up progress.
    private static let reappearGrace: TimeInterval = 0.5
    /// The front sweeps a little past the extent so the glow band and the
    /// ragged-edge jitter fully clear the fingertips.
    private static let frontOverscan: Float = 0.015

    private struct Entry {
        var joints: [simd_float4x4]
        var coverageExtent: Float
        var inflate: Float
        /// 0 = bare hand … 1 = fully covered. Advances toward the suit-up
        /// target each game-thread update, so a mid-flight toggle simply
        /// reverses from wherever the front currently is.
        var progress: Float
        var lastNow: TimeInterval
        /// When the user started looking at this hand (progress 0, waiting
        /// to begin building).
        var gazeSince: TimeInterval?
        var buildDuration: Float
    }

    private let lock = NSLock()
    private var enabled = false
    /// Target state: true → gloves build on (gaze-gated), false → they
    /// retract in reverse.
    private var suitUp = false
    private var entries: [CoolWebHandSide: Entry] = [:]
    private var removedAt: [CoolWebHandSide: (time: TimeInterval, progress: Float)] = [:]

    func setEnabled(_ newValue: Bool) {
        lock.withLock {
            enabled = newValue
            if !newValue {
                entries.removeAll()
                removedAt.removeAll()
            }
        }
    }

    func setSuitUp(_ up: Bool) {
        lock.withLock {
            guard suitUp != up else { return }
            suitUp = up
            if up {
                // Each hand re-arms its own gaze trigger.
                for side in entries.keys {
                    entries[side]?.gazeSince = nil
                }
            }
        }
    }

    var isSuitUp: Bool {
        lock.withLock { suitUp }
    }

    /// Largest suit-up progress across hands — the app uses this to decide
    /// when to hide the real passthrough hands.
    func maxProgress() -> Float {
        lock.withLock { entries.values.map(\.progress).max() ?? 0 }
    }

    func update(
        side: CoolWebHandSide,
        joints: [simd_float4x4],
        coverageExtent: Float,
        inflate: Float,
        lookedAt: Bool,
        buildDuration: Float,
        gazeDelay: Float,
        now: TimeInterval
    ) {
        lock.withLock {
            guard enabled else { return }
            let target: Float = suitUp ? 1 : 0
            guard var entry = entries[side] else {
                // Newly appeared. A short tracking blip resumes the previous
                // progress; otherwise the hand starts bare and waits for gaze.
                var progress: Float = 0
                if let removed = removedAt[side],
                   now - removed.time < Self.reappearGrace {
                    progress = removed.progress
                }
                removedAt[side] = nil
                entries[side] = Entry(
                    joints: joints,
                    coverageExtent: coverageExtent,
                    inflate: inflate,
                    progress: progress,
                    lastNow: now,
                    // The gaze timer arms from the very first looked-at frame.
                    gazeSince: (suitUp && lookedAt && progress == 0) ? now : nil,
                    buildDuration: buildDuration
                )
                return
            }
            entry.joints = joints
            entry.coverageExtent = coverageExtent
            entry.inflate = inflate
            entry.buildDuration = buildDuration
            let dt = Float(max(0, now - entry.lastNow))
            entry.lastNow = now

            if entry.progress == 0, target == 1 {
                // Bare hand waiting to build: only start once the user has
                // been looking at it for the focus delay.
                if lookedAt {
                    let since = entry.gazeSince ?? now
                    entry.gazeSince = since
                    if now - since >= TimeInterval(gazeDelay) {
                        entry.progress = 0.0001
                        entry.gazeSince = nil
                    }
                } else {
                    entry.gazeSince = nil
                }
            } else if entry.progress != target {
                let step = buildDuration > 0 ? dt / buildDuration : 1
                entry.progress = target > entry.progress
                    ? min(target, entry.progress + step)
                    : max(target, entry.progress - step)
            }
            entries[side] = entry
        }
    }

    func remove(side: CoolWebHandSide, now: TimeInterval) {
        lock.withLock {
            guard let entry = entries.removeValue(forKey: side) else { return }
            removedAt[side] = (now, entry.progress)
        }
    }

    func clear() {
        lock.withLock {
            entries.removeAll()
            removedAt.removeAll()
        }
    }

    /// Rewinds every hand to bare and re-arms the gaze triggers.
    func replayBuild(now _: TimeInterval) {
        lock.withLock {
            for side in entries.keys {
                entries[side]?.progress = 0
                entries[side]?.gazeSince = nil
            }
            removedAt.removeAll()
        }
    }

    /// Per-hand draw data, or empty when disabled/bare. While a glove is
    /// partway on, the front distance is derived from the eased progress;
    /// covered gloves report the sentinel.
    func snapshot() -> [CoolWebGloveDrawData] {
        lock.withLock {
            guard enabled, !entries.isEmpty else { return [] }
            var out: [CoolWebGloveDrawData] = []
            for side in CoolWebHandSide.allCases {
                guard let entry = entries[side], entry.progress > 0 else {
                    continue
                }
                let front: Float
                if entry.progress < 1 {
                    // smoothstep easing: the front accelerates off the wrist
                    // and settles at the fingertips (mirrored on reverse).
                    let t = entry.progress
                    let eased = t * t * (3 - 2 * t)
                    front = eased * (entry.coverageExtent + Self.frontOverscan)
                } else {
                    front = CoolWebGloveBuild.coveredFront
                }
                out.append(CoolWebGloveDrawData(
                    side: side, joints: entry.joints, front: front,
                    inflate: entry.inflate
                ))
            }
            return out
        }
    }
}

// MARK: - Public API

/// Master switch for the glove system (rendering + state). Keep it on while
/// the immersive space lives; use `setCoolWebGloveSuitUp` to animate the
/// gloves on and off.
public func setCoolWebGloveEnabled(_ enabled: Bool) {
    CoolWebGloveState.shared.setEnabled(enabled)
}

/// Suit-Up target. `true`: each hand builds its glove wrist→fingertips as
/// soon as the user has looked at it for `config.suitUpGazeDelay` seconds
/// (the `lookedAt` flag passed to `updateCoolWebGlove`). `false`: gloves
/// retract with the same animation in reverse — from wherever they are, so
/// a mid-build flip just turns the front around.
public func setCoolWebGloveSuitUp(_ up: Bool) {
    CoolWebGloveState.shared.setSuitUp(up)
}

/// Largest suit-up progress across both hands (0 bare … 1 covered). The app
/// uses it to decide when to hide the real passthrough hands.
public func coolWebGloveMaxProgress() -> Float {
    CoolWebGloveState.shared.maxProgress()
}

/// Retargets one hand's glove onto the latest pose. Call every frame from
/// the game update; pass nil (or an untracked pose) to hide that hand's
/// glove. `lookedAt` reports whether the user's gaze is on this hand — it
/// gates when a bare hand starts building. No-op until
/// `loadCoolWebGloveAssets` has provided this side's rigged asset.
public func updateCoolWebGlove(
    side: CoolWebHandSide,
    pose: CoolWebHandPose?,
    config: CoolWebGloveConfig = CoolWebGloveConfig(),
    lookedAt: Bool = true,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
) {
    guard let pose, pose.isTracked else {
        CoolWebGloveState.shared.remove(side: side, now: now)
        return
    }
    guard let asset = CoolWebGloveAssetStore.shared.asset(for: side),
          let joints = CoolWebGloveRig.skinningMatrices(
              skeleton: asset.skeleton, pose: pose, side: side,
              fit: config.fit
          )
    else {
        CoolWebGloveState.shared.remove(side: side, now: now)
        return
    }
    CoolWebGloveState.shared.update(
        side: side,
        joints: joints,
        coverageExtent: asset.coverageExtent,
        inflate: config.fit.inflate,
        lookedAt: lookedAt,
        buildDuration: config.buildDuration,
        gazeDelay: config.suitUpGazeDelay,
        now: now
    )
}

/// Rewinds both gloves to bare hands; they build again on the next gaze.
public func replayCoolWebGloveBuild(
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
) {
    CoolWebGloveState.shared.replayBuild(now: now)
}

/// Hides both gloves (e.g. on session teardown) without toggling the option.
public func clearCoolWebGloves() {
    CoolWebGloveState.shared.clear()
}
