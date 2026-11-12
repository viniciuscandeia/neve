// AGENT HEADER - Sources/NeveCore/Util.swift  (RNG, noise, frame-rate policy, small helpers)
// Role: `SplitMix64` (seedable RandomNumberGenerator: every simulation sequence is reproducible), `binCenter(c)` (x in pt of global column c), `noise`/`valueNoise`/`windNoise` (deterministic value noise; windNoise = two octaves at 8 s / 3 s, period ~9 h), `fastSin`/`fastCos` (parabola
//   + refinement, max error ~0.001: per-flake hot path), SIMD2.limited (cap launch speeds at 800 pt/s per axis), Array.swapRemove, and `FrameRate` (+ `economyFrames`: economy pref or thermal >= fair): the display-link policy used by Overlay (`range(...)`: quiet = 30 fps (economy 20), busy 30...60, Low Power / shrunk window = 30;
//   `snap` makes every rate the panel maximum divided by a whole number so 120/144/75/50 Hz panels stay even; `holdDown` 2.5 s before stepping down, stepping up is immediate), `pointerVelocity` (uses REAL elapsed dt, floored at 1/240), `cursorNear` (Liang-Barsky: does a fast cursor
//   concern this screen?), `interpAlpha` (only for Tuning.interpolateCalm). Tests: EntryRhythmTests, NaturalMotionTests, PollSchedulerTests, FlakeMotionTests (FrameRate); the seeded RNG / noise underlie DeterminismTests and most simulation tests. windNoise octaves wrap at 4096 lattice cells (8 s -> ~9 h, 3 s -> ~3.4 h).

import CoreGraphics
import Foundation

/// Small seedable generator so simulations are reproducible in tests.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Centre x (points) of global column `c`.
func binCenter(_ c: Int) -> Float { (Float(c) + 0.5) * Tuning.binWidth }

/// Deterministic value noise in -1...1 for a column index.
func noise(_ i: Int) -> CGFloat {
    var z = UInt64(bitPattern: Int64(i)) &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return CGFloat(Double((z ^ (z >> 31)) >> 11) / Double(1 << 52) - 1)
}

/// Lattice hash in 0...1 (cheap: one multiply-xorshift, no allocation).
@inline(__always) private func lattice(_ x: Int32, _ y: Int32) -> Float {
    var h = UInt32(bitPattern: x) &* 0x27D4_EB2F ^ UInt32(bitPattern: y) &* 0x1656_67B1
    h = (h ^ (h >> 15)) &* 0x85EB_CA6B
    h ^= h >> 13
    return Float(h >> 8) * (1 / 16_777_216)
}

/// Smooth 2D value noise in -1...1 (C1-continuous: smoothstep between hashed lattice points). Lattice indices wrap at `period` on the y axis
/// (a power of two) so a long-running clock on y never jumps.
func valueNoise(_ x: Float, _ y: Float, period: Int32 = 4096) -> Float {
    let fx = x.rounded(.down), fy = y.rounded(.down)
    let ix = Int32(truncatingIfNeeded: Int(fx)), iy = Int32(truncatingIfNeeded: Int(fy))
    var u = x - fx, v = y - fy
    u = u * u * (3 - 2 * u); v = v * v * (3 - 2 * v)
    let m = period - 1, j0 = iy & m, j1 = (iy &+ 1) & m
    let a = lattice(ix, j0), b = lattice(ix &+ 1, j0), c = lattice(ix, j1), d = lattice(ix &+ 1, j1)
    let top = a + (b - a) * u, bot = c + (d - c) * u
    return (top + (bot - top) * v) * 2 - 1
}

/// Time-only wind shape in about -1.3...1.3: two octaves (lattice every 8 s and every 3 s) of value noise; never repeats visibly (period ~9 h).
func windNoise(_ t: Double) -> Float {
    let a = valueNoise(Float((t / 8).truncatingRemainder(dividingBy: 4096)), 0.5), b = valueNoise(Float((t / 3).truncatingRemainder(dividingBy: 4096)), 7.5)
    return 0.9 * a + 0.4 * b
}

extension SIMD2<Float> {
    /// Debris launch speeds are capped per axis (pt/s).
    func limited(_ m: Float = 800) -> SIMD2<Float> { clamped(lowerBound: SIMD2(repeating: -m), upperBound: SIMD2(repeating: m)) }
}

extension Array {
    mutating func swapRemove(_ i: Int) -> Element {
        swapAt(i, count - 1)
        return removeLast()
    }
}

