import Foundation
import Metal
import simd
import UntoldEngine

/// The visual styles CoolScan can apply to the rendered scan.
public enum CoolScanStyle: String, CaseIterable, Sendable {
    case original
    case toon
    case comic
    case pixel
    case sketch
}

/// Tunable parameters for every style. All values have sensible defaults.
public struct CoolScanStyleParams: Sendable {
    /// Number of discrete lighting bands in the toon shader.
    public var toonBands: Float = 3
    /// Color multiplier applied to the darkest toon band.
    public var toonShadeColor: SIMD3<Float> = [0.42, 0.38, 0.52]
    /// Strength of the toon rim highlight (0 disables). Off by default: the
    /// engine's view-space normal vertex output proved noisy on scan meshes,
    /// which turns the quantized rim into per-pixel glitter.
    public var rimStrength: Float = 0
    /// Angular width of the rim highlight.
    public var rimWidth: Float = 0.35

    /// Darkness of the screen-space contour lines (0 disables the edge pass).
    public var outlineStrength: Float = 0.85
    /// Sensitivity of the depth/luminance edge detector.
    public var outlineThreshold: Float = 0.12

    /// Number of color levels per channel for the comic posterization.
    public var comicLevels: Float = 5
    /// Halftone dot shading amount in the comic style (0 disables dots).
    public var halftone: Float = 1

    /// Screen-pixel edge length of one art pixel in the pixel style.
    public var pixelSize: Float = 6
    /// Color levels per channel in the pixel style palette.
    public var pixelLevels: Float = 5

    /// Stroke frequency multiplier for the pencil-sketch hatching.
    public var sketchScale: Float = 1

    public init() {}
}

/// Attach to an entity to shade it with the CoolScan toon surface pipeline.
public final class CoolScanToonComponent: Component {
    public required init() {}
}

/// Values the render extension reads each frame. Written by the app, read
/// inside render-pass closures, hence the lock (CoolWater pattern).
public final class CoolScanStyleState: @unchecked Sendable {
    public static let shared = CoolScanStyleState()

    struct Snapshot {
        var style: CoolScanStyle
        var params: CoolScanStyleParams
        var lightDirection: SIMD3<Float>
        var toonAlbedo: MTLTexture?
    }

    private let lock = NSLock()
    private var style: CoolScanStyle = .original
    private var params = CoolScanStyleParams()
    private var lightDirection = SIMD3<Float>(-0.4, -1.0, -0.3)
    private var toonAlbedo: MTLTexture?

    private init() {}

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                style: style,
                params: params,
                lightDirection: lightDirection,
                toonAlbedo: toonAlbedo
            )
        }
    }

    fileprivate func setStyle(_ newStyle: CoolScanStyle) {
        lock.withLock { style = newStyle }
    }

    fileprivate func getStyle() -> CoolScanStyle {
        lock.withLock { style }
    }

    fileprivate func setParams(_ newParams: CoolScanStyleParams) {
        lock.withLock { params = newParams }
    }

    fileprivate func getParams() -> CoolScanStyleParams {
        lock.withLock { params }
    }

    fileprivate func setLightDirection(_ direction: SIMD3<Float>) {
        let length = simd_length(direction)
        guard length > 1e-6 else { return }
        lock.withLock { lightDirection = direction / length }
    }

    fileprivate func setToonAlbedo(_ texture: MTLTexture?) {
        lock.withLock { toonAlbedo = texture }
    }
}

/// Selects the active style. Safe to call from any thread, takes effect the
/// next frame. The app is responsible for attaching `CoolScanToonComponent`
/// to the scanned entity when selecting `.toon` (and detaching otherwise).
public func setCoolScanStyle(_ style: CoolScanStyle) {
    CoolScanStyleState.shared.setStyle(style)
}

public func getCoolScanStyle() -> CoolScanStyle {
    CoolScanStyleState.shared.getStyle()
}

public func setCoolScanStyleParams(_ params: CoolScanStyleParams) {
    CoolScanStyleState.shared.setParams(params)
}

public func getCoolScanStyleParams() -> CoolScanStyleParams {
    CoolScanStyleState.shared.getParams()
}

/// World-space direction the toon light shines toward. Normalized internally.
public func setCoolScanLightDirection(_ direction: SIMD3<Float>) {
    CoolScanStyleState.shared.setLightDirection(direction)
}

/// Base-color texture the toon fragment samples. Pass the scanned model's
/// albedo (e.g. loaded from the scan's PNG). Pass nil to fall back to white.
public func setCoolScanToonAlbedo(_ texture: MTLTexture?) {
    CoolScanStyleState.shared.setToonAlbedo(texture)
}
