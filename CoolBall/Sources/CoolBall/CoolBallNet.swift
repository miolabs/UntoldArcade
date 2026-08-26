//
//  CoolBallNet.swift
//  CoolBall
//
//  The goal net: a small CPU XPBD cloth. Particles form a grid pinned along
//  the crossbar (top row) and staked to the ground behind the goal line
//  (bottom row); structural + shear distance constraints with a little
//  compliance make it hang and billow like netting. The ball is a sphere
//  collider the cloth wraps around, so a shot visibly bulges the net.
//
//  Rendering rides the engine's standard mesh path: the net entity is a
//  PlaneNode whose grid matches the solver's, and each frame the solver
//  writes particle positions straight into the mesh's (public) MetalKit
//  position buffer. The cord look comes from an alpha-masked grid texture,
//  so the holes deform with the cloth.
//

import Foundation
import Metal
import MetalKit
import ModelIO
import simd
import UntoldEngine

/// Pure-CPU XPBD cloth grid — headless, so unit tests can run it without
/// Metal or an engine scene.
public final class CoolBallNetSolver: @unchecked Sendable {
    public struct Constraint {
        var a: Int
        var b: Int
        var restLength: Float
        var compliance: Float
    }

    public let columns: Int
    public let rows: Int
    public private(set) var positions: [SIMD3<Float>]
    private var previousPositions: [SIMD3<Float>]
    private var inverseMasses: [Float]
    private var constraints: [Constraint] = []

    public var gravity = SIMD3<Float>(0, -9.81, 0)
    /// Velocity damping per second (nets are heavily air-damped).
    public var damping: Float = 1.4
    public var substeps = 3
    let floorY: Float

    /// Builds the net surface between two rails: the top row spans
    /// `topLeft → topRight` (crossbar), the bottom row spans the same rails
    /// dropped to the stake line (`bottomOffset` from the top corners).
    /// Interior rows are interpolated, so the rest pose is the final drape.
    public init(
        columns: Int,
        rows: Int,
        topLeft: SIMD3<Float>,
        topRight: SIMD3<Float>,
        bottomOffset: SIMD3<Float>,
        floorY: Float,
        compliance: Float = 2e-5
    ) {
        self.columns = columns
        self.rows = rows
        self.floorY = floorY

        var initial: [SIMD3<Float>] = []
        initial.reserveCapacity(columns * rows)
        for row in 0 ..< rows {
            let v = Float(row) / Float(rows - 1)
            for column in 0 ..< columns {
                let u = Float(column) / Float(columns - 1)
                let top = simd_mix(topLeft, topRight, SIMD3<Float>(repeating: u))
                initial.append(top + bottomOffset * v)
            }
        }
        positions = initial
        previousPositions = initial
        inverseMasses = [Float](repeating: 1.0, count: columns * rows)

        // Pins: crossbar row and ground stakes.
        for column in 0 ..< columns {
            inverseMasses[index(column, 0)] = 0
            inverseMasses[index(column, rows - 1)] = 0
        }

        // Structural constraints along rows/columns, shear across cells.
        func addConstraint(_ a: Int, _ b: Int, _ compliance: Float) {
            constraints.append(Constraint(
                a: a, b: b,
                restLength: simd_length(initial[a] - initial[b]),
                compliance: compliance
            ))
        }
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let i = index(column, row)
                if column + 1 < columns { addConstraint(i, index(column + 1, row), compliance) }
                if row + 1 < rows { addConstraint(i, index(column, row + 1), compliance) }
                if column + 1 < columns, row + 1 < rows {
                    addConstraint(i, index(column + 1, row + 1), compliance * 8)
                    addConstraint(index(column + 1, row), index(column, row + 1), compliance * 8)
                }
            }
        }
    }

    public func index(_ column: Int, _ row: Int) -> Int {
        row * columns + column
    }

    /// Advances the cloth and resolves collision against one sphere (the ball).
    public func step(
        deltaTime: Float,
        sphereCenter: SIMD3<Float>?,
        sphereRadius: Float
    ) {
        guard deltaTime > 0 else { return }
        let dt = min(deltaTime, 1.0 / 30.0) / Float(substeps)
        let dampingFactor = max(0.0, 1.0 - damping * dt)
        let margin: Float = 0.015

        for _ in 0 ..< substeps {
            // Integrate.
            for i in 0 ..< positions.count where inverseMasses[i] > 0 {
                let velocity = (positions[i] - previousPositions[i]) / dt * dampingFactor
                previousPositions[i] = positions[i]
                positions[i] += (velocity + gravity * dt) * dt
            }

            // Distance constraints (XPBD, one Gauss-Seidel sweep per substep).
            for constraint in constraints {
                let wA = inverseMasses[constraint.a]
                let wB = inverseMasses[constraint.b]
                let wSum = wA + wB
                guard wSum > 0 else { continue }
                let delta = positions[constraint.b] - positions[constraint.a]
                let length = simd_length(delta)
                guard length > 1e-6 else { continue }
                let alpha = constraint.compliance / (dt * dt)
                let correction = (length - constraint.restLength) / (wSum + alpha)
                let direction = delta / length
                positions[constraint.a] += direction * (correction * wA)
                positions[constraint.b] -= direction * (correction * wB)
            }

            // Ball and ground.
            for i in 0 ..< positions.count where inverseMasses[i] > 0 {
                if let center = sphereCenter {
                    let offset = positions[i] - center
                    let distance = simd_length(offset)
                    let minDistance = sphereRadius + margin
                    if distance < minDistance, distance > 1e-6 {
                        positions[i] = center + offset / distance * minDistance
                    }
                }
                if positions[i].y < floorY {
                    positions[i].y = floorY
                }
            }
        }
    }
}

