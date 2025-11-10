//
//  Game.swift
//  Untoldios
//
//  Created by Harold Serrano on 11/9/25.
//

import simd
import UntoldEngine


// Build the demo scene procedurally.
private func buildSceneInCode() {
    // Stadium (static mesh)
    let stadium = createEntity()
    setEntityMesh(entityId: stadium, filename: "stadium", withExtension: "usdz")
    translateBy(entityId: stadium, position: simd_float3(0.0, -5.0, -20.0))

    // Player (animated, named for lookup)
    let player = createEntity()
    setEntityMesh(entityId: player, filename: "redplayer", withExtension: "usdz", flip: false)
    setEntityName(entityId: player, name: "player")
    translateBy(entityId: player, position: simd_float3(0.0, -5.0, -20.0))
    rotateTo(entityId: player, angle: 0, axis: simd_float3(0.0, 1.0, 0.0))
    setEntityAnimations(entityId: player, filename: "running", withExtension: "usdz", name: "running")
    setEntityAnimations(entityId: player, filename: "idle", withExtension: "usdz", name: "idle")
    setEntityKinetics(entityId: player)
    
    //play animation
    changeAnimation(entityId: player, name: "running")

    // Ball (named for lookup)
    let ball = createEntity()
    setEntityMesh(entityId: ball, filename: "ball", withExtension: "usdz")
    setEntityName(entityId: ball, name: "ball")
    translateBy(entityId: ball, position: simd_float3(0.0, -4.6, -17.0))
    setEntityKinetics(entityId: ball)

    // lighting
    ambientIntensity = 0.4
}

public func loadAssets() {
    buildSceneInCode()
}
