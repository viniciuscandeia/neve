import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

// Reference copy of the pre-optimisation `writePiles` (rediscovers runs from `visible`, allocates `held`, joins bridges against every slice).
// The shipped version must emit exactly the same PileSeg buffer.
extension SnowField {
    func writePilesRef(to p: UnsafeMutablePointer<PileSeg>, capacity: Int, dt: Float, force: Bool = false, dropped: UnsafeMutablePointer<Int>? = nil) -> Int? {
        guard force || pileVersion != pileWritten || pileEasing else { return nil }
        pileWritten = pileVersion
        let k = 1 - exp(-dt / Tuning.pileEase), kDrop = 1 - exp(-dt / 0.05), kSoft = 1 - exp(-dt / 0.12)
        var active = false
        for si in surfaces.indices {
            if surfaces[si].pile.shown.count != surfaces[si].pile.heights.count { surfaces[si].pile.shown = surfaces[si].pile.heights }
            for b in surfaces[si].pile.heights.indices {
                let h = surfaces[si].pile.heights[b], cur = surfaces[si].pile.shown[b]
                if h == cur { continue }
                if h < cur && calm { surfaces[si].pile.shown[b] = h; continue }   // Reduce Motion: drops snap
                let nx = cur + (h - cur) * (h < cur ? (cur - h < 12 && h > 0.3 ? kSoft : kDrop) : k)   // small drops that leave snow (a plowed groove) ease over ~0.3 s
                if abs(h - nx) < (h < cur ? 0.05 : 0.01) { surfaces[si].pile.shown[b] = h } else { surfaces[si].pile.shown[b] = nx; active = true }
            }
        }
        pileEasing = active
        pileEnds.removeAll(keepingCapacity: true)
        let bw = Tuning.binWidth
        var n = 0
        dropped?.pointee = 0
        func put(_ x0: Float, _ t0: Float, _ b0: Float, _ x1: Float, _ t1: Float, _ b1: Float, _ drag: Bool, bank: Bool = false) {   // bank: shades like the ground bank (AO measured from the ground, not from this piece's own base)
            guard n < capacity else { dropped?.pointee += 1; return }
            p[n] = PileSeg(x0: x0, x1: x1, top0: t0, top1: t1, base0: b0, base1: b1, slope: (t1 - t0) / max(x1 - x0, 1e-3), dragged: (drag ? 1 : 0) | (bank ? 2 : 0), n0: (t1 - t0) / max(x1 - x0, 1e-3), n1: (t1 - t0) / max(x1 - x0, 1e-3))
            n += 1
        }
        // Ground bank height beside each end of the Dock bar: the Dock pile's rounded corners are filled up to it, so bank and Dock top are one contour.
        var fillL: Float = 0, fillR: Float = 0, bankL = -1, bankR = -1   // bankL/R: the ground columns holding that height
        if let gi = index[Tuning.groundID], let di = index[0] {
            let g = surfaces[gi].pile.shown, d = surfaces[di].pile
            if g.count == numCols { bankL = column(d.x0 - bw); bankR = column(d.x1 + bw); fillL = g[bankL]; fillR = g[bankR] }
        }
        // The ground slice between the bank column and the Dock end is replaced by the bridge body below (one fill, no doubled halo / crest); held back until we know a bridge exists.
        var held: [(side: Int, seg: PileSeg)] = [], bridged = [false, false]
        for s in surfaces {
            let h = s.pile.shown, vis = s.pile.visible, base = s.pile.base
            let cnt = h.count, edge = s.edgeY, drag = s.id == draggingID
            let drop: Float = s.id == Tuning.groundID ? 0 : 1
            func x(_ i: Int) -> Float { (Float(s.c0 + i) + 0.5) * bw }
            func ceiling(_ i: Int) -> Float { edge + base[i] + s.pile.cap[i] }   // infinite where no window is in front
            // Stable irregularity keyed on the window-relative column (travels with the pile), interpolated between every 3rd column.
            func jitter(_ i: Int, _ sm: Float) -> Float {
                let rel = s.c0 + i - s.anchor, r = ((rel % 3) + 3) % 3, g = rel - r
                let u = Float(r) / 3, w = u * u * (3 - 2 * u)   // smoothstep weight: no kinks at the knots
                let nz = Float(noise(g)) * (1 - w) + Float(noise(g + 3)) * w
                let fine = 0.3 * Float(noise(rel &* 7 &+ 1013)) * min(sm / 4, 1)   // extra 1.5pt octave, stable per column
                return nz * min(sm * 0.08, s.pile.maxes.isEmpty ? 1.5 : 2.5) + fine   // the Dock bank is bigger: a little more texture
            }
            // Dock pile, on its rounded corner: the bank's height beside the bar end eases (smoothstep) into the Dock snow level over the corner's width,
            // a rounded shoulder instead of a flat block; wherever the arc is higher than that curve the plain pile on the arc shows.
            var cornL = 0, cornR = 0
            if s.id == 0 { while cornL < cnt && base[cornL] < -0.01 { cornL += 1 }; while cornR < cnt && base[cnt - 1 - cornR] < -0.01 { cornR += 1 } }
            func fill(_ i: Int) -> Float? {
                guard s.id == 0, base[i] < -0.01 else { return nil }
                let left = x(i) < (s.pile.x0 + s.pile.x1) / 2
                let f = left ? fillL : fillR
                let u = left ? Float(i + 1) / Float(cornL + 1) : Float(cnt - i) / Float(cornR + 1), w = u * u * (3 - 2 * u)
                let inner = left ? min(cornL, cnt - 1) : max(cnt - 1 - cornR, 0)
                let v = f + (edge + h[inner] - f) * w
                return v > edge + base[i] + 0.15 && f > 0 ? v : nil
            }
            func top(_ i: Int, _ b: Int, _ e: Int) -> Float {
                // Walls (a hidden neighbour) and supported ends hold their full height: no taper there.
                // A ground column beside a Dock bar end ignores the (much lower) under-bar neighbour: the bank keeps its full height up to the bar.
                func nb(_ j: Int) -> Float { s.id == Tuning.groundID && s.pile.cap[j] < h[i] ? h[i] : h[j] }
                let l = i > b ? nb(i - 1) : (b > 0 || s.pile.supportL ? h[i] : 0), r = i < e - 1 ? nb(i + 1) : (e < cnt || s.pile.supportR ? h[i] : 0)
                let sm = (l + 2 * h[i] + r) / 4
                // The bank column beside a Dock bar end sits exactly at the filled corner's height (no smoothing / noise): bank and Dock pile share one contour point.
                if s.id == Tuning.groundID && (i == bankL || i == bankR) { return min(edge + base[i] + h[i], ceiling(i)) }
                return min(max(edge + base[i] + sm + jitter(i, sm), fill(i) ?? -.infinity), ceiling(i))
            }
            var b = 0
            while b < cnt {
                guard vis[b] else { b += 1; continue }
                var e = b
                while e < cnt && vis[e] { e += 1 }
                // Snowy stretches only: 3+ bare bins split the run, so two specks far apart stay two specks (no 1pt film drawn between them).
                var k = b
                while k < e {
                    var lo = k
                    while lo < e && h[lo] <= 0.15 && fill(lo) == nil { lo += 1 }
                    var hi = lo, j = lo + 1, gap = 0
                    while j < e && gap < 3 { if h[j] <= 0.15 && fill(j) == nil { gap += 1 } else { gap = 0; hi = j }; j += 1 }
                    k = max(hi + 1, j)
                    if lo < e {
                        lo = max(b, lo - 1); hi = min(e - 1, hi + 1)
                        var prev = (x: x(lo), t: top(lo, b, e), b: edge + base[lo] - drop)
                        let first = prev, seg0 = n
                        if lo < hi {
                            for i in (lo + 1)...hi {
                                let cur = (x: x(i), t: top(i, b, e), b: edge + base[i] - drop)
                                let side = s.id != Tuning.groundID ? -1 : fillL > 0 && i - 1 == bankL ? 0 : fillR > 0 && i == bankR ? 1 : -1
                                if side >= 0 {
                                    held.append((side, PileSeg(x0: prev.x, x1: cur.x, top0: prev.t, top1: cur.t, base0: prev.b, base1: cur.b, slope: (cur.t - prev.t) / max(cur.x - prev.x, 1e-3), dragged: drag ? 1 : 0, n0: (cur.t - prev.t) / max(cur.x - prev.x, 1e-3), n1: (cur.t - prev.t) / max(cur.x - prev.x, 1e-3))))
                                } else {
                                    put(prev.x, prev.t, prev.b, cur.x, cur.t, cur.b, drag, bank: s.id == 0 && (fill(i - 1) != nil || fill(i) != nil))
                                }
                                prev = cur
                            }
                        }
                        pileEnds.append(PileEnd(id: s.id, first: first, last: prev, drag: drag, segs: seg0..<n))
                    }
                }
                b = e
            }
        }
        let bridgeStart = n
        // A ground bank that meets the Dock pile (ends within ~2.5pt in y (the top has up to 1.5pt of noise), close in x) reads as one snowbank.
        for g in pileEnds where g.id == Tuning.groundID {
            for d in pileEnds where d.id == 0 {
                // Only the ground stretch nearest the Dock end bridges (the ground run can be split into several snowy stretches).
                if g.last.x <= d.first.x, d.first.x - g.last.x < 60, abs(d.first.t - g.last.t) <= 2.5,
                   !pileEnds.contains(where: { ($0.id == Tuning.groundID && $0.last.x > g.last.x && $0.last.x <= d.first.x) || ($0.id == 0 && $0.first.x < d.first.x) }) {
                    put(g.last.x, g.last.t, g.last.b, d.first.x, d.first.t, d.first.b, d.drag)
                } else if d.last.x <= g.first.x, g.first.x - d.last.x < 60, abs(g.first.t - d.last.t) <= 2.5,
                          !pileEnds.contains(where: { ($0.id == Tuning.groundID && $0.first.x < g.first.x && $0.first.x >= d.last.x) || ($0.id == 0 && $0.last.x > d.last.x) }) {
                    put(d.last.x, d.last.t, d.last.b, g.first.x, g.first.t, g.first.b, d.drag)
                }
            }
        }
        // The Dock pile's filled corner continues the bank: one contour from the ground up and over onto the Dock. Only when the bank reaches the Dock snow's end (within 4pt): a lower bank would make a tall thin sliver up the bar's side, so the Dock pile just ends on the arc and the ground chain runs on alone.
        for d in pileEnds where d.id == 0 {
            // Only the Dock snow's outer ends meet the bank (the Dock run can be split into several snowy stretches).
            let outerL = !pileEnds.contains { $0.id == 0 && $0.first.x < d.first.x }, outerR = !pileEnds.contains { $0.id == 0 && $0.last.x > d.last.x }
            if outerL, fillL > 0, fillL >= d.first.t - 4 { put((Float(column(d.first.x - bw)) + 0.5) * bw, fillL, 0, d.first.x, d.first.t, 0, d.drag, bank: true); bridged[0] = true }
            if outerR, fillR > 0, fillR >= d.last.t - 4 { put(d.last.x, d.last.t, 0, (Float(column(d.last.x + bw)) + 0.5) * bw, fillR, 0, d.drag, bank: true); bridged[1] = true }
        }
        for h in held where !bridged[h.side] { guard n < capacity else { dropped?.pointee += 1; continue }; p[n] = h.seg; n += 1 }   // no bridge came: keep the plain ground slice
        // Seam links (a drift reaching a front window's top, windows side by side): bridge the run ends so the contour is one chain.
        for l in seams {
            for a in pileEnds where a.id == l.left {
                for c in pileEnds where c.id == l.right && c.first.x >= a.last.x && c.first.x - a.last.x < 8 {
                    // The lower side rises to the other's top over a gentle ramp (the drift reaches the front pile's surface, no cliff).
                    var a = a, c = c
                    let d = c.first.t - a.last.t
                    if abs(d) > 0.05 {
                        if d > 0 { liftRun(p, a.segs, d, atEnd: true, edge: a.last.x); a.last.t += d } else { liftRun(p, c.segs, -d, atEnd: false, edge: c.first.x); c.first.t -= d }
                    }
                    put(a.last.x, a.last.t, a.last.b, c.first.x, c.first.t, c.first.b, a.drag || c.drag)
                }
            }
        }
        // Smoothed end slopes: where two segments meet (same x, same height within tolerance) both ends take the average of the two slopes, so the
        // lighting normal is continuous. Run neighbours are adjacent in the buffer; bridges / held slices (appended after) are matched against everything.
        func join(_ a: Int, _ b: Int) {
            guard abs(p[a].x1 - p[b].x0) < 1e-3, abs(p[a].top1 - p[b].top0) < 0.05 else { return }
            let m = (p[a].slope + p[b].slope) / 2
            p[a].n1 = m; p[b].n0 = m
        }
        if n > 1 { for i in 0..<(n - 1) { join(i, i + 1) } }
        if bridgeStart < n { for j in bridgeStart..<n { for i in 0..<bridgeStart { join(i, j); join(j, i) } } }
        return n
    }
}
