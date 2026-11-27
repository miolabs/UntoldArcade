//
//  SpikeStats.swift
//  RealityKitPresenter spike
//
//  Counters written from the main thread (updates, replace calls) and the render thread
//  (tickets, anchors, GPU times), read by the control window twice a second.
//

import Foundation
import Observation
import QuartzCore
import os

enum AnchorSource {
    /// `queryDeviceAnchor` answered for the ticket's target time.
    case predicted
    /// It did not; the retry at "now" answered.
    case retried
    /// Neither did; the last good pose was used.
    case cached
    /// No pose at all yet (identity at head height).
    case missing
}

struct StatsSnapshot: Sendable {
    var ticketsPerSecond: Double = 0
    var updatesPerSecond: Double = 0
    var droppedTotal: Int = 0
    var droppedPerSecond: Double = 0
    var ticketsTotal: UInt64 = 0
    var pickupAgeAverageMs: Double = 0
    var pickupAgeMaxMs: Double = 0
    var replaceAverageMs: Double = 0
    var replaceMaxMs: Double = 0
    var textureReplaceAverageMs: Double = 0
    var textureReplaceMaxMs: Double = 0
    var meshReplaceAverageMs: Double = 0
    var meshReplaceMaxMs: Double = 0
    var encodeAverageMs: Double = 0
    var encodeMaxMs: Double = 0
    var gpuAverageMs: Double = 0
    var gpuMaxMs: Double = 0
    var completionLagAverageMs: Double = 0
    var completionLagMaxMs: Double = 0
    var inFlightMax: Int = 0
    var anchorsPredicted: Int = 0
    var anchorsRetried: Int = 0
    var anchorsCached: Int = 0
    var anchorsMissing: Int = 0
    var leadMs: Double = 0
}

final class SpikeCounters: @unchecked Sendable {
    private let lock = NSLock()

    // Main thread
    private var updates = 0
    private var dropped = 0
    private var droppedTotal = 0
    private var replaceCount = 0
    private var replaceSum = 0.0
    private var replaceMax = 0.0
    private var textureReplaceSum = 0.0
    private var textureReplaceMax = 0.0
    private var meshReplaceSum = 0.0
    private var meshReplaceMax = 0.0

    // Render thread
    private var tickets = 0
    private var ticketsTotal: UInt64 = 0
    private var pickupSum = 0.0
    private var pickupMax = 0.0
    private var encodeSum = 0.0
    private var encodeMax = 0.0
    private var inFlightMax = 0
    private var anchorsPredicted = 0
    private var anchorsRetried = 0
    private var anchorsCached = 0
    private var anchorsMissing = 0

    // GPU completion
    private var gpuCount = 0
    private var gpuSum = 0.0
    private var gpuMax = 0.0
    private var lagSum = 0.0
    private var lagMax = 0.0

    private var intervalStart = CACurrentMediaTime()

    /// `textureReplace` and `meshReplace` are the main-thread seconds inside the two kinds of
    /// replace calls of one ticket; nil when no ticket was made this update.
    func noteUpdate(textureReplace: Double?, meshReplace: Double?) {
        lock.lock(); defer { lock.unlock() }
        updates += 1
        if let textureReplace, let meshReplace {
            replaceCount += 1
            let total = textureReplace + meshReplace
            replaceSum += total
            replaceMax = max(replaceMax, total)
            textureReplaceSum += textureReplace
            textureReplaceMax = max(textureReplaceMax, textureReplace)
            meshReplaceSum += meshReplace
            meshReplaceMax = max(meshReplaceMax, meshReplace)
        }
    }

    func noteDropped() {
        lock.lock(); defer { lock.unlock() }
        dropped += 1
        droppedTotal += 1
    }

    func noteCommit(pickupAge: Double, encodeSeconds: Double, inFlight: Int, anchor: AnchorSource) {
        lock.lock(); defer { lock.unlock() }
        tickets += 1
        ticketsTotal += 1
        pickupSum += pickupAge
        pickupMax = max(pickupMax, pickupAge)
        encodeSum += encodeSeconds
        encodeMax = max(encodeMax, encodeSeconds)
        inFlightMax = max(inFlightMax, inFlight)
        switch anchor {
        case .predicted: anchorsPredicted += 1
        case .retried: anchorsRetried += 1
        case .cached: anchorsCached += 1
        case .missing: anchorsMissing += 1
        }
    }

    func noteCompletion(gpuSeconds: Double, lagSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        gpuCount += 1
        gpuSum += gpuSeconds
        gpuMax = max(gpuMax, gpuSeconds)
        lagSum += lagSeconds
        lagMax = max(lagMax, lagSeconds)
    }

