//
//  CoolMirrorGame.swift
//  CoolMirror
//
//  Virtual-mirror demo core: a rigged character standing in front of the user,
//  playing animation clips (live mocap arrives in a later phase), with the
//  engine's deformation stack switchable at runtime so skinning quality can be
//  compared live. Owns no rendering — the engine draws the character; this
//  class only spawns it and forwards control changes.
//

import simd
import UntoldEngine

/// Animation clips bundled with the demo character.
public enum CoolMirrorClip: String, CaseIterable, Sendable {
    case running
    case idle
}

/// Skinning paths the mirror can switch between live.
public enum CoolMirrorSkinningPath: String, CaseIterable, Sendable {
    case vertexShader
    case computeLBS
    case computeDQS
    case computeDDM
}

@MainActor
public final class CoolMirrorGame {
    public private(set) var characterId: EntityID?

    // Mirror framing: the character stands ~1.6 m in front of the world origin
    // and faces back toward the user like a reflection.
    private let characterPosition = simd_float3(0.0, 0.0, -1.6)
    private var skinningPath: CoolMirrorSkinningPath = .vertexShader
    private var currentClip: CoolMirrorClip = .idle

    public init() {}

    public func start() {
        let character = createEntity()
        setEntityName(entityId: character, name: "MirrorCharacter")
        characterId = character

        setEntityMeshAsync(entityId: character, filename: "redplayer", withExtension: "untold") { [weak self] _ in
            guard let self, let characterId = self.characterId else { return }
            for clip in CoolMirrorClip.allCases {
                setEntityAnimations(
                    entityId: characterId,
                    filename: clip.rawValue,
                    withExtension: "untold",
                    name: clip.rawValue
                )
            }
            translateTo(entityId: characterId, position: self.characterPosition)
            rotateTo(entityId: characterId, angle: .pi, axis: simd_float3(0, 1, 0))
            self.applyClip()
            self.applySkinningPath()
        }

        // Required for spatial input on visionOS: without these the engine
        // drops all XR events.
        registerXREvents()
        setSceneReady(true)
    }

    // Called from the XR render thread; all mutable state stays on the main
    // actor, so these are intentionally empty pass-throughs for now (live
    // mocap will feed poses here in a later phase).
    public nonisolated func update(deltaTime _: Float) {}

    public nonisolated func handleInput() {}

    // MARK: - Controls (called from the SwiftUI control window)

    public func setSkinningPath(_ path: CoolMirrorSkinningPath) {
        skinningPath = path
        applySkinningPath()
    }

    public func setClip(_ clip: CoolMirrorClip) {
        currentClip = clip
        applyClip()
    }

    private func applySkinningPath() {
        guard let characterId else { return }
        switch skinningPath {
        case .vertexShader:
            removeEntityDeformation(entityId: characterId)
        case .computeLBS:
            setEntityDeformation(entityId: characterId, skinningMode: .lbs)
        case .computeDQS:
            setEntityDeformation(entityId: characterId, skinningMode: .dqs)
        case .computeDDM:
            setEntityDeformation(entityId: characterId, skinningMode: .ddm)
        }
    }

    private func applyClip() {
        guard let characterId else { return }
        changeAnimation(entityId: characterId, name: currentClip.rawValue)
    }
}
