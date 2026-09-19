//
//  CoolBasketNetTests.swift
//  CoolBasketTests
//
//  The net: the lattice's topology, the skin that carries the artist's
//  vertices along the cords, and the soft body itself in a headless Jolt
//  world — it hangs still, and a ball dropped through the rim comes out
//  underneath.
//

@testable import CoolBasket
import simd
import UntoldEngine
import UntoldJoltPhysics
import XCTest

final class CoolBasketNetTests: XCTestCase {
    private typealias Lattice = CoolBasketNetLattice

    // MARK: Lattice

    func testLatticeHasTheModelsParticlesAndPinsTheHooksAndGhosts() {
        let lattice = Lattice.rest
        XCTAssertEqual(lattice.particles.count, Lattice.particleCount)
        XCTAssertEqual(lattice.particles.count, 12 + 60 + 12 + 72)
        XCTAssertEqual(lattice.inverseMasses.count, lattice.particles.count)
        for column in 0 ..< 12 {
            XCTAssertEqual(lattice.inverseMasses[Lattice.hook(column)], 0, "hooks are pinned")
        }
        for index in Lattice.hookCount ..< Lattice.cordParticleCount {
            XCTAssertGreaterThan(lattice.inverseMasses[index], 0, "knots and scallops swing")
            XCTAssertEqual(lattice.inverseMasses[Lattice.ghost(of: index)], 0, "ghosts are pinned")
            XCTAssertEqual(lattice.particles[Lattice.ghost(of: index)].y, lattice.particles[index].y + Lattice.ghostLift, accuracy: 1e-6)
        }
        // Hooks on the rim, rows narrowing toward the open bottom.
        let axis = SIMD3<Float>(Lattice.axis.x, 0, Lattice.axis.y)
        func radius(_ index: Int) -> Float {
            let p = lattice.particles[index] - axis
            return simd_length(SIMD2<Float>(p.x, p.z))
        }
        XCTAssertEqual(radius(Lattice.hook(3)), Lattice.hookRadius, accuracy: 1e-5)
        XCTAssertEqual(lattice.particles[Lattice.hook(3)].y, Lattice.hookHeight, accuracy: 1e-5)
        var previous = Lattice.hookRadius
        for row in 0 ..< Lattice.knotRows.count {
            let r = radius(Lattice.knot(row: row, column: 5))
            XCTAssertLessThan(r, previous)
            previous = r
        }
        XCTAssertLessThan(radius(Lattice.scallop(0)), previous)
        XCTAssertLessThan(lattice.particles[Lattice.scallop(0)].y, lattice.particles[Lattice.knot(row: 4, column: 0)].y)
    }

    func testEveryKnotHangsFromTwoCordsAndCarriesTwo() {
        let lattice = Lattice.rest
        XCTAssertEqual(lattice.edges.count, Lattice.cordEdgeCount + Lattice.freeParticleCount)
        XCTAssertEqual(lattice.edgeCompliances.count, lattice.edges.count)
        var up = [Int](repeating: 0, count: Lattice.particleCount)
        var down = [Int](repeating: 0, count: Lattice.particleCount)
        for edge in lattice.edges.prefix(Lattice.cordEdgeCount) {
            let a = Int(edge.x), b = Int(edge.y)
            XCTAssertLessThan(a, Lattice.cordParticleCount)
            XCTAssertLessThan(b, Lattice.cordParticleCount)
            XCTAssertNotEqual(a, b)
            // Cords are listed top particle first, and are cord-sized.
            XCTAssertGreaterThan(lattice.particles[a].y, lattice.particles[b].y)
            let length = simd_distance(lattice.particles[a], lattice.particles[b])
            XCTAssertGreaterThan(length, 0.04, "edge \(a)-\(b)")
            XCTAssertLessThan(length, 0.12, "edge \(a)-\(b)")
            down[a] += 1
            up[b] += 1
        }
        for column in 0 ..< 12 {
            XCTAssertEqual(down[Lattice.hook(column)], 2, "a hook carries two cords")
            XCTAssertEqual(up[Lattice.hook(column)], 0)
            XCTAssertEqual(up[Lattice.scallop(column)], 2, "a scallop bottom hangs from two knots")
            XCTAssertEqual(down[Lattice.scallop(column)], 0)
        }
        for row in 0 ..< Lattice.knotRows.count {
            for column in 0 ..< 12 {
                let knot = Lattice.knot(row: row, column: column)
                XCTAssertEqual(up[knot], 2, "row \(row) column \(column) hangs from two")
                XCTAssertEqual(down[knot], 2, "row \(row) column \(column) carries two")
            }
        }
        // Ghost springs: one per free particle, soft.
        for (offset, edge) in lattice.edges.dropFirst(Lattice.cordEdgeCount).enumerated() {
            let particle = Lattice.hookCount + offset
            XCTAssertEqual(Int(edge.x), Lattice.ghost(of: particle))
            XCTAssertEqual(Int(edge.y), particle)
            XCTAssertEqual(lattice.edgeCompliances[Lattice.cordEdgeCount + offset], Lattice.shapeCompliance)
        }
        XCTAssertEqual(lattice.edgeCompliances[0], Lattice.cordCompliance)
    }