/// Binds the solver to a rendered net entity and the backend's catch plane.
public final class CoolBallNet: @unchecked Sendable {
    public private(set) var solver: CoolBallNetSolver?
    public private(set) var entity: EntityID = .invalid

    /// Grid resolution — must match the net texture's cell count.
    static let cells = (x: 24, y: 16)
    /// How far behind the goal line the net is staked to the ground.
    static let groundDepth: Float = 0.45

    private var positionBuffer: (any MTLBuffer)?
    private var positionOffset = 0
    /// Mesh vertex slot → solver particle, derived from rest positions so the
    /// mapping is independent of ModelIO's internal vertex ordering.
    private var vertexToParticle: [Int] = []

    public init() {}

    /// The static backstop plane the physics backend uses so the ball is
    /// caught (killed bounce) instead of sailing through the visual net.
    public static func catchPlane(
        goalCenter: SIMD3<Float>,
        forward: SIMD3<Float>,
        width: Float,
        height: Float
    ) -> CoolBallWorldPlane {
        let topCenter = goalCenter + SIMD3<Float>(0, height, 0)
        let bottomCenter = goalCenter - forward * Self.groundDepth
        let center = (topCenter + bottomCenter) * 0.5
        let up = simd_normalize(topCenter - bottomCenter)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
        let normal = simd_normalize(simd_cross(right, up))
        // Normal must face the goal mouth so the ball is pushed back out.
        let facingCorrection: Float = simd_dot(normal, forward) < 0 ? -1 : 1
        return CoolBallWorldPlane(
            id: UUID(),
            center: center,
            normal: normal * facingCorrection,
            tangentU: right,
            tangentV: up,
            extentU: width * 0.5,
            extentV: simd_length(topCenter - bottomCenter) * 0.5,
            restitutionScale: 0.12
        )
    }

    /// A short vertical backstop at the stake line so a ball that slides
    /// down the pocket stays in it instead of rolling out the open back.
    public static func groundSkirtPlane(
        goalCenter: SIMD3<Float>,
        forward: SIMD3<Float>,
        width: Float
    ) -> CoolBallWorldPlane {
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
        // Short enough that the V-gap between the slanted net and the skirt
        // stays wider than the ball, so it settles to the floor instead of
        // wedging; tall enough to block a ball rolling along the floor.
        let skirtHeight: Float = 0.2
        return CoolBallWorldPlane(
            id: UUID(),
            center: goalCenter - forward * Self.groundDepth
                + SIMD3<Float>(0, skirtHeight * 0.5, 0),
            normal: simd_normalize(forward),
            tangentU: right,
            tangentV: SIMD3<Float>(0, 1, 0),
            extentU: width * 0.5,
            extentV: skirtHeight * 0.5,
            restitutionScale: 0.12
        )
    }

