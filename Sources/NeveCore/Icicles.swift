import CoreGraphics
import Foundation

extension Tuning {
    static let icicleMinPile: Float = 8          // pile height near a window end that lets icicles form
    static let icicleBreakPile: Float = 3        // below this the icicle drops
    static let icicleZone: Float = 30            // pt from each window end whose pile height counts
    static let icicleGrowth: Float = 1.0 / 60    // pt per second of snowfall (x2 Nevasca)
    static let maxIciclesPerWindow = 6
    static let maxIciclesPerScreen = 24
    static let icicleBreakSpeed: Float = shedStart * 0.5
}

/// Hangs just outside a window's top corner (never over window content). `dx` is relative to the window's left edge, so it travels with the window.
struct Icicle {
    var win: Int
    var right: Bool
    var slot: UInt8
    var dx: Float
    var len: Float
    var maxLen: Float
    var width: Float
    var tilt: Float
    var w0: Float            // window width at spawn: a resize breaks it
    var x: Float = 0, y: Float = 0   // last known top (also where it breaks if the window vanishes)
    var fade: Float = 1
    var dying = false        // Reduce Motion: fades out instead of shattering
}

extension SnowField {
    /// Deterministic 0..<1 per key; independent of the simulation RNG, so icicles never perturb other sequences.
    static func hash01(_ k: Int) -> Float {
        var g = SplitMix64(seed: UInt64(bitPattern: Int64(k)))
        return Float(g.next() >> 40) / Float(1 << 24)
    }

    /// Tallest visible pile within `icicleZone` of the (real) window end.
    func endHeight(si: Int, right: Bool) -> Float {
        let fr = surfaces[si].frame, c0 = surfaces[si].c0, n = surfaces[si].pile.heights.count
        let lo = right ? Float(fr.maxX) - Tuning.icicleZone : Float(fr.minX)
        let b0 = max(0, Int(lo * invBin) - c0), b1 = min(n - 1, Int((lo + Tuning.icicleZone) * invBin) - c0)
        guard b0 <= b1 else { return 0 }
        var m: Float = 0
        for b in b0...b1 where surfaces[si].pile.visible[b] { m = max(m, surfaces[si].pile.heights[b]) }
        return m
    }

    func stepIce(dt: Float) {
        guard !icicles.isEmpty || !surfaces.isEmpty else { return }
        let rate = Tuning.icicleGrowth * config.iceSpeed * (intensity == .nevasca ? 2 : 1) * (outro ? 0 : 1)
        var i = icicles.count - 1
        while i >= 0 {
            var c = icicles[i]
            if c.dying {
                c.fade -= dt * 2
                if c.fade <= 0 { icicles.swapAt(i, icicles.count - 1); icicles.removeLast() } else { icicles[i] = c }
                i -= 1; continue
            }
            guard let si = index[c.win] else { breakIcicle(i, .zero); i -= 1; continue }   // window closed / minimized
            let fr = surfaces[si].frame, v = surfaces[si].vel
            if abs(Float(fr.width) - c.w0) > 0.5 || (v.x * v.x + v.y * v.y) > Tuning.icicleBreakSpeed * Tuning.icicleBreakSpeed
                || endHeight(si: si, right: c.right) < Tuning.icicleBreakPile {
                breakIcicle(i, v); i -= 1; continue
            }
            c.len = min(c.maxLen, c.len + dt * rate)
            c.x = Float(fr.minX) + c.dx; c.y = surfaces[si].edgeY + 1.5   // top tucked under the snow lip
            icicles[i] = c
            i -= 1
        }
        iceT += dt
        guard iceT >= 1 else { return }
        iceT = 0
        guard !silent, !outro else { return }
        for si in surfaces.indices where surfaces[si].id > 0 && surfaces[si].id != draggingID {
            let fr = surfaces[si].frame
            for e in 0..<2 {
                let right = e == 1
                if right ? surfaces[si].pile.supportR : surfaces[si].pile.supportL { continue }
                if right ? Float(fr.maxX) > size.x : Float(fr.minX) < 0 { continue }
                guard endHeight(si: si, right: right) >= Tuning.icicleMinPile else { continue }
                for slot in 0..<3 {
                    let key = surfaces[si].id * 16 + e * 8 + slot
                    guard SnowField.hash01(key) < 0.75, icicles.count < Tuning.maxIciclesPerScreen else { continue }
                    var mine = 0, dup = false
                    for c in icicles where c.win == surfaces[si].id { mine += 1; if c.right == right && c.slot == slot { dup = true } }
                    guard !dup, mine < Tuning.maxIciclesPerWindow else { continue }
                    let off = 0.5 + Float(slot) * 2.5 + SnowField.hash01(key &+ 7) * 1.5
                    icicles.append(Icicle(win: surfaces[si].id, right: right, slot: UInt8(slot),
                                          dx: right ? Float(fr.width) + off : -off, len: 1, maxLen: 6 + 12 * SnowField.hash01(key &+ 1),
                                          width: 2 + 1.5 * SnowField.hash01(key &+ 2), tilt: (SnowField.hash01(key &+ 3) - 0.5) * 1.2, w0: Float(fr.width)))
                }
            }
        }
    }

