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

/// A pushout collider for the rope — a few of these approximate the gloved
/// hand so held strands drape over a closed fist instead of clipping it.
public struct CoolWebCollisionSphere: Sendable, Equatable {
    public var center: SIMD3<Float>
    public var radius: Float

    public init(center: SIMD3<Float>, radius: Float) {
        self.center = center
        self.radius = radius
    }
}

/// Tuning for one fired web.
public struct CoolWebNetParams: Sendable, Equatable {
    /// Particles of the single leader line from the wrist.
    public var leaderParticles: Int
    /// Short branch threads the leader blooms into near the surface.
    public var branchCount: Int
    /// Particles per branch thread.
    public var branchParticles: Int
    public var substeps: Int
    public var gravity: SIMD3<Float>
    /// Per-second velocity damping exponent (higher = calmer threads).
    public var damping: Float
    /// Max radius of the net's spread on the surface (m).
    public var netRadius: Float
    /// Spread also scales with shot distance: radius = min(netRadius,
    /// netRadiusFraction * distance).
    public var netRadiusFraction: Float
    public var webSpeed: Float
    public var maxRange: Float
    /// Leader rest-length slack (1 = taut; >1 sags).
    public var leaderSlack: Float
    /// Per-branch rest-length slack range.
    public var branchSlackRange: ClosedRange<Float>
    /// Cross-links between neighbouring branches, as a fraction of branchCount.
    public var crossLinksPerBranch: Float
    /// Seconds after attach before cross-links engage (lets threads settle).
    public var crossLinkDelay: Float
    public var threadRadius: Float
    // Per-SEGMENT stretch at the snap point. Like a hanging cable, the
    // segments at the supports carry ~1.5x the average stretch, so this
    // needs headroom above the intended end-to-end tear point (~1.9 here
    // means the whole line tears around 1.3-1.4x end to end).
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
        leaderParticles: Int = 20,
        branchCount: Int = 8,
        branchParticles: Int = 5,
        substeps: Int = 8,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        damping: Float = 2.0,
        netRadius: Float = 0.22,
        netRadiusFraction: Float = 0.12,
        webSpeed: Float = 18,
        maxRange: Float = 7,
        leaderSlack: Float = 1.05,
        branchSlackRange: ClosedRange<Float> = 1.02 ... 1.12,
        crossLinksPerBranch: Float = 0.8,
        crossLinkDelay: Float = 0.2,
        threadRadius: Float = 0.0016,
        tearStretch: Float = 1.9,
        residueWalksPerAttach: Int = 2,
        residueSegmentsPerWalk: Int = 3,
        residueStepMeters: ClosedRange<Float> = 0.015 ... 0.05,
        splatRadius: Float = 0.12,
        // A let-go web should linger on the wall for a while before fading.
        danglingDuration: Float = 6,
        dissolveDuration: Float = 1.5,
        missDissolveDuration: Float = 0.3
    ) {
        self.leaderParticles = max(4, leaderParticles)
        self.branchCount = max(1, branchCount)
        self.branchParticles = max(2, branchParticles)
        self.substeps = max(1, substeps)
        self.gravity = gravity
        self.damping = damping
        self.netRadius = netRadius
        self.netRadiusFraction = netRadiusFraction
        self.webSpeed = webSpeed
        self.maxRange = maxRange
        self.leaderSlack = leaderSlack
        self.branchSlackRange = branchSlackRange
        self.crossLinksPerBranch = crossLinksPerBranch
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
    /// The leader tip is kinematic, flying from the hand toward the target;
    /// near the surface it blooms into the branch net.
    case flying
    /// Branch tips pinned to the surface, leader root follows the hand.
    case attached
    /// Root released; the web hangs off the wall before dissolving.
    case dangling
    /// Fading out; removed when opacity reaches zero.
    case dissolving
}

