import Foundation

/// Everything the rig needs to draw the sleigh team (about 120 x 30 pt at scale 1; `pos` is the centre of the team).
public struct SleighLook {
    public var pos: SIMD2<Float>
    public var facing: Float = 1       // +-1, flight direction
    public var scale: Float = 1
    public var deer = 2                // 2...4 reindeer in single file ahead of the sleigh
    public var t: Float = 0            // seconds since take-off: gallop phase
    public init(pos: SIMD2<Float>, facing: Float = 1, scale: Float = 1, deer: Int = 2, t: Float = 0) {
        self.pos = pos; self.facing = facing; self.scale = scale; self.deer = deer; self.t = t
    }
}

extension Rig {
    static let sleighRed = C(0.82, 0.17, 0.20, 1), gold = C(0.95, 0.75, 0.20, 1), white = C(1, 1, 1, 1), reindeer = C(0.45, 0.33, 0.24, 1)
    static let skin = C(0.96, 0.80, 0.68, 1), reins = C(0.30, 0.20, 0.12, 1), sack = C(0.62, 0.46, 0.28, 1), giftGreen = C(0.16, 0.55, 0.28, 1)
    static let giftColors: [C] = [C(0.86, 0.18, 0.20, 1), giftGreen, gold]

    /// Red sleigh with gold runner, Santa (red suit, white trim), 2...4 reindeer with twig antlers, harness line. Local x forward, y up.
    public static func sleigh(_ l: SleighLook, into w: inout PrimWriter) {
        let m = l.facing, s = l.scale
        func p(_ x: Float, _ y: Float) -> V { l.pos + V(m * x * s, y * s) }
        func r(_ a: Float, _ b: Float) -> V { V(a * s, b * s) }
        // runner and supports
        w.capsule(from: p(-60, -12), to: p(-31, -12), width: 2.2 * s, color: gold)
        w.capsule(from: p(-31, -12), to: p(-27, -8), width: 2.0 * s, color: gold)
        w.capsule(from: p(-60, -12), to: p(-62, -9), width: 2.0 * s, color: gold)
        w.capsule(from: p(-54, -12), to: p(-54, -6), width: 1.4 * s, color: gold)
        w.capsule(from: p(-38, -12), to: p(-38, -6), width: 1.4 * s, color: gold)
        // sack of toys behind Santa, body, front scroll, gold rim
        w.ellipse(center: p(-56.5, 7), radii: r(5, 4.5), color: sack)
        w.quad(p(-60, -6), p(-33, -6), p(-28, 3), p(-62, 3), color: sleighRed)
        w.ellipse(center: p(-30.5, -1.2), radii: r(3.2, 4.2), color: sleighRed)
        w.capsule(from: p(-62, 3.2), to: p(-28.5, 3.2), width: 1.2 * s, color: gold)
        // Santa
        w.ellipse(center: p(-43, 8.5), radii: r(4.5, 5), color: sleighRed)
        w.capsule(from: p(-47.5, 5.6), to: p(-38.5, 5.6), width: 1.3 * s, color: white)
        w.capsule(from: p(-42, 10.5), to: p(-35, 8.5), width: 2.0 * s, color: sleighRed)
        w.ellipse(center: p(-41, 15.6), radii: r(2.7, 2.7), color: skin)
        w.ellipse(center: p(-40, 13.4), radii: r(2.3, 2.1), color: white)
        w.triangle(p(-44, 17.4), p(-38.4, 17.4), p(-46.5, 13.8), color: sleighRed)
        w.capsule(from: p(-44.2, 17.4), to: p(-38.2, 17.4), width: 1.4 * s, color: white)
        w.ellipse(center: p(-46.5, 13.8), radii: r(1.2, 1.2), color: white)
        // reindeer: gallop legs (back pair first), body, neck, head, antlers
        let n = max(2, min(l.deer, 4)), lead = -18 + Float(n - 1) * 17
        w.capsule(from: p(-28, -1), to: p(lead - 1, 2.5), width: 0.8 * s, color: reins)   // harness line to the lead deer
        for k in 0..<n {
            let x = -18 + Float(k) * 17, ph = l.t * 9 + Float(k) * 0.9, by = 1.0 * sin(ph * 2), yb = by
            let sw = 3.4 * sin(ph)
            if k > 0 { w.capsule(from: p(x - 8.5, 2.6), to: p(x - 17 + 8.5, 2.6), width: 0.7 * s, color: reins) }   // trace to the one behind
            w.capsule(from: p(x - 4, -1.5 + yb), to: p(x - 4 - sw, -10), width: 1.2 * s, color: reindeer)
            w.capsule(from: p(x + 4, -1.5 + yb), to: p(x + 4 + sw, -10), width: 1.2 * s, color: reindeer)
            w.ellipse(center: p(x, yb), radii: r(6.5, 3.2), color: reindeer)
            w.capsule(from: p(x - 4, -1.5 + yb), to: p(x - 4 + sw, -10), width: 1.2 * s, color: reindeer)
            w.capsule(from: p(x + 4, -1.5 + yb), to: p(x + 4 - sw, -10), width: 1.2 * s, color: reindeer)
            w.capsule(from: p(x + 4.5, 1 + yb), to: p(x + 8.5, 6 + yb), width: 2.4 * s, color: reindeer)
            w.ellipse(center: p(x + 10.5, 6.8 + yb), radii: r(2.7, 1.7), rotation: -0.3 * m, color: reindeer)
            w.ellipse(center: p(x + 13, 6.3 + yb), radii: r(k == n - 1 ? 1.2 : 0.8, k == n - 1 ? 1.2 : 0.8), color: k == n - 1 ? C(0.95, 0.15, 0.10, 1) : coal)
            w.ellipse(center: p(x - 6.8, 1.6 + yb), radii: r(1.4, 1.4), color: C(0.85, 0.80, 0.70, 1))
            w.capsule(from: p(x + 9.6, 8 + yb), to: p(x + 7.6, 13.4 + yb), width: 0.8 * s, color: twig)
            w.capsule(from: p(x + 8.2, 11.2 + yb), to: p(x + 10.8, 12.8 + yb), width: 0.7 * s, color: twig)
            w.capsule(from: p(x + 10.6, 8 + yb), to: p(x + 11.6, 13.4 + yb), width: 0.8 * s, color: twig)
            w.capsule(from: p(x + 11.2, 11.2 + yb), to: p(x + 13.6, 12.4 + yb), width: 0.7 * s, color: twig)
        }
    }

