import Foundation

/// Everything the rig needs to draw one robin (about 12 x 10 pt at scale 1).
public struct RobinLook {
    public var foot: SIMD2<Float>
    public var facing: Float = 1
    public var scale: Float = 1
    public var hop: Float = 0
    public var flying = false
    public var wing: Float = 0        // flap phase (rad); the two wings alternate
    public var wiggle: Float = 0      // -1...1 shake lean
    public var fade: Float = 1
    public init(foot: SIMD2<Float>, facing: Float = 1, scale: Float = 1, hop: Float = 0, flying: Bool = false, wing: Float = 0, wiggle: Float = 0, fade: Float = 1) {
        self.foot = foot; self.facing = facing; self.scale = scale; self.hop = hop; self.flying = flying; self.wing = wing; self.wiggle = wiggle; self.fade = fade
    }
}

extension Rig {
    static let robinBack = C(0.45, 0.33, 0.24, 1), robinBreast = C(0.85, 0.38, 0.20, 1), robinWing = C(0.36, 0.26, 0.19, 1), robinBeak = C(0.16, 0.14, 0.12, 1)

    /// Robin: back, red-orange breast, head with beak and coal eye, tail, legs when perched; wings flap by alternating scaleY while flying.
    public static func robin(_ l: RobinLook, contrast: Bool, into w: inout PrimWriter) {
        let m = l.facing, s = l.scale, al = l.fade
        guard al > 0.01 else { return }
        func p(_ x: Float, _ y: Float) -> V { l.foot + V(m * x * s + l.wiggle * y * s * 0.12, l.hop + y * s) }
        func r(_ a: Float, _ b: Float) -> V { V(a * s, b * s) }
        let sh = a(contrast ? shadowHC : shadow, (contrast ? 0.85 : 0.5) * al), back = a(robinBack, al), br = a(robinBreast, al), wg = a(robinWing, al), cl = a(coal, al)
        if !l.flying { w.ellipse(center: l.foot + V(0, 0.4 * s), radii: r(4.5, 1.0), color: a(shadow, 0.35 * al), soft: 1.2) }
        w.ellipse(center: p(0.4, 4.6), radii: r(5.0, 3.8), color: sh, soft: 0.5 * s)
        w.capsule(from: p(-3.4, 4.8), to: p(-6.6, 3.4), width: 2.0 * s, color: back)
        if !l.flying {
            w.capsule(from: p(-0.6, 1.6), to: p(-0.6, 0.1), width: 0.7 * s, color: cl)
            w.capsule(from: p(1.0, 1.6), to: p(1.0, 0.1), width: 0.7 * s, color: cl)
        } else {   // far wing behind the body
            let ry = 3.4 * sin(l.wing + .pi)
            w.ellipse(center: p(-1.2, 6.2 + ry), radii: r(3.4, max(abs(ry), 0.4)), color: a(wg, 0.8))
        }
        w.ellipse(center: p(0, 4.4), radii: r(4.4, 3.3), color: back)
        w.ellipse(center: p(1.8, 3.7), radii: r(3.0, 2.5), color: br)                 // breast
        w.ellipse(center: p(3.6, 7.2), radii: r(2.3, 2.2), color: back)               // head
        w.ellipse(center: p(4.2, 6.2), radii: r(1.5, 1.4), color: br)                 // throat
        w.triangle(p(5.6, 7.7), p(5.6, 6.9), p(7.5, 7.3), color: a(robinBeak, al))
        w.ellipse(center: p(4.3, 7.6), radii: r(0.5, 0.5), color: cl)                 // eye
        if l.flying {
            let ry = 3.6 * sin(l.wing)
            w.ellipse(center: p(-1.0, 6.4 + ry), radii: r(3.6, max(abs(ry), 0.4)), color: wg)
        } else {
            w.ellipse(center: p(-1.0, 4.6), radii: r(3.2, 1.6), color: wg)           // folded
        }
    }
}
