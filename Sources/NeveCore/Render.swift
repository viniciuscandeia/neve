import CoreGraphics
import Foundation

/// GPU instance, 24 bytes (8-aligned); layout mirrors the Metal struct.
public struct Instance {
    var pos: SIMD2<Float>
    var size: Float
    var alpha: Float
    var seed: Float
}

/// One SDF primitive for the Metal pass, 64 bytes; layout mirrors the Metal struct.
/// kind 0 = ellipse (a = centre, b = radii, c.x = rotation), 1 = capsule (a -> b, `width` = thickness),
/// 2 = convex quad / triangle (a, b, c, d; triangle: d = c). `soft` widens the edge (shadows). Colour is straight alpha.
public struct Prim {
    public var a = SIMD2<Float>.zero, b = SIMD2<Float>.zero, c = SIMD2<Float>.zero, d = SIMD2<Float>.zero
    public var color = SIMD4<Float>.zero
    public var kind: UInt32 = 0
    public var soft: Float = 0
    public var width: Float = 0
    var _pad: Float = 0
    public init() {}
}

/// Appends prims into a caller-owned buffer (no allocation); drops silently when full.
public struct PrimWriter {
    private let p: UnsafeMutablePointer<Prim>
    private let capacity: Int
    public private(set) var n = 0

    public init(_ p: UnsafeMutablePointer<Prim>, capacity: Int) { self.p = p; self.capacity = capacity }

    private mutating func put(_ q: Prim) {
        guard n < capacity else { return }
        p[n] = q
        n += 1
    }
    public mutating func ellipse(center: SIMD2<Float>, radii: SIMD2<Float>, rotation: Float = 0, color: SIMD4<Float>, soft: Float = 0) {
        var q = Prim(); q.kind = 0; q.a = center; q.b = radii; q.c = SIMD2(rotation, 0); q.color = color; q.soft = soft
        put(q)
    }
    public mutating func capsule(from: SIMD2<Float>, to: SIMD2<Float>, width: Float, color: SIMD4<Float>, soft: Float = 0) {
        var q = Prim(); q.kind = 1; q.a = from; q.b = to; q.width = width; q.color = color; q.soft = soft
        put(q)
    }
    public mutating func quad(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>, color: SIMD4<Float>, soft: Float = 0) {
        var q = Prim(); q.kind = 2; q.a = a; q.b = b; q.c = c; q.d = d; q.color = color; q.soft = soft
        put(q)
    }
    public mutating func triangle(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, color: SIMD4<Float>, soft: Float = 0) {
        quad(a, b, c, c, color: color, soft: soft)
    }
}

extension SnowField {
    /// Fills GPU instances; returns the count.
    public func writeInstances(to p: UnsafeMutablePointer<Instance>) -> Int {
        var n = 0
        for i in 0..<(skyEnd + bgEnd) {
            let f = flakes[i < skyEnd ? i : skyCount + i - skyEnd]
            if f.kind != .dormant { p[n] = Instance(pos: f.pos, size: f.size, alpha: f.alpha * f.fade, seed: f.seed + (f.kind == .background ? 2 : 0)); n += 1 }   // seed >= 2: background flake (shader occlusion by large windows)
        }
        for f in debris { p[n] = Instance(pos: f.pos, size: f.size, alpha: f.alpha * f.fade, seed: f.seed); n += 1 }
        return n
    }

    // MARK: Piles

