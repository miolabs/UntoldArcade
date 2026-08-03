@testable import CoolWeb
import simd
import XCTest

final class CoolWebGloveTests: XCTestCase {
    // MARK: - Synthetic hand

    /// Anatomically plausible right hand: wrist at (0, 1, 0), palm down,
    /// fingers pointing -Z, thumb splayed toward -X.
    private func makeHand(isTracked: Bool = true) -> CoolWebHandPose {
        let wrist = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, -1)
        func finger(x: Float, length: Float) -> CoolWebFingerChain {
            let base = wrist + SIMD3<Float>(x, 0, -0.02)
            let knuckle = wrist + SIMD3<Float>(x, 0, -0.085)
            return CoolWebFingerChain(points: [
                base,
                knuckle,
                knuckle + forward * (length * 0.45),
                knuckle + forward * (length * 0.75),
                knuckle + forward * length,
            ])
        }
        let thumbDir = simd_normalize(SIMD3<Float>(-1, 0, -0.7))
        return CoolWebHandPose(
            isTracked: isTracked,
            wrist: wrist,
            thumb: CoolWebFingerChain(points: [
                wrist,
                wrist + thumbDir * 0.045,
                wrist + thumbDir * 0.070,
                wrist + thumbDir * 0.090,
                wrist + thumbDir * 0.105,
            ]),
            index: finger(x: -0.030, length: 0.075),
            middle: finger(x: -0.010, length: 0.082),
            ring: finger(x: 0.010, length: 0.075),
            little: finger(x: 0.030, length: 0.062)
        )
    }

    // MARK: - Builder

    func testBuildProducesValidMesh() {
        let mesh = CoolWebGloveBuilder.build(pose: makeHand(), side: .right)

        XCTAssertGreaterThan(mesh.vertices.count, 300)
        XCTAssertLessThanOrEqual(
            mesh.vertices.count, CoolWebShaderLimits.maxGloveVertices
        )
        XCTAssertGreaterThan(mesh.indices.count, 900)
        XCTAssertLessThanOrEqual(
            mesh.indices.count, CoolWebShaderLimits.maxGloveIndices
        )
        XCTAssertEqual(mesh.indices.count % 3, 0)

        for index in mesh.indices {
            XCTAssertLessThan(Int(index), mesh.vertices.count)
        }
        for vertex in mesh.vertices {
            XCTAssertTrue(simd_length_squared(SIMD3(
                vertex.position.x, vertex.position.y, vertex.position.z
            )).isFinite)
            let normal = SIMD3(vertex.normal.x, vertex.normal.y, vertex.normal.z)
            XCTAssertTrue(simd_length_squared(normal).isFinite)
            XCTAssertEqual(simd_length(normal), 1, accuracy: 0.01)
        }
    }

    func testMeshFollowsThePose() {
        let pose = makeHand()
        let mesh = CoolWebGloveBuilder.build(pose: pose, side: .right)

        // Every vertex stays within arm's reach of the wrist…
        for vertex in mesh.vertices {
            let position = SIMD3(vertex.position.x, vertex.position.y, vertex.position.z)
            XCTAssertLessThan(simd_length(position - pose.wrist), 0.35)
        }
        // …and some vertex reaches each fingertip (glove covers the fingers).
        for chain in [pose.thumb, pose.index, pose.middle, pose.ring, pose.little] {
            guard let tip = chain.points.last else { continue }
            let closest = mesh.vertices.map { vertex in
                simd_length(SIMD3(
                    vertex.position.x, vertex.position.y, vertex.position.z
                ) - tip)
            }.min() ?? .infinity
            XCTAssertLessThan(closest, 0.02)
        }
    }

    func testBuildContainsBothMaterials() {
        let mesh = CoolWebGloveBuilder.build(pose: makeHand(), side: .right)
        let materials = Set(mesh.vertices.map { $0.params.x })
        XCTAssertTrue(materials.contains(CoolWebGloveMaterial.fabric))
        XCTAssertTrue(materials.contains(CoolWebGloveMaterial.metal))

        var noShooter = CoolWebGloveConfig()
        noShooter.showWebShooter = false
        let bare = CoolWebGloveBuilder.build(
            pose: makeHand(), side: .right, config: noShooter
        )
        XCTAssertFalse(bare.vertices.map { $0.params.x }
            .contains(CoolWebGloveMaterial.metal))
        XCTAssertLessThan(bare.vertices.count, mesh.vertices.count)
    }

    func testDegeneratePoseDoesNotProduceNaNs() {
        // All joints collapsed onto the wrist: every direction is degenerate.
        let point = SIMD3<Float>(0, 1, 0)
        let chain = CoolWebFingerChain(points: Array(repeating: point, count: 5))
        let pose = CoolWebHandPose(
            isTracked: true,
            wrist: point,
            thumb: chain, index: chain, middle: chain, ring: chain, little: chain
        )
        let mesh = CoolWebGloveBuilder.build(pose: pose, side: .left)
        for vertex in mesh.vertices {
            XCTAssertTrue(vertex.position.x.isFinite)
            XCTAssertTrue(vertex.position.y.isFinite)
            XCTAssertTrue(vertex.position.z.isFinite)
            XCTAssertTrue(vertex.normal.x.isFinite)
            XCTAssertTrue(vertex.normal.y.isFinite)
            XCTAssertTrue(vertex.normal.z.isFinite)
        }
    }

    func testLeftAndRightGlovesMirrorTheBackNormal() {
        // Same joint cloud, opposite chirality: the palm loft flips sides, so
        // the two meshes must differ while staying the same size.
        let pose = makeHand()
        let right = CoolWebGloveBuilder.build(pose: pose, side: .right)
        let left = CoolWebGloveBuilder.build(pose: pose, side: .left)
        XCTAssertEqual(right.vertices.count, left.vertices.count)
        XCTAssertNotEqual(right.vertices, left.vertices)
    }

    // MARK: - State store

    func testGloveStateRespectsEnabledFlag() {
        let state = CoolWebGloveState.shared
        state.clear()
        setCoolWebGloveEnabled(false)

        // Disabled: updates are dropped.
        updateCoolWebGlove(side: .right, pose: makeHand())
        XCTAssertTrue(state.snapshot().vertices.isEmpty)

        setCoolWebGloveEnabled(true)
        defer {
            setCoolWebGloveEnabled(false)
            state.clear()
        }
        updateCoolWebGlove(side: .right, pose: makeHand())
        let one = state.snapshot()
        XCTAssertFalse(one.vertices.isEmpty)

        // Second hand combines, indices rebased past the first hand's block.
        updateCoolWebGlove(side: .left, pose: makeHand())
        let two = state.snapshot()
        XCTAssertEqual(two.vertices.count, one.vertices.count * 2)
        XCTAssertTrue(two.indices.contains { Int($0) >= one.vertices.count })
        for index in two.indices {
            XCTAssertLessThan(Int(index), two.vertices.count)
        }

        // Tracking loss removes the hand; disabling clears everything.
        updateCoolWebGlove(side: .left, pose: nil)
        XCTAssertEqual(state.snapshot().vertices.count, one.vertices.count)
        setCoolWebGloveEnabled(false)
        XCTAssertTrue(state.snapshot().vertices.isEmpty)
    }

    func testUntrackedPoseRemovesGlove() {
        let state = CoolWebGloveState.shared
        state.clear()
        setCoolWebGloveEnabled(true)
        defer {
            setCoolWebGloveEnabled(false)
            state.clear()
        }
        updateCoolWebGlove(side: .right, pose: makeHand())
        XCTAssertFalse(state.snapshot().vertices.isEmpty)
        updateCoolWebGlove(side: .right, pose: makeHand(isTracked: false))
        XCTAssertTrue(state.snapshot().vertices.isEmpty)
    }
}
