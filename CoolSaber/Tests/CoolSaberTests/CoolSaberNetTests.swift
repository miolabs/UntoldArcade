@testable import CoolSaber
import Foundation
import simd
import XCTest

final class CoolSaberNetTests: XCTestCase {
    func testPosePacketRoundTrip() throws {
        let packet = SaberPosePacket(
            sequence: 4711,
            timestamp: 123.456,
            left: SaberBladeWire(
                hilt: SIMD3(-0.31, 1.12, -0.55),
                direction: SIMD3(0.12, 0.94, -0.32),
                length: 0.87,
                ignited: true
            ),
            right: SaberBladeWire(
                hilt: SIMD3(0.28, 1.05, -0.61),
                direction: SIMD3(-0.05, 0.99, 0.1),
                length: 0,
                ignited: false
            )
        )
        let data = try JSONEncoder().encode(packet)
        let decoded = try JSONDecoder().decode(SaberPosePacket.self, from: data)
        XCTAssertEqual(decoded, packet)
    }

    func testIgniteEventRoundTrip() throws {
        let event = SaberEvent.ignite(
            hand: .right,
            ignited: true,
            color: SIMD3(1.0, 0.22, 0.15)
        )
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(SaberEvent.self, from: data), event)
    }

    func testClashEventRoundTrip() throws {
        let event = SaberEvent.clash(
            position: SIMD3(0.1, 1.4, -0.9),
            intensity: 7.5
        )
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(SaberEvent.self, from: data), event)
    }

    func testFrameSyncEventRoundTrip() throws {
        var matrix = simd_float4x4(simd_quatf(angle: 0.7, axis: SIMD3(0, 1, 0)))
        matrix.columns.3 = SIMD4(1.5, 0, -2.25, 1)
        let event = SaberEvent.frameSync(receiverFromSender: SaberFrameTransform(matrix))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(SaberEvent.self, from: data)
        XCTAssertEqual(decoded, event)
        guard case .frameSync(let transform) = decoded else { return XCTFail("wrong case") }
        XCTAssertEqual(transform.matrix, matrix)
    }

    func testPosePacketIsCompactEnoughForUnreliableMessaging() throws {
        let packet = SaberPosePacket(
            sequence: .max,
            timestamp: 99999.999,
            left: SaberBladeWire(ignited: true),
            right: SaberBladeWire(ignited: true)
        )
        let data = try JSONEncoder().encode(packet)
        // GroupSessionMessenger unreliable payloads should stay well under 1 KB.
        XCTAssertLessThan(data.count, 1024)
    }
}