    func testDiamondsAreClosed() {
        // Two cords leaving a knot downward meet the same knot two rows
        // below, through the row between: the lattice is a proper diamond
        // mesh, not a tangle.
        let lattice = Lattice.rest
        var below: [Int: [Int]] = [:]
        for edge in lattice.edges.prefix(Lattice.cordEdgeCount) {
            below[Int(edge.x), default: []].append(Int(edge.y))
        }
        for row in 0 ..< (Lattice.knotRows.count - 1) {
            for column in 0 ..< 12 {
                let top = row == 0 ? Lattice.hook(column) : Lattice.knot(row: row - 1, column: column)
                let sides = below[top] ?? []
                XCTAssertEqual(sides.count, 2)
                let bottoms = sides.map { Set(below[$0] ?? []) }
                let shared = bottoms[0].intersection(bottoms[1])
                XCTAssertEqual(shared.count, 1, "row \(row) column \(column): the diamond closes on one knot")
                XCTAssertEqual(shared.first, Lattice.knot(row: row + 1, column: column), "directly below, two rows down")
            }
        }
    }

    // MARK: Skin

    func testSkinKeepsTheRestPoseAndFollowsItsCord() {
        let lattice = Lattice.rest
        // Three vertices: on a cord's midpoint, beside it, and at a knot.
        let edge = lattice.edges[7]
        let a = lattice.particles[Int(edge.x)], b = lattice.particles[Int(edge.y)]
        let mid = (a + b) * 0.5
        let side = mid + SIMD3<Float>(0.003, 0, 0.002)
        let restPositions = [mid, side, a]
        let restNormals = [SIMD3<Float>(0, 1, 0), simd_normalize(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 0, 1)]
        let skin = CoolBasketNetSkin(restPositions: restPositions, restNormals: restNormals, lattice: lattice)
        XCTAssertEqual(skin.vertexCount, 3)
        XCTAssertEqual(Int(skin.bindings[0].edge), 7)
        XCTAssertEqual(Int(skin.bindings[1].edge), 7)

        // At rest the skin is the identity.
        let rest = skin.posedPositions(particles: lattice.particles, lattice: lattice)
        for (posed, original) in zip(rest, restPositions) {
            XCTAssertEqual(simd_distance(posed, original), 0, accuracy: 1e-5)
        }

        // Move the whole lattice: the vertices move with it.
        let shift = SIMD3<Float>(0.1, -0.2, 0.05)
        let shifted = skin.posedPositions(particles: lattice.particles.map { $0 + shift }, lattice: lattice)
        for (posed, original) in zip(shifted, restPositions) {
            XCTAssertEqual(simd_distance(posed, original + shift), 0, accuracy: 1e-5)
        }

        // Swing the cord's lower end out sideways: the side vertex turns
        // with the cord and keeps its distance from it.
        var swung = lattice.particles
        swung[Int(edge.y)] = a + simd_quatf(angle: 0.6, axis: SIMD3<Float>(0, 0, 1)).act(b - a)
        let posed = skin.posedPositions(particles: swung, lattice: lattice)
        XCTAssertEqual(simd_distance(posed[2], a), 0, accuracy: 1e-5, "the knot vertex stays on the knot")
        let newMid = (a + swung[Int(edge.y)]) * 0.5
        XCTAssertEqual(simd_distance(posed[0], newMid), 0, accuracy: 1e-5, "the midpoint vertex follows the cord")
        XCTAssertEqual(simd_distance(posed[1], newMid), simd_distance(side, mid), accuracy: 1e-5, "the side vertex keeps its offset")
        XCTAssertGreaterThan(simd_distance(posed[1], side), 0.01, "and has moved")
    }

    func testSkinBindsAVertexOutsideEveryBandToTheNearestCord() {
        let lattice = Lattice.rest
        // Far above the net: nothing in range, the fallback searches all.
        let skin = CoolBasketNetSkin(restPositions: [SIMD3<Float>(0.2, 3.4, 0.38)], restNormals: [], lattice: lattice)
        XCTAssertEqual(skin.vertexCount, 1)
        let edge = lattice.edges[Int(skin.bindings[0].edge)]
        XCTAssertLessThan(Int(edge.x), Lattice.hookCount, "a top cord")
    }

    // MARK: Soft body

    private func makeWorld() -> JoltPhysicsBackend {
        var settings = JoltWorldSettings()
        settings.workerThreads = 0
        let backend = JoltPhysicsBackend(settings: settings)
        backend.configure(PhysicsWorldConfiguration())
        return backend
    }

    private func step(_ backend: JoltPhysicsBackend, seconds: Float) {
        let dt: Float = 1.0 / 60.0
        var elapsed: Float = 0
        while elapsed < seconds {
            backend.step(deltaTime: dt)
            elapsed += dt
        }
    }

