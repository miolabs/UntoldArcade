import Foundation
import UntoldEngine

/// Stable identifiers owned by the CoolScan package.
public enum CoolScanPluginContract {
    public static let pluginID = "com.untoldengine.coolscan"
    public static let extensionID = "com.untoldengine.coolscan.renderer"
    public static let shaderLibraryID: RenderShaderLibraryID =
        "com.untoldengine.coolscan.shaders"

    public static let toonPipelineID: RenderPipelineType =
        "com.untoldengine.coolscan.surface.toon"
    public static let toonArgumentLayoutID = "com.untoldengine.coolscan.surface.toon.arguments"
    public static let surfacePassID = "com.untoldengine.coolscan.surface.pass"

    public static let comicPipelineID: ComputePipelineType =
        "com.untoldengine.coolscan.compute.comic"
    public static let pixelPipelineID: ComputePipelineType =
        "com.untoldengine.coolscan.compute.pixel"
    public static let sketchPipelineID: ComputePipelineType =
        "com.untoldengine.coolscan.compute.sketch"
    public static let edgePipelineID: ComputePipelineType =
        "com.untoldengine.coolscan.compute.edge"
    public static let screenPassID = "com.untoldengine.coolscan.screen.pass"

    public static let scratchTextureID: RenderTextureResourceID =
        "com.untoldengine.coolscan.textures.scratch"

    public static let shaderFunctionNames = [
        "coolScanToonFragment",
        "coolScanComicKernel",
        "coolScanPixelKernel",
        "coolScanSketchKernel",
        "coolScanEdgeKernel",
    ]
}

/// Package-level lifecycle and distribution wrapper for CoolScan extensions.
public struct CoolScanPlugin: RenderExtensionPlugin {
    public static var bundledMetallibURL: URL? {
        Bundle.module.url(
            forResource: CoolScanPlatform.metallibResourceName,
            withExtension: "metallib"
        )
    }

    public let manifest = RenderExtensionPluginManifest(
        id: CoolScanPluginContract.pluginID,
        displayName: "Cool Scan",
        version: RenderExtensionPluginVersion(major: 1, minor: 0, patch: 0)
    )

    public init() {}

    public func makeRenderExtensions() -> [any RenderExtension] {
        [CoolScanRenderExtension()]
    }
}

enum CoolScanPlatform {
    static let metallibResourceName: String = {
        #if os(macOS)
        "CoolScan-macos"
        #elseif os(visionOS) && targetEnvironment(simulator)
        "CoolScan-xrossim"
        #elseif os(visionOS)
        "CoolScan-xros"
        #elseif os(iOS) && targetEnvironment(simulator)
        "CoolScan-iossim"
        #elseif os(iOS)
        "CoolScan-ios"
        #else
        #error("CoolScan does not provide a metallib for this platform")
        #endif
    }()
}

/// Installs CoolScan atomically. Call once before renderer creation.
@discardableResult
public func registerCoolScanPlugin() -> RenderExtensionPluginInstallationResult {
    RenderExtensionPluginRegistry.shared.install(CoolScanPlugin())
}