    /// Creates the net entity and solver. Main actor: node creation.
    @MainActor
    public func build(
        goalCenter: SIMD3<Float>,
        forward: SIMD3<Float>,
        width: Float,
        height: Float,
        floorY: Float
    ) {
        destroy()

        let columns = Self.cells.x + 1
        let rows = Self.cells.y + 1
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
        let topLeft = goalCenter + SIMD3<Float>(0, height, 0) - right * (width * 0.5)
        let topRight = goalCenter + SIMD3<Float>(0, height, 0) + right * (width * 0.5)
        let bottomOffset = SIMD3<Float>(0, -height, 0) - forward * Self.groundDepth
        solver = CoolBallNetSolver(
            columns: columns,
            rows: rows,
            topLeft: topLeft,
            topRight: topRight,
            bottomOffset: bottomOffset,
            floorY: floorY
        )

        // The rendered grid: cell counts match the solver so the alpha-mask
        // cords line up with the simulated cords. The rest depth is the slant
        // length from crossbar to stake line, matching the solver's rows.
        let slant = simd_length(bottomOffset)
        let node = PlaneNode(
            width: width,
            depth: slant,
            segments: [UInt32(Self.cells.x), UInt32(Self.cells.y)],
            name: "CoolBall.net"
        )
        .baseColor(1.0, 1.0, 1.0)
        .roughness(0.85)
        .metallic(0.0)
        entity = node.entityID

        if let textureURL = Bundle.module.url(forResource: "net_baseColor", withExtension: "png") {
            updateMaterialTexture(entityId: entity, textureType: .baseColor, path: textureURL)
            updateMaterialAlphaMode(entityId: entity, mode: .mask)
        }

        bindMesh(width: width, depth: slant)

        // Identity transform: the solver writes world-space positions. The
        // culling bounds must cover the whole drape.
        translateTo(entityId: entity, position: .zero)
        if let transform = scene.get(component: LocalTransformComponent.self, for: entity) {
            let lows = SIMD3<Float>(
                min(topLeft.x, topRight.x) - 0.5,
                floorY - 0.2,
                goalCenter.z - Self.groundDepth - 0.5
            )
            let highs = SIMD3<Float>(
                max(topLeft.x, topRight.x) + 0.5,
                goalCenter.y + height + 0.5,
                goalCenter.z + 0.5
            )
            transform.boundingBox = (min: lows, max: highs)
        }

        writeVertices()
    }

    /// Locates the mesh's position buffer and derives the vertex→particle map
    /// from the plane's rest layout (x across width, z across depth).
    @MainActor
    private func bindMesh(width: Float, depth: Float) {
        guard let solver,
              let renderComponent = scene.get(component: RenderComponent.self, for: entity),
              let mesh = renderComponent.mesh.first
        else {
            print("CoolBall: net mesh unavailable — net will not render")
            return
        }

        guard let positionAttribute = vertexDescriptor.model
            .attributeNamed(MDLVertexAttributePosition)
        else {
            print("CoolBall: no position attribute in model descriptor")
            return
        }
        let bufferIndex = positionAttribute.bufferIndex
        let buffers = mesh.metalKitMesh.vertexBuffers
        guard bufferIndex < buffers.count else {
            print("CoolBall: position buffer index out of range")
            return
        }
        let meshBuffer = buffers[bufferIndex]
        positionBuffer = meshBuffer.buffer
        positionOffset = meshBuffer.offset

        let vertexCount = mesh.metalKitMesh.vertexCount
        let stride = MemoryLayout<simd_float4>.stride
        let base = meshBuffer.buffer.contents()
            .advanced(by: meshBuffer.offset)
            .assumingMemoryBound(to: simd_float4.self)

        // Rest pose: XZ plane centered at the origin. Map each vertex to the
        // nearest grid node.
        let columns = solver.columns
        let rows = solver.rows
        vertexToParticle = (0 ..< vertexCount).map { vertexIndex in
            let position = base[vertexIndex]
            let u = (position.x / width) + 0.5
            let v = (position.z / depth) + 0.5
            let column = min(max(Int((u * Float(columns - 1)).rounded()), 0), columns - 1)
            let row = min(max(Int((v * Float(rows - 1)).rounded()), 0), rows - 1)
            return solver.index(column, row)
        }
    }

    /// Advances the cloth and pushes the deformed grid to the GPU.
    public func step(
        deltaTime: Float,
        ballCenter: SIMD3<Float>?,
        ballRadius: Float
    ) {
        guard let solver else { return }
        solver.step(
            deltaTime: deltaTime,
            sphereCenter: ballCenter,
            sphereRadius: ballRadius
        )
        writeVertices()
    }

    private func writeVertices() {
        guard let solver, let positionBuffer, !vertexToParticle.isEmpty else { return }
        let base = positionBuffer.contents()
            .advanced(by: positionOffset)
            .assumingMemoryBound(to: simd_float4.self)
        for (vertexIndex, particleIndex) in vertexToParticle.enumerated() {
            let p = solver.positions[particleIndex]
            base[vertexIndex] = simd_float4(p.x, p.y, p.z, 1.0)
        }
        #if os(macOS)
        if positionBuffer.storageMode == .managed {
            positionBuffer.didModifyRange(
                positionOffset ..< (positionOffset + vertexToParticle.count * MemoryLayout<simd_float4>.stride)
            )
        }
        #endif
    }

    public func destroy() {
        if entity != .invalid {
            destroyEntity(entityId: entity)
        }
        entity = .invalid
        solver = nil
        positionBuffer = nil
        vertexToParticle = []
    }
}
