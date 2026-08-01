import Foundation
import simd

/// Deterministic splitmix64 generator so net topology is reproducible in tests.
struct CoolWebRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Tuning for one fired web net.
public struct CoolWebNetParams: Sendable, Equatable {
    /// Threads fanning out from the wrist.
    public var threadCount: Int
    /// Particles per thread (roots at the wrist, tips on the wall).
    public var particlesPerThread: Int
    public var substeps: Int
    public var gravity: SIMD3<Float>
    /// Per-second velocity damping exponent (higher = calmer threads).
    public var damping: Float
    /// Half-angle of the aim cone the thread rays scatter into (degrees).
    public var coneHalfAngleDegrees: Float
    public var webSpeed: Float
    public var maxRange: Float
    /// Per-thread rest-length slack range (1 = taut; >1 sags).
    public var slackRange: ClosedRange<Float>
    /// Random thread-to-thread links, as a fraction of threadCount.
    public var crossLinksPerThread: Float
    /// Seconds after attach before cross-links engage (lets threads settle).
    public var crossLinkDelay: Float
    public var threadRadius: Float
    /// Stretch ratio (length / rest) at which a thread segment snaps.
    public var tearStretch: Float
    /// Random-walk web patches left on the surface around each attach point.
    public var residueWalksPerAttach: Int
    public var residueSegmentsPerWalk: Int
    public var residueStepMeters: ClosedRange<Float>
    public var splatRadius: Float
    public var danglingDuration: Float
    public var dissolveDuration: Float
    public var missDissolveDuration: Float

    public init(
        threadCount: Int = 14,
        particlesPerThread: Int = 16,
        substeps: Int = 8,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        damping: Float = 2.0,
        coneHalfAngleDegrees: Float = 9,
        webSpeed: Float = 18,
        maxRange: Float = 7,
        slackRange: ClosedRange<Float> = 1.03 ... 1.16,
        crossLinksPerThread: Float = 1.4,
        crossLinkDelay: Float = 0.2,
        threadRadius: Float = 0.0018,
        // Per-SEGMENT stretch at the snap point. Like a hanging cable, the
        // segments at the supports carry ~1.5x the average stretch, so this
        // needs headroom above the intended end-to-end tear point (~1.9 here
        // means the whole thread tears around 1.3-1.4x end to end).
        tearStretch: Float = 1.9,
        residueWalksPerAttach: Int = 2,
        residueSegmentsPerWalk: Int = 4,
        residueStepMeters: ClosedRange<Float> = 0.03 ... 0.09,
        splatRadius: Float = 0.12,
        danglingDuration: Float = 2.5,
        dissolveDuration: Float = 0.8,
        missDissolveDuration: Float = 0.3
    ) {
        self.threadCount = max(1, threadCount)
        self.particlesPerThread = max(2, particlesPerThread)
        self.substeps = max(1, substeps)
        self.gravity = gravity
        self.damping = damping
        self.coneHalfAngleDegrees = coneHalfAngleDegrees
        self.webSpeed = webSpeed
        self.maxRange = maxRange
        self.slackRange = slackRange
        self.crossLinksPerThread = crossLinksPerThread
        self.crossLinkDelay = crossLinkDelay
        self.threadRadius = threadRadius
        self.tearStretch = max(1.05, tearStretch)
        self.residueWalksPerAttach = residueWalksPerAttach
        self.residueSegmentsPerWalk = residueSegmentsPerWalk
        self.residueStepMeters = residueStepMeters
        self.splatRadius = splatRadius
        self.danglingDuration = danglingDuration
        self.dissolveDuration = dissolveDuration
        self.missDissolveDuration = missDissolveDuration
    }
}

public enum CoolWebNetPhase: Sendable, Equatable {
    /// Tips are kinematic, flying from the hand toward their targets.
    case flying
    /// Tips pinned to the surface, root cluster follows the hand.
    case attached
    /// Roots released; the net hangs off the wall before dissolving.
    case dangling
    /// Fading out; removed when opacity reaches zero.
    case dissolving
}

