//
//  CoolMirrorGame.swift
//  CoolMirror
//
//  Virtual-mirror demo core: a rigged character standing in front of the user,
//  playing animation clips (live mocap arrives in a later phase), with the
//  engine's deformation stack switchable at runtime. Owns no rendering — the
//  engine draws the character; this class spawns it and forwards controls.
//

import simd
import UntoldEngine

/// Characters bundled with the demo, each with its own rig and clips.
public enum CoolMirrorCharacter: String, CaseIterable, Sendable {
    case spiderman
    case batman
    case redplayer

    /// (clip name shown in UI, animation file name, file extension)
    public var clips: [(name: String, file: String, ext: String)] {
        switch self {
        case .redplayer:
            [("idle", "idle", "untold"), ("running", "running", "untold")]
        case .spiderman:
            [("flex", "spiderman_flex", "untoldanim")]
        case .batman:
            [("flex", "batman_flex", "untoldanim")]
        }
    }
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
    public private(set) var character: CoolMirrorCharacter = .spiderman

    /// Called on the main actor when a character finishes loading (morph
    /// target names are available from then on).
    public var onCharacterReady: (() -> Void)?

    // Mirror framing: the character stands ~1.6 m in front of the world origin
    // and faces back toward the user like a reflection.
    private let characterPosition = simd_float3(0.0, 0.0, -1.6)
    private var skinningPath: CoolMirrorSkinningPath = .vertexShader
    private var currentClip: String?
    private var generation = 0

    public init() {}

    public func start() {
        // Required for spatial input on visionOS: without these the engine
        // drops all XR events.
        registerXREvents()
        setSceneReady(true)
        setCharacter(character)
    }

    // Called from the XR render thread; all mutable state stays on the main
    // actor, so these are intentionally empty pass-throughs for now (live
    // mocap will feed poses here in a later phase).
    public nonisolated func update(deltaTime _: Float) {}

    public nonisolated func handleInput() {}

    // MARK: - Controls (called from the SwiftUI control window)

    /// Called during immersive-space teardown, before the engine resets the
    /// world: drops entity references so late async loads touch nothing.
    public func prepareForShutdown() {
        generation += 1
        characterId = nil
        onCharacterReady = nil
    }

    public func setCharacter(_ newCharacter: CoolMirrorCharacter) {
        if let characterId {
            destroyEntity(entityId: characterId)
            self.characterId = nil
        }
        character = newCharacter
        currentClip = newCharacter.clips.first?.name
        generation += 1
        let expectedGeneration = generation

        let entity = createEntity()
        setEntityName(entityId: entity, name: "MirrorCharacter-\(newCharacter.rawValue)")
        characterId = entity

        setEntityMeshAsync(entityId: entity, filename: newCharacter.rawValue, withExtension: "untold") { [weak self] _ in
            guard let self, self.generation == expectedGeneration, let characterId = self.characterId else { return }
            for clip in newCharacter.clips {
                setEntityAnimations(
                    entityId: characterId,
                    filename: clip.file,
                    withExtension: clip.ext,
                    name: clip.name
                )
            }
            translateTo(entityId: characterId, position: self.characterPosition)
            rotateTo(entityId: characterId, angle: .pi, axis: simd_float3(0, 1, 0))
            self.applyClip()
            self.applySkinningPath()
            self.onCharacterReady?()
        }
    }

    public func setSkinningPath(_ path: CoolMirrorSkinningPath) {
        skinningPath = path
        applySkinningPath()
    }

    public func setClip(_ name: String) {
        currentClip = name
        applyClip()
    }

    /// Freeze playback on the current frame so skinning paths can be
    /// compared on the exact same pose.
    public func setPaused(_ paused: Bool) {
        guard let characterId else { return }
        pauseAnimationComponent(entityId: characterId, isPaused: paused)
    }

    /// Morph target weight passthrough. Applied by the deformation pass, so a
    /// compute skinning path must be active for the weight to show.
    public func setMorphWeight(name: String, weight: Float) {
        guard let characterId else { return }
        setEntityMorphTargetWeight(entityId: characterId, name: name, weight: weight)
    }

    public func morphTargetNames() -> [String] {
        guard let characterId else { return [] }
        return entityMorphTargetNames(entityId: characterId)
    }

    public func clipNames() -> [String] {
        character.clips.map(\.name)
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
        guard let characterId, let currentClip else { return }
        changeAnimation(entityId: characterId, name: currentClip)
    }
}
