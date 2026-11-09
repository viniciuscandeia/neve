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

/// Display-link rate choice. Calm (nothing fast for 0.5 s): economy 20 fps, otherwise 30. Busy: 60 (30...60), except under Low Power / a shrunk
/// window, which stay at 30. Economy never exceeds 30: busy economy 30.
public enum FrameRate {
    public static func range(lowPower: Bool, economy: Bool, shrunk: Bool, calm: Bool) -> (min: Float, max: Float, preferred: Float) {
        if economy { return calm ? (20, 20, 20) : (30, 30, 30) }
        if lowPower || shrunk || calm { return (30, 30, 30) }
        return (30, 60, 60)
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
