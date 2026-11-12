// AGENT HEADER - Sources/NeveCore/Rig+Tree.swift  (the Christmas tree as prims)
// Role: `TreeLook` (foot, scale, tilt, squash 0 / 1, snow counters per layer, fade, grounded) and `Rig.tree`: shadow (grounded only), trunk, four branch layers (bottom first: triangle, a darker half on the side away from Palette.light,
//   two tip ellipses), baubles, snow on the branches (per layer up to 6 ellipses along the slopes + a cap on the apex once the counter passes 0.5: grows with `snow`) and the gold star (glow + two triangles). <= ~60 prims (budget 120).
//   Colours via Palette (treeGreen / treeShade / twig / gold / giftRed, light + dark Tones). Pure geometry, no state, no allocation; called by SnowField.writeTreePrims. Tests: TreeTests (prim budget, snow grows the count).
// Units: points at the tree's scale, local y up from the trunk foot; tilt rotates about the foot.

import Foundation

public struct TreeLook {
    public var foot: SIMD2<Float>, scale: Float, tilt: Float, squash: Float, snow: SIMD4<Float>, fade: Float, grounded: Bool
    public init(foot: SIMD2<Float>, scale: Float = 1, tilt: Float = 0, squash: Float = 0, snow: SIMD4<Float> = .zero, fade: Float = 1, grounded: Bool = true) {
        self.foot = foot; self.scale = scale; self.tilt = tilt; self.squash = squash; self.snow = snow; self.fade = fade; self.grounded = grounded
    }
}

extension Rig {
    static var treeGreen: C { c4(Palette.treeGreen.now) }
    static var treeShade: C { c4(Palette.treeShade.now) }

    public static func tree(_ l: TreeLook, contrast: Bool, into w: inout PrimWriter) {
        guard l.fade > 0.01 else { return }
        let start = w.n
        let s = l.scale, sn = sin(l.tilt), cs = cos(l.tilt), kx: Float = 1 + 0.06 * l.squash, ky: Float = 1 - 0.08 * l.squash
        func p(_ x: Float, _ y: Float) -> V {
            let lx = x * kx * s, ly = y * ky * s
            return l.foot + V(lx * cs - ly * sn, lx * sn + ly * cs)
        }
        func r(_ x: Float, _ y: Float) -> V { V(x * s, y * s) }
        let shadeSide: Float = Palette.light.x < 0 ? 1 : -1
        let bottoms: [Float] = [8, 21, 34, 46], tops: [Float] = [31, 43, 54, 66], halves: [Float] = [20, 16, 12, 8]
        if l.grounded { w.ellipse(center: l.foot + V(0, -0.5 * s), radii: r(24, 2.6), color: a(contrast ? shadowHC : shadow, contrast ? 0.6 : 0.4), soft: 1.6) }
        w.capsule(from: p(0, 0), to: p(0, 12), width: 6.5 * s, color: twig)
        for i in 0..<4 {
            let b = bottoms[i], t = tops[i], h = halves[i]
            w.triangle(p(0, t), p(-h, b), p(h, b), color: treeGreen)
            w.triangle(p(0, t), p(shadeSide * h, b), p(0, b), color: a(treeShade, 0.6))
            w.ellipse(center: p(-h * 0.82, b + 0.6), radii: r(3.4, 1.8), rotation: l.tilt, color: treeGreen)
            w.ellipse(center: p(h * 0.82, b + 0.6), radii: r(3.4, 1.8), rotation: l.tilt, color: treeGreen)
        }
        let balls: [(Float, Float, Bool)] = [(-9, 14, true), (8, 17, false), (-2, 26, false), (5, 28, true), (-8, 24, false), (-4, 40, true), (3, 46, false), (0, 53, true)]
        for (x, y, red) in balls { w.ellipse(center: p(x, y), radii: r(1.7, 1.7), color: red ? c4(Palette.giftRed.now) : c4(Palette.gold.now)) }
        for i in 0..<4 {   // snow on the branches: grows with the counter
            let sc = min(max(l.snow[i], 0), 1), b = bottoms[i], t = tops[i], h = halves[i]
            let n = min(6, Int((sc * 6).rounded(.up)))
            let ang = atan2(t - b, h)
            for k in 0..<n {
                let side: Float = k % 2 == 0 ? -1 : 1, u = (Float(k / 2) + 0.6) / 3, big = 0.7 + 0.3 * Float((i * 7 + k * 13) % 5) / 4
                w.ellipse(center: p(side * h * u * 0.92, t - (t - b) * u + 1), radii: r((2.2 + 1.8 * sc) * big, (1.2 + 0.7 * sc) * big), rotation: l.tilt - side * ang, color: snow)
            }
            if sc > 0.5 { w.triangle(p(0, t + 0.8), p(-h * 0.3, t - (t - b) * 0.3), p(h * 0.3, t - (t - b) * 0.3), color: a(snow, min(1, (sc - 0.5) * 3))) }
        }
        let gold = c4(Palette.gold.now), star = p(0, 69)
        w.ellipse(center: star, radii: r(6, 6), color: a(gold, 0.25), soft: 3)
        w.triangle(p(0, 74), p(-3.8, 66.8), p(3.8, 66.8), color: gold)
        w.triangle(p(0, 64.4), p(-3.8, 71.2), p(3.8, 71.2), color: gold)
        w.fade(from: start, by: l.fade)
    }
}
