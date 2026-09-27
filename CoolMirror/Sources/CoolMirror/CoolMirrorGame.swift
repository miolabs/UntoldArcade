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

    /// The source models are authored oversized (Spider-Man 2.05 m,
    /// Batman 2.22 m in the files); scale them to believable human heights
    /// for the mirror. Uniform scale composes after skinning and morphs.
    var displayScale: Float {
        switch self {
        case .redplayer: 1.0
        case .spiderman: 1.75 / 2.05
        case .batman: 1.90 / 2.22
        }
    }

    /// (clip name shown in UI, animation file name, file extension)
    public var clips: [(name: String, file: String, ext: String)] {
        switch self {
        case .redplayer:
            [("idle", "idle", "untold"), ("running", "running", "untold")]
        case .spiderman:
            // Two curl signs while we pin down which way the Mixamo rig
            // plays back on device — pick the anatomically correct one.
            [("flex", "spiderman_flex", "untoldanim"),
             ("flex-alt", "spiderman_flex_alt", "untoldanim")]
        case .batman:
            [("flex", "batman_flex", "untoldanim")]
        }
    }
}

/// How the muscle deltas are produced on top of skinning.
public enum CoolMirrorMuscleMode: String, CaseIterable, Sendable {
    case off
    /// Live XPBD volumetric muscle simulation.
    case simulation
    /// Network trained on the simulation (needs `<hero>.untoldml`).
    case mlDeformer
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
    private var muscleMode: CoolMirrorMuscleMode = .off
    private var muscleFlex: Float = 0
    private var mlDeformerWeight: Float = 1
    private var muscleCagesVisible = false
    private var disabledMuscles: Set<String> = []
    private var muscleActivations: [String: Float] = [:]
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
            scaleTo(entityId: characterId, scale: simd_float3(repeating: newCharacter.displayScale))
            setEntityMuscleRig(entityId: characterId, rig: CoolMirrorMuscles.rig(for: newCharacter))
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

    /// Pose-space deformation: authored drivers fire morphs from the pose
    /// automatically (the biceps bulge as the elbows curl).
    public func setPoseDrivers(enabled: Bool) {
        guard let characterId else { return }
        setEntityPoseDrivers(entityId: characterId, enabled: enabled)
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

    /// Volumetric muscles: XPBD tet cages built from the character's muscle
    /// rig, simulated on the GPU and wrapped onto the skin after skinning,
    /// or the ML deformer that learned those deltas. Needs a compute
    /// skinning path.
    public func setMuscleMode(_ mode: CoolMirrorMuscleMode) {
        muscleMode = mode
        applyMuscles()
    }

    /// Whether the current character ships a trained `.untoldml` payload.
    public func hasMLDeformer() -> Bool {
        guard let characterId else { return false }
        return entityHasMLDeformerPayload(entityId: characterId)
    }

    /// Blend of the ML deformer's delta (A/B against nothing).
    public func setMLDeformerWeight(_ weight: Float) {
        mlDeformerWeight = weight
        applyMuscles()
    }

    /// Flexes every muscle at once (0 = let the pose drivers decide).
    public func setMuscleFlex(_ value: Float) {
        muscleFlex = value
        applyMuscles()
    }

    public func muscleNames() -> [String] {
        guard let characterId else { return [] }
        return entityMuscleNames(entityId: characterId)
    }

    /// Draws every muscle cage as wireframe lines over the character
    /// (coloured by activation, bone capsules in cyan) to tune placement.
    public func setMuscleCagesVisible(_ visible: Bool) {
        muscleCagesVisible = visible
        setMuscleDebugOverlay(enabled: visible)
    }

    /// Hides one muscle (it keeps simulating but no longer moves the skin).
    public func setMuscleEnabled(name: String, enabled: Bool) {
        if enabled { disabledMuscles.remove(name) } else { disabledMuscles.insert(name) }
        guard let characterId else { return }
        setEntityMuscleEnabled(entityId: characterId, name: name, enabled: enabled)
    }

    /// Manual activation of one muscle (0 = back to its pose driver).
    public func setMuscleActivation(name: String, value: Float) {
        muscleActivations[name] = value
        guard let characterId else { return }
        setEntityMuscleActivation(entityId: characterId, name: name, activation: value)
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
        // The deformation component is recreated with the path; re-apply the
        // muscle settings on top of it.
        applyMuscles()
    }

    private func applyMuscles() {
        guard let characterId, skinningPath != .vertexShader else { return }
        setEntityMuscleSimulation(entityId: characterId, enabled: muscleMode == .simulation)
        setEntityMLDeformer(entityId: characterId, enabled: muscleMode == .mlDeformer)
        setEntityMLDeformerWeight(entityId: characterId, weight: mlDeformerWeight)
        setEntityMuscleActivationOverride(entityId: characterId, activation: muscleFlex > 0.01 ? muscleFlex : nil)
        for name in disabledMuscles {
            setEntityMuscleEnabled(entityId: characterId, name: name, enabled: false)
        }
        for (name, value) in muscleActivations {
            setEntityMuscleActivation(entityId: characterId, name: name, activation: value)
        }
        setMuscleDebugOverlay(enabled: muscleCagesVisible && muscleMode == .simulation)
    }

    private func applyClip() {
        guard let characterId, let currentClip else { return }
        changeAnimation(entityId: characterId, name: currentClip)
    }
}
