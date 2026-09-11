@testable import CoolWeb
import simd
import XCTest

final class CoolWebGloveTests: XCTestCase {
    // MARK: - Fixtures

    /// The real rigged assets shipped with the example app, reached relative
    /// to this source file so host tests exercise the actual usdz parsing.
    private static let modelsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CoolWebTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // CoolWeb
        .appendingPathComponent(
            "Examples/CoolWebVisionOS/CoolWebVisionOS/visionOS/Resources/Models"
        )

    private static let loadedRight: CoolWebGloveAsset? =
        try? CoolWebGloveAssetLoader.load(
            url: modelsDirectory.appendingPathComponent("hand_right.usdz"),
            side: .right
        )
    private static let loadedLeft: CoolWebGloveAsset? =
        try? CoolWebGloveAssetLoader.load(
            url: modelsDirectory.appendingPathComponent("hand_left.usdz"),
            side: .left
        )

    private func rightAsset() throws -> CoolWebGloveAsset {
        try XCTUnwrap(Self.loadedRight, "hand_right.usdz failed to load")
    }

    private func leftAsset() throws -> CoolWebGloveAsset {
        try XCTUnwrap(Self.loadedLeft, "hand_left.usdz failed to load")
    }

    /// A pose whose joints sit exactly at the asset's bind positions — the
    /// retarget solver must return (near-)identity matrices for it.
    private func bindPose(of asset: CoolWebGloveAsset) throws -> CoolWebHandPose {
        let skeleton = asset.skeleton
        func joint(_ name: String) throws -> SIMD3<Float> {
            let index = try XCTUnwrap(
                skeleton.jointIndex(named: name), "missing joint \(name)"
            )
            return skeleton.bindPositions[index]
        }
        let wrist = try joint("wrist")
        func chain(_ prefix: String) throws -> CoolWebFingerChain {
            let knuckle = try joint("\(prefix)Knuckle")
            let base = try joint("\(prefix)IntermediateBase")
            let tip = try joint("\(prefix)IntermediateTip")
            // Tip target: the asset's fingertip marker when it has one, else
            // the solver's own estimate (continue the last bone's direction)
            // so the last bone is unrotated either way.
            let end = skeleton.jointIndex(named: "\(prefix)Tip").map {
                skeleton.bindPositions[$0]
            } ?? tip + (tip - base)
            return CoolWebFingerChain(
                points: [wrist, knuckle, base, tip, end]
            )
        }
        return CoolWebHandPose(
            isTracked: true,
            wrist: wrist,
            thumb: try chain("thumb"),
            index: try chain("indexFinger"),
            middle: try chain("middleFinger"),
            ring: try chain("ringFinger"),
            little: try chain("littleFinger")
        )
    }

    /// Anatomically plausible tracked right hand somewhere in the room:
    /// wrist at (0, 1, 0), palm down, fingers pointing -Z, thumb toward -X.
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

    // MARK: - Asset loading