    /// Writes one `PileSeg` per visible bin pair of every snowy run (the top edge uses the same blur, stable noise and ceiling
    /// clamp the CA path had; the ground bank and the Dock pile are bridged where they meet). Heights come from the eased `shown`
    /// arrays: they rise toward the real ones with a 0.25 s time constant and snap down. Returns nil when nothing changed since the
    /// last write (same `pileVersion`, no easing left): the caller reuses its last buffer. `force` writes regardless (tests).
    public func writePiles(to p: UnsafeMutablePointer<PileSeg>, capacity: Int, dt: Float, force: Bool = false) -> Int? {
        guard force || pileVersion != pileWritten || pileEasing else { return nil }
        pileWritten = pileVersion
        let k = 1 - exp(-dt / Tuning.pileEase)
        var active = false
        for si in surfaces.indices {
            if surfaces[si].pile.shown.count != surfaces[si].pile.heights.count { surfaces[si].pile.shown = surfaces[si].pile.heights }
            for b in surfaces[si].pile.heights.indices {
                let h = surfaces[si].pile.heights[b], cur = surfaces[si].pile.shown[b]
                if h == cur { continue }
                if h < cur { surfaces[si].pile.shown[b] = h; continue }
                let nx = cur + (h - cur) * k
                if h - nx < 0.01 { surfaces[si].pile.shown[b] = h } else { surfaces[si].pile.shown[b] = nx; active = true }
            }
        }
        pileEasing = active
        pileEnds.removeAll(keepingCapacity: true)
        let bw = Tuning.binWidth
        var n = 0
        func put(_ x0: Float, _ t0: Float, _ b0: Float, _ x1: Float, _ t1: Float, _ b1: Float, _ drag: Bool) {
            guard n < capacity else { return }
            p[n] = PileSeg(x0: x0, x1: x1, top0: t0, top1: t1, base0: b0, base1: b1, slope: (t1 - t0) / max(x1 - x0, 1e-3), dragged: drag ? 1 : 0)
            n += 1
        }
        for s in surfaces {
            let h = s.pile.shown, vis = s.pile.visible, base = s.pile.base
            let cnt = h.count, edge = s.edgeY, drag = s.id == draggingID
            let drop: Float = s.id == Tuning.groundID ? 0 : 1
            func x(_ i: Int) -> Float { (Float(s.c0 + i) + 0.5) * bw }
            func ceiling(_ i: Int) -> Float { edge + base[i] + s.pile.cap[i] }   // infinite where no window is in front
            // Stable irregularity keyed on the window-relative column (travels with the pile), interpolated between every 3rd column.
            func jitter(_ i: Int, _ sm: Float) -> Float {
                let rel = s.c0 + i - s.anchor, r = ((rel % 3) + 3) % 3, g = rel - r
                let nz = Float(noise(g)) * (1 - Float(r) / 3) + Float(noise(g + 3)) * Float(r) / 3
                return nz * min(sm * 0.08, 1.5)
            }
            func top(_ i: Int, _ b: Int, _ e: Int) -> Float {
                // Runs split at the Dock bar ends keep their full height there (no taper): that edge is a wall, not a pile end.
                // Walls (a hidden neighbour), supported ends and Dock splits hold their full height: no taper there.
                let l = i > b ? h[i - 1] : (b > 0 || s.pile.supportL || s.pile.splits.contains(b) ? h[i] : 0), r = i < e - 1 ? h[i + 1] : (e < cnt || s.pile.supportR || s.pile.splits.contains(e) ? h[i] : 0)
                let sm = (l + 2 * h[i] + r) / 4
                return min(edge + base[i] + sm + jitter(i, sm), ceiling(i))
            }
            var b = 0
            while b < cnt {
                guard vis[b] else { b += 1; continue }
                var e = b
                while e < cnt && vis[e] && (e == b || !s.pile.splits.contains(e)) { e += 1 }
                var lo = b, hi = e - 1
                while lo <= hi && h[lo] <= 0.15 { lo += 1 }
                while hi >= lo && h[hi] <= 0.15 { hi -= 1 }
                if lo <= hi {
                    lo = max(b, lo - 1); hi = min(e - 1, hi + 1)
                    var prev = (x: x(lo), t: top(lo, b, e), b: edge + base[lo] - drop)
                    let first = prev
                    if lo < hi {
                        for i in (lo + 1)...hi {
                            let cur = (x: x(i), t: top(i, b, e), b: edge + base[i] - drop)
                            put(prev.x, prev.t, prev.b, cur.x, cur.t, cur.b, drag)
                            prev = cur
                        }
                    }
                    pileEnds.append(PileEnd(id: s.id, first: first, last: prev, drag: drag))
                }
                b = e
            }
        }
        // A ground bank that meets the Dock pile (ends within ~2.5pt in y (the top has up to 1.5pt of noise), close in x) reads as one snowbank.
        for g in pileEnds where g.id == Tuning.groundID {
            for d in pileEnds where d.id == 0 {
                if g.last.x <= d.first.x, d.first.x - g.last.x < 60, abs(d.first.t - g.last.t) <= 2.5 {
                    put(g.last.x, g.last.t, g.last.b, d.first.x, d.first.t, d.first.b, d.drag)
                } else if d.last.x <= g.first.x, g.first.x - d.last.x < 60, abs(g.first.t - d.last.t) <= 2.5 {
                    put(d.last.x, d.last.t, d.last.b, g.first.x, g.first.t, g.first.b, d.drag)
                }
            }
        }
        // Seam links (a drift reaching a front window's top, windows side by side): bridge the run ends so the contour is one chain.
        for l in seams {
            for a in pileEnds where a.id == l.left {
                for c in pileEnds where c.id == l.right && c.first.x >= a.last.x && c.first.x - a.last.x < 8 {
                    put(a.last.x, a.last.t, a.last.b, c.first.x, c.first.t, c.first.b, a.drag || c.drag)
                }
            }
        }
        return n
    }
}

/// One bin-pair slice of a pile contour for the Metal pile pass, 32 bytes; layout mirrors the Metal struct.
public struct PileSeg {
    public var x0: Float, x1: Float, top0: Float, top1: Float, base0: Float, base1: Float, slope: Float
    public var dragged: UInt32   // 1 = on the window being dragged (the app shifts it with the mouse)
}

/// Ends of a ground / Dock run, for bridging where they meet.
struct PileEnd {
    typealias P = (x: Float, t: Float, b: Float)
    let id: Int
    let first: P, last: P
    let drag: Bool
}
