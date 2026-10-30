//
//  ZombieRagdollRig.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
import UntoldEngine
import UntoldJoltPhysics

/// The zombie's ragdoll: twenty rigid parts on the mannequin rig's bones
/// from the pelvis up and out — every link of the spine, the neck, the
/// clavicles — each a capsule fitted to the body around its bone with the
/// body origin at the joint, jointed to the part on its parent joint by a
/// swing-twist constraint (so no bind-pose offset is frozen into a joint).
/// Built from the skeleton's bind pose, so the parts' origins sit exactly
/// on the joints and a pose read back from the parts maps straight onto
/// them; the capsules are the fitted ones (`specs`), in the zombie export's
/// model space, carried into each part's frame at build — up to 8 cm off
/// the joint where the spine runs along the back of the trunk — so the rig
/// takes any skeleton with these joints but places the capsules where this
/// body is (ZombieRagdollRigTests holds every joint to within a tenth of a
/// metre of its capsule on the export). Bones without a part (the toes, the
/// fingers, the twist helpers) keep their animated offsets under whichever
/// part moves them.
public struct ZombieRagdollRig: Sendable {
    /// How a part's capsule is aimed: at another joint, or continuing the
    /// direction from a previous joint (for the last bone of a chain).
    enum Axis: Sendable {
        case toward(String)
        case continuing(from: String)
    }

    /// Where a joint's swing cone is centred: on the bind pose, or part way
    /// into the bend the joint makes, toward or away from the body's front.
    /// A knee bends only backward, an elbow and a hip mostly forward: one
    /// symmetric cone centred mid-bend covers straight to fully bent and
    /// nothing beyond straight.
    enum Flexion: Sendable {
        case none
        case forward(Float)
        case backward(Float)
    }

    /// A part's capsule in the bind pose, model space: its two tips and its
    /// radius, fitted to the exported body (see `specs`). The capsule is
    /// carried into the part's frame at build time, so it sits on the body
    /// whatever the joint's own axes are.
    public struct Capsule: Sendable {
        public let from: simd_float3
        public let to: simd_float3
        public let radius: Float
    }

    struct PartSpec: Sendable {
        let name: String
        let joint: String
        let parent: String?
        /// Where the joint's twist axis points: along the bone.
        let axis: Axis
        let capsule: Capsule
        let mass: Float
        /// Swing half-cone of the bend (a rotation about the plane axis,
        /// tilting the bone toward the normal) and twist half-range from
        /// the parent, radians.
        let cone: Float
        let twist: Float
        /// Swing half-cone across the bend (tilting the bone toward the
        /// plane axis); nil = the same as `cone`. A hinge gets a sliver.
        var abduction: Float? = nil
        var flexion: Flexion = .none
    }

    private static func capsule(_ fx: Float, _ fy: Float, _ fz: Float, _ tx: Float, _ ty: Float, _ tz: Float, _ radius: Float) -> Capsule {
        Capsule(from: simd_float3(fx, fy, fz), to: simd_float3(tx, ty, tz), radius: radius)
    }

    private static func deg(_ degrees: Float) -> Float { degrees * .pi / 180 }

    private enum Path {
        static let pelvis = "/root/pelvis"
        static let spine1 = pelvis + "/spine_01"
        static let spine2 = spine1 + "/spine_02"
        static let spine3 = spine2 + "/spine_03"
        static let neck = spine3 + "/neck_01"
        static let head = neck + "/head"
        static func clavicle(_ s: String) -> String { spine3 + "/clavicle_\(s)" }
        static func upperArm(_ s: String) -> String { clavicle(s) + "/upperarm_\(s)" }
        static func lowerArm(_ s: String) -> String { upperArm(s) + "/lowerarm_\(s)" }
        static func hand(_ s: String) -> String { lowerArm(s) + "/hand_\(s)" }
        static func thigh(_ s: String) -> String { pelvis + "/thigh_\(s)" }
        static func calf(_ s: String) -> String { thigh(s) + "/calf_\(s)" }
        static func foot(_ s: String) -> String { calf(s) + "/foot_\(s)" }
        static func ball(_ s: String) -> String { foot(s) + "/ball_\(s)" }
    }