/// One fired web: a small position-based particle system — threads fanning
/// from the wrist to scattered surface points, sparse cross-links, per-thread
/// slack, tension-based tearing, and static residue threads sprayed on the
/// surface around every attach point.
public final class CoolWebNet {
    public let hand: CoolWebHandSide
    public private(set) var phase: CoolWebNetPhase = .flying
    public let seed: Float
    /// Center-ray hit; nil means the whole shot misses and dissolves.
    public let centerHit: CoolWebSurfaceHit?

    private struct Constraint {
        var i: Int
        var j: Int
        var rest: Float
        var isCrossLink: Bool
        var active = true
        var tension: Float = 0
        /// Consecutive frames past the tear stretch. Tearing requires the
        /// overstretch to be sustained so a hand-tracking jump (a teleported
        /// root pin) doesn't shred the net in one transient frame.
        var overstretchedFrames: UInt8 = 0
    }

    /// Frames a segment must stay past the tear stretch before it snaps
    /// (~0.1 s at 90 fps).
    private static let tearSustainFrames: UInt8 = 9

    private let params: CoolWebNetParams
    private let origin: SIMD3<Float>
    private let threadDirections: [SIMD3<Float>]
    private let threadTargets: [SIMD3<Float>]
    private let threadTargetNormals: [SIMD3<Float>?]
    private let threadSlack: [Float]

    private var positions: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    private var constraints: [Constraint]
    private var crossLinkPairs: [(Int, Int)]
    private var crossLinksEngaged = false

    private var handPosition: SIMD3<Float>
    private var rootsPinned = true
    private var threadAttached: [Bool]
    private var tipTravel: Float = 0
    private var attachTime: TimeInterval?
    private var phaseChangeTime: TimeInterval
    private var opacity: Float = 1
    private var dissolveDuration: Float

    private var residueSegments: [CoolWebSegmentDesc] = []
    /// Main-thread segments torn so far (diagnostics / tests).
    public private(set) var tornThreadCount = 0
    /// Cross-links torn so far — these are the weakest and snap first.
    public private(set) var tornCrossLinkCount = 0
    public var tornCount: Int { tornThreadCount + tornCrossLinkCount }

    private let particlesPerThread: Int

    public init(
        hand: CoolWebHandSide,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        surfaceQuery: (SIMD3<Float>, SIMD3<Float>, Float) -> CoolWebSurfaceHit?,
        params: CoolWebNetParams,
        now: TimeInterval,
        randomSeed: UInt64 = .random(in: 1 ... .max)
    ) {
        self.hand = hand
        self.params = params
        self.origin = origin
        particlesPerThread = params.particlesPerThread
        handPosition = origin
        phaseChangeTime = now
        dissolveDuration = params.dissolveDuration

        var rng = CoolWebRandom(seed: randomSeed)
        seed = Float.random(in: 0 ..< 100, using: &rng)

        let aim = simd_normalize(direction)
        centerHit = surfaceQuery(origin, aim, params.maxRange)

        // Scatter thread rays inside the aim cone; ray 0 is the center ray.
        var basisU = simd_cross(aim, abs(aim.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0))
        basisU = simd_normalize(basisU)
        let basisV = simd_cross(aim, basisU)
        let maxAngle = params.coneHalfAngleDegrees * .pi / 180

        var directions: [SIMD3<Float>] = []
        var targets: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>?] = []
        var slacks: [Float] = []
        for thread in 0 ..< params.threadCount {
            let dir: SIMD3<Float>
            if thread == 0 {
                dir = aim
            } else {
                let angle = maxAngle * sqrt(Float.random(in: 0.15 ... 1, using: &rng))
                let azimuth = Float.random(in: 0 ..< 2 * .pi, using: &rng)
                dir = simd_normalize(
                    aim * cos(angle)
                        + (basisU * cos(azimuth) + basisV * sin(azimuth)) * sin(angle)
                )
            }
            directions.append(dir)

            if let hit = surfaceQuery(origin, dir, params.maxRange) {
                targets.append(hit.position)
                normals.append(hit.normal)
            } else if let centerHit {
                // Project the ray onto the center hit's plane so stray threads
                // still land on the wall around the impact.
                let denom = simd_dot(dir, centerHit.normal)
                let toPlane = simd_dot(centerHit.position - origin, centerHit.normal)
                if abs(denom) > 1e-4, toPlane / denom > 0 {
                    let t = min(toPlane / denom, params.maxRange * 1.3)
                    targets.append(origin + dir * t)
                    normals.append(centerHit.normal)
                } else {
                    targets.append(origin + dir * params.maxRange)
                    normals.append(nil)
                }
            } else {
                targets.append(origin + dir * params.maxRange)
                normals.append(nil)
            }
            slacks.append(Float.random(in: params.slackRange, using: &rng))
        }
        threadDirections = directions
        threadTargets = targets
        threadTargetNormals = normals
        threadSlack = slacks
        threadAttached = Array(repeating: false, count: params.threadCount)

