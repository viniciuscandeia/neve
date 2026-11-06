import Foundation

/// Everything the rig needs to draw one rabbit (about 18 x 14 pt at scale 1, ears included).
public struct RabbitLook {
    public var foot: SIMD2<Float>      // centre of the feet on the pile
    public var facing: Float = 1       // +-1
    public var scale: Float = 1        // snowman scale
    public var hop: Float = 0          // lift (pt)
    public var squash: Float = 0       // > 0 squashed (landing), < 0 stretched (in the air)
    public var ear: Float = 0          // one ear twitches (0...0.5 rad); -1 = both laid back (running)
    public var bob: Float = 0          // nose / head bob while sniffing
    public var fade: Float = 1
    public var carry = false           // a carrot in the mouth
    public var flight: SIMD3<Float>?   // x, y, angle of a carrot flying into the mouth
    public init(foot: SIMD2<Float>, facing: Float = 1, scale: Float = 1, hop: Float = 0, squash: Float = 0, ear: Float = 0, bob: Float = 0, fade: Float = 1) {
        self.foot = foot; self.facing = facing; self.scale = scale; self.hop = hop; self.squash = squash; self.ear = ear; self.bob = bob; self.fade = fade
    }
}

extension Rig {
    static let rabbitFur = C(0.93, 0.95, 0.99, 1), earPink = C(0.95, 0.75, 0.80, 1), pom = C(1, 1, 1, 1)

    /// Rabbit: ground shadow, ears (inner pink), haunch, chest, head with a coal eye and pink nose, white pom tail, optional carrot in the mouth.
    /// Bluish drop shadow under every body part (a darker outline in high contrast). Local x runs forward, y up, in points at scale 1.
    public static func rabbit(_ l: RabbitLook, contrast: Bool, into w: inout PrimWriter) {
        let m = l.facing, s = l.scale, sx = 1 + 0.5 * l.squash, sy = 1 - 0.4 * l.squash, al = l.fade
        guard al > 0.01 else { return }
        func p(_ x: Float, _ y: Float) -> V { l.foot + V(m * x * s * sx, l.hop + y * s * sy) }
        func r(_ a: Float, _ b: Float) -> V { V(a * s * sx, b * s * sy) }
        let sh = Rig.a(contrast ? shadowHC : shadow, (contrast ? 0.85 : 0.5) * al), fur = Rig.a(rabbitFur, al), pink = Rig.a(earPink, al), cl = Rig.a(coal, al)
        w.ellipse(center: l.foot + V(0, 0.4 * s), radii: V(7.5 * s, 1.4 * s), color: Rig.a(shadow, 0.35 * al), soft: 1.6)   // stays on the ground while it hops
        // Ears: (base, tip) in local points; the near one twitches, both lay back when running.
        func ear(_ bx: Float, _ by: Float, _ tx: Float, _ ty: Float, twitch: Float) {
            let back: Float = l.ear < 0 ? 1.0 : twitch * l.ear
            let t = rot(V(tx, ty), V(bx, by), back)
            w.capsule(from: p(bx, by - 0.4), to: p(t.x, t.y), width: 2.9 * s, color: sh, soft: 0.5 * s)
            w.capsule(from: p(bx, by), to: p(t.x, t.y), width: 2.3 * s, color: fur)
            let ti = V(bx, by) + (t - V(bx, by)) * 0.85
            w.capsule(from: p(bx, by + 0.6), to: p(ti.x, ti.y), width: 1.0 * s, color: pink)
        }
        ear(3.6, 7.8, 2.0, 13.6, twitch: 0)
        ear(5.2, 8.0, 4.4, 13.8, twitch: 1)
        let hy: Float = l.bob * 0.5
        // haunch, chest, head: shadows first, then fur
        for k in 0..<6 {
            let i = k % 3, dark = k < 3
            let cx: Float = i == 0 ? -3 : i == 1 ? 1.2 : 5.4, cy: Float = i == 0 ? 3.4 : i == 1 ? 3.6 : 6.0 + hy
            let rx: Float = i == 0 ? 5.2 : i == 1 ? 4.4 : 3.3, ry: Float = i == 0 ? 3.4 : i == 1 ? 3.2 : 2.8
            if dark { w.ellipse(center: p(cx, cy - 0.5), radii: r(rx * 1.1, ry * 1.1), color: sh, soft: 0.5 * s) } else { w.ellipse(center: p(cx, cy), radii: r(rx, ry), color: fur) }
        }
        w.ellipse(center: p(6.4, 6.6 + hy), radii: r(0.7, 0.7), color: cl)                   // eye
        w.ellipse(center: p(8.5, 6.1 + hy), radii: r(0.55, 0.5), color: pink)                // nose
        w.ellipse(center: p(-8, 4.0), radii: r(2.0, 2.0), color: Rig.a(pom, al))             // pom tail
        if l.carry { carrotPiece(from: p(7.0, 5.0), to: p(13.0, 4.0), width: 2.0 * s, alpha: al, into: &w) }
        if let f = l.flight { carrotPiece(at: V(f.x, f.y), angle: f.z, length: 6.5 * s, alpha: al, into: &w) }
    }

    /// A carrot lying (or flying) at `at`, `length` long, tilted by `angle`.
    public static func carrotPiece(at c: SIMD2<Float>, angle: Float, length: Float, alpha: Float, into w: inout PrimWriter) {
        let h = length / 2, k = length * 0.17
        func q(_ x: Float, _ y: Float) -> V { rot(c + V(x, y), c, angle) }
        w.triangle(q(-h, k), q(-h, -k), q(h, 0), color: a(carrot, alpha))
    }

    /// A carrot from its wide end to the tip (in the mouth).
    static func carrotPiece(from b: V, to tip: V, width: Float, alpha: Float, into w: inout PrimWriter) {
        let d = tip - b, n = V(-d.y, d.x) / max((d.x * d.x + d.y * d.y).squareRoot(), 1e-3) * (width / 2)
        w.triangle(b + n, b - n, tip, color: a(carrot, alpha))
    }
}