    func testAssetsLoadWithExpectedShape() throws {
        for asset in [try rightAsset(), try leftAsset()] {
            let jointCount = asset.skeleton.names.count
            XCTAssertGreaterThanOrEqual(jointCount, 17)
            XCTAssertLessThanOrEqual(jointCount, CoolWebShaderLimits.maxGloveJoints)
            XCTAssertEqual(asset.skeleton.parents.count, jointCount)
            XCTAssertEqual(asset.skeleton.bindPositions.count, jointCount)
            // The cooked Mixamo gloves carry fingertip + muzzle markers.
            for name in ["thumbTip", "indexFingerTip", "middleFingerTip",
                         "ringFingerTip", "littleFingerTip",
                         CoolWebGloveSkeleton.muzzleJoint] {
                XCTAssertNotNil(asset.skeleton.jointIndex(named: name), name)
            }
            XCTAssertGreaterThan(asset.vertices.count, 10_000)
            XCTAssertGreaterThan(asset.indices.count, 30_000)
            XCTAssertEqual(asset.indices.count % 3, 0)
            XCTAssertEqual(asset.submeshes.count, 2)
            XCTAssertEqual(
                Set(asset.submeshes.map(\.materialIndex)), Set([0, 1])
            )

            // Every ARKit-named joint the solver drives must exist.
            for name in ["forearmArm", "wrist"] {
                XCTAssertNotNil(asset.skeleton.jointIndex(named: name), name)
            }
            for prefix in [
                "thumb", "indexFinger", "middleFinger", "ringFinger",
                "littleFinger",
            ] {
                for suffix in [
                    "Knuckle", "IntermediateBase", "IntermediateTip",
                ] {
                    XCTAssertNotNil(
                        asset.skeleton.jointIndex(named: prefix + suffix),
                        prefix + suffix
                    )
                }
            }

            // A life-size glove: coverage spans wrist → fingertip ≈ 0.1–0.3 m.
            XCTAssertGreaterThan(asset.coverageExtent, 0.10)
            XCTAssertLessThan(asset.coverageExtent, 0.35)

            for vertex in asset.vertices {
                // Indices reference real joints, weights are normalized.
                XCTAssertLessThan(Int(vertex.texJoint.z), jointCount)
                XCTAssertLessThan(Int(vertex.texJoint.w), jointCount)
                XCTAssertLessThan(Int(vertex.extra.x), jointCount)
                XCTAssertLessThan(Int(vertex.extra.y), jointCount)
                XCTAssertEqual(vertex.weights.sum(), 1, accuracy: 1e-3)
                XCTAssertTrue(vertex.position.x.isFinite)
                XCTAssertGreaterThanOrEqual(vertex.position.w, 0)
                XCTAssertLessThanOrEqual(
                    vertex.position.w, asset.coverageExtent
                )
                let material = vertex.normal.w
                XCTAssertTrue(material == 0 || material == 1)
            }
            for index in asset.indices {
                XCTAssertLessThan(Int(index), asset.vertices.count)
            }
        }
    }

    func testAssetsHaveTheCorrectHandedness() throws {
        // Regression for the on-device "exploding glove": the suit faces +Z,
        // so its +X arm is the character's LEFT hand — the extracted gloves
        // must be assigned to the matching ARKit side or the solver fits a
        // mirrored glove and the mesh contorts. Ground truth: the
        // web-shooter plate sits on the PALM side, so it must lie opposite
        // the bind hand frame's back normal.
        for asset in [try rightAsset(), try leftAsset()] {
            let skeleton = asset.skeleton
            let frame = try XCTUnwrap(CoolWebGloveRig.bindHandFrame(
                skeleton: skeleton, side: asset.side
            ))
            let back = frame.basis.columns.2
            let wrist = skeleton.bindPositions[
                try XCTUnwrap(skeleton.jointIndex(named: "wrist"))
            ]
            var shooterCentroid = SIMD3<Float>()
            var count = 0
            for vertex in asset.vertices where vertex.normal.w == 1 {
                shooterCentroid += SIMD3(
                    vertex.position.x, vertex.position.y, vertex.position.z
                )
                count += 1
            }
            XCTAssertGreaterThan(count, 0)
            shooterCentroid /= Float(count)
            XCTAssertLessThan(
                simd_dot(shooterCentroid - wrist, back), 0,
                "\(asset.side): webshooter is not on the palm side — glove is mirrored"
            )
        }
    }

    func testMeshAndSkeletonShareOneSpace() throws {
        // The bind wrist joint must sit inside the mesh, not off in some
        // unapplied-transform space: nearest vertex within a few cm.
        for asset in [try rightAsset(), try leftAsset()] {
            let skeleton = asset.skeleton
            let wrist = skeleton.bindPositions[
                try XCTUnwrap(skeleton.jointIndex(named: "wrist"))
            ]
            let nearest = asset.vertices
                .map {
                    simd_length(SIMD3(
                        $0.position.x, $0.position.y, $0.position.z
                    ) - wrist)
                }
                .min() ?? .infinity
            XCTAssertLessThan(nearest, 0.05)
        }
    }

    // MARK: - Retarget solver

    func testBindPoseRetargetsToIdentity() throws {
        for asset in [try rightAsset(), try leftAsset()] {
            let pose = try bindPose(of: asset)
            let matrices = try XCTUnwrap(CoolWebGloveRig.skinningMatrices(
                skeleton: asset.skeleton, pose: pose, side: asset.side,
                fit: .neutral
            ))
            XCTAssertEqual(matrices.count, asset.skeleton.names.count)
            for (joint, matrix) in matrices.enumerated() {
                for column in 0 ..< 4 {
                    for row in 0 ..< 4 {
                        let expected: Float = column == row ? 1 : 0
                        XCTAssertEqual(
                            matrix[column][row], expected, accuracy: 0.02,
                            "joint \(asset.skeleton.names[joint]) [\(column)][\(row)]"
                        )
                    }
                }
            }
        }
    }

