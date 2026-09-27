//
//  MocapRecording.swift
//  CoolMirrorMocap
//
//  Raw capture recordings: the frames exactly as the iPhone produced them,
//  in the wire form, one after another in a file. A recording taken while a
//  problem shows on the headset can be replayed through the filters on a
//  Mac, measured, and turned into a regression test.
//

import Foundation
import simd

public enum MocapRecording {
    /// File magic, "CMR1"; then, per frame, a little-endian 32-bit length
    /// and the frame's wire form.
    public static let magic: UInt32 = 0x3152_4D43
    public static let fileExtension = "cmr"

    public static func read(url: URL) throws -> [MocapFrame] {
        let data = try Data(contentsOf: url)
        return frames(in: data)
    }

    public static func frames(in data: Data) -> [MocapFrame] {
        var cursor = data.startIndex
        func read32() -> UInt32? {
            guard cursor + 4 <= data.endIndex else { return nil }
            let value = data[cursor ..< cursor + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            cursor += 4
            return UInt32(littleEndian: value)
        }
        guard read32() == magic else { return [] }
        var frames: [MocapFrame] = []
        while let length = read32(), length > 0, cursor + Int(length) <= data.endIndex {
            if let frame = MocapFrame(data: data[cursor ..< cursor + Int(length)]) {
                frames.append(frame)
            }
            cursor += Int(length)
        }
        return frames
    }

    /// How the raw skeleton moves from frame to frame: what a jump on the
    /// headset looks like at the source. Per frame, the root's travel and
    /// turn and the largest travel of any joint relative to the root; the
    /// summary names the frames that moved most.
    public static func report(_ frames: [MocapFrame], worst: Int = 12) -> String {
        guard frames.count > 1 else { return "\(frames.count) frame(s)" }
        struct Step {
            var index: Int
            var time: Double
            var root: Float
            var yaw: Float
            var joint: Float
            var jointName: String
        }
        var steps: [Step] = []
        let first = frames[0].timestamp
        for index in 1 ..< frames.count {
            let a = frames[index - 1], b = frames[index]
            let root = simd_length(b.rootPosition - a.rootPosition)
            let yaw = abs(Self.yaw(b.rotations[.root]) - Self.yaw(a.rotations[.root])) * 180 / .pi
            var joint: Float = 0
            var jointName = "-"
            for (name, p) in b.positions {
                guard let q = a.positions[name] else { continue }
                let d = simd_length(p - q)
                if d > joint {
                    joint = d
                    jointName = "\(name)"
                }
            }
            steps.append(Step(index: index, time: b.timestamp - first, root: root, yaw: min(yaw, 360 - yaw), joint: joint, jointName: jointName))
        }
        func percentile(_ values: [Float], _ f: Float) -> Float {
            let s = values.sorted()
            return s.isEmpty ? 0 : s[min(s.count - 1, Int(Float(s.count - 1) * f))]
        }
        let duration = frames.last!.timestamp - first
        var lines: [String] = []
        lines.append(String(format: "%d frames over %.1f s (%.0f/s), %d untracked", frames.count, duration, Double(frames.count - 1) / max(duration, 1e-3), frames.filter { !$0.isTracked }.count))
        lines.append(String(format: "root travel per frame: median %.1f mm, p95 %.1f mm, max %.1f mm", percentile(steps.map(\.root), 0.5) * 1000, percentile(steps.map(\.root), 0.95) * 1000, (steps.map(\.root).max() ?? 0) * 1000))
        lines.append(String(format: "root turn per frame: median %.2f°, p95 %.2f°, max %.2f°", percentile(steps.map(\.yaw), 0.5), percentile(steps.map(\.yaw), 0.95), steps.map(\.yaw).max() ?? 0))
        lines.append(String(format: "largest joint travel per frame (relative to the root): median %.1f mm, p95 %.1f mm, max %.1f mm", percentile(steps.map(\.joint), 0.5) * 1000, percentile(steps.map(\.joint), 0.95) * 1000, (steps.map(\.joint).max() ?? 0) * 1000))
        lines.append("worst root moves:")
        for step in steps.sorted(by: { $0.root > $1.root }).prefix(worst) {
            lines.append(String(format: "  frame %d at %.2f s: root %.1f mm, turn %.1f°, %@ %.1f mm", step.index, step.time, step.root * 1000, step.yaw, step.jointName, step.joint * 1000))
        }
        lines.append("worst root turns:")
        for step in steps.sorted(by: { $0.yaw > $1.yaw }).prefix(worst) {
            lines.append(String(format: "  frame %d at %.2f s: turn %.1f°, root %.1f mm, %@ %.1f mm", step.index, step.time, step.yaw, step.root * 1000, step.jointName, step.joint * 1000))
        }
        return lines.joined(separator: "\n")
    }

    static func yaw(_ rotation: simd_quatf?) -> Float {
        guard let rotation else { return 0 }
        let forward = rotation.act(simd_float3(0, 0, 1))
        return atan2(forward.x, forward.z)
    }
}

/// Appends frames to a recording file as they arrive.
public final class MocapRecordingWriter: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var count = 0

    public var frameCount: Int {
        lock.withLock { count }
    }

    public init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        var magic = MocapRecording.magic.littleEndian
        handle.write(Data(bytes: &magic, count: 4))
    }

    public func append(_ frame: MocapFrame) {
        let payload = frame.encode()
        var length = UInt32(payload.count).littleEndian
        lock.withLock {
            handle.write(Data(bytes: &length, count: 4))
            handle.write(payload)
            count += 1
        }
    }

    public func close() {
        lock.withLock { try? handle.close() }
    }
}
