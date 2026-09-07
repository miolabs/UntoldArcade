//
//  ZombieSpatialSession.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

#if os(visionOS)
    import ARKit

    /// visionOS adapter running the demo's own ARKitSession: world tracking
    /// for the player's head, and plane detection for the real floor. The
    /// world origin's height is only the system's estimate of the floor and
    /// can sit a centimetre or two off; the detected floor plane is what the
    /// zombie should stand on. Fresh providers on every start: ARKit
    /// providers are one-shot.
    public final class ZombieSpatialSession: @unchecked Sendable {
        private let session = ARKitSession()
        private let lock = NSLock()
        private var runTask: Task<Void, Never>?
        private var worldTracking: WorldTrackingProvider?
        /// Detected floor planes by anchor id: world height and area.
        private var floorPlanes: [UUID: (height: Float, area: Float)] = [:]

        public init() {}

        public static var isSupported: Bool {
            WorldTrackingProvider.isSupported
        }

        public static var isFloorDetectionSupported: Bool {
            PlaneDetectionProvider.isSupported
        }

        public func start() {
            lock.withLock {
                guard runTask == nil, WorldTrackingProvider.isSupported else { return }
                let provider = WorldTrackingProvider()
                worldTracking = provider
                let planes = PlaneDetectionProvider.isSupported
                    ? PlaneDetectionProvider(alignments: [.horizontal]) : nil
                runTask = Task { [weak self] in
                    guard let self else { return }
                    var providers: [any DataProvider] = [provider]
                    if let planes { providers.append(planes) }
                    do {
                        try await session.run(providers)
                    } catch {
                        print("CoolZombie: ARKit session failed to run — \(error)")
                        lock.withLock { worldTracking = nil }
                        return
                    }
                    guard let planes else { return }
                    for await update in planes.anchorUpdates {
                        guard !Task.isCancelled else { break }
                        handle(planeUpdate: update)
                    }
                }
            }
        }

        public func stop() {
            let task = lock.withLock { () -> Task<Void, Never>? in
                let task = runTask
                runTask = nil
                worldTracking = nil
                floorPlanes.removeAll()
                return task
            }
            task?.cancel()
            session.stop()
        }

        /// The player's head position in world space, or nil until tracking
        /// runs.
        public func headPosition() -> simd_float3? {
            let provider = lock.withLock { worldTracking }
            guard let provider, provider.state == .running,
                  let anchor = provider.queryDeviceAnchor(atTimestamp: ProcessInfo.processInfo.systemUptime)
            else { return nil }
            let transform = anchor.originFromAnchorTransform
            return simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }

        /// World height of the largest detected floor plane, or nil until
        /// one has been classified.
        public func floorHeight() -> Float? {
            lock.withLock { floorPlanes.values.max { $0.area < $1.area }?.height }
        }

        private func handle(planeUpdate update: AnchorUpdate<PlaneAnchor>) {
            let anchor = update.anchor
            switch update.event {
            case .removed:
                lock.withLock { _ = floorPlanes.removeValue(forKey: anchor.id) }
            case .added, .updated:
                guard anchor.classification == .floor else {
                    lock.withLock { _ = floorPlanes.removeValue(forKey: anchor.id) }
                    return
                }
                // The extent transform's origin is the plane's centre in
                // world space (its X-Y plane spans the extent, +Z is the normal).
                let extent = anchor.geometry.extent
                let transform = anchor.originFromAnchorTransform * extent.anchorFromExtentTransform
                let plane = (height: transform.columns.3.y, area: extent.width * extent.height)
                lock.withLock { floorPlanes[anchor.id] = plane }
            }
        }
    }
#endif