    /// A 9 x 9 box (red / green / gold) with a white ribbon cross, tilted by `rot`; opened: the lid has flown off, the inside shows.
    public static func gift(_ g: Gift, offset: SIMD2<Float>, into w: inout PrimWriter) {
        let al = g.fade
        guard al > 0.01 else { return }
        let c = g.pos + offset, h = Tuning.giftSize / 2, sn = sin(g.rot), cs = cos(g.rot)
        func p(_ x: Float, _ y: Float, _ o: V = .zero) -> V { c + o + V(x * cs - y * sn, x * sn + y * cs) }
        let col = a(giftColors[Int(g.color)], al), rib = a(white, al)
        if !g.falling { w.ellipse(center: c + V(0, -h), radii: V(h * 1.3, 1.3), color: a(shadow, 0.35 * al), soft: 1.2) }
        let open = g.opened >= 0
        w.quad(p(-h, -h), p(h, -h), p(h, h), p(-h, h), color: col)
        w.quad(p(-0.8, -h), p(0.8, -h), p(0.8, h), p(-0.8, h), color: rib)
        w.quad(p(-h, -0.8), p(h, -0.8), p(h, 0.8), p(-h, 0.8), color: rib)
        if open { w.ellipse(center: p(0, h), radii: V(h * 0.85, 1.2), color: a(C(0.12, 0.07, 0.08, 1), 0.85 * al)) }
        if open, g.opened < Tuning.lidLife {   // the lid pops up and away, spinning
            let u = g.opened, d: Float = g.color == 1 ? -1 : 1
            let o = V(d * 22 * u, 60 * u - 110 * u * u), k = g.rot + d * 9 * u, s2 = sin(k), c2 = cos(k), fa = al * (1 - u / Tuning.lidLife)
            func q(_ x: Float, _ y: Float) -> V { c + V(0, h) + o + V(x * c2 - y * s2, x * s2 + y * c2) }
            w.quad(q(-h - 0.6, -1.3), q(h + 0.6, -1.3), q(h + 0.6, 1.3), q(-h - 0.6, 1.3), color: a(giftColors[Int(g.color)], fa))
            w.quad(q(-0.8, -1.3), q(0.8, -1.3), q(0.8, 1.3), q(-0.8, 1.3), color: a(white, fa))
        }
    }

    /// A confetti scrap, 2.8 x 1.6 pt.
    static func confetti(center c: V, rot: Float, color: UInt8, alpha: Float, into w: inout PrimWriter) {
        let sn = sin(rot), cs = cos(rot)
        func p(_ x: Float, _ y: Float) -> V { c + V(x * cs - y * sn, x * sn + y * cs) }
        w.quad(p(-1.4, -0.8), p(1.4, -0.8), p(1.4, 0.8), p(-1.4, 0.8), color: a(giftColors[Int(color)], alpha))
    }
}