    /// Parents before children, the order Jolt wants. Ranges are a limp
    /// body's: what the joint allows, not what a walk uses.
    ///
    /// The capsules are fitted to the body: the numbers are what
    /// `Tools/blender/prep_zombie.py` (`fit_capsules`) logs for
    /// `Zombie_new_cloth.blend`, 2026-10-30, in the bind pose, engine space.
    /// Per part it takes the skin the part's bones move (the body without
    /// its hair, plus the shoes), profiles it around the capsule's own line
    /// in 1 cm bins along the line and 15° sectors around it — the skin's
    /// reach in a bin is its farthest vertex, so the teeth and the eyes
    /// inside the head never count — and keeps the largest radius whose
    /// surface stays within that reach everywhere (to 3 mm) and a cloth
    /// particle's collision radius, 1 cm, inside the shirt and the trousers
    /// proxies: Jolt holds a particle that far off a capsule, so a capsule
    /// any closer pushes the resting garment off its skin, and the parts hang
    /// a finger's width off their joints at rest (the forearm 1 cm, the hand
    /// 3 cm, from the tracking motors' stiffness: ZombieClothTests pins
    /// them). The line runs along the
    /// bone through the skin's centre, for the limbs from the centroid of
    /// their first third to their last third's (the shin leaves the ankle
    /// at the Achilles tendon, the femur lies lateral in the thigh); it
    /// spans the bone, the chain's free ends reaching the skin's extent
    /// (the crown, the palm from a finger's width below the wrist, the heel
    /// to the ball) and the pelvis the hips. The mannequin's radii before this
    /// reached 7 cm through the back of this shirt; a high percentile of
    /// the radial distances, the first idea, pokes through the front and the
    /// back of every spine link, because the torso is an ellipse and a
    /// capsule is round — so the torso links are as thick as their thinnest
    /// direction allows, and the sides of the chest are the skin's own. The
    /// arms are as thick as the tight sleeve leaves room for a particle's
    /// radius under it, 1.0-1.4 cm, and the clavicles keep the fit's floor of
    /// 5 mm under the yoke: thin for a ball to find, but the balls are thrown
    /// at the chest, and a sleeve pushed off its skin every frame showed more.
    /// The hips, the belly link, the thighs and the shins are bounded the same
    /// way by the trousers proxy (not simulated yet, but in the sidecar and
    /// one switch away): the thighs 3.4-4 cm, the shins 1.5. The right-side
    /// radii differ from the left's where the artist's body does; the
    /// garment surfaces are sampled 28 points a triangle, so the margin is
    /// the surface's and not the vertices'. `ZombieRagdollRigTests` holds
    /// every capsule to the export.
    static let specs: [PartSpec] = {
        var parts: [PartSpec] = [
            // The pelvis part is the hips, from above the crotch to the waist
            // (the first spine joint sits level with the hips on this rig, so
            // the belly is spine_01's); its twist axis still points up the
            // spine for the pose read-back.
            PartSpec(name: "pelvis", joint: Path.pelvis, parent: nil, axis: .toward(Path.spine2), capsule: capsule(0.000, 0.886, -0.059, 0.000, 1.037, -0.110, 0.104), mass: 12, cone: 0, twist: 0),
            PartSpec(name: "spine_01", joint: Path.spine1, parent: "pelvis", axis: .toward(Path.spine2), capsule: capsule(-0.000, 1.000, -0.060, -0.000, 1.149, -0.060, 0.089), mass: 7, cone: deg(25), twist: deg(20), abduction: deg(15), flexion: .forward(deg(10))),
            PartSpec(name: "spine_02", joint: Path.spine2, parent: "spine_01", axis: .toward(Path.spine3), capsule: capsule(0.000, 1.161, -0.099, 0.000, 1.326, -0.143, 0.081), mass: 7, cone: deg(25), twist: deg(20), abduction: deg(15), flexion: .forward(deg(10))),
            PartSpec(name: "spine_03", joint: Path.spine3, parent: "spine_02", axis: .toward(Path.neck), capsule: capsule(-0.001, 1.293, -0.110, -0.001, 1.427, -0.075, 0.068), mass: 9, cone: deg(25), twist: deg(20), abduction: deg(15), flexion: .forward(deg(10))),
            PartSpec(name: "neck_01", joint: Path.neck, parent: "spine_03", axis: .toward(Path.head), capsule: capsule(0.001, 1.442, -0.144, 0.001, 1.577, -0.080, 0.041), mass: 1, cone: deg(35), twist: deg(30), abduction: deg(25)),
            PartSpec(name: "head", joint: Path.head, parent: "neck_01", axis: .continuing(from: Path.neck), capsule: capsule(0.001, 1.582, -0.091, 0.001, 1.731, -0.021, 0.070), mass: 4, cone: deg(30), twist: deg(35), abduction: deg(20)),
        ]
        // The right side mirrors the left in x; the fit gives each its own
        // numbers, a millimetre or two apart where the artist's body is.
        let clavicle = ["l": capsule(0.060, 1.378, -0.021, 0.192, 1.391, -0.119, 0.005), "r": capsule(-0.058, 1.379, -0.023, -0.190, 1.392, -0.122, 0.005)]
        let upperArm = ["l": capsule(0.188, 1.414, -0.156, 0.292, 1.166, -0.129, 0.014), "r": capsule(-0.190, 1.416, -0.155, -0.292, 1.166, -0.131, 0.010)]
        let lowerArm = ["l": capsule(0.321, 1.174, -0.151, 0.475, 0.990, -0.051, 0.013), "r": capsule(-0.324, 1.174, -0.155, -0.474, 0.990, -0.050, 0.013)]
        let hand = ["l": capsule(0.479, 0.970, -0.043, 0.507, 0.936, -0.025, 0.014), "r": capsule(-0.479, 0.970, -0.043, -0.507, 0.936, -0.025, 0.014)]
        let thigh = ["l": capsule(0.105, 0.915, -0.091, 0.092, 0.498, -0.107, 0.034), "r": capsule(-0.099, 0.914, -0.094, -0.100, 0.496, -0.102, 0.040)]
        let calf = ["l": capsule(0.112, 0.500, -0.129, 0.133, 0.089, -0.158, 0.015), "r": capsule(-0.112, 0.500, -0.130, -0.132, 0.089, -0.157, 0.015)]
        let foot = ["l": capsule(0.122, 0.047, -0.175, 0.164, 0.034, -0.038, 0.020), "r": capsule(-0.122, 0.048, -0.175, -0.164, 0.034, -0.038, 0.020)]
        for side in ["l", "r"] {
            parts += [
                // The clavicle is a short link: it carries the shoulder's
                // true offset so an arm hangs from where the animation put
                // it, not from the bind pose. Its capsule is the collar bone
                // under the shirt's yoke, which hugs it: the fit's floor.
                // The clavicle is a proxy joint the retarget turns freely: on
                // a rig whose clavicles rest pulled back (the studio's zombie,
                // 37°) the clips ask it for 40° of twist, and a tight twist
                // limit there leaves the whole arm a fist off the animation.
                PartSpec(name: "clavicle_\(side)", joint: Path.clavicle(side), parent: "spine_03", axis: .toward(Path.upperArm(side)), capsule: clavicle[side]!, mass: 1, cone: deg(35), twist: deg(50), abduction: deg(20)),
                // The arms are as thick as the tight sleeve allows a
                // particle's radius under it; fitted to the skin alone they
                // would be 2-2.5 cm, the elbow's and the wrist's.
                PartSpec(name: "upperarm_\(side)", joint: Path.upperArm(side), parent: "clavicle_\(side)", axis: .toward(Path.lowerArm(side)), capsule: upperArm[side]!, mass: 2.2, cone: deg(95), twist: deg(70), abduction: deg(80), flexion: .forward(deg(25))),
                PartSpec(name: "lowerarm_\(side)", joint: Path.lowerArm(side), parent: "upperarm_\(side)", axis: .toward(Path.hand(side)), capsule: lowerArm[side]!, mass: 1.5, cone: deg(75), twist: deg(80), abduction: deg(15), flexion: .forward(deg(70))),
                // The hand is the palm, from a finger's width below the wrist:
                // the zombie's fingers are a claw, and a capsule through them
                // would have to be a wire; and the hand part sits 3 cm off its
                // joint at rest (its limits), so a capsule up to the wrist
                // reached into the shirt's cuff and pushed it off its skin.
                PartSpec(name: "hand_\(side)", joint: Path.hand(side), parent: "lowerarm_\(side)", axis: .continuing(from: Path.lowerArm(side)), capsule: hand[side]!, mass: 0.5, cone: deg(60), twist: deg(30), abduction: deg(40)),
            ]
        }
        for side in ["l", "r"] {
            parts += [
                // The thigh and the shin are as thick as the trousers leave
                // room for a particle's radius under them (the knee and the
                // ankle would let them be 4.7-5 and 2.3 cm).
                PartSpec(name: "thigh_\(side)", joint: Path.thigh(side), parent: "pelvis", axis: .toward(Path.calf(side)), capsule: thigh[side]!, mass: 8, cone: deg(75), twist: deg(25), abduction: deg(30), flexion: .forward(deg(50))),
                PartSpec(name: "calf_\(side)", joint: Path.calf(side), parent: "thigh_\(side)", axis: .toward(Path.foot(side)), capsule: calf[side]!, mass: 4, cone: deg(75), twist: deg(12), abduction: deg(12), flexion: .backward(deg(72))),
                // The foot's capsule lies along the sole from the heel to just
                // past the ball; the twist axis still points at the toes.
                PartSpec(name: "foot_\(side)", joint: Path.foot(side), parent: "calf_\(side)", axis: .toward(Path.ball(side)), capsule: foot[side]!, mass: 1, cone: deg(30), twist: deg(15), abduction: deg(15)),
            ]
        }
        return parts
    }()

