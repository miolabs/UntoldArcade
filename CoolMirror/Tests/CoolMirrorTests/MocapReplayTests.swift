//
//  MocapReplayTests.swift
//  CoolMirrorTests
//
//  Real sessions recorded on the headset (Recordings/*.cmr: every frame
//  the iPhone sent, with a marker per guided step), replayed through the
//  smoothing filter the mirror uses. What the wearer saw jump must stay
//  steady here.
//

@testable import CoolMirror
@testable import CoolMirrorMocap
import simd
import XCTest

final class MocapReplayTests: XCTestCase {
    private static func recording(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Recordings/\(name).cmr")
    }

    /// The mirror's smoothing options for the panel's default sliders.
    private static var options: MocapSmoothingOptions {
        var options = MocapSmoothingOptions()
        options.bodyCutoff = 8 * powf(0.03, 0.4)
        options.legCutoff = 8 * powf(0.03, 0.6)
        options.rootCutoff = options.legCutoff * 0.6
        return options
    }

    private struct Replay {
        var raw: [MocapFrame]
        var filtered: [MocapFrame]
        var markers: [MocapRecording.Marker]

        func stretch(_ label: String) -> Range<Int> {
            let sorted = markers.sorted { $0.time < $1.time }
            guard let index = sorted.firstIndex(where: { $0.label.hasPrefix(label) }) else { return 0 ..< 0 }
            let start = sorted[index].time
            let end = index + 1 < sorted.count ? sorted[index + 1].time : .infinity
            let first = raw.firstIndex { $0.timestamp >= start } ?? raw.count
            let last = raw.firstIndex { $0.timestamp >= end } ?? raw.count
            return first ..< last
        }
    }

