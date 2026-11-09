import Foundation

/// The one snow palette: shaders (flake, clump, slab, pile) and Rig prims (balls, splats) all read these.
public enum Palette {
    public static let snow = SIMD3<Float>(0.84, 0.90, 0.98)
    public static let lift = SIMD3<Float>(0.88, 0.93, 0.99)
    public static let shade = SIMD3<Float>(0.86, 0.92, 1.0)   // multiplier for snow facing away from the light
    public static let crestAlpha: Float = 0.95
    public static let shadow = SIMD3<Float>(0.25, 0.40, 0.65)
    public static let shadowHC = SIMD3<Float>(0.15, 0.28, 0.50)
    public static let rim = SIMD3<Float>(0.56, 0.65, 0.80)
    public static let ice = SIMD3<Float>(0.80, 0.90, 1.0)

    /// `float3(r, g, b)` literal for interpolating into a Metal source string.
    public static func msl(_ c: SIMD3<Float>) -> String { "float3(\(c.x), \(c.y), \(c.z))" }
}
