//
//  EyeMaterialLoader.swift
//  RealityKitPresenter spike
//
//  Loads Resources/EyeMaterial.usda as a ShaderGraphMaterial and sets its two parameters.
//  When the graph fails to load, an UnlitMaterial stands in (no eye switch: both grids
//  show in both eyes) so the rest of the spike can still run; the log says so.
//

import Foundation
import RealityKit

enum EyeMaterialError: Error, CustomStringConvertible {
    case resourceMissing

    var description: String { "EyeMaterial.usda is not in the bundle" }
}

@MainActor
enum EyeMaterialLoader {
    static let primPath = "/Root/EyeMaterial"
    static let fileName = "EyeMaterial.usda"

    static func load() async throws -> ShaderGraphMaterial {
        guard let url = Bundle.main.url(forResource: "EyeMaterial", withExtension: "usda") else {
            throw EyeMaterialError.resourceMissing
        }
        var material = try await ShaderGraphMaterial(named: primPath, from: url)
        material.faceCulling = .none
        return material
    }

    /// `eye` is 1 for the left eye, 2 for the right (the graph's convention).
    static func configure(_ material: inout ShaderGraphMaterial, eye: Int, texture: TextureResource) throws {
        try material.setParameter(name: "colorTexture", value: .textureResource(texture))
        try material.setParameter(name: "eye", value: .int(Int32(eye)))
    }

    static func fallback(texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial(texture: texture)
        material.blending = .transparent(opacity: .init(texture: .init(texture)))
        material.opacityThreshold = 0.5
        material.faceCulling = .none
        return material
    }
}
