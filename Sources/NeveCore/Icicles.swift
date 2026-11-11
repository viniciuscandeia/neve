// AGENT HEADER - Sources/NeveCore/Icicles.swift  (stalactites under frozen windows)
// Role: `Icicle` (window-relative: win id, slot, dx from the left edge, len/maxLen, width, tilt, w0 = width at spawn so a resize breaks it) in `SnowField.icicles` (<= 10 per window, 40 per screen), `stepIce` (growth, break on fast window motion
//   via icicleBreakSpeed = shedStart/2, vanish), `breakIcicle` (2-3 thin slabs; Reduce Motion fades instead; muted = gone), `breakIcicles` (cursor sweep a->b shatters them), `writeIciclePrims` (blue edge triangle + pale fill + white highlight,
//   after the frost lip; `shift` moves ones on the dragged window), `hash01` (deterministic per-key noise, independent of the sim RNG). Colours from Palette.ice/iceEdge/iceShine. Uses `fxRng`.
// Callers: Frost.swift (spawn), Surfaces.sweep (breaking), Overlay.writePrims (draw). Tests: IceAvalancheTests, FrostTests.

import CoreGraphics
import Foundation

extension Tuning {
    static let maxStalactitesPerWindow = 10
    static let maxStalactitesPerScreen = 40
    static let icicleBreakSpeed: Float = shedStart * 0.5
}

/// Stalactite hanging under a frozen window (Frost.swift); `dx` = distance from the left edge. Window-relative, so it travels with the window.
struct Icicle {
    var win: Int
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
    var grow: Float = 0      // growth, pt per second (before the demo speed-up)
}

extension SnowField {
    /// Deterministic 0..<1 per key; independent of the simulation RNG, so icicles never perturb other sequences.
    static func hash01(_ k: Int) -> Float {
        var g = SplitMix64(seed: UInt64(bitPattern: Int64(k)))
        return Float(g.next() >> 40) / Float(1 << 24)
    }

    func stepIce(dt: Float) {
        guard !icicles.isEmpty || !surfaces.isEmpty else { return }
        stepFrost(dt: dt)
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
            let held = iceWin.contains { $0.id == c.win && $0.frozen }
            if abs(Float(fr.width) - c.w0) > 0.5 || (v.x * v.x + v.y * v.y) > Tuning.icicleBreakSpeed * Tuning.icicleBreakSpeed || !held {
                breakIcicle(i, v); i -= 1; continue
            }
            if c.fade < 1 { c.fade = min(1, c.fade + dt * 0.7) }   // Reduce Motion stalactites fade in
            let r = surfaces[si].radius
            let w = Float(fr.width), d = max(r - c.dx, c.dx - (w - r), 0)
            c.x = Float(fr.minX) + c.dx; c.y = Float(fr.minY) + r - (r * r - d * d).squareRoot() + 0.5   // top tucked into the frost lip
            if !covered(si, SIMD2(c.x, c.y)) { c.len = min(c.maxLen, c.len + dt * c.grow * config.iceSpeed * (intensity == .nevasca ? 2 : 1)) }   // anchor hidden by a front window: no growth
            icicles[i] = c
            i -= 1
        }
        iceT += dt
        guard iceT >= 1 else { return }
        iceT = 0
        scanFrost()
    }

    /// Shatters icicle `i` into 2-3 thin slabs (Reduce Motion: fades; muted: just gone).
    func breakIcicle(_ i: Int, _ v: SIMD2<Float>) {
        let c = icicles[i]
        if calm || melting, !silent { icicles[i].dying = true; return }
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
    /// Frozen windows get their frost lip first (Frost.swift).
    public func writeIciclePrims(_ w: inout PrimWriter, contrast: Bool = false, shift: (Int?) -> SIMD2<Float>) {
        writeFrostPrims(&w, contrast: contrast, shift: shift)
        let edge = Rig.a(contrast ? Rig.shadowHC : Rig.c4(Palette.iceEdge.now), 0.7)
        for c in icicles {
            if let si = index[c.win], covered(si, SIMD2(c.x, c.y)) || covered(si, SIMD2(c.tilt + c.x, c.y - c.len)) { continue }   // hidden by a window in front
            let p = SIMD2(c.x, c.y) + shift(c.win), a = c.fade, hw = c.width / 2
            let tip = p + SIMD2(c.tilt, -c.len)
            w.triangle(p + SIMD2(-hw - 0.5, 0.5), p + SIMD2(hw + 0.5, 0.5), tip + SIMD2(0, -0.8), color: Rig.a(edge, a))
            w.triangle(p + SIMD2(-hw, 0), p + SIMD2(hw, 0), tip, color: Rig.c4(Palette.ice.now, 0.75 * a))
            w.capsule(from: p + SIMD2(-hw * 0.5, -0.5), to: p + SIMD2(c.tilt * 0.4 - hw * 0.15, -c.len * 0.65), width: 0.6, color: Rig.c4(Palette.iceShine.now, 0.7 * a))
        }
    }
}
