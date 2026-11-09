import Foundation

/// Post-pass over the buffer `writePiles` filled (kept separate so `writePiles` stays the reference-checked 2pt-per-bin contour):
/// 1. merges runs of neighbouring slices whose top and base both stay within `tol` pt of one straight line (same dragged/bank flags and
///    inset, no cliffs, and a lighting normal that stays within `nTol` of the merged slope, so the n0 -> n1 ramp reads the same);
/// 2. sets `dragged` bit 4 / 8 (no left / right overlap strip) where the neighbour continues the same slopes, so the shader does not shade
///    that strip twice; the 1pt overlap stays wherever slopes differ (steep slopes keep their seamless joins) and at free ends.
/// Compacts in place and returns the new count.
public func mergePileSegs(_ p: UnsafeMutablePointer<PileSeg>, count n: Int, tol: Float = 0.15, nTol: Float = 0.05) -> Int {
    guard n > 0 else { return 0 }
    func plain(_ s: PileSeg) -> Bool { abs(s.slope) <= 2.5 && abs((s.base1 - s.base0) / max(s.x1 - s.x0, 1e-3)) <= 2.5 }
    var o = 0, i = 0
    while i < n {
        var cur = p[i]; i += 1
        var tLo = -Float.infinity, tHi = Float.infinity, bLo = -Float.infinity, bHi = Float.infinity   // allowed slopes from the start point
        var nLo = min(cur.n0, cur.n1), nHi = max(cur.n0, cur.n1), first = true
        let t0 = cur.top0, b0 = cur.base0, x0 = cur.x0
        let mergeable = plain(cur)
        while mergeable && i < n {
            let q = p[i]
            guard abs(q.x0 - cur.x1) < 1e-3, abs(q.top0 - cur.top1) < 1e-3, abs(q.base0 - cur.base1) < 1e-3,
                  (q.dragged & 3) == (cur.dragged & 3), q.inset == cur.inset, plain(q) else { break }
            let dx = max(q.x1 - x0, 1e-3), st = (q.top1 - t0) / dx, sb = (q.base1 - b0) / dx
            // The interior point (cur's old end) must lie within tol of the new chord: first time its slope band is open, then intersected.
            let ix = cur.x1 - x0
            var tl = tLo, th = tHi, bl = bLo, bh = bHi
            if ix > 1e-3 { tl = max(tl, (cur.top1 - tol - t0) / ix); th = min(th, (cur.top1 + tol - t0) / ix); bl = max(bl, (cur.base1 - tol - b0) / ix); bh = min(bh, (cur.base1 + tol - b0) / ix) }
            guard st >= tl, st <= th, sb >= bl, sb <= bh else { break }
            let lo = min(nLo, q.n0, q.n1), hi = max(nHi, q.n0, q.n1)
            guard max(abs(lo - st), abs(hi - st)) <= nTol else { break }
            if first, abs(min(cur.n0, cur.n1) - st) > nTol || abs(max(cur.n0, cur.n1) - st) > nTol { break }
            first = false
            tLo = tl; tHi = th; bLo = bl; bHi = bh; nLo = lo; nHi = hi
            cur.x1 = q.x1; cur.top1 = q.top1; cur.base1 = q.base1; cur.n1 = q.n1
            cur.slope = st
            i += 1
        }
        p[o] = cur; o += 1
    }
    // Overlap only where it hides something: neighbours that continue the same top and base slopes need no strip.
    func bs(_ s: PileSeg) -> Float { (s.base1 - s.base0) / max(s.x1 - s.x0, 1e-3) }
    if o > 1 {
        for k in 0..<(o - 1) {
            let a = p[k], b = p[k + 1]
            guard abs(a.x1 - b.x0) < 1e-3, abs(a.top1 - b.top0) < 0.05, abs(a.base1 - b.base0) < 0.05, plain(a), plain(b),
                  abs(a.slope - b.slope) <= 0.05, abs(bs(a) - bs(b)) <= 0.05 else { continue }
            p[k].dragged |= 8; p[k + 1].dragged |= 4
        }
    }
    return o
}
