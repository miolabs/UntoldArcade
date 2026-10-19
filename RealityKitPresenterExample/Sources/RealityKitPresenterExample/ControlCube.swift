//
//  ControlCube.swift
//  RealityKitPresenterExample
//
//  A plain RealityKit cube beside the engine's cubes, drawn by RealityKit itself: the control
//  for the edge measurements on the headset's captures. The engine's cubes reach the display
//  through the presenter (the eye texture, the grid, the edge band) and then the device's own
//  render of those entities and the compositor; the control reaches it through the device's
//  render and the compositor alone. One capture holds both kinds of edge, measured by the same
//  script (`cube_tops2.py` beside the presenter's proposal in the engine repository): the same
//  wobble on the control is the device's render or the capture, which no presenter change can
//  touch; a straight control beside a wavy engine cube is the presenter's materials under the
//  device's render. The cube is a child of the presenter's root beside the grid entities, so it
//  is world-locked like them, and nothing the presenter manages; the engine's scene does not
//  know it.
//

import RealityKit
import UIKit

enum ControlCube {
    /// The engine cubes' edge (`ExampleScene`: `BasicPrimitives.createCube(extent: 0.2)`).
    static let edgeMetres: Float = 0.2

    /// Where the cube stands. The engine's cubes are at x = -0.35, 0 and 0.35 on the slab's
    /// top plane, their centres at y = 1.025 and z = -1.6 in the space's world (its origin on
    /// the floor where the session began, the engine's own); the control one step further
    /// right at the same gap and the same height, so that a capture frames it with them. The
    /// slab is 1.2 m wide, so the control stands just past its end, on the plane of its top;
    /// its top edge, the one measured, is against the room as the engine cubes' are. No yaw,
    /// as the middle cube (the engine's outer cubes are yawed 20°), so its far top edge is one
    /// straight line in a capture, like the middle cube's.
    static let position = SIMD3<Float>(0.7, 1.025, -1.6)

    /// About the engine cubes' colour as the engine draws them: their base colour is white,
    /// the sun straight above lights their tops near white and the sky their sides a pale blue
    /// (sRGB about 0.63, 0.69, 0.77 in a simulator picture; the pale blue the capture scripts
    /// mask on, saturation over 15 of 255 in OpenCV's HSV). A lit material shades under the
    /// room's light, the top brighter and the sides darker, and a warm room greys it: with
    /// that pale blue as the base the simulator's room read it at saturation 18, at the
    /// mask's floor; this bluer base reads about the engine's sides there (top 0.67, 0.71,
    /// 0.77, sides 0.50, 0.55, 0.61) with room to spare for a warmer one.
    static let color = UIColor(red: 0.70, green: 0.78, blue: 0.92, alpha: 1)

    /// The cube at its place, enabled: a lit `SimpleMaterial` (roughness 0.4 as the engine's
    /// cubes, not metallic), which shades under the room's light as the engine's cubes do under
    /// their sun; unlit it would be one flat colour on every face.
    @MainActor
    static func makeEntity() -> ModelEntity {
        let material = SimpleMaterial(color: color, roughness: 0.4, isMetallic: false)
        let entity = ModelEntity(mesh: .generateBox(size: edgeMetres), materials: [material])
        entity.name = "Control cube"
        entity.position = position
        return entity
    }
}
