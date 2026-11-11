// AGENT HEADER - Sources/NeveCore/Contour.swift  (the drawn snow of window supports: ONE contour per connected group)
// Role: `windowGroups()` = connected sets of window surfaces (seams + walls, from frames only: side by side within 6 pt, or a higher window's end over a lower window's top edge, any step), `writeGroups` = the PileSeg slices of every group.
//   Each group is drawn as ONE column function over its x range: every global column is owned by the OPEN bin (visible, not under a higher window: Pile.open) with the highest top (ties: lower window id), so a lower window's covered span belongs
//   to the higher window's pile. A column's top is the old per-pile crest (1-2-1 blur of `shown`, stable jitter, cap blend, held full height at supported / covered ends); its base follows the owner's edge AND the rounded-corner arc of
//   its frame (also at supported ends: the snow fills the corner cut-out, arc - 1 pt); columns without an owner between two owners (<= 4, the 0...6 pt gap of side-by-side windows) are interpolated. A slope limit over the group
//   (`slope`, 0.95 pt per bin (a gentle ramp: <= 1 pt per 2 pt step)) LIFTS the lower side toward the other crest (forward + backward pass, only into snowy columns, at most `Tuning.maxDrift`, never above the lower pile's own ceiling, and not at all on the corner arc of a bare (unsupported) end: there the crest follows the arc down instead of floating above the closing column): the bank climbs the wall, the crest has no
//   step, it replaces the old per-pile runs stitched with junction merges, blendCrest, liftSeam, seam bridges, tintRefs, drawHeights and the fillet. A pair of owners further apart than `maxStep` after the lift is not joined (the stretch just ends). Draw only: never changes `heights`.
//   z per slice = the window the snow rests on (owner; across owners the one with the lower floor, i.e. the back one: the higher window's occluder clips what lies inside its body); drag = both ends dragged. Stretch rule as before: 3+ bare
//   columns split, one bare column of the same owner closes each end. Order independent: nothing here reads the stacking order except the z numbers.
// Tests: GroupContourTests, StackIndependenceTests, SliceZTests, WallBankTests, JunctionTests, OcclusionTests.

import CoreGraphics
import Foundation

extension SnowField {
    /// Window surfaces (indices) that touch: linked by a seam, or one is a HIGHER window whose end lies over the other's top edge (frames only). Ordered by first member.
    func windowGroups() -> [[Int]] {
        var parent = Array(surfaces.indices)
        func find(_ i: Int) -> Int { var r = i; while parent[r] != r { r = parent[r] }; var k = i; while parent[k] != r { let n = parent[k]; parent[k] = r; k = n }; return r }
        func union(_ a: Int, _ b: Int) { let x = find(a), y = find(b); if x != y { parent[max(x, y)] = min(x, y) } }
        for l in seams { if let a = index[l.left], let b = index[l.right] { union(a, b) } }
        let ws = surfaces.indices.filter { surfaces[$0].id > 0 }
        for (k, i) in ws.enumerated() {
            let a = surfaces[i].frame
            for j in ws[(k + 1)...] {
                let b = surfaces[j].frame
                guard a.minX < b.maxX - 2, b.minX < a.maxX - 2 else { continue }
                let hi = a.maxY >= b.maxY ? a : b, lo = a.maxY >= b.maxY ? b : a
                if hi.maxY - lo.maxY > 1, hi.minY <= lo.maxY + 1 { union(i, j) }
            }
        }
        var out: [[Int]] = [], at: [Int: Int] = [:]
        for i in ws {
            let r = find(i)
            if let g = at[r] { out[g].append(i) } else { at[r] = out.count; out.append([i]) }
        }
        return out
    }