    /// The parts, in order, as the plugin wants them.
    public let descriptor: JoltRagdollDescriptor
    /// Skeleton joint index of each part.
    public let jointIndices: [Int]
    /// Part index by skeleton joint index, for the joints that have one.
    public let partByJoint: [Int: Int]
    public let parentIndices: [Int?]
    public let partNames: [String]
    public let jointCount: Int
    /// Each part's bone direction in its own frame, and its length.
    public let localDirections: [simd_float3]
    public let lengths: [Float]
    /// Each part's capsule in its own frame: the two ends of the cylinder
    /// and the radius (what `nearestPart` measures against).
    public let localCapsules: [Capsule]
    /// The body's front in model space, read off the feet (toes ahead of
    /// ankles); +Z when the feet cannot say.
    public let forward: simd_float3

    /// Nil when the skeleton is missing a joint the rig needs.
    public init?(joints: SkeletonJointInfo, entity: EntityID, layer: UInt32) {
        var indexByPath: [String: Int] = [:]
        for (index, path) in joints.jointPaths.enumerated() { indexByPath[path] = index }
        func position(_ path: String) -> simd_float3? {
            guard let index = indexByPath[path] else { return nil }
            let c = joints.bindModelTransforms[index].columns.3
            return simd_float3(c.x, c.y, c.z)
        }
        func rotation(_ index: Int) -> simd_quatf {
            let m = joints.bindModelTransforms[index]
            let x = simd_normalize(simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
            let y = simd_normalize(simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
            let z = simd_normalize(simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            return simd_normalize(simd_quatf(simd_float3x3(columns: (x, y, z))))
        }

        var parts: [JoltRagdollPart] = []
        var jointIndices: [Int] = []
        var partByJoint: [Int: Int] = [:]
        var parentIndices: [Int?] = []
        var localDirections: [simd_float3] = []
        var lengths: [Float] = []
        var localCapsules: [Capsule] = []
        var indexByName: [String: Int] = [:]

        var front = simd_float3.zero
        for side in ["l", "r"] {
            if let foot = position(Path.foot(side)), let ball = position(Path.ball(side)) {
                front += simd_float3(ball.x - foot.x, 0, ball.z - foot.z)
            }
        }
        let forward = simd_length(front) > 1e-4 ? simd_normalize(front) : simd_float3(0, 0, 1)

        for spec in Self.specs {
            guard let jointIndex = indexByPath[spec.joint], let origin = position(spec.joint) else { return nil }
            let direction: simd_float3
            let length: Float
            switch spec.axis {
            case let .toward(path):
                guard let target = position(path) else { return nil }
                let delta = target - origin
                length = simd_length(delta)
                guard length > 1e-4 else { return nil }
                direction = delta / length
            case let .continuing(from: path):
                guard let previous = position(path) else { return nil }
                let delta = origin - previous
                length = simd_length(delta)
                guard length > 1e-4 else { return nil }
                direction = delta / length
            }

            let frame = rotation(jointIndex)
            let localDirection = simd_normalize(frame.inverse.act(direction))
            // The capsule is the fitted one, carried into the part's frame:
            // its axis is its local Y, turned onto the fitted line, its
            // centre halfway between the tips, the caps inside them.
            let capsule = spec.capsule
            let span = capsule.to - capsule.from
            let spanLength = simd_length(span)
            let capsuleDirection = simd_normalize(frame.inverse.act(span / spanLength))
            let shapeRotation = simd_normalize(simd_quatf(from: simd_float3(0, 1, 0), to: capsuleDirection))
            let cylinder = max(spanLength - 2 * capsule.radius, 0.005)
            let capsuleCentre = frame.inverse.act((capsule.from + capsule.to) / 2 - origin)
            // The hinge: across the body. A bend turns about an axis square
            // to the bone and to the body's front — sideways for the spine,
            // the neck, the legs and the feet, the arm plane's up for the
            // arms, which hang in the coronal plane. The bind frames' own
            // axes are not consulted: rigs disagree about which of them is
            // the bend axis (the UE mannequin keeps Z across the body, a
            // Blender rig X), and a wrong pick folds a joint the wrong way.
            var hinge = simd_cross(direction, forward)
            if simd_length(hinge) < 0.3 {
                // A bone along the front (a foot): sideways, squared up.
                let side = simd_cross(simd_float3(0, 1, 0), forward)
                hinge = side - direction * simd_dot(side, direction)
                if simd_length(hinge) < 0.3 {
                    let helper = abs(direction.y) > 0.9 ? simd_float3(1, 0, 0) : simd_float3(0, 1, 0)
                    hinge = helper - direction * simd_dot(helper, direction)
                }
            }
            let plane = simd_normalize(hinge)

            let parentIndex = spec.parent.flatMap { indexByName[$0] }
            var part = JoltRagdollPart(
                name: spec.name,
                parentIndex: parentIndex,
                shape: .capsule(radius: capsule.radius, height: cylinder),
                mass: spec.mass,
                position: origin,
                rotation: frame,
                twistAxis: direction,
                planeAxis: plane
            )
            part.shapeOffset = capsuleCentre
            part.shapeRotation = shapeRotation
            part.twistRange = (-spec.twist) ... spec.twist
            // The bend is a rotation about the plane axis, which tilts the
            // bone toward the normal axis: Jolt's normal half cone. Across
            // it (toward the plane axis) the other.
            part.normalHalfConeAngle = spec.cone
            part.planeHalfConeAngle = spec.abduction ?? spec.cone
            // Centring the cone: the parent holds the joint's axes turned
            // part way into the bend, so the bind pose sits at one edge of
            // the cone and full flexion at the other. A swing of +θ about
            // the plane axis carries the bone toward plane × bone.
            switch spec.flexion {
            case .none:
                break
            case let .forward(angle), let .backward(angle):
                let toward: simd_float3
                if case .backward = spec.flexion { toward = -forward } else { toward = forward }
                let swing = simd_cross(plane, direction)
                let sign: Float = simd_dot(swing, toward) >= 0 ? 1 : -1
                let centre = simd_quatf(angle: sign * angle, axis: plane)
                part.parentTwistAxis = simd_normalize(centre.act(direction))
                part.parentPlaneAxis = plane
            }
            part.motorFrequency = 20
            part.motorDamping = 2
            part.maxTorque = spec.mass >= 8 ? 800 : 300

            if ProcessInfo.processInfo.arguments.contains("-debugRig") {
                let m = joints.bindModelTransforms[jointIndex]
                func c(_ v: simd_float4) -> String { String(format: "(%.2f,%.2f,%.2f)", v.x, v.y, v.z) }
                func v(_ v: simd_float3) -> String { String(format: "(%.2f,%.2f,%.2f)", v.x, v.y, v.z) }
                print("CoolZombie: rig \(spec.name) bone=\(v(direction)) X=\(c(m.columns.0)) Y=\(c(m.columns.1)) Z=\(c(m.columns.2)) plane=\(v(plane)) normal=\(v(simd_cross(direction, plane)))")
            }
            indexByName[spec.name] = parts.count
            parts.append(part)
            jointIndices.append(jointIndex)
            partByJoint[jointIndex] = parts.count - 1
            parentIndices.append(parentIndex)
            localDirections.append(localDirection)
            lengths.append(length)
            localCapsules.append(Capsule(from: capsuleCentre - capsuleDirection * (cylinder / 2), to: capsuleCentre + capsuleDirection * (cylinder / 2), radius: capsule.radius))
        }

        var descriptor = JoltRagdollDescriptor(parts: parts)
        descriptor.entity = entity
        descriptor.layer = layer
        descriptor.gravityFactor = 1
        descriptor.maxLinearVelocity = 20
        // A limp body: joints swing freely, but flesh damps the swing.
        descriptor.linearDamping = 0.1
        descriptor.angularDamping = 1.0
        // A folded body must fold: the torso capsules would otherwise rest
        // on the thighs, and the pelvis on the calves, and prop it up
        // kneeling with the hips in the air.
        var pairs: [(Int, Int)] = []
        func disable(_ groupA: [String], _ groupB: [String]) {
            for nameA in groupA {
                for nameB in groupB {
                    guard let a = indexByName[nameA], let b = indexByName[nameB], a != b,
                          parts[b].parentIndex != a, parts[a].parentIndex != b else { continue }
                    if !pairs.contains(where: { ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a) }) { pairs.append((a, b)) }
                }
            }
        }
        disable(["pelvis", "spine_01", "spine_02", "spine_03"], ["thigh_l", "thigh_r", "calf_l", "calf_r"])
        // The torso chain never collides with itself: its capsules overlap
        // by design (a rig whose first spine joint sits level with the hips
        // puts the pelvis inside the second spine capsule), and a contact
        // against the kinematic pelvis would shove the chain off the
        // animation every step.
        let chain = ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head"]
        disable(chain, chain)
        // The arms swing close to the chest and the head in the chase's
        // raised postures; their own torso must not push them off the
        // animation. Arms still meet legs, and each other.
        let torso = ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head", "clavicle_l", "clavicle_r"]
        disable(torso, ["upperarm_l", "lowerarm_l", "hand_l", "upperarm_r", "lowerarm_r", "hand_r"])
        descriptor.disabledCollisionPairs = pairs
        // A powered chain of twenty links converges better with a few more
        // solver iterations than the world's default.
        descriptor.solverVelocitySteps = 20
        descriptor.solverPositionSteps = 4
        descriptor.startActive = false
        self.descriptor = descriptor
        self.forward = forward
        self.jointIndices = jointIndices
        self.partByJoint = partByJoint
        self.parentIndices = parentIndices
        partNames = Self.specs.map(\.name)
        jointCount = joints.jointPaths.count
        self.localDirections = localDirections
        self.lengths = lengths
        self.localCapsules = localCapsules
    }

    public var partCount: Int { jointIndices.count }

    public func partIndex(named name: String) -> Int? {
        partNames.firstIndex(of: name)
    }

    /// What a hit on `part` sets in motion: the part and everything hanging
    /// from it — except for the root, which has no joint to hold it and
    /// would take the whole body down, so a hit there moves the torso
    /// above it instead. `anchor` is the part the impulse lands on.
    public func reactionSubtree(for part: Int) -> (anchor: Int, parts: [Int]) {
        guard parentIndices.indices.contains(part), parentIndices[part] == nil else { return (part, subtree(of: part)) }
        let child = parentIndices.firstIndex { $0 == part } ?? part
        return (child, subtree(of: child))
    }

    /// What a hard hit on `part` sets staggering: everything under the top
    /// of its chain — the part just below the root on the way up, so a hit
    /// on the head or an arm takes the whole upper body, a hit on a leg
    /// that leg — while the root and the rest keep the animation. `anchor`
    /// is the part the impulse lands on (the torso for a hit on the root).
    public func staggerSubtree(for part: Int) -> (anchor: Int, parts: [Int]) {
        guard parentIndices.indices.contains(part) else { return (part, []) }
        guard parentIndices[part] != nil else { return reactionSubtree(for: part) }
        var top = part
        while let parent = parentIndices[top], parentIndices[parent] != nil { top = parent }
        return (part, subtree(of: top))
    }

    /// The part and everything hanging from it, in part order.
    public func subtree(of part: Int) -> [Int] {
        var members = [part]
        var included = Set([part])
        for index in (part + 1) ..< partCount {
            if let parent = parentIndices[index], included.contains(parent) {
                members.append(index)
                included.insert(index)
            }
        }
        return members
    }

    /// World transforms of the parts for a skeleton pose (model space) and
    /// the entity's world transform: the joint's transform is the body's.
    public func partWorldTransforms(jointModelTransforms: [simd_float4x4], entityWorld: simd_float4x4) -> [simd_float4x4] {
        jointIndices.map { entityWorld * jointModelTransforms[$0] }
    }

    /// The physics pose the animation takes from the parts' world
    /// transforms: model-space transforms for the joints that have a part,
    /// each with its part's weight; every other joint stays animated.
    public func physicsPose(partWorldTransforms: [simd_float4x4], entityWorld: simd_float4x4, partWeights: [Float]) -> (transforms: [simd_float4x4], weights: [Float]) {
        let toModel = entityWorld.inverse
        var transforms = Array(repeating: matrix_identity_float4x4, count: jointCount)
        var weights = Array(repeating: Float(0), count: jointCount)
        for (part, joint) in jointIndices.enumerated() where part < partWorldTransforms.count {
            transforms[joint] = toModel * partWorldTransforms[part]
            weights[joint] = part < partWeights.count ? partWeights[part] : 0
        }
        return (transforms, weights)
    }

    /// The part whose capsule's surface passes nearest a world point.
    public func nearestPart(to point: simd_float3, partWorldTransforms: [simd_float4x4]) -> Int {
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (part, transform) in partWorldTransforms.enumerated() where part < partCount {
            let c = transform.columns.3
            let origin = simd_float3(c.x, c.y, c.z)
            let rotation = simd_quatf(simd_float3x3(
                columns: (
                    simd_normalize(simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)),
                    simd_normalize(simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)),
                    simd_normalize(simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
                )
            ))
            let capsule = localCapsules[part]
            let start = origin + rotation.act(capsule.from)
            let axis = rotation.act(capsule.to - capsule.from)
            let t = min(max(simd_dot(point - start, axis) / max(simd_length_squared(axis), 1e-6), 0), 1)
            let distance = simd_distance(point, start + axis * t) - capsule.radius
            if distance < bestDistance {
                bestDistance = distance
                best = part
            }
        }
        return best
    }
}
