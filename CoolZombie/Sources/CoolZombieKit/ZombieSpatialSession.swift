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

    /// visionOS adapter running the demo's own ARKitSession with just world
    /// tracking, to know where the player's head is. Fresh provider on every
    /// start: ARKit providers are one-shot.
    public final class ZombieSpatialSession: @unchecked Sendable {
        private let session = ARKitSession()
        private let lock = NSLock()
        private var runTask: Task<Void, Never>?
        private var worldTracking: WorldTrackingProvider?

        public init() {}

        public static var isSupported: Bool {
            WorldTrackingProvider.isSupported
        }

        public func start() {
            lock.withLock {
                guard runTask == nil, WorldTrackingProvider.isSupported else { return }
                let provider = WorldTrackingProvider()
                worldTracking = provider
                runTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await session.run([provider])
                    } catch {
                        print("CoolZombie: ARKit session failed to run — \(error)")
                        lock.withLock { worldTracking = nil }
                    }
                }
            }
        }

        public func stop() {
            let task = lock.withLock { () -> Task<Void, Never>? in
                let task = runTask
                runTask = nil
                worldTracking = nil
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
    }
#endif