    func testTrackedHandCarriesJointsToTrackedPositions() throws {
        let asset = try rightAsset()
        let pose = makeHand()
        let matrices = try XCTUnwrap(CoolWebGloveRig.skinningMatrices(
            skeleton: asset.skeleton, pose: pose, side: .right
        ))

        // Each driven joint's skinning matrix must map its bind head onto
        // the tracked joint position it is anchored to.
        func assertMaps(_ name: String, to target: SIMD3<Float>) throws {
            let joint = try XCTUnwrap(asset.skeleton.jointIndex(named: name))
            let bind = asset.skeleton.bindPositions[joint]
            let mapped4 = matrices[joint] * SIMD4<Float>(bind, 1)
            let mapped = SIMD3(mapped4.x, mapped4.y, mapped4.z)
            XCTAssertLessThan(
                simd_length(mapped - target), 1e-4, name
            )
        }
        try assertMaps("wrist", to: pose.wrist)
        try assertMaps("indexFingerKnuckle", to: pose.index.points[1])
        try assertMaps("indexFingerIntermediateBase", to: pose.index.points[2])
        try assertMaps("indexFingerIntermediateTip", to: pose.index.points[3])
        try assertMaps("thumbKnuckle", to: pose.thumb.points[1])
        try assertMaps("littleFingerIntermediateTip", to: pose.little.points[3])

        // Matrices stay affine and finite.
        for matrix in matrices {
            for column in 0 ..< 4 {
                for row in 0 ..< 4 {
                    XCTAssertTrue(matrix[column][row].isFinite)
                }
            }
            XCTAssertEqual(matrix[0][3], 0)
            XCTAssertEqual(matrix[3][3], 1)
        }
    }

    func testFingerBonesStayContinuousAcrossKnucklesOnASmallerHand() throws {
        // Regression for the on-device "broken fingers": a real hand whose
        // segment lengths differ from the glove's must not tear the skin at
        // the joints. Each finger bone's matrix must carry its bind TAIL
        // (the next joint) onto the same tracked position the next bone's
        // matrix anchors its head at — otherwise the blend zone folds.
        let asset = try rightAsset()
        let skeleton = asset.skeleton

        // A hand ~20 % smaller than the glove and moved across the room:
        // scale the bind pose about the wrist, then translate.
        let bindHand = try bindPose(of: asset)
        let offset = SIMD3<Float>(0.4, 1.1, -0.6)
        func shrink(_ p: SIMD3<Float>) -> SIMD3<Float> {
            (p - bindHand.wrist) * 0.8 + bindHand.wrist + offset
        }
        func shrinkChain(_ c: CoolWebFingerChain) -> CoolWebFingerChain {
            CoolWebFingerChain(points: c.points.map(shrink))
        }
        let pose = CoolWebHandPose(
            isTracked: true,
            wrist: shrink(bindHand.wrist),
            thumb: shrinkChain(bindHand.thumb),
            index: shrinkChain(bindHand.index),
            middle: shrinkChain(bindHand.middle),
            ring: shrinkChain(bindHand.ring),
            little: shrinkChain(bindHand.little)
        )
        let matrices = try XCTUnwrap(CoolWebGloveRig.skinningMatrices(
            skeleton: skeleton, pose: pose, side: .right
        ))

        func mapped(_ joint: Int, _ point: SIMD3<Float>) -> SIMD3<Float> {
            let out = matrices[joint] * SIMD4<Float>(point, 1)
            return SIMD3(out.x, out.y, out.z)
        }
        let chains: [(CoolWebFingerChain, String)] = [
            (pose.thumb, "thumb"), (pose.index, "indexFinger"),
            (pose.middle, "middleFinger"), (pose.ring, "ringFinger"),
            (pose.little, "littleFinger"),
        ]
        for (chain, prefix) in chains {
            let boneNames = [
                "\(prefix)Knuckle", "\(prefix)IntermediateBase",
                "\(prefix)IntermediateTip",
            ]
            for bone in 0 ..< 2 {
                let joint = try XCTUnwrap(
                    skeleton.jointIndex(named: boneNames[bone])
                )
                let next = try XCTUnwrap(
                    skeleton.jointIndex(named: boneNames[bone + 1])
                )
                // This bone's image of the next joint == where the next bone
                // anchors it. 2 mm of slack for the clamped scale rounding.
                let carried = mapped(joint, skeleton.bindPositions[next])
                XCTAssertLessThan(
                    simd_length(carried - chain.points[bone + 2]), 0.002,
                    "\(boneNames[bone]) tears at \(boneNames[bone + 1])"
                )
            }
        }
    }

