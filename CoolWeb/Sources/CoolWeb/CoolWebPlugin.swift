import Foundation
import UntoldEngine

/// Stable identifiers owned by the CoolWeb package.
public enum CoolWebPluginContract {
    public static let pluginID = "com.untoldengine.coolweb"
    public static let extensionID = "com.untoldengine.coolweb.renderer"
    public static let shaderLibraryID: RenderShaderLibraryID =
        "com.untoldengine.coolweb.shaders"
    public static let strandPipelineID: RenderPipelineType =
        "com.untoldengine.coolweb.scene.strands"
    public static let occlusionPipelineID: RenderPipelineType =
        "com.untoldengine.coolweb.scene.occlusion"
    public static let glovePipelineID: RenderPipelineType =
        "com.untoldengine.coolweb.scene.glove"
    public static let scenePassID = "com.untoldengine.coolweb.scene.pass"
    public static let shaderFunctionNames = [
        "coolWebStrandVertex",
        "coolWebStrandFragment",
        "coolWebOcclusionVertex",
        "coolWebOcclusionFragment",
        "coolWebGloveVertex",
        "coolWebGloveFragment",
    ]
}

/// Package-level lifecycle and distribution wrapper for CoolWeb extensions.
public struct CoolWebPlugin: RenderExtensionPlugin {
    public static var bundledMetallibURL: URL? {
        Bundle.module.url(
            forResource: CoolWebPlatform.metallibResourceName,
            withExtension: "metallib"
        )
    }

    public let manifest = RenderExtensionPluginManifest(
        id: CoolWebPluginContract.pluginID,
        displayName: "Cool Web",
        version: RenderExtensionPluginVersion(major: 1, minor: 0, patch: 0)
    )

    public init() {}

    public func makeRenderExtensions() -> [any RenderExtension] {
        [CoolWebRenderExtension()]
    }
}

enum CoolWebPlatform {
    static let metallibResourceName: String = {
        #if os(macOS)
        "CoolWeb-macos"
        #elseif os(visionOS) && targetEnvironment(simulator)
        "CoolWeb-xrossim"
        #elseif os(visionOS)
        "CoolWeb-xros"
        #elseif os(iOS) && targetEnvironment(simulator)
        "CoolWeb-iossim"
        #elseif os(iOS)
        "CoolWeb-ios"
        #else
        #error("CoolWeb does not provide a metallib for this platform")
        #endif
    }()
}

/// Installs CoolWeb atomically. Call once before renderer creation.
@discardableResult
public func registerCoolWebPlugin() -> RenderExtensionPluginInstallationResult {
    RenderExtensionPluginRegistry.shared.install(CoolWebPlugin())
}
