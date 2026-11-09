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

    /// `target` fps made to divide `maxFPS`: the highest `maxFPS / k` that is at most 25 % above the target (75 Hz busy stays 75, 144 Hz gives 72 / 36 / 24).
    public static func snap(_ target: Float, maxFPS: Int) -> Float {
        guard maxFPS > 0 else { return target }
        let m = Float(maxFPS)
        var k: Float = 1
        while m / k > target * 1.25 + 0.001 { k += 1 }
        return m / k
    }

    public static func range(lowPower: Bool, economy: Bool, shrunk: Bool, quiet: Bool, maxFPS: Int = 60) -> (min: Float, max: Float, preferred: Float) {
        func r(_ a: Float, _ b: Float, _ c: Float) -> (min: Float, max: Float, preferred: Float) { (snap(a, maxFPS: maxFPS), snap(b, maxFPS: maxFPS), snap(c, maxFPS: maxFPS)) }
        if economy { return quiet ? r(20, 20, 20) : r(30, 30, 30) }
        if lowPower || shrunk || quiet { return r(30, 30, 30) }
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