    func testNetHangsStillAtRest() {
        let backend = makeWorld()
        let lattice = Lattice.rest
        guard let net = CoolBasketNet(backend: backend, origin: .zero, orientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), lattice: lattice) else {
            return XCTFail("the world refused the net")
        }
        step(backend, seconds: 3)
        net.update(partEntities: [])
        var worst: Float = 0
        for index in 0 ..< Lattice.cordParticleCount {
            worst = max(worst, simd_distance(net.particles[index], lattice.particles[index]))
        }
        XCTAssertLessThan(worst, 0.03, "the net keeps the artist's shape (worst drift \(worst) m)")
        net.remove()
    }

    func testBallDroppedThroughTheRimComesOutUnderTheNet() {
        let backend = makeWorld()
        let lattice = Lattice.rest
        let origin = SIMD3<Float>(1, 0, -2)
        let orientation = simd_quatf(angle: 0.7, axis: SIMD3<Float>(0, 1, 0))
        guard let net = CoolBasketNet(backend: backend, origin: origin, orientation: orientation, lattice: lattice) else {
            return XCTFail("the world refused the net")
        }
        step(backend, seconds: 1)

        let rimCenter = origin + orientation.act(SIMD3<Float>(Lattice.axis.x, CoolBasketScene.rimHeight, Lattice.axis.y))
        let ball: EntityID = 7
        backend.didAddBody(entity: ball, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(
                shape: .sphere(radius: CoolBasketScene.ballRadius),
                friction: 0.4,
                restitution: CoolBasketScene.ballRestitution
            ),
            mass: CoolBasketScene.ballMass,
            position: rimCenter + SIMD3<Float>(0, 0.6, 0)
        ))

        var touchedNet = false
        var lowest = Float.greatestFiniteMagnitude
        var exitedAt: Float?
        var elapsed: Float = 0
        while elapsed < 3, exitedAt == nil {
            backend.step(deltaTime: 1.0 / 60.0)
            elapsed += 1.0 / 60.0
            guard let state = backend.bodyState(for: ball) else { return XCTFail("the ball vanished") }
            lowest = min(lowest, state.position.y)
            net.update(partEntities: [])
            let bottom = net.particles[Lattice.scallop(0)]
            if simd_distance(bottom, lattice.particles[Lattice.scallop(0)]) > 0.05 { touchedNet = true }
            if state.position.y < Lattice.scallopHeight - CoolBasketScene.ballRadius - 0.1 { exitedAt = elapsed }
        }
        XCTAssertNotNil(exitedAt, "the ball fell out under the net (lowest \(lowest))")
        XCTAssertTrue(touchedNet, "and it flared the net on the way")
        if let state = backend.bodyState(for: ball) {
            let local = orientation.inverse.act(state.position - origin)
            let offAxis = simd_length(SIMD2<Float>(local.x - Lattice.axis.x, local.z - Lattice.axis.y))
            XCTAssertLessThan(offAxis, 0.15, "through the net, not around it")
        }

        // The net settles back.
        step(backend, seconds: 3)
        net.update(partEntities: [])
        var worst: Float = 0
        for index in 0 ..< Lattice.cordParticleCount {
            worst = max(worst, simd_distance(net.particles[index], lattice.particles[index]))
        }
        XCTAssertLessThan(worst, 0.04, "the net returned to shape (worst drift \(worst) m)")
        net.remove()
    }

    func testBallRestingOnTheRimEdgeDoesNotFallThroughTheCords() {
        // A ball placed just inside the rim over the net's wall, at rest:
        // with the artist's radii it slides down through the mouth (the net
        // is ball-sized), but never sideways through a cord.
        let backend = makeWorld()
        let lattice = Lattice.rest
        guard let net = CoolBasketNet(backend: backend, origin: .zero, orientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), lattice: lattice) else {
            return XCTFail("the world refused the net")
        }
        let ball: EntityID = 8
        let start = SIMD3<Float>(Lattice.axis.x + 0.08, Lattice.hookHeight + 0.2, Lattice.axis.y)
        backend.didAddBody(entity: ball, descriptor: PhysicsBodyDescriptor(
            motionType: .dynamic,
            collider: PhysicsColliderDescriptor(shape: .sphere(radius: CoolBasketScene.ballRadius), friction: 0.4, restitution: 0.3),
            mass: CoolBasketScene.ballMass,
            position: start
        ))
        var maxOffAxis: Float = 0
        for _ in 0 ..< 180 {
            backend.step(deltaTime: 1.0 / 60.0)
            guard let state = backend.bodyState(for: ball) else { return XCTFail("the ball vanished") }
            if state.position.y > Lattice.scallopHeight - CoolBasketScene.ballRadius {
                maxOffAxis = max(maxOffAxis, simd_length(SIMD2<Float>(state.position.x - Lattice.axis.x, state.position.z - Lattice.axis.y)))
            }
        }
        XCTAssertLessThan(maxOffAxis, Lattice.hookRadius, "while inside the net the ball stayed inside its walls")
        net.remove()
    }
}