    func testDegeneratePoseReturnsNilInsteadOfNaNs() throws {
        let asset = try rightAsset()
        let point = SIMD3<Float>(0, 1, 0)
        let chain = CoolWebFingerChain(points: Array(repeating: point, count: 5))
        let pose = CoolWebHandPose(
            isTracked: true,
            wrist: point,
            thumb: chain, index: chain, middle: chain, ring: chain,
            little: chain
        )
        // All joints collapsed: the hand frame is degenerate. Either refuse
        // (nil) or return finite matrices — never NaNs.
        if let matrices = CoolWebGloveRig.skinningMatrices(
            skeleton: asset.skeleton, pose: pose, side: .right
        ) {
            for matrix in matrices {
                for column in 0 ..< 4 {
                    for row in 0 ..< 4 {
                        XCTAssertTrue(matrix[column][row].isFinite)
                    }
                }
            }
        }
    }

    func testWebShooterMuzzleSitsOffThePalmSideOfTheWrist() throws {
        try installAssets()
        let pose = makeHand()
        guard let muzzle = CoolWebGloveBuilder.webShooterMuzzle(
            pose: pose, side: .right
        ) else { return XCTFail("no muzzle for a valid pose") }
        // The skinned marker: close to the wrist, on the PALM side (the
        // synthetic hand is palm-down, so the palm normal is -Y), and not
        // behind the wrist — the emitter sits on the inner wrist.
        let offset = muzzle - pose.wrist
        XCTAssertGreaterThan(simd_length(offset), 0.01)
        XCTAssertLessThan(simd_length(offset), 0.08)
        XCTAssertLessThan(offset.y, 0, "muzzle must be on the palm side")
        XCTAssertGreaterThan(simd_dot(offset, pose.aimDirection), -0.01)

        // The marker rides with the wrist: moving the whole hand moves it.
        let shift = SIMD3<Float>(0.3, -0.2, 0.1)
        func moved(_ chain: CoolWebFingerChain) -> CoolWebFingerChain {
            CoolWebFingerChain(points: chain.points.map { $0 + shift })
        }
        let movedPose = CoolWebHandPose(
            isTracked: true, wrist: pose.wrist + shift,
            thumb: moved(pose.thumb), index: moved(pose.index),
            middle: moved(pose.middle), ring: moved(pose.ring),
            little: moved(pose.little)
        )
        let movedMuzzle = try XCTUnwrap(CoolWebGloveBuilder.webShooterMuzzle(
            pose: movedPose, side: .right
        ))
        XCTAssertLessThan(simd_length(movedMuzzle - (muzzle + shift)), 1e-4)
    }

    func testFingertipsFollowTheTrackedTips() throws {
        // With fingertip markers the distal bone maps the asset's real tip
        // onto the tracked tip — no more real fingertips poking out.
        let asset = try rightAsset()
        let pose = makeHand()
        var padded = CoolWebGloveFit.neutral
        padded.fingertipPadding = 0.008
        let matrices = try XCTUnwrap(CoolWebGloveRig.skinningMatrices(
            skeleton: asset.skeleton, pose: pose, side: .right, fit: padded
        ))
        for (prefix, chain) in [
            ("thumb", pose.thumb), ("indexFinger", pose.index),
            ("middleFinger", pose.middle), ("ringFinger", pose.ring),
            ("littleFinger", pose.little),
        ] {
            let tip = try XCTUnwrap(asset.skeleton.jointIndex(named: "\(prefix)Tip"))
            let bind = asset.skeleton.bindPositions[tip]
            let mapped4 = matrices[tip] * SIMD4<Float>(bind, 1)
            let mapped = SIMD3(mapped4.x, mapped4.y, mapped4.z)
            // …plus the fingertip padding, along the distal direction.
            let distal = simd_normalize(chain.points[4] - chain.points[3])
            let expected = chain.points[4] + distal * 0.008
            XCTAssertLessThan(simd_length(mapped - expected), 1e-3, prefix)
        }
    }

