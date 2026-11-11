// AGENT HEADER - Sources/NeveCore/Frost.swift  (freeze progress per window + frost lip drawing)
// Role: `WinIce` (per-window freeze progress: acc, fill, frost 0...1, frozen, w0/h0 at start) tracked in `SnowField.iceWin`; `scanFrost()` (called once a second from Icicles.swift: refresh each window's `fillRatio` = mean height/limit
//   over visible bins of its top pile, and start tracking windows with fill >= frozenFill 0.7, Nevasca thawFill 0.25) and `stepFrost` (progress `acc` grows while fill >= that threshold; frozen at frozenAfter 180 s, Nevasca 120 s, then
//   `spawnStalactites`; progress and frozen are reset when the window is resized, moves faster than icicleBreakSpeed, fill < thawFill, or while `quiet`; NEVE_DEMO_ICE speeds the clock via config.iceSpeed, capped at 18x), `frost` eases to 1
//   over 15 s (1.5 s calm) when frozen and back to 0 over 3 s, `spawnStalactites` (2..Tuning.maxStalactitesPerWindow seeded spots along the bottom edge, thicker near corners; appends `Icicle`s, see Icicles.swift), `writeFrostPrims`
//   (pale blue-white lip 0.8 pt under the bottom edge and rounded corners + a faint haze at each lower corner, clipped by windows in front via `clipSegment`, Liang-Barsky, recursive, no array allocation beyond the 4-tuple loop), `covered`.
// Frost state is window-relative (local frame coords); the `shift` closure supplied by Overlay moves it with a dragged window. `iceWin` entries are stashed / restored across Space switches (Surfaces.swift) and cleared by clear().
// Tests: FrostTests, IceAvalancheTests. Units: pt, sim seconds.

import CoreGraphics
import Foundation

extension Tuning {
    static let frozenAfter: Float = 180          // snowfall seconds with the top pile >= frozenFill full
    static let nevascaFrozenAfter: Float = 120   // Nevasca: any decent pile (>= thawFill) counts
    static let frozenFill: Float = 0.7
    static let thawFill: Float = 0.25            // below this the pile is "knocked off": freeze progress and frost are lost
    static let freezeDemoSpeed: Float = 18       // demo cap on the freeze clock (NEVE_DEMO_ICE: ~10 s)
}

/// Freeze progress of one window. Frozen windows grow stalactites along the bottom edge and a frost lip.
struct WinIce {
    var id: Int
    var acc: Float = 0, fill: Float = 0, frost: Float = 0
    var frozen = false
    var w0: Float, h0: Float
}

extension SnowField {
    /// Mean of height / limit over the visible bins of the window's top pile (0...1).
    func fillRatio(si: Int) -> Float {
        var sum: Float = 0, n: Float = 0
        let pile = surfaces[si].pile
        for b in pile.heights.indices where pile.visible[b] {
            let l = pile.limit(b)
            guard l > 2 else { continue }
            sum += min(pile.heights[b] / l, 1); n += 1
        }
        return n > 0 ? sum / n : 0
    }

    /// Once a second: refresh each window's fill, and start tracking windows whose pile is full enough.
    func scanFrost() {
        let minFill = intensity == .nevasca ? Tuning.thawFill : Tuning.frozenFill
        for si in surfaces.indices where surfaces[si].id > 0 {
            let id = surfaces[si].id, f = fillRatio(si: si)
            if let j = iceWin.firstIndex(where: { $0.id == id }) { iceWin[j].fill = f }
            else if f >= minFill, !silent, !quiet {
                iceWin.append(WinIce(id: id, fill: f, w0: Float(surfaces[si].frame.width), h0: Float(surfaces[si].frame.height)))
            }
        }
    }

    func stepFrost(dt: Float) {
        guard !iceWin.isEmpty else { return }
        let nev = intensity == .nevasca
        let minFill = nev ? Tuning.thawFill : Tuning.frozenFill, after = nev ? Tuning.nevascaFrozenAfter : Tuning.frozenAfter
        var j = iceWin.count - 1
        while j >= 0 {
            var s = iceWin[j]
            guard let si = index[s.id] else { iceWin.swapAt(j, iceWin.count - 1); iceWin.removeLast(); j -= 1; continue }
            let fr = surfaces[si].frame, v = surfaces[si].vel
            if abs(Float(fr.width) - s.w0) > 0.5 || abs(Float(fr.height) - s.h0) > 0.5 || (v.x * v.x + v.y * v.y) > Tuning.icicleBreakSpeed * Tuning.icicleBreakSpeed
                || s.fill < Tuning.thawFill || quiet {
                s.acc = 0; s.frozen = false; s.w0 = Float(fr.width); s.h0 = Float(fr.height)   // knocked off / moved fast / resized / snow off
            } else if !s.frozen {
                if s.fill >= minFill { s.acc += dt * min(config.iceSpeed, Tuning.freezeDemoSpeed) }
                if s.acc >= after { s.frozen = true; iceWin[j] = s; spawnStalactites(si: si) }
            }
            s.frost = min(max(s.frost + dt / (s.frozen ? (calm ? 1.5 : 15) : -3), 0), 1)
            if !s.frozen && s.frost <= 0 && s.acc <= 0 && s.fill < minFill { iceWin.swapAt(j, iceWin.count - 1); iceWin.removeLast() } else { iceWin[j] = s }
            j -= 1
        }
    }

