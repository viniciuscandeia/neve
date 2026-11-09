import CoreGraphics
import Foundation

/// GPU instance, 40 bytes (8-aligned); layout mirrors the Metal struct. kind: 0 flake, 1 clump, 2 slab, 3 puff, 4 glint, 5 drop, 6 out-of-focus disc.
public struct Instance {
    var pos: SIMD2<Float>
    var size: Float
    var alpha: Float
    var seed: Float
    var rot: Float = 0
    var kind: UInt32 = 0
    var vel: SIMD2<Float> = .zero   // pt/s, for the motion streak (0 = none)
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

/// Appends prims into a caller-owned buffer (no allocation); when full it drops and counts them in `dropped` (the caller grows the buffer).
public struct PrimWriter {
    private let p: UnsafeMutablePointer<Prim>
    private let capacity: Int
    public private(set) var n = 0
    public private(set) var dropped = 0

    public init(_ p: UnsafeMutablePointer<Prim>, capacity: Int) { self.p = p; self.capacity = capacity }

    private mutating func put(_ q: Prim) {
        guard n < capacity else { dropped += 1; return }
        p[n] = q
        n += 1
    }
    /// Multiplies the alpha of the prims written since index `start` (a whole figure fading out).
    public mutating func fade(from start: Int, by k: Float) {
        guard k < 1 else { return }
        for i in start..<n { p[i].color.w *= max(k, 0) }
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
            if f.kind != .dormant {
                // Crystals (> 4pt) turn and sway like a pendulum; small dots stay round. Reduce Motion: fixed angle.
                let rot: Float = f.size > 4 && f.kind != .near ? f.seed * 2 * .pi + (calm ? 0 : 0.5 * sin(f.phase)) : 0
                p[n] = Instance(pos: f.pos, size: f.size, alpha: f.alpha * f.fade, seed: f.seed + (f.kind == .background ? 2 : 0), rot: rot, kind: f.kind == .near ? 6 : 0, vel: calm || f.kind == .near ? .zero : f.vel); n += 1
            }   // seed >= 2: background flake (shader occlusion by large windows)
        }
        for f in puffs {   // grow 1 -> 1.8x while fading
            let t = max(f.delay, 0) / Tuning.puffLife
            p[n] = Instance(pos: f.pos, size: f.size * (1 + 0.8 * (1 - t)), alpha: f.alpha * t * t, seed: f.seed, rot: 0, kind: 3); n += 1
        }
        writeDrops(to: p, n: &n)
        for f in glints {
            let env = sin(.pi * min(max(1 - f.delay / Tuning.glintLife, 0), 1))   // 0 -> 1 -> 0
            p[n] = Instance(pos: f.pos + [0, 1.5], size: f.size * (0.6 + 0.4 * env), alpha: env * max(f.fade, 0), seed: f.seed, rot: .pi / 4 + f.seed * 0.5, kind: 4); n += 1   // 1.5pt above the crest
        }
        for f in debris {   // falling chunk: its packed profile rides in kind's upper 24 bits (the shader draws the crest and the broken edges from it)
            // A slab without its own profile (flushed run, split slab, icicle shard) gets a flat rounded block, never the glint branch.
            let k = f.shape == 2 ? 2 | (f.amp > 0 && f.prof > 0 ? f.prof : Flake.pack(thickness: max(f.size * 0.45, 3), left: 0.7, mid: 0.85, right: 0.7)) << 8 : UInt32(f.shape)
            p[n] = Instance(pos: f.pos, size: f.size, alpha: f.alpha * f.fade, seed: f.seed, rot: f.rot, kind: k, vel: calm ? .zero : [f.vx, -f.fall]); n += 1
        }
        return n
    }

    // MARK: Piles

    /// Upper bound of the segments `writePiles` can emit for the current surfaces (one per bin pair, plus bridges): size the buffer from it when the window list changes.
    public var pileSegDemand: Int { surfaces.reduce(0) { $0 + $1.pile.heights.count } + 2 * seams.count + 16 }

