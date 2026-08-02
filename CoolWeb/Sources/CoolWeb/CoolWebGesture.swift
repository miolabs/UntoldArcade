import Foundation
import simd

/// Joint chain of one finger, base (palm side) first, tip last. The chain for
/// the four fingers is metacarpal → knuckle → intermediateBase →
/// intermediateTip → tip; the thumb chain starts at the wrist instead of a
/// metacarpal. Positions are world space.
public struct CoolWebFingerChain: Sendable, Equatable {
    public var points: [SIMD3<Float>]

    public init(points: [SIMD3<Float>]) {
        self.points = points
    }

    /// 1 = perfectly straight, → 0 as the finger curls onto itself:
    /// end-to-end distance over summed segment lengths.
    public var extensionRatio: Float {
        guard points.count >= 3 else { return 0 }
        var chainLength: Float = 0
        for i in 1 ..< points.count {
            chainLength += simd_length(points[i] - points[i - 1])
        }
        guard chainLength > 1e-6 else { return 0 }
        return simd_length(points[points.count - 1] - points[0]) / chainLength
    }
}

/// One tracked hand, reduced to exactly what the classifier and the aim ray
/// need — deliberately free of ARKit types so it can be built in unit tests.
public struct CoolWebHandPose: Sendable, Equatable {
    public var isTracked: Bool
    public var wrist: SIMD3<Float>
    public var thumb: CoolWebFingerChain
    public var index: CoolWebFingerChain
    public var middle: CoolWebFingerChain
    public var ring: CoolWebFingerChain
    public var little: CoolWebFingerChain

    public init(
        isTracked: Bool,
        wrist: SIMD3<Float>,
        thumb: CoolWebFingerChain,
        index: CoolWebFingerChain,
        middle: CoolWebFingerChain,
        ring: CoolWebFingerChain,
        little: CoolWebFingerChain
    ) {
        self.isTracked = isTracked
        self.wrist = wrist
        self.thumb = thumb
        self.index = index
        self.middle = middle
        self.ring = ring
        self.little = little
    }

    /// Ray the web fires along: from the wrist through the knuckle line —
    /// i.e. where the extended palm points.
    public var aimOrigin: SIMD3<Float> { wrist }
    public var aimDirection: SIMD3<Float> {
        guard index.points.count > 1, little.points.count > 1 else {
            return SIMD3<Float>(0, 0, -1)
        }
        let knuckleCenter = (index.points[1] + little.points[1]) * 0.5
        let direction = knuckleCenter - wrist
        let length = simd_length(direction)
        return length > 1e-6 ? direction / length : SIMD3<Float>(0, 0, -1)
    }

    /// Extension ratios ordered thumb, index, middle, ring, little (debug UI).
    public var extensions: [Float] {
        [thumb, index, middle, ring, little].map { $0.extensionRatio }
    }
}

public enum CoolWebGestureEvent: Sendable, Equatable {
    /// The web-shooter pose (thumb + index + little extended, middle + ring
    /// curled) was just struck: fire a web along the aim ray.
    case webShooterFired(origin: SIMD3<Float>, direction: SIMD3<Float>)
    /// The palm was held fully open: let go of the held web. A closed fist
    /// deliberately does nothing — the web stays tied to the fist.
    case palmOpened
}

/// Thresholds and debounce for the pose classifier. Enter thresholds are
/// stricter than exit thresholds (hysteresis) so a pose near the boundary
/// doesn't flicker.
public struct CoolWebGestureConfig: Sendable, Equatable {
    public var extendedEnter: Float = 0.78
    public var extendedExit: Float = 0.68
    public var curledEnter: Float = 0.60
    public var curledExit: Float = 0.70
    public var thumbExtendedEnter: Float = 0.70
    public var thumbExtendedExit: Float = 0.62
    /// Whether the thumb must read extended for the pose (loosest joint —
    /// disable if it proves noisy on device).
    public var requireThumb = true
    /// Consecutive frames the pose must hold before firing.
    public var onsetFrames = 3
    /// Consecutive frames out of pose before the classifier re-arms.
    public var releaseFrames = 6
    /// All four fingers above this extension = open palm.
    public var palmOpenEnter: Float = 0.72
    /// Consecutive open-palm frames before the web lets go (~0.2 s at 90 Hz)
    /// so a passing hand pose can't drop the web by accident.
    public var palmOpenFrames = 20

    public init() {}
}

/// Per-hand state machine over `CoolWebHandPose` frames. Feed it every hand
/// update; it emits at most one event per frame, on transitions only.
public final class CoolWebGestureClassifier {
    public var config: CoolWebGestureConfig

    private enum PoseState {
        case idle
        case inPose
    }

    private var poseState = PoseState.idle
    private var poseFrames = 0
    private var outOfPoseFrames = 0
    private var openPalmFrames = 0
    private var openPalmLatched = false
    public private(set) var lastExtensions: [Float] = [0, 0, 0, 0, 0]

    public init(config: CoolWebGestureConfig = CoolWebGestureConfig()) {
        self.config = config
    }

    public func reset() {
        poseState = .idle
        poseFrames = 0
        outOfPoseFrames = 0
        openPalmFrames = 0
        openPalmLatched = false
    }

    public func update(pose: CoolWebHandPose) -> CoolWebGestureEvent? {
        guard pose.isTracked else {
            reset()
            return nil
        }
        let ext = pose.extensions
        lastExtensions = ext
        let (thumb, index, middle, ring, little) = (ext[0], ext[1], ext[2], ext[3], ext[4])

        // Open palm first: all four fingers held straight lets the web go.
        // A closed fist is deliberately NOT a release — the web stays tied
        // to the fist; only a sustained open hand detaches it.
        let isOpenPalm = index > config.palmOpenEnter
            && middle > config.palmOpenEnter
            && ring > config.palmOpenEnter
            && little > config.palmOpenEnter
        if isOpenPalm {
            openPalmFrames += 1
            poseState = .idle
            poseFrames = 0
            if openPalmFrames >= config.palmOpenFrames, !openPalmLatched {
                openPalmLatched = true
                return .palmOpened
            }
            return nil
        }
        openPalmFrames = 0
        openPalmLatched = false

        switch poseState {
        case .idle:
            let thumbOK = !config.requireThumb || thumb > config.thumbExtendedEnter
            let inPose = thumbOK
                && index > config.extendedEnter
                && little > config.extendedEnter
                && middle < config.curledEnter
                && ring < config.curledEnter
            if inPose {
                poseFrames += 1
                if poseFrames >= config.onsetFrames {
                    poseState = .inPose
                    outOfPoseFrames = 0
                    return .webShooterFired(
                        origin: pose.aimOrigin,
                        direction: pose.aimDirection
                    )
                }
            } else {
                poseFrames = 0
            }
            return nil

        case .inPose:
            let thumbOK = !config.requireThumb || thumb > config.thumbExtendedExit
            let stillInPose = thumbOK
                && index > config.extendedExit
                && little > config.extendedExit
                && middle < config.curledExit
                && ring < config.curledExit
            if stillInPose {
                outOfPoseFrames = 0
            } else {
                outOfPoseFrames += 1
                if outOfPoseFrames >= config.releaseFrames {
                    poseState = .idle
                    poseFrames = 0
                }
            }
            return nil
        }
    }
}
