// AGENT HEADER - Sources/NeveCore/Palette.swift  (the one colour palette, light + dark)
// Role: `Tone` (light/dark SIMD3 pair; `now` blends by `Palette.dark`) and `Palette` (static `dark` 0...1, `darkTarget`, eased over ~0.5 s by `tick(now:)` with an ABSOLUTE clock so several overlays ticking in one frame do not speed it up; `stepDt` capped at 1/30 s; `resetClock`; `isBlending`;
//   `light` = the single light vector (-0.15, 0.99 normalised, x right y up) used by piles, clumps, chunks, figures and icicles; named tones: snow, lift, flake, shade, deep, shadow, shadowHC (Increase Contrast), glint, drop*, ice*, carrot, red, twig, coal, rabbit/penguin/robin/sleigh colours...).
// Consumers: shaders get colours baked in via `Palette.msl(tone)` string interpolation when the Metal source is built (Sources/Neve/*Shader.swift, Renderer.swift), and Rig reads `Tone.now` on the CPU. Adding/changing a colour needs no shader edit unless a new uniform is wanted. Appearance input: Renderer.swift AppearanceWatcher sets `darkTarget`; Overlay.swift calls `Palette.tick(now:)` every frame; state is main-thread only (nonisolated(unsafe)). Tests: PaletteTests.

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
    // Appearance blend. Every access is on the main thread (AppearanceWatcher, and the display link is added to the main run loop, so tick / encode run there);
    // `nonisolated(unsafe)` only because NeveCore is nonisolated (tests, pure code).
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
        let dt = stepDt(now: now, last: lastTick)
        lastTick = now
        dark = blend(dark, toward: darkTarget, dt: dt)
    }
    /// Pure: seconds to advance. Capped at 1/30 s (a first tick or one after a long pause is one ordinary frame), so a blend is always a smooth ~0.5 s, never a pop.
    public static func stepDt(now: Double, last: Double) -> Float { last == 0 ? 1.0 / 60 : Float(min(max(now - last, 0), 1.0 / 30)) }
    /// The overlays were asleep: the next tick is a first tick.
    public static func resetClock() { lastTick = 0 }
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
    // Optional extras (snowman, penguin, rabbit, robin, sleigh, gifts, frost). Dark: softened whites, a little less saturation, dark parts lifted so they do not vanish.
    public static let carrot = Tone(SIMD3(0.96, 0.52, 0.12), SIMD3(0.90, 0.52, 0.18))     // carrot nose, penguin beak and feet
    public static let red = Tone(SIMD3(0.82, 0.17, 0.20), SIMD3(0.76, 0.22, 0.24))        // scarf, sleigh, Santa's suit
    public static let stripe = Tone(SIMD3(0.98, 0.88, 0.86), SIMD3(0.90, 0.82, 0.81))     // scarf stripes
    public static let twig = Tone(SIMD3(0.38, 0.25, 0.14), SIMD3(0.42, 0.30, 0.20))       // arms, antlers
    public static let coal = Tone(SIMD3(0.13, 0.14, 0.16), SIMD3(0.16, 0.17, 0.19))       // eyes, buttons
    public static let rabbitFur = Tone(SIMD3(0.93, 0.95, 0.99), SIMD3(0.86, 0.88, 0.93))
    public static let earPink = Tone(SIMD3(0.95, 0.75, 0.80), SIMD3(0.88, 0.72, 0.76))
    public static let trim = Tone(SIMD3(1, 1, 1), SIMD3(0.93, 0.94, 0.97))                // pom tail, Santa's trim, gift ribbon
    public static let rim = Tone(SIMD3(0.85, 0.92, 1.0), SIMD3(0.80, 0.87, 0.96))         // faint rim light on dark parts
    public static let penguinBack = Tone(SIMD3(0.12, 0.13, 0.16), SIMD3(0.17, 0.18, 0.22))
    public static let penguinBelly = Tone(SIMD3(0.97, 0.98, 1), SIMD3(0.88, 0.90, 0.94))
    public static let fawn = Tone(SIMD3(0.45, 0.33, 0.24), SIMD3(0.48, 0.37, 0.28))       // robin back, reindeer
    public static let robinBreast = Tone(SIMD3(0.85, 0.38, 0.20), SIMD3(0.80, 0.40, 0.24))
    public static let robinWing = Tone(SIMD3(0.36, 0.26, 0.19), SIMD3(0.41, 0.31, 0.24))
    public static let robinBeak = Tone(SIMD3(0.16, 0.14, 0.12), SIMD3(0.20, 0.18, 0.16))
    public static let gold = Tone(SIMD3(0.95, 0.75, 0.20), SIMD3(0.88, 0.72, 0.28))
    public static let skin = Tone(SIMD3(0.96, 0.80, 0.68), SIMD3(0.88, 0.74, 0.64))
    public static let reins = Tone(SIMD3(0.30, 0.20, 0.12), SIMD3(0.38, 0.27, 0.18))
    public static let sack = Tone(SIMD3(0.62, 0.46, 0.28), SIMD3(0.58, 0.45, 0.30))
    public static let rudolph = Tone(SIMD3(0.95, 0.15, 0.10), SIMD3(0.88, 0.20, 0.15))    // red nose of the lead reindeer
    public static let deerTail = Tone(SIMD3(0.85, 0.80, 0.70), SIMD3(0.80, 0.76, 0.68))
    public static let giftRed = Tone(SIMD3(0.86, 0.18, 0.20), SIMD3(0.80, 0.24, 0.25))
    public static let giftGreen = Tone(SIMD3(0.16, 0.55, 0.28), SIMD3(0.20, 0.50, 0.30))
    public static let giftInside = Tone(SIMD3(0.12, 0.07, 0.08), SIMD3(0.14, 0.09, 0.10))
    public static let frost = Tone(SIMD3(0.93, 0.96, 0.99), SIMD3(0.84, 0.88, 0.94))      // neutral icy white, a hint of cool
    /// Every colour, for tests.
    public static let all: [(String, Tone)] = extras + [("snow", snow), ("lift", lift), ("flake", flake), ("shade", shade), ("deep", deep), ("shadow", shadow), ("shadowHC", shadowHC),
                                               ("glint", glint), ("dropFill", dropFill), ("dropEdge", dropEdge), ("speckle", speckle), ("ice", ice), ("iceEdge", iceEdge), ("iceShine", iceShine)]
    static let extras: [(String, Tone)] = [("carrot", carrot), ("red", red), ("stripe", stripe), ("twig", twig), ("coal", coal), ("rabbitFur", rabbitFur), ("earPink", earPink), ("trim", trim), ("rim", rim),
        ("penguinBack", penguinBack), ("penguinBelly", penguinBelly), ("fawn", fawn), ("robinBreast", robinBreast), ("robinWing", robinWing), ("robinBeak", robinBeak), ("gold", gold), ("skin", skin),
        ("reins", reins), ("sack", sack), ("rudolph", rudolph), ("deerTail", deerTail), ("giftRed", giftRed), ("giftGreen", giftGreen), ("giftInside", giftInside), ("frost", frost)]

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