    /// Appends the slices of every window group to `p` (see the header). `n` counts what is written, `dropped` the slices that did not fit.
    func writeGroups(_ p: UnsafeMutablePointer<PileSeg>, capacity: Int, n: inout Int, dropped: UnsafeMutablePointer<Int>?) {
        let bw = Tuning.binWidth, slope: Float = 0.95, maxStep: Float = 2.0
        for group in windowGroups() {
            var lo = Int.max, hi = Int.min
            for si in group { lo = min(lo, surfaces[si].c0); hi = max(hi, surfaces[si].c0 + surfaces[si].pile.heights.count) }
            let m = hi - lo
            guard m > 1 else { continue }
            var own = [Int32](repeating: -1, count: m)   // surface index; -1 nothing, -2 interpolated gap
            var top = [Float](repeating: 0, count: m), flo = top, hs = top, lim = [Float](repeating: .infinity, count: m)
            var zc = [UInt32](repeating: 0, count: m), drg = [Bool](repeating: false, count: m)
            for si in group {
                let s = surfaces[si], pile = s.pile, h = pile.shown, base = pile.base, cnt = h.count, edge = s.edgeY
                let z = zOf[s.id] ?? groundZ, drag = s.id == draggingID
                let rad = min(s.radius, Float(s.frame.width) / 2, Float(s.frame.height) / 2)
                for i in 0..<cnt where pile.open(i) {
                    let c = s.c0 + i - lo, x = (Float(s.c0 + i) + 0.5) * bw
                    // Crest: blur of the shown heights; supported / covered neighbours hold the full height (no taper there), the bare window ends taper to 0.
                    let l = i > 0 ? (pile.open(i - 1) ? h[i - 1] : h[i]) : (pile.supportL ? h[i] : 0)
                    let r = i < cnt - 1 ? (pile.open(i + 1) ? h[i + 1] : h[i]) : (pile.supportR ? h[i] : 0)
                    let sm = (l + 2 * h[i] + r) / 4
                    let ceiling = edge + base[i] + pile.cap[i]   // infinite where no window is in front
                    let plain = min(edge + base[i] + sm + Self.jitter(s, i, sm), ceiling)
                    var t = plain
                    if pile.cap[i].isFinite {   // packed up to a window's underside: drawn exactly at it, blended over the last 1.5 pt
                        let u = min(max((h[i] - (pile.cap[i] - 1.5)) / 1.45, 0), 1)
                        t = plain + (ceiling - plain) * (u * u * (3 - 2 * u))
                    }
                    if own[c] >= 0 && (t < top[c] || (t == top[c] && s.id > surfaces[Int(own[c])].id)) { continue }
                    var b = base[i]   // the base follows the frame's corner arc too (a supported end has no arc in `base`: the snow fills the cut-out)
                    let d = min(x - s.pile.x0, s.pile.x1 - x)
                    var bareArc = false   // on the corner arc of an unsupported end: the lift must not raise the crest above the arc (the closing column stays low: a vertical cut)
                    if rad > 0, d < rad { let k = rad - max(d, 0); b = min(b, -(rad - (rad * rad - k * k).squareRoot())); bareArc = x - s.pile.x0 < s.pile.x1 - x ? !pile.supportL : !pile.supportR }
                    own[c] = Int32(si); top[c] = t; flo[c] = edge + b - 1; hs[c] = h[i]; lim[c] = bareArc ? t : ceiling; zc[c] = z; drg[c] = drag
                }
            }
            // Gaps between two owners (side by side, up to 4 columns): straight bridge.
            var c = 0
            while c < m {
                guard own[c] == -1, c > 0, own[c - 1] != -1 else { c += 1; continue }
                var e = c
                while e < m && own[e] == -1 { e += 1 }
                if e < m, e - c <= 4 {
                    let a = c - 1
                    for k in c..<e {
                        let u = Float(k - a) / Float(e - a)
                        own[k] = -2; top[k] = top[a] + (top[e] - top[a]) * u; flo[k] = flo[a] + (flo[e] - flo[a]) * u
                        hs[k] = min(hs[a], hs[e]); lim[k] = min(lim[a], lim[e]); zc[k] = min(zc[a], zc[e]); drg[k] = drg[a] && drg[e]
                    }
                }
                c = e
            }
            func snow(_ c: Int) -> Bool { own[c] != -1 && hs[c] > 0.15 }
            // Slope limit over the whole group (one smooth function): a snowy column climbs toward a higher snowy neighbour (forward, then backward pass) by at most maxDrift, under its own pile's ceiling.
            // Within one pile the crest already is that gentle, so it only acts at owner changes (walls, seams) and on the odd jittery column.
            for c in 1..<m where snow(c) && snow(c - 1) {
                let cand = min(top[c - 1] - slope, max(top[c], lim[c]), top[c] + Tuning.maxDrift)
                if cand > top[c] { top[c] = cand }
            }
            for c in stride(from: m - 2, through: 0, by: -1) where snow(c) && snow(c + 1) {
                let cand = min(top[c + 1] - slope, max(top[c], lim[c]), top[c] + Tuning.maxDrift)
                if cand > top[c] { top[c] = cand }
            }
            // Stretches: snowy columns, 3+ bare ones split, one bare column of the same owner closes each end.
            c = 0
            while c < m {
                while c < m && !snow(c) { c += 1 }
                guard c < m else { break }
                var a = c, b = c, j = c + 1, gap = 0
                while j < m && gap < 3 { if !snow(j) { gap += 1 } else { gap = 0; b = j }; j += 1 }
                c = max(b + 1, j)
                if a > 0, own[a - 1] >= 0, own[a - 1] == own[a] { a -= 1 }
                if b + 1 < m, own[b + 1] >= 0, own[b + 1] == own[b] { b += 1 }
                if a >= b { continue }
                for i in a..<b {
                    guard own[i] != -1, own[i + 1] != -1, own[i] >= 0 || snow(i), own[i + 1] >= 0 || snow(i + 1), own[i] == own[i + 1] || abs(top[i + 1] - top[i]) <= maxStep else { continue }
                    guard n < capacity else { dropped?.pointee += 1; continue }
                    let x0 = (Float(lo + i) + 0.5) * bw, x1 = x0 + bw, sl = (top[i + 1] - top[i]) / bw
                    p[n] = PileSeg(x0: x0, x1: x1, top0: top[i], top1: top[i + 1], base0: flo[i], base1: flo[i + 1], slope: sl, dragged: drg[i] && drg[i + 1] ? 1 : 0, n0: sl, n1: sl, inset: 1, z: own[i] == own[i + 1] || flo[i] <= flo[i + 1] ? zc[i] : zc[i + 1])
                    n += 1
                }
            }
        }
    }
}