    /// The interval's numbers; the per-interval accumulators restart.
    func snapshot(leadSeconds: Double) -> StatsSnapshot {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let interval = max(now - intervalStart, 1e-3)
        var s = StatsSnapshot()
        s.ticketsPerSecond = Double(tickets) / interval
        s.updatesPerSecond = Double(updates) / interval
        s.droppedTotal = droppedTotal
        s.droppedPerSecond = Double(dropped) / interval
        s.ticketsTotal = ticketsTotal
        s.pickupAgeAverageMs = tickets > 0 ? pickupSum / Double(tickets) * 1000 : 0
        s.pickupAgeMaxMs = pickupMax * 1000
        s.replaceAverageMs = replaceCount > 0 ? replaceSum / Double(replaceCount) * 1000 : 0
        s.replaceMaxMs = replaceMax * 1000
        s.textureReplaceAverageMs = replaceCount > 0 ? textureReplaceSum / Double(replaceCount) * 1000 : 0
        s.textureReplaceMaxMs = textureReplaceMax * 1000
        s.meshReplaceAverageMs = replaceCount > 0 ? meshReplaceSum / Double(replaceCount) * 1000 : 0
        s.meshReplaceMaxMs = meshReplaceMax * 1000
        s.encodeAverageMs = tickets > 0 ? encodeSum / Double(tickets) * 1000 : 0
        s.encodeMaxMs = encodeMax * 1000
        s.gpuAverageMs = gpuCount > 0 ? gpuSum / Double(gpuCount) * 1000 : 0
        s.gpuMaxMs = gpuMax * 1000
        s.completionLagAverageMs = gpuCount > 0 ? lagSum / Double(gpuCount) * 1000 : 0
        s.completionLagMaxMs = lagMax * 1000
        s.inFlightMax = inFlightMax
        s.anchorsPredicted = anchorsPredicted
        s.anchorsRetried = anchorsRetried
        s.anchorsCached = anchorsCached
        s.anchorsMissing = anchorsMissing
        s.leadMs = leadSeconds * 1000

        updates = 0; dropped = 0
        replaceCount = 0; replaceSum = 0; replaceMax = 0
        textureReplaceSum = 0; textureReplaceMax = 0; meshReplaceSum = 0; meshReplaceMax = 0
        tickets = 0; pickupSum = 0; pickupMax = 0; encodeSum = 0; encodeMax = 0; inFlightMax = 0
        gpuCount = 0; gpuSum = 0; gpuMax = 0; lagSum = 0; lagMax = 0
        intervalStart = now
        return s
    }
}

@Observable
@MainActor
final class SpikeStatsStore {
    var latest = StatsSnapshot()
    var routeInUse = "—"
    var materialInUse = "—"
    var trackingState = "—"
    var messages: [String] = []

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let logger = Logger(subsystem: "com.miolabs.RealityKitPresenterSpike", category: "presenter")
    private static let numbersLogger = Logger(subsystem: "com.miolabs.RealityKitPresenterSpike", category: "numbers")

    /// One compact line of the numbers to the system log (Console.app, `log show`), not to the window.
    func logNumbers(_ s: StatsSnapshot, route: String) {
        let line = String(
            format: "fps %.1f updates %.1f dropped %d (%.1f/s) lead %.1f ms pickup %.2f/%.2f ms replace %.2f/%.2f ms (tex %.2f/%.2f mesh %.2f/%.2f) encode %.2f/%.2f ms gpu %.2f/%.2f ms lag %.2f/%.2f ms inflight %d anchors p%d r%d c%d m%d route %@",
            s.ticketsPerSecond, s.updatesPerSecond, s.droppedTotal, s.droppedPerSecond, s.leadMs,
            s.pickupAgeAverageMs, s.pickupAgeMaxMs, s.replaceAverageMs, s.replaceMaxMs, s.textureReplaceAverageMs, s.textureReplaceMaxMs, s.meshReplaceAverageMs, s.meshReplaceMaxMs, s.encodeAverageMs, s.encodeMaxMs,
            s.gpuAverageMs, s.gpuMaxMs, s.completionLagAverageMs, s.completionLagMaxMs, s.inFlightMax,
            s.anchorsPredicted, s.anchorsRetried, s.anchorsCached, s.anchorsMissing, route
        )
        Self.numbersLogger.notice("\(line, privacy: .public)")
    }

    func log(_ message: String) {
        let line = "\(Self.clock.string(from: Date())) \(message)"
        messages.append(line)
        if messages.count > 60 { messages.removeFirst(messages.count - 60) }
        Self.logger.notice("\(message, privacy: .public)")
    }
}
