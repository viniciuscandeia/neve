// AGENT HEADER - Sources/NeveCore/Rig+Tree.swift  (the Christmas tree as prims)
// Role: `TreeLook` (foot, scale, tilt, squash 0 / 1, snow counters per layer, fade, grounded) and `Rig.tree`: shadow (grounded only), trunk + snow mound, SIX branch tiers (`treeTiers`: bottom first; each = body triangle in treeGreen, a treeShade half on the
//   side away from Palette.light, a treeLight lit side, and a sawtooth of 5 drooping teeth + 2 end droops along the bottom edge, depth varied per tier / tooth), gold tinsel swags on tiers 0 / 2 / 4, 14 baubles of varied size (`treeBaubles`, red / gold / blue,
//   each with a small specular dot toward the light), snow on the tiers (up to 4 ellipses along the slopes + an apex cap once the counter passes 0.5; the four counters map to tiers by `treeSnowIdx`) and a five-point gold star with a two-ring glow. <= ~145 prims (budget 160).
//   `treeWidth(y)` = half width of the silhouette at height y (scale 1): used by hit-testing (Tree.treeUnder), the light spiral (Lights.swift) and tests. Colours via Palette (treeGreen / treeShade / treeLight / twig / gold / giftRed / lightBlue, light + dark Tones).
//   Pure geometry, no state, no allocation; called by SnowField.writeTreePrims. Tests: TreeTests (prim budget, snow grows the count, size, bulbs / baubles inside the silhouette).
// Units: points at the tree's scale, local y up from the trunk foot (tip of the star = Tuning.treeHeight = 118); tilt rotates about the foot.

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
    static let treeTiers: [(b: Float, t: Float, h: Float)] = [(12, 44, 34), (30, 62, 29), (47, 78, 24), (62, 92, 19), (76, 104, 14), (88, 110, 9)]   // bottom y, top y, half width
    static let treeSnowIdx = [0, 1, 1, 2, 3, 3]          // tier -> snow counter (SIMD4)
    static let treeCounterTier = [0, 2, 3, 5]            // counter -> the tier its shed debris starts from
    static let treeBaubles: [(fx: Float, y: Float, r: Float, col: Int)] = [(-0.62, 20, 3.0, 0), (0.5, 22, 2.4, 1), (0, 28, 2.8, 2), (-0.4, 34, 2.2, 1), (0.6, 40, 3.0, 0), (-0.55, 48, 2.6, 2), (0.3, 52, 2.2, 0),
        (-0.1, 58, 3.0, 1), (0.5, 62, 2.4, 2), (-0.5, 68, 2.4, 0), (0.35, 73, 2.8, 1), (-0.2, 80, 2.2, 2), (0.4, 84, 2.0, 0), (0, 92, 2.2, 1)]   // x as a fraction of the half width at y

    /// Half width of the silhouette at height `y` (scale 1): the union of the tiers' triangles, and the trunk below them.
    static func treeWidth(_ y: Float) -> Float {
        var m: Float = y >= -2 && y < 14 ? 4.5 : 0
        for t in treeTiers where y >= t.b && y <= t.t { m = max(m, t.h * (t.t - y) / (t.t - t.b)) }
        return m
    }

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
        let green = treeGreen, dark = treeShade, lit = c4(Palette.treeLight.now), mid = green + (dark - green) * 0.5, bright = green + (lit - green) * 0.5
        if l.grounded { w.ellipse(center: l.foot + V(0, -0.5 * s), radii: r(40, 4), color: a(contrast ? shadowHC : shadow, contrast ? 0.6 : 0.4), soft: 1.6) }
        w.capsule(from: p(0, 0), to: p(0, 16), width: 9 * s, color: twig)
        if l.grounded { w.ellipse(center: p(0, 1.8), radii: r(17, 4), rotation: l.tilt, color: snow) }
        for (i, tier) in treeTiers.enumerated() {
            let b = tier.b, t = tier.t, h = tier.h
            for k in -1...5 {   // sawtooth of drooping teeth along the bottom edge (k = -1 / 5: the end droops), depth and sway vary per tier and tooth
                let end = k < 0 || k > 4, x = end ? (k < 0 ? -h - 2.5 : h + 2.5) : h * (-0.8 + 1.6 * Float(k) / 4), jit = Float((i * 5 + k * 3 + 6) % 3)
                let hw = end ? 3.4 : h * 0.26 + 1, depth = 3.4 + 0.075 * h + jit * 1.2 + (end ? 1.5 : 0)
                let col = x * shadeSide > 0.25 * h ? mid : (k % 2 == 0 ? green : bright)
                w.triangle(p(x - hw, b + 2.2), p(x + hw, b + 2.2), p(x + (jit - 1) * 0.8, b - depth), color: col)
            }
            w.triangle(p(0, t), p(-h, b), p(h, b), color: green)
            w.triangle(p(0, t), p(-shadeSide * h, b), p(-shadeSide * h * 0.35, b), color: a(lit, 0.55))
            w.triangle(p(0, t), p(shadeSide * h, b), p(0, b), color: a(dark, 0.6))
        }
        let gold = c4(Palette.gold.now)
        for i in [0, 2, 4] {   // tinsel: a drooping gold swag across the bottom of a tier
            let b = treeTiers[i].b + 3, hw = treeTiers[i].h * 0.82
            var prev = p(-hw, b + 4)
            for k in 1...4 {
                let u = Float(k) / 4, q = p(-hw + 2 * hw * u, b + 4 - 7 * 4 * u * (1 - u))
                w.capsule(from: prev, to: q, width: 1.5 * s, color: a(gold, 0.85))
                prev = q
            }
        }
        let cols = [c4(Palette.giftRed.now), gold, c4(Palette.lightBlue.now)], spec = c4(Palette.glint.now)
        for bl in treeBaubles {
            let x = bl.fx * treeWidth(bl.y)
            w.ellipse(center: p(x, bl.y), radii: r(bl.r, bl.r), color: cols[bl.col])
            w.ellipse(center: p(x + bl.r * (0.35 + 0.3 * Palette.light.x), bl.y + bl.r * 0.4), radii: r(bl.r * 0.32, bl.r * 0.32), color: a(spec, 0.85))
        }
        for (i, tier) in treeTiers.enumerated() {   // snow on the tiers: grows with the counter
            let sc = min(max(l.snow[treeSnowIdx[i]], 0), 1), b = tier.b, t = tier.t, h = tier.h
            let n = min(4, Int((sc * 4).rounded(.up)))
            let ang = atan2(t - b, h)
            for k in 0..<n {
                let side: Float = k % 2 == 0 ? -1 : 1, u = (Float(k / 2) + 0.6) / 2.4, big = 0.7 + 0.3 * Float((i * 7 + k * 13) % 5) / 4
                w.ellipse(center: p(side * h * u * 0.92, t - (t - b) * u + 1), radii: r((2.4 + 2 * sc) * big, (1.3 + 0.8 * sc) * big), rotation: l.tilt - side * ang, color: snow)
            }
            if sc > 0.5 { w.triangle(p(0, t + 0.8), p(-h * 0.3, t - (t - b) * 0.3), p(h * 0.3, t - (t - b) * 0.3), color: a(snow, min(1, (sc - 0.5) * 3))) }
        }
        let c = V(0, 112)   // five-point star: five kites around the centre, plus a two-ring glow
        w.ellipse(center: p(c.x, c.y), radii: r(14, 14), color: a(gold, 0.14), soft: 4)
        w.ellipse(center: p(c.x, c.y), radii: r(8.5, 8.5), color: a(gold, 0.28), soft: 3)
        for k in 0..<5 {
            func pt(_ deg: Float, _ rad: Float) -> V { p(c.x + rad * cos(deg * .pi / 180), c.y + rad * sin(deg * .pi / 180)) }
            let d = 90 + 72 * Float(k)
            w.quad(p(c.x, c.y), pt(d - 36, 3.1), pt(d, 6.6), pt(d + 36, 3.1), color: gold)
        }
        w.fade(from: start, by: l.fade)
    }
}