/// One fired web: a single leader line from the wrist that blooms into a
/// small net just before the surface — short branch threads fanning to
/// scattered attach points around the hit, sparse cross-links, tension-based
/// tearing, and a modest patch of residue threads on the wall.
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
        /// root pin) doesn't shred the web in one transient frame.
        var overstretchedFrames: UInt8 = 0
    }

    /// Frames a segment must stay past the tear stretch before it snaps
    /// (~0.1 s at 90 fps).
    private static let tearSustainFrames: UInt8 = 9

    private let params: CoolWebNetParams
    private let origin: SIMD3<Float>
    private let aim: SIMD3<Float>
    /// Where the leader ends and the net begins (just off the surface).
    private let branchPoint: SIMD3<Float>
    private let leaderDistance: Float
    private let branchTargets: [SIMD3<Float>]
    private let branchTargetNormals: [SIMD3<Float>?]
    private let branchSlack: [Float]
    private let leaderRest: Float
    private let branchRest: [Float]

    private var positions: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    private var constraints: [Constraint]
    private var crossLinkPairs: [(Int, Int)]
    private var crossLinksEngaged = false

    private var handPosition: SIMD3<Float>
    private var rootPinned = true
    private var branchAttached: [Bool]
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
        handPosition = origin
        phaseChangeTime = now
        dissolveDuration = params.dissolveDuration

        var rng = CoolWebRandom(seed: randomSeed)
        seed = Float.random(in: 0 ..< 100, using: &rng)

        aim = simd_normalize(direction)
        centerHit = surfaceQuery(origin, aim, params.maxRange)

        // The net spreads over a small disc around the hit; the leader stops
        // one net-radius short of the wall and the branches bloom from there.
        let hitDistance = centerHit?.distance ?? params.maxRange
        let netRadius = min(params.netRadius, params.netRadiusFraction * hitDistance)
        let standoff = min(max(netRadius * 1.2, 0.12), hitDistance * 0.5)
        leaderDistance = hitDistance - standoff
        branchPoint = origin + aim * leaderDistance

        var targets: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>?] = []
        var slacks: [Float] = []
        if let centerHit {
            var tangent = simd_cross(
                centerHit.normal,
                abs(centerHit.normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            )
            tangent = simd_normalize(tangent)
            let bitangent = simd_cross(centerHit.normal, tangent)

            for branch in 0 ..< params.branchCount {
                // Even angular spread with jitter, radius biased outward.
                let angle = (Float(branch) + Float.random(in: -0.3 ... 0.3, using: &rng))
                    / Float(params.branchCount) * 2 * .pi
                let radius = netRadius * sqrt(Float.random(in: 0.25 ... 1, using: &rng))
                let sample = centerHit.position
                    + (tangent * cos(angle) + bitangent * sin(angle)) * radius

                // Raycast from the branch point at the sampled spot so the
                // net hugs real geometry; fall back to the hit plane.
                let toSample = sample - branchPoint
                let sampleDistance = simd_length(toSample)
                if sampleDistance > 1e-4,
                   let hit = surfaceQuery(
                       branchPoint,
                       toSample / sampleDistance,
                       sampleDistance + 0.5
                   ) {
                    targets.append(hit.position)
                    normals.append(hit.normal)
                } else {
                    targets.append(sample)
                    normals.append(centerHit.normal)
                }
                slacks.append(Float.random(in: params.branchSlackRange, using: &rng))
            }
        } else {
            // Whole shot misses: no net, the leader just flies out and fades.
            for _ in 0 ..< params.branchCount {
                targets.append(origin + aim * params.maxRange)
                normals.append(nil)
                slacks.append(1)
            }
            dissolveDuration = params.missDissolveDuration
        }
        branchTargets = targets
        branchTargetNormals = normals
        branchSlack = slacks
        branchAttached = Array(repeating: false, count: params.branchCount)

        leaderRest = max(leaderDistance, 0.05) * params.leaderSlack
            / Float(params.leaderParticles - 1)
        let bloomOrigin = origin + aim * leaderDistance
        var rests: [Float] = []
        for branch in 0 ..< params.branchCount {
            rests.append(
                simd_length(targets[branch] - bloomOrigin) * slacks[branch]
                    / Float(params.branchParticles)
            )
        }
        branchRest = rests

        // Particles: leader chain first, then each branch's own particles.
        // A branch's first constraint hooks onto the leader's tip particle,
        // forming the knot where the line blooms into the net.
        let particleCount = params.leaderParticles
            + params.branchCount * params.branchParticles
        positions = Array(repeating: origin, count: particleCount)
        previous = positions

        var built: [Constraint] = []
        for i in 0 ..< (params.leaderParticles - 1) {
            built.append(Constraint(i: i, j: i + 1, rest: 0, isCrossLink: false))
        }
        let leaderTip = params.leaderParticles - 1
        for branch in 0 ..< params.branchCount {
            let base = params.leaderParticles + branch * params.branchParticles
            built.append(Constraint(i: leaderTip, j: base, rest: 0, isCrossLink: false))
            for i in 0 ..< (params.branchParticles - 1) {
                built.append(Constraint(i: base + i, j: base + i + 1, rest: 0, isCrossLink: false))
            }
        }
        constraints = built

        // Sparse cross-links between neighbouring branches at mid depth
        // (activated after attach, once rest distances are meaningful).
        var pairs: [(Int, Int)] = []
        let crossLinkCount = Int(Float(params.branchCount) * params.crossLinksPerBranch)
        for link in 0 ..< crossLinkCount {
            let branchA = link % params.branchCount
            let branchB = (branchA + 1) % params.branchCount
            guard branchA != branchB else { continue }
            let depth = Int.random(
                in: (params.branchParticles / 2) ..< params.branchParticles,
                using: &rng
            )
            pairs.append((
                params.leaderParticles + branchA * params.branchParticles + depth,
                params.leaderParticles + branchB * params.branchParticles + depth
            ))
        }
        crossLinkPairs = pairs
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

    /// Hand colliders for this frame; strands are pushed out of them each
    /// substep so a closed fist gathers the web over the glove instead of
    /// letting it clip through the fingers.
    public var collisionSpheres: [CoolWebCollisionSphere] = []

    /// Lets go of the root: the web stays on the wall and dangles.
    public func release(now: TimeInterval) {
        guard isHeld else { return }
        if phase == .attached {
            rootPinned = false
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

        guard centerHit != nil else {
            if tipTravel >= params.maxRange {
                transition(to: .dissolving, now: now)
            }
            return
        }

        // Past the branch point the tips fan out; each branch pins on arrival.
        var allDone = tipTravel >= leaderDistance
        if tipTravel >= leaderDistance {
            let bloomTravel = tipTravel - leaderDistance
            for branch in 0 ..< branchTargets.count where !branchAttached[branch] {
                let reach = simd_length(branchTargets[branch] - branchPoint)
                if bloomTravel >= reach {
                    branchAttached[branch] = true
                } else {
                    allDone = false
                }
            }
        }

        if allDone {
            spawnResidue()
            attachTime = now
            transition(to: .attached, now: now)
        }
    }

    // MARK: - Solver

    private func step(dt rawDt: Float) {
        let dt = min(max(rawDt, 0), 1.0 / 30.0)
        guard dt > 0 else { return }
        let substepDt = dt / Float(params.substeps)
        let dampingFactor = exp(-params.damping * substepDt)
        let gravityStep = params.gravity * (substepDt * substepDt)

        updateRestLengths()

        for _ in 0 ..< params.substeps {
            applyPins()
            for i in 0 ..< positions.count where !isPinned(i) {
                let velocity = (positions[i] - previous[i]) * dampingFactor
                previous[i] = positions[i]
                positions[i] += velocity + gravityStep
            }
            // Several forward+backward sweeps per substep: a taut chain
            // between two pins needs the extra iterations or the residual
            // stretch concentrates at the pinned ends.
            for _ in 0 ..< 4 {
                solveConstraints(forward: true)
                solveConstraints(forward: false)
            }
            resolveCollisions()
            applyPins()
        }
    }

    /// Leader particles this close to the root ignore the hand colliders:
    /// the strand is tied to the wrist shooter, so its first stretch is
    /// SUPPOSED to lie on the glove — pushing it away bends it into
    /// unnatural kinks right at the hand.
    private static let rootCollisionExemptParticles = 3

    private func isCollisionExempt(_ index: Int) -> Bool {
        index < Self.rootCollisionExemptParticles
    }

    private func resolveCollisions() {
        guard !collisionSpheres.isEmpty else { return }
        for sphere in collisionSpheres {
            let radiusSq = sphere.radius * sphere.radius

            // Particle pushout keeps endpoints out…
            for i in 0 ..< positions.count
            where !isPinned(i) && !isCollisionExempt(i) {
                let delta = positions[i] - sphere.center
                let distanceSq = simd_length_squared(delta)
                guard distanceSq < radiusSq, distanceSq > 1e-10 else { continue }
                let distance = sqrt(distanceSq)
                positions[i] = sphere.center + delta * (sphere.radius / distance)
            }

            // …but leader particles sit ~15 cm apart on a long shot, so a
            // fist-sized sphere passes clean between them: the SEGMENTS must
            // collide too, pushing both endpoints by the closest-point
            // penetration (weighted, pinned ends exempt).
            for constraint in constraints where constraint.active {
                let i = constraint.i
                let j = constraint.j
                if isCollisionExempt(i) || isCollisionExempt(j) { continue }
                let a = positions[i]
                let b = positions[j]
                let ab = b - a
                let abLengthSq = simd_length_squared(ab)
                guard abLengthSq > 1e-10 else { continue }
                let t = min(max(
                    simd_dot(sphere.center - a, ab) / abLengthSq, 0
                ), 1)
                let closest = a + ab * t
                let delta = closest - sphere.center
                let distanceSq = simd_length_squared(delta)
                guard distanceSq < radiusSq, distanceSq > 1e-10 else { continue }
                let distance = sqrt(distanceSq)
                let push = delta * ((sphere.radius - distance) / distance)

                let iPinned = isPinned(i)
                let jPinned = isPinned(j)
                switch (iPinned, jPinned) {
                case (true, true):
                    continue
                case (true, false):
                    positions[j] += push
                case (false, true):
                    positions[i] += push
                case (false, false):
                    positions[i] += push * (1 - t)
                    positions[j] += push * t
                }
            }
        }
    }

    private func updateRestLengths() {
        // Leader: taut behind the flying tip, slack once the net attaches.
        // Leader constraints occupy the first leaderParticles-1 slots; the
        // branch constraints after them keep their build-time layout and the
        // cross-links appended last keep their attach-time rest.
        let leaderSegments = Float(params.leaderParticles - 1)
        let flyingRest: Float
        if phase == .flying {
            let tip = leaderTipPosition()
            flyingRest = simd_length(tip - handPosition) / leaderSegments
        } else {
            flyingRest = leaderRest
        }
        for i in 0 ..< (params.leaderParticles - 1) {
            constraints[i].rest = flyingRest
        }

        var index = params.leaderParticles - 1
        for branch in 0 ..< branchTargets.count {
            // Connector + branch internals share the branch's rest spacing.
            for _ in 0 ..< params.branchParticles {
                constraints[index].rest = branchRest[branch]
                index += 1
            }
        }
    }

    private func leaderTipPosition() -> SIMD3<Float> {
        guard phase == .flying else { return positions[params.leaderParticles - 1] }
        if centerHit == nil {
            return origin + aim * min(tipTravel, params.maxRange)
        }
        return origin + aim * min(tipTravel, leaderDistance)
    }

    private func branchTipPosition(branch: Int) -> SIMD3<Float> {
        if branchAttached[branch] {
            return branchTargets[branch]
        }
        // Before the bloom the branch tips ride on the leader tip; afterwards
        // they fly from the branch point toward their own targets.
        let bloomTravel = tipTravel - leaderDistance
        guard phase == .flying, bloomTravel > 0 else { return leaderTipPosition() }
        let target = branchTargets[branch]
        let reach = simd_length(target - branchPoint)
        guard reach > 1e-4 else { return target }
        let t = min(bloomTravel / reach, 1)
        return branchPoint + (target - branchPoint) * t
    }

    private func isPinned(_ index: Int) -> Bool {
        if index == 0 { return rootPinned }
        if phase == .flying, index == params.leaderParticles - 1, centerHit != nil {
            return true
        }
        if index >= params.leaderParticles {
            let branchIndex = index - params.leaderParticles
            if (branchIndex + 1) % params.branchParticles == 0 {
                let branch = branchIndex / params.branchParticles
                return phase == .flying || branchAttached[branch]
            }
        }
        return false
    }

    private func applyPins() {
        if rootPinned {
            positions[0] = handPosition
            previous[0] = handPosition
        }
        if phase == .flying, centerHit != nil {
            let tip = leaderTipPosition()
            positions[params.leaderParticles - 1] = tip
            previous[params.leaderParticles - 1] = tip
        }
        for branch in 0 ..< branchTargets.count {
            let tipIndex = params.leaderParticles
                + branch * params.branchParticles + params.branchParticles - 1
            if phase == .flying || branchAttached[branch] {
                let tip = branchTipPosition(branch: branch)
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
        // relief propagates through the web before anything else tears.
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
            // tear on a genuine hard pull.
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

    /// A modest patch of static web threads sprayed on the surface around
    /// each attach point — sized to the net, not the room. Generated once at
    /// attach; drawn with the web's opacity but never simulated.
    private func spawnResidue() {
        var rng = CoolWebRandom(seed: UInt64(bitPattern: Int64(seed * 1e6)) | 1)
        for branch in 0 ..< branchTargets.count {
            guard let normal = branchTargetNormals[branch] else { continue }
            var tangent = simd_cross(
                normal,
                abs(normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            )
            tangent = simd_normalize(tangent)
            let bitangent = simd_cross(normal, tangent)
            let anchor = branchTargets[branch] + normal * 0.0015

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
            // While the shot misses everything, only the leader line shows —
            // the branch threads stay collapsed on the tip.
            if centerHit == nil, constraint.i >= params.leaderParticles - 1,
               constraint.j >= params.leaderParticles {
                continue
            }
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
