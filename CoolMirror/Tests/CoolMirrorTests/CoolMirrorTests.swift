//
//  CoolMirrorTests.swift
//  CoolMirrorTests
//

@testable import CoolMirror
import XCTest

final class CoolMirrorTests: XCTestCase {
    func testClipNamesMatchBundledAssets() {
        XCTAssertEqual(CoolMirrorClip.running.rawValue, "running")
        XCTAssertEqual(CoolMirrorClip.idle.rawValue, "idle")
    }
}