        let particleCount = params.threadCount * params.particlesPerThread
        positions = Array(repeating: origin, count: particleCount)
        previous = positions

        // Thread segments: one distance constraint per consecutive pair.
        var built: [Constraint] = []
        for thread in 0 ..< params.threadCount {
            let base = thread * params.particlesPerThread
            for i in 0 ..< (params.particlesPerThread - 1) {
                built.append(Constraint(i: base + i, j: base + i + 1, rest: 0, isCrossLink: false))
            }
        }
        constraints = built

        // Sparse cross-links between neighbouring threads at random depths
        // (activated after attach, once rest distances are meaningful).
        var pairs: [(Int, Int)] = []
        let crossLinkCount = Int(Float(params.threadCount) * params.crossLinksPerThread)
        for _ in 0 ..< crossLinkCount {
            let threadA = Int.random(in: 0 ..< params.threadCount, using: &rng)
            var threadB = Int.random(in: 0 ..< params.threadCount, using: &rng)
            if threadB == threadA { threadB = (threadB + 1) % params.threadCount }
            let depth = Int.random(
                in: (params.particlesPerThread / 4) ..< (params.particlesPerThread - 1),
                using: &rng
            )
            pairs.append((
                threadA * params.particlesPerThread + depth,
                threadB * params.particlesPerThread + depth
            ))
        }
        crossLinkPairs = pairs