    /// Shatters icicle `i` into 2-3 thin slabs (Reduce Motion: fades; muted: just gone).
    func breakIcicle(_ i: Int, _ v: SIMD2<Float>) {
        let c = icicles[i]
        if calm, !silent { icicles[i].dying = true; return }
        icicles.swapAt(i, icicles.count - 1); icicles.removeLast()
        guard !silent else { return }
        let n = Int.random(in: 2...3, using: &fxRng)
        for k in 0..<n {
            let t = (Float(k) + 0.5) / Float(n)
            _ = put(Flake(pos: [c.x + Float.random(in: -1...1, using: &fxRng), c.y - c.len * t], vx: v.x * 0.3 + Float.random(in: -15...15, using: &fxRng),
                          fall: max(Float.random(in: 10...50, using: &fxRng) - v.y * 0.3, 0), phase: 0, amp: 0, freq: 0,
                          size: min(max(c.len * 0.5, 3), 7), alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &fxRng), fade: 1,
                          spin: Float.random(in: -3...3, using: &fxRng), vol: c.len * c.width / 2 / Float(n), shape: 2))
        }
        pilesDirty = true
    }

    /// Cursor sweep a->b (radius r) shatters the icicles it touches.
    func breakIcicles(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ r: Float, _ v: SIMD2<Float>) {
        guard !icicles.isEmpty else { return }
        let dx = bx - ax, dy = by - ay, len2 = max(dx * dx + dy * dy, 1e-6)
        var i = icicles.count - 1
        while i >= 0 {
            let c = icicles[i]
            if !c.dying, c.win != draggingID {
                for k in 0..<2 {   // near the top and near the tip
                    let f: Float = k == 0 ? 0.15 : 0.85
                    let px = c.x, py = c.y - c.len * f
                    let t = min(max(((px - ax) * dx + (py - ay) * dy) / len2, 0), 1)
                    let qx = ax + t * dx - px, qy = ay + t * dy - py
                    if qx * qx + qy * qy <= (r + c.width) * (r + c.width) { breakIcicle(i, v); break }
                }
            }
            i -= 1
        }
    }

    /// Triangle (blue edge behind, pale fill) plus a white highlight; `shift` moves the ones on the dragged window.
    public func writeIciclePrims(_ w: inout PrimWriter, shift: (Int?) -> SIMD2<Float>) {
        for c in icicles {
            let p = SIMD2(c.x, c.y) + shift(c.win), a = c.fade, hw = c.width / 2
            let tip = p + SIMD2(c.tilt, -c.len)
            w.triangle(p + SIMD2(-hw - 0.5, 0.5), p + SIMD2(hw + 0.5, 0.5), tip + SIMD2(0, -0.8), color: SIMD4(0.45, 0.62, 0.85, 0.5 * a))
            w.triangle(p + SIMD2(-hw, 0), p + SIMD2(hw, 0), tip, color: SIMD4(0.80, 0.90, 1.0, 0.75 * a))
            w.capsule(from: p + SIMD2(-hw * 0.5, -0.5), to: p + SIMD2(c.tilt * 0.4 - hw * 0.15, -c.len * 0.65), width: 0.6, color: SIMD4(1, 1, 1, 0.7 * a))
        }
    }
}