    // MARK: - Suit-up state machine

    private func installAssets() throws {
        CoolWebGloveAssetStore.shared.set(asset: try rightAsset())
        CoolWebGloveAssetStore.shared.set(asset: try leftAsset())
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

    func testSuitUpBuildsThenReversesFromAnywhere() throws {
        try installAssets()
        let state = CoolWebGloveState.shared
        state.clear()
        setCoolWebGloveEnabled(true)
        setCoolWebGloveSuitUp(true)
        defer {
            setCoolWebGloveSuitUp(false)
            setCoolWebGloveEnabled(false)
            state.clear()
        }
        let extent = try rightAsset().coverageExtent

        // Gaze satisfied at 0.4 (delay 0.35), then the front sweeps out.
        pump(.right, at: [0, 0.4, 0.5])
        let building = state.snapshot()
        XCTAssertEqual(building.count, 1)
        XCTAssertGreaterThan(building[0].front, 0)
        XCTAssertLessThan(building[0].front, extent)
        XCTAssertEqual(
            building[0].joints.count, try rightAsset().skeleton.names.count
        )

        pump(.right, at: [2.5])
        XCTAssertEqual(
            state.snapshot()[0].front, CoolWebGloveBuild.coveredFront
        )

        // Toggle off: the animation reverses from covered…
        setCoolWebGloveSuitUp(false)
        pump(.right, at: [2.7])
        let reversing = state.snapshot()
        XCTAssertGreaterThan(reversing[0].front, 0)
        XCTAssertLessThan(reversing[0].front, extent + 0.02)
        // …down to a bare (invisible) hand.
        pump(.right, at: [5])
        XCTAssertTrue(state.snapshot().isEmpty)
        XCTAssertEqual(coolWebGloveMaxProgress(), 0)

        // Toggling back on mid-bare requires the gaze again, then rebuilds.
        setCoolWebGloveSuitUp(true)
        pump(.right, at: [5.1, 5.5, 5.6])
        XCTAssertFalse(state.snapshot().isEmpty)
    }

    func testGazeGateBlocksTheBuildUntilLookedAt() throws {
        try installAssets()
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
        XCTAssertTrue(state.snapshot().isEmpty)

        // Looking, but shorter than the focus delay: still bare.
        pump(.right, at: [2.1, 2.2])
        XCTAssertTrue(state.snapshot().isEmpty)

        // Held past the delay: the build starts.
        pump(.right, at: [2.5, 2.6])
        XCTAssertFalse(state.snapshot().isEmpty)

        // Looking away mid-build does NOT pause the animation.
        pump(.right, at: [2.7], lookedAt: false)
        XCTAssertFalse(state.snapshot().isEmpty)
    }

    func testTrackingBlipKeepsSuitUpProgress() throws {
        try installAssets()
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
            state.snapshot()[0].front, CoolWebGloveBuild.coveredFront
        )

        // Long absence: back to bare, waiting for gaze again.
        updateCoolWebGlove(side: .left, pose: nil, now: 4)
        pump(.left, at: [6])
        XCTAssertTrue(state.snapshot().isEmpty)
    }

    func testGloveStateCombinesHandsAndRespectsEnabledFlag() throws {
        try installAssets()
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
        XCTAssertTrue(state.snapshot().isEmpty)

        setCoolWebGloveEnabled(true)
        suitUpFully(.right, from: 10)
        XCTAssertEqual(state.snapshot().count, 1)

        // Second hand joins with its own joint palette.
        suitUpFully(.left, from: 13)
        pump(.right, at: [15.01])
        let two = state.snapshot()
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(Set(two.map(\.side)), Set([.left, .right]))
        for hand in two {
            XCTAssertGreaterThanOrEqual(hand.joints.count, 17)
        }

        // An untracked pose removes the hand; disabling clears everything.
        updateCoolWebGlove(
            side: .left, pose: makeHand(isTracked: false), now: 16
        )
        XCTAssertEqual(state.snapshot().count, 1)
        setCoolWebGloveEnabled(false)
        XCTAssertTrue(state.snapshot().isEmpty)
    }
}
