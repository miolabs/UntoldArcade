// Builds a bowling-pin mesh by revolving a profile (lathe) and exports it
// with ModelIO. Usage: swift make_pin.swift <outDir>
import Foundation
import MetalKit
import ModelIO
import simd

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// Regulation-ish pin, metres: (radius, height). Height 0.381, max radius 0.0605.
let profile: [(r: Float, y: Float)] = [
    (0.000, 0.000), (0.030, 0.000), (0.040, 0.004), (0.050, 0.020), (0.058, 0.060),
    (0.0605, 0.110), (0.058, 0.150), (0.050, 0.190), (0.040, 0.220), (0.031, 0.250),
    (0.026, 0.275), (0.026, 0.300), (0.031, 0.320), (0.036, 0.340), (0.034, 0.362),
    (0.024, 0.376), (0.010, 0.381), (0.000, 0.381),
]
let segments = 32
var positions: [SIMD3<Float>] = []
var normals: [SIMD3<Float>] = []
var uvs: [SIMD2<Float>] = []
var indices: [UInt32] = []
let rings = profile.count
for (i, p) in profile.enumerated() {
    // Normal from the profile tangent.
    let prev = profile[max(i - 1, 0)], next = profile[min(i + 1, rings - 1)]
    let dr = next.r - prev.r, dy = next.y - prev.y
    let n2 = simd_normalize(SIMD2<Float>(dy, -dr)) // outward normal in (r, y)
    for s in 0 ... segments {
        let a = Float(s) / Float(segments) * 2 * .pi
        let c = cosf(a), sn = sinf(a)
        positions.append(SIMD3<Float>(p.r * c, p.y, p.r * sn))
        let n = p.r < 1e-4 ? SIMD3<Float>(0, p.y > 0.1 ? 1 : -1, 0) : simd_normalize(SIMD3<Float>(n2.x * c, n2.y, n2.x * sn))
        normals.append(n)
        uvs.append(SIMD2<Float>(Float(s) / Float(segments), p.y / 0.381))
    }
}
for i in 0 ..< rings - 1 {
    for s in 0 ..< segments {
        let a = UInt32(i * (segments + 1) + s), b = a + 1
        let c = UInt32((i + 1) * (segments + 1) + s), d = c + 1
        indices += [a, c, b, b, c, d]
    }
}
let device = MTLCreateSystemDefaultDevice()!
let allocator = MTKMeshBufferAllocator(device: device)
struct V { var p: SIMD3<Float>; var n: SIMD3<Float>; var t: SIMD2<Float> }
var verts = (0 ..< positions.count).map { V(p: positions[$0], n: normals[$0], t: uvs[$0]) }
let vdata = Data(bytes: &verts, count: verts.count * MemoryLayout<V>.stride)
let vbuf = allocator.newBuffer(with: vdata, type: .vertex)
let idata = Data(bytes: &indices, count: indices.count * 4)
let ibuf = allocator.newBuffer(with: idata, type: .index)
let desc = MDLVertexDescriptor()
desc.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
desc.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 16, bufferIndex: 0)
desc.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 32, bufferIndex: 0)
desc.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<V>.stride)
let submesh = MDLSubmesh(indexBuffer: ibuf, indexCount: indices.count, indexType: .uInt32, geometryType: .triangles, material: nil)
let mesh = MDLMesh(vertexBuffer: vbuf, vertexCount: verts.count, descriptor: desc, submeshes: [submesh])
mesh.name = "BowlingPin"
let material = MDLMaterial(name: "PinMaterial", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, string: "pin_baseColor.png"))
material.setProperty(MDLMaterialProperty(name: "roughness", semantic: .roughness, float: 0.35))
material.setProperty(MDLMaterialProperty(name: "metallic", semantic: .metallic, float: 0.0))
submesh.material = material
let asset = MDLAsset(bufferAllocator: allocator)
asset.add(mesh)
print("bounds:", mesh.boundingBox.minBounds, mesh.boundingBox.maxBounds, "verts:", verts.count, "tris:", indices.count / 3)
for ext in ["usdc", "usda", "obj"] {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("bowling_pin.\(ext)")
    do {
        try asset.export(to: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("exported \(ext): \(size) bytes  canExport=\(MDLAsset.canExportFileExtension(ext))")
        let back = MDLAsset(url: url)
        print("  re-import: objects=\(back.count) bounds=\(back.boundingBox.minBounds) \(back.boundingBox.maxBounds)")
    } catch { print("export \(ext) failed: \(error)") }
}
