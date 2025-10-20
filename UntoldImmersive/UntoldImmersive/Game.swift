//
//  Game.swift
//  UntoldImmersive
//
//  Created by Harold Serrano on 10/15/25.
//

import simd
import UntoldEngine

// Build the demo scene procedurally.
private func buildSceneInCode() {
    // Stadium (static mesh)
    let stadium = createEntity()
    setEntityMesh(entityId: stadium, filename: "stadium", withExtension: "usdc")
    translateBy(entityId: stadium, position: simd_float3(0.0, 0.0, 0.0))

    // Player (animated, named for lookup)
    let player = createEntity()
    setEntityMesh(entityId: player, filename: "redplayer", withExtension: "usdc", flip: false)
    setEntityName(entityId: player, name: "player")
    rotateTo(entityId: player, angle: 0, axis: simd_float3(0.0, 1.0, 0.0))
    setEntityAnimations(entityId: player, filename: "running", withExtension: "usdc", name: "running")
    setEntityAnimations(entityId: player, filename: "idle", withExtension: "usdc", name: "idle")
    setEntityKinetics(entityId: player)

    // Ball (named for lookup)
    let ball = createEntity()
    setEntityMesh(entityId: ball, filename: "ball", withExtension: "usdc")
    setEntityName(entityId: ball, name: "ball")
    translateBy(entityId: ball, position: simd_float3(0.0, 0.6, 3.0))
    setEntityKinetics(entityId: ball)

    // lighting
    ambientIntensity = 0.4
}

public func loadAssets() {
    buildSceneInCode()
}
