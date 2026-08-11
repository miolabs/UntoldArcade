//
//  CoolBallPlugin.swift
//  CoolBall
//

import Foundation
import UntoldEngine

/// Stable identifiers owned by the CoolBall package.
public enum CoolBallPluginContract {
    public static let pluginID = "com.untoldengine.coolball"
    public static let backendID = "com.untoldengine.coolball.physics"
}

/// The demo's physics backend, packaged as a `PhysicsBackendPlugin`.
public struct CoolBallPlugin: PhysicsBackendPlugin {
    public let manifest = PhysicsBackendPluginManifest(
        id: CoolBallPluginContract.pluginID,
        displayName: "Cool Ball Physics",
        version: PhysicsBackendVersion(major: 1, minor: 0, patch: 0),
        requiredAPIVersion: .current
    )

    /// The instance handed to the engine, kept so the demo can feed it
    /// real-world planes and read ball state.
    public let backend: CoolBallPhysicsBackend

    public init(backend: CoolBallPhysicsBackend = CoolBallPhysicsBackend()) {
        self.backend = backend
    }

    public func makeBackend() -> any PhysicsBackend {
        backend
    }
}

/// Installs the CoolBall physics backend. Call once before renderer creation.
/// Returns the live backend on success so the demo keeps its side channel
/// (world planes, ball state).
@discardableResult
public func registerCoolBallPhysics() -> CoolBallPhysicsBackend? {
    let plugin = CoolBallPlugin()
    switch PhysicsBackendRegistry.shared.install(plugin) {
    case .installed, .replaced:
        return plugin.backend
    case let .rejected(failure):
        print("CoolBall physics installation rejected:", failure)
        return nil
    }
}
