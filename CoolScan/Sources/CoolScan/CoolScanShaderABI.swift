import simd

// Hand-maintained Swift mirrors of the structs in Shaders/CoolScanShaderTypes.h.
// CoolScanABITests guards the strides so a drifted layout fails in CI before
// the GPU reads garbage.

struct CoolScanToonUniforms {
    /// xyz: normalized world direction the light shines toward; w unused.
    var lightDirection: SIMD4<Float> = .zero
    /// rgb: darkest-band color multiplier; w: band count.
    var shadeColor: SIMD4<Float> = .zero
    /// x: rim strength, y: rim width, z/w reserved.
    var params: SIMD4<Float> = .zero
}

struct CoolScanScreenUniforms {
    /// Style-specific packing, see CoolScanShaderTypes.h.
    var paramsA: SIMD4<Float> = .zero
    var paramsB: SIMD4<Float> = .zero
}