    /// 4-10 stalactites at seeded, irregular spots along the bottom edge; thicker near the corners.
    func spawnStalactites(si: Int) {
        let fr = surfaces[si].frame, id = surfaces[si].id, w = Float(fr.width)
        let n = max(2, min(Tuning.maxStalactitesPerWindow, Int(w / 70) + 4) / (economy ? 2 : 1))
        guard w > 40, icicles.count + n <= Tuning.maxStalactitesPerScreen else { return }
        for i in 0..<n {
            let key = id * 64 + i + 1_000_000
            let t = (Float(i) + 0.5 + (SnowField.hash01(key) - 0.5) * 0.7) / Float(n)
            let dx = 4 + t * (w - 8)
            let corner = max(0, 1 - min(dx, w - dx) / (0.15 * w + 1))
            let maxLen = 4 + 16 * SnowField.hash01(key &+ 1)
            icicles.append(Icicle(win: id, slot: UInt8(i), dx: dx, len: calm ? maxLen : 1, maxLen: maxLen,
                                  width: 2.2 + 1.4 * SnowField.hash01(key &+ 2) + 1.6 * corner, tilt: (SnowField.hash01(key &+ 3) - 0.5) * 0.8,
                                  w0: w, fade: calm ? 0 : 1, grow: maxLen / (60 + 60 * SnowField.hash01(key &+ 4))))
        }
    }

    func covered(_ si: Int, _ p: SIMD2<Float>) -> Bool {
        for r in surfaces[si].cover where p.x >= Float(r.minX) && p.x <= Float(r.maxX) && p.y >= Float(r.minY) && p.y <= Float(r.maxY) { return true }
        return false
    }

    /// Calls `emit` for the parts of segment a->b not inside any of `cover[k...]` (Liang-Barsky per rect, allocation-free recursion).
    func clipSegment(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ cover: [CGRect], _ k: Int, _ emit: (SIMD2<Float>, SIMD2<Float>) -> Void) {
        var k = k
        while k < cover.count {
            let r = cover[k]; k += 1
            var t0: Float = 0, t1: Float = 1, ok = true
            let d = b - a
            for (p, q) in [(-d.x, a.x - Float(r.minX)), (d.x, Float(r.maxX) - a.x), (-d.y, a.y - Float(r.minY)), (d.y, Float(r.maxY) - a.y)] {
                if p == 0 { if q < 0 { ok = false } }
                else if p < 0 { t0 = max(t0, q / p) } else { t1 = min(t1, q / p) }
            }
            guard ok, t0 < t1 else { continue }
            if t0 > 0 { clipSegment(a, a + d * t0, cover, k, emit) }
            if t1 < 1 { clipSegment(a + d * t1, b, cover, k, emit) }
            return
        }
        emit(a, b)
    }

    /// Frost lip: a pale blue-white line 0.8pt under the bottom edge and its rounded corners, plus a faint haze at each lower corner.
    func writeFrostPrims(_ w: inout PrimWriter, contrast: Bool = false, shift: (Int?) -> SIMD2<Float>) {
        let col = Palette.frost.now, sc = Rig.a(contrast ? Rig.shadowHC : Rig.shadow, 0.25)
        // Frost capsule with a faint shadow capsule 0.8 pt below it, so the lip reads on light backgrounds.
        func lip(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ al: Float, _ w: inout PrimWriter, _ cover: [CGRect], _ sh: SIMD2<Float>) {
            clipSegment(a, b, cover, 0) { a, b in   // a, b unshifted (window-local); drawn shifted
                w.capsule(from: a + sh + SIMD2(0, -0.8), to: b + sh + SIMD2(0, -0.8), width: 1.8, color: Rig.a(sc, al))
                w.capsule(from: a + sh, to: b + sh, width: 1.8, color: SIMD4(col, 0.75 * al))
            }
        }
        for s in iceWin where s.frost > 0.01 {
            guard let si = index[s.id] else { continue }
            let fr = surfaces[si].frame, r = surfaces[si].radius, R = r + 0.8, sh = shift(s.id), a = s.frost
            let x0 = Float(fr.minX), x1 = Float(fr.maxX), y0 = Float(fr.minY), cv = surfaces[si].cover
            for left in [true, false] {
                let cx = left ? x0 + r : x1 - r, cy = y0 + r, sg: Float = left ? -1 : 1
                var prev = SIMD2(cx, cy - R)
                for k in 1...3 {   // from the bottom point round to the side
                    let t = Float.pi / 2 * Float(k) / 3
                    let q = SIMD2(cx + sg * R * sin(t), cy - R * cos(t))
                    lip(prev, q, a, &w, cv, sh)
                    prev = q
                }
                let m = Float.pi / 4
                let hz = SIMD2(cx + sg * (R + 2) * sin(m), cy - (R + 2) * cos(m))
                if !covered(si, hz) { w.ellipse(center: hz + sh, radii: SIMD2(5, 4), color: SIMD4(col, 0.16 * a), soft: 3) }
            }
            lip(SIMD2(x0 + r, y0 - 0.8), SIMD2(x1 - r, y0 - 0.8), a, &w, cv, sh)
        }
    }
}
