//
//  CoolBasketPlugin.swift
//  CoolBasket
//

import Foundation
import UntoldEngine

/// Stable identifiers owned by the CoolBasket package.
public enum CoolBasketPluginContract {
    public static let pluginID = "com.untoldengine.coolbasket"
    public static let backendID = "com.untoldengine.coolbasket.physics"
}

/// The demo's physics backend, packaged as a `PhysicsBackendPlugin`.
public struct CoolBasketPlugin: PhysicsBackendPlugin {
    public let manifest = PhysicsBackendPluginManifest(
        id: CoolBasketPluginContract.pluginID,
        displayName: "Cool Basket Physics",
        version: PhysicsBackendVersion(major: 1, minor: 0, patch: 0),
        requiredAPIVersion: .current
    )

    /// The instance handed to the engine, kept so the demo can feed it
    /// real-world planes and read ball state.
    public let backend: CoolBasketPhysicsBackend

    public init(backend: CoolBasketPhysicsBackend = CoolBasketPhysicsBackend()) {
        self.backend = backend
    }

    public func makeBackend() -> any PhysicsBackend {
        backend
    }
}

/// Installs the CoolBasket physics backend. Call once before renderer creation.
/// Returns the live backend on success so the demo keeps its side channel
/// (world planes, ball state).
@discardableResult
public func registerCoolBasketPhysics() -> CoolBasketPhysicsBackend? {
    let plugin = CoolBasketPlugin()
    switch PhysicsBackendRegistry.shared.install(plugin) {
    case .installed, .replaced:
        return plugin.backend
    case let .rejected(failure):
        // The registry freezes on the first simulated substep, so reopening
        // the immersive space cannot reinstall — reuse the live backend.
        if failure.registryLocked,
           let existing = PhysicsBackendRegistry.shared.activeBackend() as? CoolBasketPhysicsBackend
        {
            return existing
        }
        print("CoolBasket physics installation rejected:", failure)
        return nil
    }
}
