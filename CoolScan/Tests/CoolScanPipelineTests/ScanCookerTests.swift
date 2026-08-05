@testable import CoolScanPipeline
import XCTest

final class ScanCookerTests: XCTestCase {
    // Real coverage (MDLMesh → cook → UntoldReader round-trip) lands with the
    // Phase 2 cooker implementation.
    func testCookerErrorsDescribeThemselves() {
        let error = CoolScanCookerError.missingVertexAttribute("normal")
        XCTAssertTrue(error.description.contains("normal"))
    }
}
