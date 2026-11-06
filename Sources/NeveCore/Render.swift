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

    // MARK: Pile path

    /// One path for every pile on this screen: a closed, smooth subpath per snowy run.
    /// Top edge = midpoint quadratic curves through every 3rd bin of the lightly blurred surface.
    /// `forDrag` false: every pile except window `dragging`'s; true: only that one (it gets its own layer while dragged).
    public func pilePath(dragging: Int = .min, forDrag: Bool = false) -> CGPath {
        struct Run { var id: Int; var pts: [CGPoint] = [], ceil: [CGFloat] = [], bottom: [CGPoint] = [] }
        let bw = CGFloat(Tuning.binWidth)
        var runs: [Run] = []
        var idx: [Int] = []
        for s in surfaces where (s.id == dragging) == forDrag {
            let h = s.pile.heights, vis = s.pile.visible, base = s.pile.base
            let n = h.count
            let edge = CGFloat(s.edgeY)
            func x(_ i: Int) -> CGFloat { (CGFloat(s.c0 + i) + 0.5) * bw }
            func ceiling(_ i: Int) -> CGFloat { edge + CGFloat(base[i] + s.pile.cap[i]) }   // infinite where no window is in front
            func top(_ i: Int, _ b: Int, _ e: Int) -> CGPoint {
                // Runs split at the Dock bar ends keep their full height there (no taper): that edge is a wall, not a pile end.
                let l = i > b ? h[i - 1] : (s.pile.splits.contains(b) ? h[i] : 0), r = i < e - 1 ? h[i + 1] : (s.pile.splits.contains(e) ? h[i] : 0)
                let sm = (l + 2 * h[i] + r) / 4
                // Stable irregularity keyed on the window-relative column (travels with the pile), scaled by height so it vanishes at the ends.
                let n = Float(noise(s.c0 + i - s.anchor)) * min(sm * 0.08, 1.5)
                return CGPoint(x: x(i), y: min(edge + CGFloat(base[i] + sm + n), ceiling(i)))
            }
            var b = 0
            while b < n {
                guard vis[b] else { b += 1; continue }
                var e = b
                while e < n && vis[e] && (e == b || !s.pile.splits.contains(e)) { e += 1 }
                var lo = b, hi = e - 1
                while lo <= hi && h[lo] <= 0.15 { lo += 1 }
                while hi >= lo && h[hi] <= 0.15 { hi -= 1 }
                if lo <= hi {
                    lo = max(b, lo - 1); hi = min(e - 1, hi + 1)
                    idx.removeAll(keepingCapacity: true)
                    for i in lo..<hi where i == lo || (s.c0 + i - s.anchor) % 3 == 0 { idx.append(i) }
                    idx.append(hi)
                    let drop: CGFloat = s.id == Tuning.groundID ? 0 : 1
                    runs.append(Run(id: s.id, pts: idx.map { top($0, b, e) }, ceil: idx.map(ceiling),
                                    bottom: idx.map { CGPoint(x: x($0), y: edge + CGFloat(base[$0]) - drop) }))
                }
                b = e
            }
        }
        // A ground bank that meets the Dock pile (ends within ~2.5pt in y (the top has up to 1.5pt of noise), close in x) reads as one snowbank: one contour.
        var merged = true
        while merged {
            merged = false
            search: for i in runs.indices where runs[i].id == Tuning.groundID {
                for j in runs.indices where runs[j].id == 0 {
                    let (g, d) = (runs[i], runs[j])
                    if g.pts.last!.x <= d.pts.first!.x, d.pts.first!.x - g.pts.last!.x < 60, abs(d.pts.first!.y - g.pts.last!.y) <= 2.5 {
                        runs[j] = Run(id: 0, pts: g.pts + d.pts, ceil: g.ceil + d.ceil, bottom: g.bottom + d.bottom)
                    } else if d.pts.last!.x <= g.pts.first!.x, g.pts.first!.x - d.pts.last!.x < 60, abs(g.pts.first!.y - d.pts.last!.y) <= 2.5 {
                        runs[j] = Run(id: 0, pts: d.pts + g.pts, ceil: d.ceil + g.ceil, bottom: d.bottom + g.bottom)
                    } else { continue }
                    runs.remove(at: i)   // the chain keeps id 0 so the bank on the Dock's other end can join it too
                    merged = true
                    break search
                }
            }
        }
        let path = CGMutablePath()
        for r in runs {
            let pts = r.pts
            path.move(to: pts[0])
            if pts.count > 2 {
                for k in 1..<(pts.count - 1) {
                    let c = pts[k], nx = pts[k + 1]
                    // Control and end points all stay under the ceiling, so the quad cannot cross it.
                    path.addQuadCurve(to: CGPoint(x: (c.x + nx.x) / 2, y: min((c.y + nx.y) / 2, r.ceil[k], r.ceil[k + 1])), control: c)
                }
            }
            if pts.count > 1 { path.addLine(to: pts[pts.count - 1]) }
            for p in r.bottom.reversed() { path.addLine(to: p) }
            path.closeSubpath()
        }
        return path
    }
}
