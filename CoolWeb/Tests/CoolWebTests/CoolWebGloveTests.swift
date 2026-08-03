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

    func testWebShooterMuzzleSitsOffThePalmSideOfTheWrist() {
        let pose = makeHand()
        guard let muzzle = CoolWebGloveBuilder.webShooterMuzzle(
            pose: pose, side: .right
        ) else { return XCTFail("no muzzle for a valid pose") }
        // Close to the wrist but clearly offset from it (palm side), and not
        // behind it — the barrel hugs the wrist, not the palm.
        let offset = muzzle - pose.wrist
        XCTAssertGreaterThan(simd_length(offset), 0.015)
        XCTAssertLessThan(simd_length(offset), 0.07)
        XCTAssertGreaterThan(simd_dot(offset, pose.aimDirection), 0)
        XCTAssertLessThan(simd_dot(offset, pose.aimDirection), 0.02)
        // And it matches a metal vertex of the built glove (the barrel).
        let mesh = CoolWebGloveBuilder.build(pose: pose, side: .right)
        let nearestMetal = mesh.vertices
            .filter { $0.params.x == CoolWebGloveMaterial.metal }
            .map { simd_length(SIMD3($0.position.x, $0.position.y, $0.position.z) - muzzle) }
            .min() ?? .infinity
        XCTAssertLessThan(nearestMetal, 0.02)
    }

    func testBuildContainsBothMaterials() {
        let mesh = CoolWebGloveBuilder.build(pose: makeHand(), side: .right)
        let materials = Set(mesh.vertices.map { $0.params.x })
        XCTAssertTrue(materials.contains(CoolWebGloveMaterial.fabric))
        XCTAssertTrue(materials.contains(CoolWebGloveMaterial.metal))
        XCTAssertTrue(materials.contains(CoolWebGloveMaterial.fingerFabric))

        var noShooter = CoolWebGloveConfig()
        noShooter.showWebShooter = false
        let bare = CoolWebGloveBuilder.build(
            pose: makeHand(), side: .right, config: noShooter
        )
        XCTAssertFalse(bare.vertices.map { $0.params.x }
            .contains(CoolWebGloveMaterial.metal))
        XCTAssertLessThan(bare.vertices.count, mesh.vertices.count)
    }

    func testCoverageGrowsFromWristToFingertips() {
        let pose = makeHand()
        let mesh = CoolWebGloveBuilder.build(pose: pose, side: .right)

        // Coverage spans wrist (≈0) to past the middle fingertip, and every
        // vertex starts life fully covered (no animation running).
        XCTAssertGreaterThan(mesh.coverageExtent, 0.12)
        var minCoverage = Float.infinity
        for vertex in mesh.vertices {
            XCTAssertTrue(vertex.params.z.isFinite)
            XCTAssertGreaterThanOrEqual(vertex.params.z, 0)
            XCTAssertLessThanOrEqual(vertex.params.z, mesh.coverageExtent)
            XCTAssertEqual(vertex.params.w, CoolWebGloveBuild.coveredFront)
            minCoverage = min(minCoverage, vertex.params.z)
        }
        XCTAssertLessThan(minCoverage, 0.02)

        // The vertex closest to the middle fingertip carries (nearly) the
        // largest coverage — the suit-up reaches it last.
        guard let tip = pose.middle.points.last else { return XCTFail() }
        let tipVertex = mesh.vertices.min { a, b in
            simd_length(SIMD3(a.position.x, a.position.y, a.position.z) - tip)
                < simd_length(SIMD3(b.position.x, b.position.y, b.position.z) - tip)
        }
        XCTAssertGreaterThan(tipVertex!.params.z, mesh.coverageExtent * 0.75)
    }

    /// Pumps per-frame glove updates for one hand at the given times.
    private func pump(
        _ side: CoolWebHandSide,
        at times: [TimeInterval],
        lookedAt: Bool = true
    ) {
        for t in times {
            updateCoolWebGlove(
                side: side, pose: makeHand(), lookedAt: lookedAt, now: t
            )
        }
    }

    /// Suits one hand fully up (gaze + build time). Default config: gaze
    /// delay 0.35 s, build 0.9 s.
    private func suitUpFully(_ side: CoolWebHandSide, from t0: TimeInterval) {
        pump(side, at: [t0, t0 + 0.4, t0 + 2.0])
    }

    func testSuitUpBuildsThenReversesFromAnywhere() {
        let state = CoolWebGloveState.shared
        state.clear()
        setCoolWebGloveEnabled(true)
        setCoolWebGloveSuitUp(true)
        defer {
            setCoolWebGloveSuitUp(false)
            setCoolWebGloveEnabled(false)
            state.clear()
        }
        let extent = CoolWebGloveBuilder
            .build(pose: makeHand(), side: .right).coverageExtent

        // Gaze satisfied at 0.4 (delay 0.35), then the front sweeps out.
        pump(.right, at: [0, 0.4, 0.5])
        let building = state.snapshot().vertices
        XCTAssertFalse(building.isEmpty)
        XCTAssertGreaterThan(building[0].params.w, 0)
        XCTAssertLessThan(building[0].params.w, extent)

        pump(.right, at: [2.5])
        XCTAssertEqual(
            state.snapshot().vertices[0].params.w,
            CoolWebGloveBuild.coveredFront
        )

        // Toggle off: the animation reverses from covered…
        setCoolWebGloveSuitUp(false)
        pump(.right, at: [2.7])
        let reversing = state.snapshot().vertices
        XCTAssertGreaterThan(reversing[0].params.w, 0)
        XCTAssertLessThan(reversing[0].params.w, extent + 0.02)
        // …down to a bare (invisible) hand.
        pump(.right, at: [5])
        XCTAssertTrue(state.snapshot().vertices.isEmpty)
        XCTAssertEqual(coolWebGloveMaxProgress(), 0)

        // Toggling back on mid-bare requires the gaze again, then rebuilds.
        setCoolWebGloveSuitUp(true)
        pump(.right, at: [5.1, 5.5, 5.6])
        XCTAssertFalse(state.snapshot().vertices.isEmpty)
    }

    func testGazeGateBlocksTheBuildUntilLookedAt() {
        let state = CoolWebGloveState.shared
        state.clear()
        setCoolWebGloveEnabled(true)
        setCoolWebGloveSuitUp(true)
        defer {
            setCoolWebGloveSuitUp(false)
            setCoolWebGloveEnabled(false)
            state.clear()
        }
        // Not looking: nothing builds, no matter how long.
        pump(.right, at: [0, 1, 2], lookedAt: false)
        XCTAssertTrue(state.snapshot().vertices.isEmpty)

        // Looking, but shorter than the focus delay: still bare.
        pump(.right, at: [2.1, 2.2])
        XCTAssertTrue(state.snapshot().vertices.isEmpty)

        // Held past the delay: the build starts.
        pump(.right, at: [2.5, 2.6])
        XCTAssertFalse(state.snapshot().vertices.isEmpty)

        // Looking away mid-build does NOT pause the animation.
        pump(.right, at: [2.7], lookedAt: false)
        XCTAssertFalse(state.snapshot().vertices.isEmpty)
    }

    func testTrackingBlipKeepsSuitUpProgress() {
        let state = CoolWebGloveState.shared
        state.clear()
        setCoolWebGloveEnabled(true)
        setCoolWebGloveSuitUp(true)
        defer {
            setCoolWebGloveSuitUp(false)
            setCoolWebGloveEnabled(false)
            state.clear()
        }
        suitUpFully(.left, from: 0)
        // Blip: gone 0.2 s, back — still covered, no second animation.
        updateCoolWebGlove(side: .left, pose: nil, now: 3)
        pump(.left, at: [3.2, 3.25])
        XCTAssertEqual(
            state.snapshot().vertices[0].params.w,
            CoolWebGloveBuild.coveredFront
        )

        // Long absence: back to bare, waiting for gaze again.
        updateCoolWebGlove(side: .left, pose: nil, now: 4)
        pump(.left, at: [6])
        XCTAssertTrue(state.snapshot().vertices.isEmpty)
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

    func testGloveStateCombinesHandsAndRespectsEnabledFlag() {
        let state = CoolWebGloveState.shared
        state.clear()
        setCoolWebGloveEnabled(false)
        setCoolWebGloveSuitUp(true)
        defer {
            setCoolWebGloveSuitUp(false)
            setCoolWebGloveEnabled(false)
            state.clear()
        }

        // Disabled: updates are dropped.
        pump(.right, at: [0, 0.4, 2])
        XCTAssertTrue(state.snapshot().vertices.isEmpty)

        setCoolWebGloveEnabled(true)
        suitUpFully(.right, from: 10)
        let one = state.snapshot()
        XCTAssertFalse(one.vertices.isEmpty)

        // Second hand combines, indices rebased past the first hand's block.
        suitUpFully(.left, from: 13)
        pump(.right, at: [15.01])
        let two = state.snapshot()
        XCTAssertEqual(two.vertices.count, one.vertices.count * 2)
        XCTAssertTrue(two.indices.contains { Int($0) >= one.vertices.count })
        for index in two.indices {
            XCTAssertLessThan(Int(index), two.vertices.count)
        }

        // An untracked pose removes the hand; disabling clears everything.
        updateCoolWebGlove(
            side: .left, pose: makeHand(isTracked: false), now: 16
        )
        XCTAssertEqual(state.snapshot().vertices.count, one.vertices.count)
        setCoolWebGloveEnabled(false)
        XCTAssertTrue(state.snapshot().vertices.isEmpty)
    }
}
