//
//  SplatSynthesizer.swift
//  SplatTwin
//
//  Builds a Gaussian-splat "capture" of a primitive's surface so the demo can swap between a
//  mesh and its splat twin without shipping a real scan: splats are scattered over the cube,
//  sphere or cylinder surface, shaded by a fixed light (a capture bakes its lighting in), and
//  written to a `.untoldgs` file the engine loads like any cooked payload.
//

import Foundation
import simd
import UntoldEngine

enum SplatSynthesizer {
    /// The primitives the demo knows how to cover with splats, matching `BasicPrimitives`.
    enum Shape: Equatable {
        /// `BasicPrimitives.createCube(extent:)`: an axis-aligned box of edge `extent`.
        case cube(extent: Float)
        /// `BasicPrimitives.createSphere(extent:)`: a sphere of diameter `extent`.
        case sphere(extent: Float)
        /// `BasicPrimitives.createCylinder(height:radius:)`: axis along +Y, centred.
        case cylinder(height: Float, radius: Float)

        var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>) {
            switch self {
            case let .cube(extent):
                let h = extent / 2
                return (SIMD3(-h, -h, -h), SIMD3(h, h, h))
            case let .sphere(extent):
                let r = extent / 2
                return (SIMD3(-r, -r, -r), SIMD3(r, r, r))
            case let .cylinder(height, radius):
                return (SIMD3(-radius, -height / 2, -radius), SIMD3(radius, height / 2, radius))
            }
        }
    }

    /// The light baked into the splat colours when the caller has no scene light to match;
    /// the demo passes its sun's direction so the "capture" agrees with the lit mesh.
    static let defaultLightDirection = simd_normalize(SIMD3<Float>(0.35, 1.0, 0.55))

    /// Splats over the surface of `shape`. `spacing` is the distance between neighbouring splat
    /// centres in metres; each splat is a flat disc a little wider than the spacing so the cover
    /// closes, lying in the surface with its thin axis along the normal.
    static func splats(
        for shape: Shape,
        baseColor: SIMD3<Float>,
        spacing: Float,
        lightDirection: SIMD3<Float> = defaultLightDirection,
        seed: UInt64 = 1
    ) -> [UntoldGSSplat] {
        let light = simd_normalize(lightDirection)
        var rng = SplitMix64(seed: seed)
        var result: [UntoldGSSplat] = []

        func add(position: SIMD3<Float>, normal: SIMD3<Float>, checker: Float) {
            let unitNormal = simd_normalize(normal)
            // A little in-surface jitter breaks the grid up the way a real capture would.
            let jitter = spacing * 0.15
            let tangent = perpendicular(to: unitNormal)
            let bitangent = simd_cross(unitNormal, tangent)
            let offset = tangent * rng.nextFloat(in: -jitter ... jitter) + bitangent * rng.nextFloat(in: -jitter ... jitter)
            result.append(UntoldGSSplat(
                position: position + offset,
                scale: SIMD3(spacing * 0.8, spacing * 0.8, spacing * 0.12),
                rotation: rotation(alignedTo: unitNormal),
                color: shaded(baseColor, normal: unitNormal, lightDirection: light, checker: checker),
                opacity: 0.95
            ))
        }

        switch shape {
        case let .cube(extent):
            let h = extent / 2
            let n = max(2, Int((extent / spacing).rounded()))
            let step = extent / Float(n)
            let faces: [(normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
                (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
                (SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
                (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
                (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
                (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
                (SIMD3(0, 0, -1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
            ]
            for face in faces {
                for i in 0 ..< n {
                    for j in 0 ..< n {
                        let a = -h + step * (Float(i) + 0.5)
                        let b = -h + step * (Float(j) + 0.5)
                        let position = face.normal * h + face.u * a + face.v * b
                        let checker: Float = (i / max(1, n / 4) + j / max(1, n / 4)) % 2 == 0 ? 1 : 0
                        add(position: position, normal: face.normal, checker: checker)
                    }
                }
            }

        case let .sphere(extent):
            let r = extent / 2
            let count = max(64, Int((4 * Float.pi * r * r) / (spacing * spacing)))
            let golden = Float.pi * (3 - Float(5).squareRoot())
            for i in 0 ..< count {
                let y = 1 - (Float(i) + 0.5) / Float(count) * 2
                let radiusAtY = (1 - y * y).squareRoot()
                let theta = golden * Float(i)
                let normal = SIMD3(cos(theta) * radiusAtY, y, sin(theta) * radiusAtY)
                let bands: Float = Int((theta / (Float.pi / 4)).rounded(.down)) % 2 == 0 ? 1 : 0
                add(position: normal * r, normal: normal, checker: bands)
            }

        case let .cylinder(height, radius):
            let circumference = 2 * Float.pi * radius
            let around = max(8, Int((circumference / spacing).rounded()))
            let along = max(2, Int((height / spacing).rounded()))
            for i in 0 ..< around {
                let angle = 2 * Float.pi * (Float(i) + 0.5) / Float(around)
                let normal = SIMD3(cos(angle), 0, sin(angle))
                for j in 0 ..< along {
                    let y = -height / 2 + height * (Float(j) + 0.5) / Float(along)
                    let checker: Float = (i / max(1, around / 8) + j / max(1, along / 3)) % 2 == 0 ? 1 : 0
                    add(position: normal * radius + SIMD3(0, y, 0), normal: normal, checker: checker)
                }
            }
            for sign: Float in [1, -1] {
                let normal = SIMD3<Float>(0, sign, 0)
                let rings = max(1, Int((radius / spacing).rounded()))
                for ring in 0 ..< rings {
                    let ringRadius = radius * (Float(ring) + 0.5) / Float(rings)
                    let count = max(1, Int((2 * Float.pi * ringRadius / spacing).rounded()))
                    for k in 0 ..< count {
                        let angle = 2 * Float.pi * Float(k) / Float(count)
                        let position = SIMD3(cos(angle) * ringRadius, sign * height / 2, sin(angle) * ringRadius)
                        add(position: position, normal: normal, checker: Float(ring % 2))
                    }
                }
            }
        }
        return result
    }

    /// Writes the twin of `shape` to `directory/<name>.untoldgs` unless a file with the same
    /// name and version is already there, and returns its URL.
    static func twinFile(
        for shape: Shape,
        baseColor: SIMD3<Float>,
        spacing: Float,
        lightDirection: SIMD3<Float> = defaultLightDirection,
        name: String,
        in directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-v\(fileVersion).untoldgs")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let splats = splats(for: shape, baseColor: baseColor, spacing: spacing, lightDirection: lightDirection)
        var options = UntoldGSWriteOptions()
        options.boundingBoxMin = shape.boundingBox.min
        options.boundingBoxMax = shape.boundingBox.max
        try UntoldGSFormat.write(splats: splats, options: options, to: url)
        return url
    }

    /// Bump when the synthesis changes so stale cached files are regenerated.
    static let fileVersion = 1
    /// Shade of a face turned away from the light: a capture keeps its bounce light.
    static let ambientFloor: Float = 0.45

    // MARK: - Helpers

    /// Lambert from the baked light plus an ambient floor, with a soft checker so the "capture"
    /// has some texture; colours are display-referred like a real capture's.
    static func shaded(_ base: SIMD3<Float>, normal: SIMD3<Float>, lightDirection: SIMD3<Float>, checker: Float) -> SIMD3<Float> {
        let lambert = max(0, simd_dot(normal, simd_normalize(lightDirection)))
        let shade = ambientFloor + (1 - ambientFloor) * lambert
        let texture: Float = 1 - 0.08 * checker
        return simd_clamp(base * shade * texture, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    /// The rotation taking +Z (the disc's thin axis) to `normal`.
    static func rotation(alignedTo normal: SIMD3<Float>) -> simd_quatf {
        let z = SIMD3<Float>(0, 0, 1)
        let d = simd_dot(z, normal)
        if d > 0.9999 {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        if d < -0.9999 {
            return simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
        }
        return simd_quatf(from: z, to: normal)
    }

    static func perpendicular(to n: SIMD3<Float>) -> SIMD3<Float> {
        let helper = abs(n.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return simd_normalize(simd_cross(n, helper))
    }
}

/// Deterministic generator so the twins look the same on every run.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnitFloat() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + nextUnitFloat() * (range.upperBound - range.lowerBound)
    }
}
