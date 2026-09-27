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
        XCTAssertGreaterThan(Self.range(turnFiltered), 0.85 * Self.range(turnRaw), "a real turn is not a glitch")

        // Nowhere does the heading step by more than a few degrees between frames.
        let whole = Self.headings(session.filtered[...])
        XCTAssertLessThan(Self.largestStep(whole), 9)
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
}