    private func replay(_ name: String) throws -> Replay? {
        let url = Self.recording(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let all = try MocapRecording.readAll(url: url)
        var filter = MocapPoseFilter()
        let options = Self.options
        let filtered = all.frames.map { filter.filter($0, at: $0.timestamp, options: options) }
        return Replay(raw: all.frames, filtered: filtered, markers: all.markers)
    }

    /// Hip heading in world space, degrees.
    private static func heading(_ frame: MocapFrame) -> Float? {
        MocapPoseFilter.bodyYaw(of: frame).map { $0 * 180 / .pi }
    }

    /// Headings unwrapped so a range across ±180° reads right.
    private static func headings(_ frames: ArraySlice<MocapFrame>) -> [Float] {
        var out: [Float] = []
        for frame in frames {
            guard let h = heading(frame) else { continue }
            if let last = out.last {
                var d = h - last
                while d > 180 {
                    d -= 360
                }
                while d < -180 {
                    d += 360
                }
                out.append(last + d)
            } else {
                out.append(h)
            }
        }
        return out
    }

    private static func range(_ values: [Float]) -> Float {
        (values.max() ?? 0) - (values.min() ?? 0)
    }

    private static func largestStep(_ values: [Float]) -> Float {
        zip(values.dropFirst(), values).map { abs($0 - $1) }.max() ?? 0
    }

    /// Session of 2026-09-27: standing still the tracker's hip heading
    /// wandered 23° and its root 3 mm a frame; raising the arms turned the
    /// whole skeleton 37° in one frame for three seconds, and back; a real
    /// turn of about 100° to the left and back was made on the spot.
    func testSessionStaysSteadyWhereTheWearerDidAndFollowsTheRealTurn() throws {
        guard let session = try replay("session-20260927-190849") else { throw XCTSkip("recording not present") }
        XCTAssertEqual(session.raw.count, 2689)

        // Standing still: the heading stays within a few degrees and never steps.
        let still = session.stretch("Stand still, arms down")
        let stillRaw = Self.headings(session.raw[still]), stillFiltered = Self.headings(session.filtered[still])
        XCTAssertGreaterThan(Self.range(stillRaw), 20, "the tracker did wander")
        XCTAssertLessThan(Self.range(stillFiltered), 12, "the character does not")
        XCTAssertLessThan(Self.largestStep(stillFiltered), 1.0, "no visible step while standing still")

        // Raising the arms: the 37° flip is held, nothing steps by more than a few degrees.
        let arms = session.stretch("Raise both arms")
        let armsRaw = Self.headings(session.raw[arms]), armsFiltered = Self.headings(session.filtered[arms])
        XCTAssertGreaterThan(Self.largestStep(armsRaw), 30, "the tracker did flip")
        XCTAssertLessThan(Self.largestStep(armsFiltered), 5, "the character never flips")
        // During the three seconds the tracker sat 37° off, the character kept its heading.
        let t0 = session.raw[0].timestamp
        let during = session.raw.indices.filter { session.raw[$0].timestamp - t0 > 22.6 && session.raw[$0].timestamp - t0 < 25.3 }
        let before = session.raw.indices.filter { session.raw[$0].timestamp - t0 > 21.5 && session.raw[$0].timestamp - t0 < 22.4 }
        let heldHeadings = during.compactMap { Self.heading(session.filtered[$0]) }
        let beforeMean = before.compactMap { Self.heading(session.filtered[$0]) }.reduce(0, +) / Float(max(before.count, 1))
        for h in heldHeadings {
            XCTAssertLessThan(abs(h - beforeMean), 4, "held through the flip")
        }

        // The real turn is followed almost in full.
        let turn = session.stretch("Turn to your left")
        let turnRaw = Self.headings(session.raw[turn]), turnFiltered = Self.headings(session.filtered[turn])
        XCTAssertGreaterThan(Self.range(turnRaw), 90)
        // (The last twenty degrees of this turn came slowly, at 10°/s, and
        // are followed only after two seconds: the price of not following
        // the tracker's wander with the arms up, which drifts at that rate.)
        XCTAssertGreaterThan(Self.range(turnFiltered), 0.7 * Self.range(turnRaw), "a real turn is not a glitch")

        // Nowhere does the heading step by more than a few degrees between frames.
        let whole = Self.headings(session.filtered[...])
        XCTAssertLessThan(Self.largestStep(whole), 9)
    }

    /// Session of 2026-09-27, latest: the tracker's heading drifted 27°
    /// and back over three seconds with the arms going up, at 20°/s, with
    /// both feet on the floor; a real 70° turn on the spot at 45°/s.
    func testThirdSessionIgnoresTheArmsUpWanderAndFollowsTheTurn() throws {
        guard let session = try replay("session-20260927-202923") else { throw XCTSkip("recording not present") }

        let still = session.stretch("Stand still, arms down")
        XCTAssertLessThan(Self.range(Self.headings(session.filtered[still])), 6)
        XCTAssertLessThan(Self.largestStep(Self.headings(session.filtered[still])), 0.5)

        // With the arms going up (20–24 s) the tracker wandered 27°; the character stays put.
        let t0 = session.raw[0].timestamp
        let wander = session.raw.indices.filter { session.raw[$0].timestamp - t0 > 20 && session.raw[$0].timestamp - t0 < 24 }
        let wanderRaw = Self.headings(ArraySlice(wander.map { session.raw[$0] }))
        let wanderFiltered = Self.headings(ArraySlice(wander.map { session.filtered[$0] }))
        XCTAssertGreaterThan(Self.range(wanderRaw), 20, "the tracker did wander")
        XCTAssertLessThan(Self.range(wanderFiltered), 12, "the character does not")

        // The turn on the spot is followed, within a few frames.
        let turn = session.stretch("Turn to your left")
        XCTAssertGreaterThan(Self.range(Self.headings(session.filtered[turn])), 50)
        XCTAssertLessThan(Self.largestStep(Self.headings(session.filtered[turn])), 4)
    }

    /// Session of 2026-09-27, later: ten frames the tracker lost (they
    /// once let the raw skeleton through for a frame, a 29° spike); the
    /// tracker's heading toggling between two readings 30° apart while
    /// the arms went up; a fast turn back to the phone that the tracker
    /// reported as a snap and that must still be followed.
    func testSecondSessionHasNoSpikesAndFollowsTheTurnBack() throws {
        guard let session = try replay("session-20260927-200725") else { throw XCTSkip("recording not present") }
        XCTAssertEqual(session.raw.filter { !$0.isTracked }.count, 10)

        let still = session.stretch("Stand still, arms down")
        XCTAssertLessThan(Self.range(Self.headings(session.filtered[still])), 12)
        XCTAssertLessThan(Self.largestStep(Self.headings(session.filtered[still])), 1.0)

        let arms = session.stretch("Raise both arms")
        XCTAssertGreaterThan(Self.largestStep(Self.headings(session.raw[arms])), 15, "the tracker did snap")
        XCTAssertLessThan(Self.largestStep(Self.headings(session.filtered[arms])), 6, "the character never snaps")
        // The hands never jump either (the lost frames used to throw them 40 cm).
        var largestHandStep: Float = 0
        for index in arms.dropFirst() {
            for joint in [MocapJoint.leftHand, .rightHand] {
                guard let a = session.filtered[index - 1].positions[joint], let b = session.filtered[index].positions[joint],
                      let ra = session.filtered[index - 1].rotations[.root], let rb = session.filtered[index].rotations[.root]
                else { continue }
                let wa = ra.act(a) + session.filtered[index - 1].rootPosition, wb = rb.act(b) + session.filtered[index].rootPosition
                largestHandStep = max(largestHandStep, simd_length(wb - wa))
            }
        }
        XCTAssertLessThan(largestHandStep, 0.08)

        // The turn: a real 50° turn left and the fast turn back are followed.
        let turn = session.stretch("Turn to your left")
        XCTAssertGreaterThan(Self.range(Self.headings(session.filtered[turn])), 40)

        // Nowhere does the heading step by more than the rate limit allows
        // (the fast turn back runs at it).
        let whole = Self.headings(session.filtered[...])
        XCTAssertLessThan(Self.largestStep(whole), 12)
    }

    // MARK: - Arm reach

    /// The hands' reach targets over a stretch, for a character with
    /// wider shoulders, a longer torso and longer arms than the wearer,
    /// standing as calibrated: per frame the step of each target and of
    /// the captured hand it follows.
    private func reachSteps(_ session: Replay, _ stretch: Range<Int>) throws -> (target: [Float], hand: [Float], scale: Float) {
        let retargeter = MocapRetargeter(mapping: MocapRigMapping(joints: [:], rootJoint: "hips"))
        let calibration = try XCTUnwrap(session.filtered[stretch].first { $0.isTracked })
        retargeter.calibrate(with: calibration)
        let standing = try XCTUnwrap(retargeter.retarget(calibration)).capturedJointPositions
        var rig: [MocapJoint: simd_float3] = [:]
        for joint in MocapArmReach.joints {
            let p = try XCTUnwrap(standing[joint])
            rig[joint] = simd_float3(p.x * 1.3, p.y * 1.1, p.z)
        }
        func armLength(_ positions: [MocapJoint: simd_float3], _ arm: (shoulder: MocapJoint, elbow: MocapJoint, hand: MocapJoint)) -> Float {
            simd_distance(positions[arm.shoulder]!, positions[arm.elbow]!) + simd_distance(positions[arm.elbow]!, positions[arm.hand]!)
        }
        let scale: Float = 1.25
        var lengths: [MocapJoint: Float] = [:]
        for arm in MocapArmReach.arms {
            lengths[arm.shoulder] = armLength(standing, arm) * scale
        }

        let solver = MocapArmReach()
        var previous: (targets: [MocapJoint: simd_float3], hands: [MocapJoint: simd_float3])?
        var targetSteps: [Float] = [], handSteps: [Float] = []
        for frame in session.filtered[stretch] where frame.isTracked {
            let captured = try XCTUnwrap(retargeter.retarget(frame)).capturedJointPositions
            let targets = solver.targets(captured: captured, rig: rig, rigArmLength: lengths)
            var hands: [MocapJoint: simd_float3] = [:]
            for arm in MocapArmReach.arms {
                hands[arm.shoulder] = captured[arm.hand]
            }
            if let previous {
                for arm in MocapArmReach.arms {
                    guard let a = targets[arm.shoulder], let b = previous.targets[arm.shoulder],
                          let c = hands[arm.shoulder], let d = previous.hands[arm.shoulder]
                    else { continue }
                    targetSteps.append(simd_distance(a, b))
                    handSteps.append(simd_distance(c, d))
                }
            }
            previous = (targets, hands)
        }
        return (targetSteps, handSteps, scale)
    }

    /// Raising the arms takes the hands from beside the hips past the
    /// chest and the head: the anchors hand over all the way, and the
    /// targets must move like the hands do, scaled to the character's
    /// reach, without adding steps of their own.
    func testReachTargetsMoveLikeTheCapturedHands() throws {
        guard let session = try replay("session-20260927-190849") else { throw XCTSkip("recording not present") }
        for label in ["Stand still, arms down", "Raise both arms"] {
            let steps = try reachSteps(session, session.stretch(label))
            XCTAssertGreaterThan(steps.target.count, 100)
            let target = steps.target.sorted(), hand = steps.hand.sorted()
            let allowed = steps.scale * 1.1
            XCTAssertLessThan(try XCTUnwrap(target.last), try XCTUnwrap(hand.last) * allowed, label)
            XCTAssertLessThan(target[target.count * 99 / 100], hand[hand.count * 99 / 100] * allowed, label)
            XCTAssertLessThan(target.reduce(0, +), hand.reduce(0, +) * allowed, label)
        }
    }
}
