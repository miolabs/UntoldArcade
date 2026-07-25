//
//  SaberAudio.swift  (visionOS)
//  CoolSaber
//
//  Saber sound design with zero asset files: every buffer is synthesized at
//  startup (hum loop, ignite/retract sweeps, three clash variants). The engine
//  has no audio system, so this is plain AVAudioEngine. All node mutation runs
//  on a private serial queue; per-frame hum modulation from the XR game thread
//  only writes lock-guarded targets that a 30 Hz timer applies (no zipper, no
//  cross-thread AVAudioEngine access).
//

import AVFAudio
import CoolSaber
import Foundation

final class SaberAudio: @unchecked Sendable {
    private struct HumTarget {
        var volume: Float = 0
        var pitchCents: Float = 0
    }

    private let queue = DispatchQueue(label: "com.miolabs.coolsaber.audio")
    private let engine = AVAudioEngine()
    private let sampleRate: Double = 48000

    private var humPlayers: [AVAudioPlayerNode] = []
    private var humPitches: [AVAudioUnitTimePitch] = []
    private var oneShotPlayer = AVAudioPlayerNode()

    private var humBuffer: AVAudioPCMBuffer?
    private var igniteBuffer: AVAudioPCMBuffer?
    private var retractBuffer: AVAudioPCMBuffer?
    private var clashBuffers: [AVAudioPCMBuffer] = []

    private let targetLock = NSLock()
    private var humTargets = [HumTarget](repeating: HumTarget(), count: 4)
    private var applyTimer: DispatchSourceTimer?
    private var started = false