/// Display-link rate choice. Quiet (nothing fast for `holdDown`): economy 20 fps, otherwise 30. Busy: 60 (30...60), except under Low Power / a shrunk
/// window, which stay at 30. Economy never exceeds 30: busy economy 30. Every rate is the panel's maximum divided by a whole number
/// (`snap`), so 30 / 20 / 60 also fit 120, 144, 75 and 50 Hz displays.
public enum FrameRate {
    /// Stepping down waits this long after the last fast moment (stepping up is immediate): gentle triggers near a threshold must not flip 60 <-> 30.
    public static let holdDown = 2.5
    /// Quiet ("calm") floor: fps the display link drops to when nothing fast happened for `holdDown`. Values live in Tuning (30, economy 20 today).
    public static var calmFloor: Float { Tuning.calmFloorFPS }
    public static var calmFloorEconomy: Float { Tuning.calmFloorEconomyFPS }

    /// Interpolation option (Tuning.interpolateCalm, default off): at the calm floor the simulation steps at `floor` while the renderer draws every display
    /// refresh at `lerp(prev, cur, alpha)`, alpha = time since the last sim step / step period, clamped 0...1. Pure helper; the renderer owns the buffers.
    public static func interpAlpha(sinceStep: Double, stepPeriod: Double) -> Float { stepPeriod > 0 ? Float(min(max(sinceStep / stepPeriod, 0), 1)) : 1 }

    /// `target` fps made to divide `maxFPS`: the highest `maxFPS / k` that is at most 25 % above the target (75 Hz busy stays 75, 144 Hz gives 72 / 36 / 24).
    public static func snap(_ target: Float, maxFPS: Int) -> Float {
        guard maxFPS > 0 else { return target }
        let m = Float(maxFPS)
        var k: Float = 1
        while m / k > target * 1.25 + 0.001 { k += 1 }
        return m / k
    }

    /// Frame-rate economy: the economy pref OR a warm Mac (ProcessInfo.ThermalState rawValue >= 1 = .fair; .serious+ additionally pauses the snow, RunState `hot`). Frame rates only: nothing else of Economy mode follows.
    public static func economyFrames(pref: Bool, thermalRaw: Int) -> Bool { pref || thermalRaw >= 1 }

    public static func range(lowPower: Bool, economy: Bool, shrunk: Bool, quiet: Bool, maxFPS: Int = 60) -> (min: Float, max: Float, preferred: Float) {
        func r(_ a: Float, _ b: Float, _ c: Float) -> (min: Float, max: Float, preferred: Float) { (snap(a, maxFPS: maxFPS), snap(b, maxFPS: maxFPS), snap(c, maxFPS: maxFPS)) }
        let q = Tuning.calmFloorFPS, qe = Tuning.calmFloorEconomyFPS
        if economy { return quiet ? r(qe, qe, qe) : r(30, 30, 30) }
        if lowPower || shrunk { return r(30, 30, 30) }
        if quiet { return r(q, q, q) }
        return r(30, 60, 60)
    }

    /// Cursor speed (pt/s) from a move over the REAL elapsed time (never the clamped simulation step: a stall would inflate it).
    /// `slowmo` < 1 stretches simulated time, so the pointer is scaled with it. dt is floored (two frames can share a timestamp: 0/0 would be NaN).
    public static func pointerVelocity(dx: Float, dy: Float, realDt: Double, slowmo: Float = 1) -> SIMD2<Float> {
        SIMD2(dx, dy) / Float(max(realDt * Double(slowmo), 1.0 / 240))
    }
}

public extension FrameRate {
    /// True when a fast cursor concerns this screen: the segment prev→cur touches `frame` grown by `margin` (≈ `Tuning.pointerRadius`).
    /// Other screens have no reason to run at 60 fps because of it. Liang–Barsky slab clip; no allocation.
    static func cursorNear(frame: CGRect, from a: CGPoint, to b: CGPoint, margin: CGFloat = 60) -> Bool {
        let r = frame.insetBy(dx: -margin, dy: -margin)
        var t0: CGFloat = 0, t1: CGFloat = 1
        let d = (x: b.x - a.x, y: b.y - a.y)
        for (p, q) in [(-d.x, a.x - r.minX), (d.x, r.maxX - a.x), (-d.y, a.y - r.minY), (d.y, r.maxY - a.y)] {
            if p == 0 { if q < 0 { return false } }
            else { let t = q / p; if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) } }
        }
        return t0 <= t1
    }
}

/// Cheap sine for per-flake sway and wobble (a libm call per flake per frame is the cost): parabola plus one refinement, max error ~0.001, smooth.
@inline(__always) func fastSin(_ x: Float) -> Float {
    var t = x * 0.159_154_94   // x / 2π
    t -= t.rounded()           // -0.5...0.5
    let y = 8 * t * (1 - 2 * abs(t))
    return 0.225 * (y * abs(y) - y) + y
}
@inline(__always) func fastCos(_ x: Float) -> Float { fastSin(x + 1.570_796_3) }
