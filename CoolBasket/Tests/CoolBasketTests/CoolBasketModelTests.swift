//
//  CoolBasketModelTests.swift
//  CoolBasketTests
//
//  The shipped hoop model against the scene's constants: the invisible
//  colliders and the net's lattice are measured on the model, and the model
//  is re-exported (lowered) by hand — this is what keeps the two in step.
//

@testable import CoolBasket
import simd
import UntoldEngine
import XCTest

final class CoolBasketModelTests: XCTestCase {
    private typealias Lattice = CoolBasketNetLattice

    private func loadHoop() throws -> RuntimeAsset {
        let url = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Models/hoop/hoop.untold"))
        return try NativeFormatLoader().loadAssetSync(from: url)
    }

    private func bounds(_ asset: RuntimeAsset, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> RuntimeAABB {
        try XCTUnwrap(asset.nodes.first { $0.name == name }?.worldBounds, "node \(name)", file: file, line: line)
    }

    func testTheModelStandsWhereTheCollidersAre() throws {
        let asset = try loadHoop()
        let rim = try bounds(asset, "Rim | 457 mm clear opening")
        XCTAssertEqual((rim.min.y + rim.max.y) * 0.5, CoolBasketScene.rimHeight, accuracy: 0.02, "rim centre height")
        XCTAssertEqual((rim.max.x - rim.min.x) * 0.5, CoolBasketScene.rimRadius, accuracy: 0.02, "rim radius")
        XCTAssertEqual((rim.min.z + rim.max.z) * 0.5, CoolBasketScene.boardSetback, accuracy: 0.02, "rim centre in front of the glass")

        let glass = try bounds(asset, "Backboard | 12 mm tempered glass")
        XCTAssertEqual(glass.min.y, CoolBasketScene.rimHeight - CoolBasketScene.boardBottomBelowRim, accuracy: 0.02, "glass bottom")
        XCTAssertEqual(glass.max.y - glass.min.y, CoolBasketScene.boardHeight, accuracy: 0.02, "glass height")
        XCTAssertEqual(glass.max.x - glass.min.x, CoolBasketScene.boardWidth, accuracy: 0.02, "glass width")

        let post = try bounds(asset, "Post | main 230 mm square column")
        XCTAssertEqual(post.max.y, CoolBasketScene.poleHeight, accuracy: 0.02, "post top")
        XCTAssertEqual(post.max.x - post.min.x, CoolBasketScene.poleHalfWidth * 2, accuracy: 0.02, "post width")
        XCTAssertEqual(-(post.min.z + post.max.z) * 0.5, CoolBasketScene.poleSetback, accuracy: 0.03, "post behind the glass")
    }

    func testTheNetLatticeMatchesTheModelsNet() throws {
        let asset = try loadHoop()
        for name in CoolBasketNet.drivenPartNames {
            XCTAssertNotNil(asset.nodes.first { $0.name == name }, "net part \(name)")
        }
        XCTAssertNotNil(asset.nodes.first { $0.name.contains("tempered glass") }, "the glass the game tints")

        let hook = try bounds(asset, "Rim | welded net hook 01")
        XCTAssertEqual(hook.min.y, Lattice.hookHeight, accuracy: 0.01, "hooks tie on at the lattice's top")
        let scallops = try bounds(asset, "Net_Open_Bottom_Scallops")
        XCTAssertEqual(scallops.min.y, Lattice.scallopHeight, accuracy: 0.01, "the open bottom")
        let knots = try bounds(asset, "Net_Knots")
        XCTAssertEqual(knots.max.y, Lattice.knotRows.first!.height, accuracy: 0.01, "top knot row")
        XCTAssertEqual(knots.min.y, Lattice.knotRows.last!.height, accuracy: 0.01, "bottom knot row")
        XCTAssertEqual((knots.max.x - knots.min.x) * 0.5, Lattice.knotRows.first!.radius, accuracy: 0.01, "widest row")
        XCTAssertEqual((knots.min.z + knots.max.z) * 0.5, Lattice.axis.y, accuracy: 0.01, "on the rim's axis")
    }

    func testTheBallModelIsCentredAndBallSized() throws {
        // The palm seat and the two-hand midpoint place the ball by its
        // origin and CoolBasketScene.ballRadius.
        let url = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Models/basketball/basketball.untold"))
        let asset = try NativeFormatLoader().loadAssetSync(from: url)
        let bounds = asset.worldBounds
        for axis in 0 ..< 3 {
            XCTAssertEqual(bounds.min[axis], -CoolBasketScene.ballRadius, accuracy: 0.01, "axis \(axis) min")
            XCTAssertEqual(bounds.max[axis], CoolBasketScene.ballRadius, accuracy: 0.01, "axis \(axis) max")
        }
    }

    func testTheLoweredPostPaddingKeptItsSeamsAndStraps() throws {
        // The export shortens the post padding with the rim; its stitched
        // seams (separate parts) must come with it and the straps must not
        // be scaled.
        let asset = try loadHoop()
        let protector = try bounds(asset, "Padding | tall front post protector")
        for name in ["Padding | vertical stitched seam", "Padding | vertical stitched seam.001", "Padding | horizontal stitched seam.001"] {
            let seam = try bounds(asset, name)
            XCTAssertLessThanOrEqual(seam.max.y, protector.max.y + 0.005, "\(name) stays on the padding")
        }
        for name in ["Padding | rear securing strap", "Padding | rear securing strap.001", "Padding | strap clasp", "Padding | strap clasp.001"] {
            let strap = try bounds(asset, name)
            XCTAssertLessThan(strap.max.y - strap.min.y, 0.06, "\(name) is a thin band")
            XCTAssertLessThanOrEqual(strap.max.y, protector.max.y + 0.005, "\(name) stays on the padding")
        }
    }
}
