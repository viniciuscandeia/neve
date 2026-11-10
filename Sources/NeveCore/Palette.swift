import Foundation

/// A colour with a light and a dark variant; `now` blends by `Palette.dark` (0 light ... 1 dark, eased over ~0.5 s on an appearance change).
public struct Tone: Sendable {
    public let light: SIMD3<Float>, dark: SIMD3<Float>
    public init(_ light: SIMD3<Float>, _ dark: SIMD3<Float>) { self.light = light; self.dark = dark }
    public var now: SIMD3<Float> { light + (dark - light) * Palette.dark }
}

/// The one snow palette: shaders (flake, clump, slab, pile) and Rig prims (balls, splats, icicles) all read these. Every colour has both appearances;
/// shaders blend with a `dark` uniform (see `msl`), the CPU side with `Tone.now`. Neutral shadows, one light from above (`light`).
public enum Palette {
    // Appearance blend. Written on the main thread, read by the render thread: a torn Float is harmless.
    nonisolated(unsafe) public static var dark: Float = 0
    nonisolated(unsafe) public static var darkTarget: Float = 0
    nonisolated(unsafe) private static var lastTick: Double = 0

    /// Pure: moves `cur` toward `target` so a full 0 -> 1 swing takes `duration` seconds.
    public static func blend(_ cur: Float, toward target: Float, dt: Float, duration: Float = 0.5) -> Float {
        let step = max(dt, 0) / duration
        return cur < target ? min(cur + step, target) : max(cur - step, target)
    }
    /// Advances `dark` by the time since the last call (absolute clock, so several overlays ticking in one frame do not speed it up).
    public static func tick(now: Double) {
        let dt = lastTick == 0 ? 1 : Float(min(max(now - lastTick, 0), 1))
        lastTick = now
        dark = blend(dark, toward: darkTarget, dt: dt)
    }
    public static var isBlending: Bool { dark != darkTarget }

    /// Light from above, a touch from the left: the same vector for piles, clumps, chunks, figures and icicles (x right, y up).
    public static let light: SIMD2<Float> = { let v = SIMD2<Float>(-0.15, 0.99); return v / (v.x * v.x + v.y * v.y).squareRoot() }()

    public static let snow = Tone(SIMD3(0.93, 0.95, 0.98), SIMD3(0.86, 0.89, 0.94))        // pile body, clumps, chunk undersides (dark: softened white)
    public static let lift = Tone(SIMD3(0.96, 0.97, 0.99), SIMD3(0.90, 0.92, 0.96))
    public static let flake = Tone(SIMD3(1, 1, 1), SIMD3(0.94, 0.96, 0.99))               // flake core, pile crest, chunk crest
    public static let shade = Tone(SIMD3(0.90, 0.93, 0.98), SIMD3(0.85, 0.88, 0.95))      // multiplier for snow facing away from the light
    public static let deep = Tone(SIMD3(0.90, 0.94, 1.0), SIMD3(0.86, 0.90, 0.98))        // cool tint in the lower part of deep snow (multiplier)
    public static let shadow = Tone(SIMD3(0, 0, 0.02), SIMD3(0, 0, 0.02))                 // neutral, never blue
    public static let shadowHC = Tone(SIMD3(0.05, 0.08, 0.16), SIMD3(0, 0, 0.02))         // Increase Contrast outline
    public static let glint = Tone(SIMD3(1, 1, 1), SIMD3(1, 1, 1))
    public static let dropFill = Tone(SIMD3(0.62, 0.80, 0.97), SIMD3(0.66, 0.82, 0.98))
    public static let dropEdge = Tone(SIMD3(0.25, 0.40, 0.65), SIMD3(0.30, 0.45, 0.70))
    public static let speckle = Tone(SIMD3(0.60, 0.70, 0.86), SIMD3(0.58, 0.67, 0.83))
    public static let ice = Tone(SIMD3(0.80, 0.90, 1.0), SIMD3(0.74, 0.85, 0.97))         // icicle fill
    public static let iceEdge = Tone(SIMD3(0.45, 0.62, 0.85), SIMD3(0.40, 0.57, 0.80))
    public static let iceShine = Tone(SIMD3(1, 1, 1), SIMD3(0.95, 0.97, 1))
    /// Every colour, for tests.
    public static let all: [(String, Tone)] = [("snow", snow), ("lift", lift), ("flake", flake), ("shade", shade), ("deep", deep), ("shadow", shadow), ("shadowHC", shadowHC),
                                               ("glint", glint), ("dropFill", dropFill), ("dropEdge", dropEdge), ("speckle", speckle), ("ice", ice), ("iceEdge", iceEdge), ("iceShine", iceShine)]

    // Scalars: (light, dark).
    public static let crestAlpha: Float = 0.9
    public static let shadowAlpha: (light: Float, dark: Float) = (0.18, 0.35)             // pile skirt: neutral black
    public static let rimAlpha: (light: Float, dark: Float) = (0.08, 0)                   // flake edge shadow (contrast on white pages); none on dark ones
    public static var shadowA: Float { shadowAlpha.light + (shadowAlpha.dark - shadowAlpha.light) * dark }
    /// Figure shadows were written for a 0.5 alpha multiplier at the old blue; this scales them to `shadowAlpha`.
    public static var figureShadowK: Float { shadowA / 0.5 }

    /// `mix(float3(light), float3(dark), dark)` for a Metal string; the shader must have a float `dark` in scope.
    public static func msl(_ t: Tone) -> String { "mix(float3(\(t.light.x), \(t.light.y), \(t.light.z)), float3(\(t.dark.x), \(t.dark.y), \(t.dark.z)), dark)" }
    public static func msl(_ s: (light: Float, dark: Float)) -> String { "mix(\(s.light), \(s.dark), dark)" }
    public static var mslLight: String { "float2(\(light.x), \(light.y))" }
}