    // MARK: - Public API (safe from the XR game thread)

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.applyTimer?.cancel()
            self?.applyTimer = nil
            self?.engine.stop()
            self?.started = false
        }
    }

    /// Per-blade hum: volume tracks ignition, pitch tracks how fast the tip moves.
    func setHum(slot: Int, ignited: Bool, tipSpeed: Float) {
        guard (0 ..< 4).contains(slot) else { return }
        let speed = min(max(tipSpeed, 0), 6)
        var target = HumTarget()
        target.volume = ignited ? 0.22 + speed * 0.05 : 0
        target.pitchCents = speed * 90
        targetLock.withLock { humTargets[slot] = target }
    }

    func playIgnite() {
        playOneShot { $0.igniteBuffer }
    }

    func playRetract() {
        playOneShot { $0.retractBuffer }
    }

    func playClash(intensity: Float) {
        let volume = min(max(intensity / 8, 0.4), 1)
        queue.async { [weak self] in
            guard let self, self.started, !self.clashBuffers.isEmpty else { return }
            let buffer = self.clashBuffers.randomElement()!
            self.oneShotPlayer.volume = volume
            self.oneShotPlayer.scheduleBuffer(buffer)
            if !self.oneShotPlayer.isPlaying { self.oneShotPlayer.play() }
        }
    }

    // MARK: - Setup (on `queue`)

    private func startOnQueue() {
        guard !started else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        humBuffer = makeHumBuffer(format: format)
        igniteBuffer = makeSweepBuffer(format: format, from: 60, to: 220)
        retractBuffer = makeSweepBuffer(format: format, from: 220, to: 60)
        clashBuffers = (0 ..< 3).compactMap {
            makeClashBuffer(format: format, seed: UInt64($0) &* 7919 &+ 17)
        }

        for _ in 0 ..< 4 {
            let player = AVAudioPlayerNode()
            let pitch = AVAudioUnitTimePitch()
            engine.attach(player)
            engine.attach(pitch)
            engine.connect(player, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
            humPlayers.append(player)
            humPitches.append(pitch)
        }
        engine.attach(oneShotPlayer)
        engine.connect(oneShotPlayer, to: engine.mainMixerNode, format: format)

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.restartAfterConfigurationChange() }
        }

        do {
            try engine.start()
        } catch {
            print("CoolSaber: audio engine start failed: \(error)")
            return
        }
        started = true

        if let humBuffer {
            for player in humPlayers {
                player.volume = 0
                player.scheduleBuffer(humBuffer, at: nil, options: .loops)
                player.play()
            }
        }

        // Apply hum targets at 30 Hz with a light ramp toward the target so the
        // 90 Hz game writes never zipper.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in self?.applyHumTargets() }
        timer.resume()
        applyTimer = timer
    }

    private func restartAfterConfigurationChange() {
        guard started else { return }
        engine.stop()
        try? engine.start()
        if let humBuffer, engine.isRunning {
            for player in humPlayers {
                player.scheduleBuffer(humBuffer, at: nil, options: .loops)
                player.play()
            }
        }
    }

    private func applyHumTargets() {
        guard started, engine.isRunning else { return }
        let targets = targetLock.withLock { humTargets }
        for (index, target) in targets.enumerated() {
            let player = humPlayers[index]
            let pitch = humPitches[index]
            player.volume += (target.volume - player.volume) * 0.35
            pitch.pitch += (target.pitchCents - pitch.pitch) * 0.35
        }
    }

    private func playOneShot(_ buffer: @escaping (SaberAudio) -> AVAudioPCMBuffer?) {
        queue.async { [weak self] in
            guard let self, self.started, let buffer = buffer(self) else { return }
            self.oneShotPlayer.volume = 0.7
            self.oneShotPlayer.scheduleBuffer(buffer)
            if !self.oneShotPlayer.isPlaying { self.oneShotPlayer.play() }
        }
    }

    // MARK: - DSP

    /// 1 s seamless hum loop: two detuned low tones with odd harmonics and a
    /// slow amplitude wobble. All component frequencies are integer Hz, so the
    /// buffer is phase-continuous at the loop point.
    private func makeHumBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        let twoPi = 2 * Float.pi
        for frame in 0 ..< Int(frames) {
            let t = Float(frame) / Float(sampleRate)
            var value: Float = 0
            for (base, weight) in [(Float(85), Float(1.0)), (Float(113), Float(0.7))] {
                value += weight * sin(twoPi * base * t)
                value += weight * 0.35 * sin(twoPi * base * 3 * t)
                value += weight * 0.15 * sin(twoPi * base * 5 * t)
            }
            let wobble = 1 + 0.15 * sin(twoPi * 6 * t)
            samples[frame] = value * wobble * 0.18
        }
        return buffer
    }

    /// 0.4 s exponential frequency sweep plus a noise swish, for ignite/retract.
    private func makeSweepBuffer(format: AVAudioFormat, from: Float, to: Float) -> AVAudioPCMBuffer? {
        let duration: Float = 0.4
        let frames = AVAudioFrameCount(Float(sampleRate) * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        let twoPi = 2 * Float.pi
        var phase: Float = 0
        var noiseState: UInt64 = 0x9E3779B97F4A7C15
        for frame in 0 ..< Int(frames) {
            let t = Float(frame) / (Float(sampleRate) * duration)
            let frequency = from * pow(to / from, t)
            phase += twoPi * frequency / Float(sampleRate)
            let envelope = sin(Float.pi * t) // smooth in and out
            let noise = Self.nextNoise(&noiseState) * 0.25 * envelope * envelope
            samples[frame] = (sin(phase) * 0.6 + noise) * envelope * 0.8
        }
        return buffer
    }

    /// 0.3 s clash: white-noise burst with instant attack, fast decay, a low
    /// thump, and a couple of crackle ticks. Seed varies the crackle placement.
    private func makeClashBuffer(format: AVAudioFormat, seed: UInt64) -> AVAudioPCMBuffer? {
        let duration: Float = 0.3
        let frames = AVAudioFrameCount(Float(sampleRate) * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        let twoPi = 2 * Float.pi
        var noiseState = seed
        var tickState = seed &* 6364136223846793005 &+ 1442695040888963407
        let tickTimes: [Float] = (0 ..< 3).map { _ in
            0.02 + Self.nextNoise(&tickState) * 0.04 + 0.06
        }
        for frame in 0 ..< Int(frames) {
            let t = Float(frame) / Float(sampleRate)
            let decay = exp(-t * 18)
            var value = Self.nextNoise(&noiseState) * decay * 0.9
            value += sin(twoPi * 150 * t) * exp(-t * 25) * 0.7
            for tick in tickTimes {
                let dt = t - tick
                if dt > 0, dt < 0.01 {
                    value += Self.nextNoise(&noiseState) * exp(-dt * 900) * 0.5
                }
            }
            samples[frame] = value * 0.85
        }
        return buffer
    }

    /// Cheap deterministic white noise in [-1, 1] (xorshift64*).
    private static func nextNoise(_ state: inout UInt64) -> Float {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 2685821657736338717
        return Float(Int64(bitPattern: value)) / Float(Int64.max)
    }
}