        if centerHit == nil {
            dissolveDuration = params.missDissolveDuration
        }
    }

    public var isDead: Bool { opacity <= 0 }
    public var isHeld: Bool { phase == .flying || phase == .attached }
    public var currentOpacity: Float { opacity }
    public var activeSegmentCount: Int {
        constraints.lazy.filter { $0.active }.count + residueSegments.count
    }

    public func updateHand(_ position: SIMD3<Float>) {
        handPosition = position
    }

    /// Lets go of the roots: the net stays on the wall and dangles.
    public func release(now: TimeInterval) {
        guard isHeld else { return }
        if phase == .attached {
            rootsPinned = false
            transition(to: .dangling, now: now)
        } else {
            dissolveDuration = params.missDissolveDuration
            transition(to: .dissolving, now: now)
        }
    }

    public func update(now: TimeInterval, dt: Float) {
        switch phase {
        case .flying:
            updateFlying(now: now, dt: dt)
        case .attached:
            if !crossLinksEngaged,
               let attachTime,
               now - attachTime > TimeInterval(params.crossLinkDelay) {
                engageCrossLinks()
            }
        case .dangling:
            if now - phaseChangeTime > TimeInterval(params.danglingDuration) {
                transition(to: .dissolving, now: now)
            }
        case .dissolving:
            let t = Float(now - phaseChangeTime) / max(0.01, dissolveDuration)
            opacity = max(0, 1 - t)
        }

        step(dt: dt)
        if phase == .attached || phase == .dangling {
            tearOverstretched()
        }
    }

    // MARK: - Flight

    private func updateFlying(now: TimeInterval, dt: Float) {
        tipTravel += params.webSpeed * dt
        var allDone = true
        for thread in 0 ..< threadDirections.count {
            guard !threadAttached[thread] else { continue }
            let targetDistance = simd_length(threadTargets[thread] - origin)
            if tipTravel >= targetDistance {
                threadAttached[thread] = true
            } else {
                allDone = false
            }
        }

        if centerHit != nil, threadAttached[0], attachTime == nil {
            attachTime = now
        }

        if allDone {
            if centerHit != nil {
                spawnResidue()
                transition(to: .attached, now: now)
                if attachTime == nil { attachTime = now }
            } else {
                transition(to: .dissolving, now: now)
            }
        }
    }

    // MARK: - Solver

    private func step(dt rawDt: Float) {
        let dt = min(max(rawDt, 0), 1.0 / 30.0)
        guard dt > 0 else { return }
        let substepDt = dt / Float(params.substeps)
        let dampingFactor = exp(-params.damping * substepDt)
        let gravityStep = params.gravity * (substepDt * substepDt)

        // Update rest lengths: taut behind the flying tips, slack once attached.
        // Thread constraints occupy the first threadCount * (P-1) slots; the
        // cross-links appended later keep their attach-time rest.
        for thread in 0 ..< threadDirections.count {
            let segments = Float(particlesPerThread - 1)
            let rest: Float
            if phase == .flying, !threadAttached[thread] {
                let tip = tipPosition(thread: thread)
                rest = simd_length(tip - handPosition) / segments
            } else {
                rest = simd_length(threadTargets[thread] - origin)
                    * threadSlack[thread] / segments
            }
            let firstConstraint = thread * (particlesPerThread - 1)
            for i in 0 ..< (particlesPerThread - 1) {
                constraints[firstConstraint + i].rest = rest
            }
        }

        for _ in 0 ..< params.substeps {
            applyPins()
            for i in 0 ..< positions.count where !isPinned(i) {
                let velocity = (positions[i] - previous[i]) * dampingFactor
                previous[i] = positions[i]
                positions[i] += velocity + gravityStep
            }
            // Several forward+backward sweeps per substep: a taut chain
            // between two pins needs the extra iterations or the residual
            // stretch concentrates at the pinned ends and fakes local tension
            // spikes (observed: 1.5x local stretch at 1.23x average).
            for _ in 0 ..< 4 {
                solveConstraints(forward: true)
                solveConstraints(forward: false)
            }
            applyPins()
        }
    }

    private func tipPosition(thread: Int) -> SIMD3<Float> {
        if threadAttached[thread] {
            return threadTargets[thread]
        }
        let target = threadTargets[thread]
        let distance = simd_length(target - origin)
        let t = min(tipTravel / max(distance, 1e-4), 1)
        return origin + threadDirections[thread] * (distance * t)
    }

    private func isPinned(_ index: Int) -> Bool {
        let inThread = index % particlesPerThread
        if inThread == 0 { return rootsPinned }
        if inThread == particlesPerThread - 1 {
            let thread = index / particlesPerThread
            return phase == .flying || threadAttached[thread]
        }
        return false
    }

    private func applyPins() {
        for thread in 0 ..< threadDirections.count {
            let base = thread * particlesPerThread
            if rootsPinned {
                positions[base] = handPosition
                previous[base] = handPosition
            }
            let tipIndex = base + particlesPerThread - 1
            if phase == .flying || threadAttached[thread] {
                let tip = tipPosition(thread: thread)
                positions[tipIndex] = tip
                previous[tipIndex] = tip
            }
        }
    }

    private func solveConstraints(forward: Bool) {
        let count = constraints.count
        for index in 0 ..< count {
            let c = forward ? index : count - 1 - index
            guard constraints[c].active, constraints[c].rest > 0 else { continue }
            let i = constraints[c].i
            let j = constraints[c].j
            var delta = positions[j] - positions[i]
            let distance = simd_length(delta)
            guard distance > 1e-7 else { continue }
            delta /= distance
            let correction = delta * (distance - constraints[c].rest)

            let iPinned = isPinned(i)
            let jPinned = isPinned(j)
            switch (iPinned, jPinned) {
            case (true, true):
                continue
            case (true, false):
                positions[j] -= correction
            case (false, true):
                positions[i] += correction
            case (false, false):
                positions[i] += correction * 0.5
                positions[j] -= correction * 0.5
            }
        }
    }

    // MARK: - Cross-links, tearing, residue

    private func engageCrossLinks() {
        crossLinksEngaged = true
        for (i, j) in crossLinkPairs {
            let rest = simd_length(positions[j] - positions[i]) * 1.05
            guard rest > 1e-4 else { continue }
            constraints.append(
                Constraint(i: i, j: j, rest: rest, isCrossLink: true)
            )
        }
    }

    private func tearOverstretched() {
        // At most one segment snaps per frame — the worst offender — so the
        // relief propagates through the net before anything else tears.
        // Threads then snap one by one on a hard pull instead of shredding,
        // and a local stress spike can't take a healthy thread with it.
        var worstIndex = -1
        var worstRatio: Float = 0
        for index in 0 ..< constraints.count {
            guard constraints[index].active, constraints[index].rest > 0 else { continue }
            let length = simd_length(
                positions[constraints[index].j] - positions[constraints[index].i]
            )
            let stretch = length / constraints[index].rest
            // Cross-links are deliberately the weakest link: snapping them
            // first relieves stress concentration so the main threads only
            // tear on a genuine hard pull (matches the reference look, where
            // the connector threads go first).
            let tearStretch = constraints[index].isCrossLink
                ? params.tearStretch * 0.9
                : params.tearStretch
            constraints[index].tension = min(
                max((stretch - 1) / (tearStretch - 1), 0), 1
            )
            if stretch > tearStretch {
                constraints[index].overstretchedFrames &+= 1
                let ratio = stretch / tearStretch
                if constraints[index].overstretchedFrames >= Self.tearSustainFrames,
                   ratio > worstRatio {
                    worstRatio = ratio
                    worstIndex = index
                }
            } else {
                constraints[index].overstretchedFrames = 0
            }
        }
        if worstIndex >= 0 {
            constraints[worstIndex].active = false
            if constraints[worstIndex].isCrossLink {
                tornCrossLinkCount += 1
            } else {
                tornThreadCount += 1
            }
        }
    }

    /// Static web patches sprayed on the surface around every attach point —
    /// the messy wall coverage from the reference clip. Generated once at
    /// attach; drawn with the net's opacity but never simulated.
    private func spawnResidue() {
        var rng = CoolWebRandom(seed: UInt64(bitPattern: Int64(seed * 1e6)) | 1)
        for thread in 0 ..< threadTargets.count {
            guard let normal = threadTargetNormals[thread] else { continue }
            var tangent = simd_cross(
                normal,
                abs(normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            )
            tangent = simd_normalize(tangent)
            let bitangent = simd_cross(normal, tangent)
            let anchor = threadTargets[thread] + normal * 0.0015

            for _ in 0 ..< params.residueWalksPerAttach {
                var point = anchor
                var walkAngle = Float.random(in: 0 ..< 2 * .pi, using: &rng)
                for _ in 0 ..< params.residueSegmentsPerWalk {
                    walkAngle += Float.random(in: -0.9 ... 0.9, using: &rng)
                    let stepLength = Float.random(in: params.residueStepMeters, using: &rng)
                    let step = (tangent * cos(walkAngle) + bitangent * sin(walkAngle))
                        * stepLength
                    let next = point + step
                    residueSegments.append(CoolWebSegmentDesc(
                        a: point,
                        b: next,
                        radius: params.threadRadius * 0.75,
                        tension: 0,
                        opacity: 1,
                        seed: Float.random(in: 0 ..< 100, using: &rng)
                    ))
                    point = next
                }
            }
        }
    }

    private func transition(to newPhase: CoolWebNetPhase, now: TimeInterval) {
        phase = newPhase
        phaseChangeTime = now
    }

    // MARK: - Drawable output

    public func appendSegments(into segments: inout [CoolWebSegmentDesc]) {
        for constraint in constraints where constraint.active {
            segments.append(CoolWebSegmentDesc(
                a: positions[constraint.i],
                b: positions[constraint.j],
                radius: constraint.isCrossLink
                    ? params.threadRadius * 0.8
                    : params.threadRadius,
                tension: constraint.tension,
                opacity: opacity,
                seed: seed + Float(constraint.i % 17)
            ))
        }
        for residue in residueSegments {
            var faded = residue
            faded.opacity = opacity
            segments.append(faded)
        }
    }

    public func splatDesc(now: TimeInterval) -> CoolWebSplatDesc? {
        guard let centerHit, let attachTime else { return nil }
        return CoolWebSplatDesc(
            center: centerHit.position,
            normal: centerHit.normal,
            radius: params.splatRadius,
            opacity: opacity * 0.6,
            seed: seed,
            age: Float(now - attachTime)
        )
    }
}