    /// Writes one `PileSeg` per bin pair of every snowy stretch of every run (top edge: neighbour blur, stable per-column noise and the
    /// front-window ceiling clamp; the ground bank and the Dock pile are bridged where they meet). Heights come from the eased `shown`
    /// arrays: they rise toward the real ones with a `Tuning.pileEase` time constant and ease down with a 0.05 s one (0.12 s for small drops that
    /// leave snow; Reduce Motion: snap down). Returns nil when nothing changed since the last write (same `pileVersion`, no easing left):
    /// the caller reuses its last buffer. `force` writes regardless (tests).
    /// Note: `shown`, `pileWritten` and `pileEasing` are presentation state (what was last drawn, and the easing toward the real heights), kept in the core so the output stays testable.
    /// `dropped` (optional) receives the number of segments that did not fit in `capacity`.
    public func writePiles(to p: UnsafeMutablePointer<PileSeg>, capacity: Int, dt: Float, force: Bool = false, dropped: UnsafeMutablePointer<Int>? = nil) -> Int? {
        guard force || pileVersion != pileWritten || pileEasing else { return nil }
        pileWritten = pileVersion
        let tp0 = timer?() ?? 0
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
        let tp1 = timer?() ?? 0
        pileEnds.removeAll(keepingCapacity: true)
        let bw = Tuning.binWidth
        var n = 0
        dropped?.pointee = 0
        func put(_ x0: Float, _ t0: Float, _ b0: Float, _ x1: Float, _ t1: Float, _ b1: Float, _ drag: Bool, bank: Bool = false, inset: Float = 0) {   // bank: shades like the ground bank (AO measured from the ground, not from this piece's own base); inset: how far b0/b1 sit under the real edge
            guard n < capacity else { dropped?.pointee += 1; return }
            p[n] = PileSeg(x0: x0, x1: x1, top0: t0, top1: t1, base0: b0, base1: b1, slope: (t1 - t0) / max(x1 - x0, 1e-3), dragged: (drag ? 1 : 0) | (bank ? 2 : 0), n0: (t1 - t0) / max(x1 - x0, 1e-3), n1: (t1 - t0) / max(x1 - x0, 1e-3), inset: inset)
            n += 1
        }
        // Ground bank height beside each end of the Dock bar: the Dock pile's rounded corners are filled up to it, so bank and Dock top are one contour.
        var fillL: Float = 0, fillR: Float = 0, bankL = -1, bankR = -1   // bankL/R: the ground columns holding that height
        if let gi = index[Tuning.groundID], let di = index[0] {
            let g = surfaces[gi].pile.shown, d = surfaces[di].pile
            if g.count == numCols { bankL = column(d.x0 - bw); bankR = column(d.x1 + bw); fillL = g[bankL]; fillR = g[bankR] }
        }
        // The ground slice between the bank column and the Dock end is replaced by the bridge body below (one fill, no doubled halo / crest); held back until we know a bridge exists.
        var heldL: PileSeg?, heldR: PileSeg?, bridgedL = false, bridgedR = false   // at most one ground slice per side
        for s in surfaces {
            let h = s.pile.shown, base = s.pile.base
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
            for run in s.runs {
                let b = run.lowerBound, e = run.upperBound
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
                                    let seg = PileSeg(x0: prev.x, x1: cur.x, top0: prev.t, top1: cur.t, base0: prev.b, base1: cur.b, slope: (cur.t - prev.t) / max(cur.x - prev.x, 1e-3), dragged: drag ? 1 : 0, n0: (cur.t - prev.t) / max(cur.x - prev.x, 1e-3), n1: (cur.t - prev.t) / max(cur.x - prev.x, 1e-3), inset: drop)
                                    if side == 0 { heldL = seg } else { heldR = seg }
                                } else {
                                    put(prev.x, prev.t, prev.b, cur.x, cur.t, cur.b, drag, bank: s.id == 0 && (fill(i - 1) != nil || fill(i) != nil), inset: drop)
                                }
                                prev = cur
                            }
                        }
                        pileEnds.append(PileEnd(id: s.id, first: first, last: prev, drag: drag, segs: seg0..<n))
                    }
                }
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
            if outerL, fillL > 0, fillL >= d.first.t - 4 { put((Float(column(d.first.x - bw)) + 0.5) * bw, fillL, 0, d.first.x, d.first.t, 0, d.drag, bank: true); bridgedL = true }
            if outerR, fillR > 0, fillR >= d.last.t - 4 { put(d.last.x, d.last.t, 0, (Float(column(d.last.x + bw)) + 0.5) * bw, fillR, 0, d.drag, bank: true); bridgedR = true }
        }
        func keep(_ seg: PileSeg?, _ bridged: Bool) {   // no bridge came: keep the plain ground slice
            guard !bridged, let seg else { return }
            guard n < capacity else { dropped?.pointee += 1; return }
            p[n] = seg; n += 1
        }
        keep(heldL, bridgedL); keep(heldR, bridgedR)
        // Seam links (a drift reaching a front window's top, windows side by side): bridge the run ends so the contour is one chain.
        for l in seams {
            for a in pileEnds where a.id == l.left {
                for c in pileEnds where c.id == l.right && c.first.x >= a.last.x && c.first.x - a.last.x < 8 {
                    // The lower side rises to the other's top over a gentle ramp (the drift reaches the front pile's surface, no cliff).
                    var a = a, c = c
                    liftSeam(p, &a, &c)
                    put(a.last.x, a.last.t, a.last.b, c.first.x, c.first.t, c.first.b, a.drag && c.drag, inset: 1)   // moves with the drag only when both sides do (else it would detach from the side that stays)
                }
            }
        }
        // Smoothed end slopes: where two segments meet (same x, same height within tolerance) both ends take the average of the two slopes, so the
        // lighting normal is continuous. Run neighbours are adjacent in the buffer; bridges / held slices (appended after) are matched against the run slices
        // (x strictly increases inside a run: a binary search per run finds the only slice whose end can meet the bridge's start, and the only one whose start can meet its end).
        func join(_ a: Int, _ b: Int) {
            guard abs(p[a].x1 - p[b].x0) < 1e-3, abs(p[a].top1 - p[b].top0) < 0.05 else { return }
            let m = (p[a].slope + p[b].slope) / 2
            p[a].n1 = m; p[b].n0 = m
        }
        let tp2 = timer?() ?? 0
        if n > 1 { for i in 0..<(n - 1) { join(i, i + 1) } }
        if bridgeStart < n {
            for j in bridgeStart..<n {
                for e in pileEnds where !e.segs.isEmpty {
                    var lo = e.segs.lowerBound, hi = e.segs.upperBound
                    while lo < hi { let m = (lo + hi) / 2; if p[m].x1 > p[j].x0 - 1e-3 { hi = m } else { lo = m + 1 } }
                    let a = lo   // first slice whose end reaches the bridge's start
                    lo = e.segs.lowerBound; hi = e.segs.upperBound
                    while lo < hi { let m = (lo + hi) / 2; if p[m].x0 > p[j].x1 - 1e-3 { hi = m } else { lo = m + 1 } }
                    let c = lo   // first slice whose start reaches the bridge's end
                    let end = e.segs.upperBound
                    if min(a, c) < end { join(min(a, c), j); join(j, min(a, c)) }
                    if a != c, max(a, c) < end { join(max(a, c), j); join(j, max(a, c)) }
                }
            }
        }
        if let timer { let tp3 = timer(); pileSeconds.ease += tp1 - tp0; pileSeconds.contour += tp2 - tp1; pileSeconds.join += tp3 - tp2 }
        return n
    }

    /// The lower side of a seam rises toward the other's top (no cliff), but only by what the physics backs: at most 6pt (a drift's usual
    /// boost), over a ramp that stays inside the stretch (slope <= 0.3), and not at all on a thin stretch (a speck must not grow a ramp).
    func liftSeam(_ p: UnsafeMutablePointer<PileSeg>, _ a: inout PileEnd, _ c: inout PileEnd) {
        let d = c.first.t - a.last.t
        guard abs(d) > 0.05 else { return }
        let lowIsA = d > 0
        let low = lowIsA ? a : c, end = lowIsA ? a.last : c.first
        guard end.t - end.b - 1 >= 1 else { return }
        let w = min(20, low.last.x - low.first.x)
        let lift = min(abs(d), 6, 0.3 * w)
        guard lift > 0.01 else { return }
        liftRun(p, low.segs, lift, atEnd: lowIsA, edge: end.x, width: w)
        if lowIsA { a.last.t += lift } else { c.first.t += lift }
    }

    /// Adds up to `d` to the tops of the segments within `width` of one end of a run (full at the end, 0 at the far
    /// side of the ramp), so the bridge to the neighbouring window's pile has no step.
    func liftRun(_ p: UnsafeMutablePointer<PileSeg>, _ r: Range<Int>, _ d: Float, atEnd: Bool, edge: Float, width w: Float) {
        func f(_ x: Float) -> Float { d * max(0, 1 - abs(edge - x) / w) }
        for i in r {
            p[i].top0 += f(p[i].x0); p[i].top1 += f(p[i].x1)
            p[i].slope = (p[i].top1 - p[i].top0) / max(p[i].x1 - p[i].x0, 1e-3)
        }
    }
}

/// One bin-pair slice of a pile contour for the Metal pile pass, 44 bytes; layout mirrors the Metal struct.
public struct PileSeg {
    public var x0: Float, x1: Float, top0: Float, top1: Float, base0: Float, base1: Float, slope: Float
    public var dragged: UInt32   // 1 = on the window being dragged (the app shifts it with the mouse)
    public var n0: Float = 0, n1: Float = 0   // smoothed slope at each end (average with the neighbour across the junction): continuous lighting normal, no facets
    public var inset: Float = 0   // how far base0 / base1 sit under the real window edge (the overlap hides the seam): the shader measures snow depth as top - base - inset
}

/// Ends of a ground / Dock run, for bridging where they meet.
struct PileEnd {
    typealias P = (x: Float, t: Float, b: Float)
    let id: Int
    var first: P, last: P
    let drag: Bool
    var segs: Range<Int> = 0..<0   // this run's slices in the PileSeg buffer
}
