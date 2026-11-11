import Foundation

/// Body pose of a figure: lift (pt), head offset (pt), squash 0...1 (1 = 1.5 wide x 0.6 tall), head jitter (pt), scarf / arms.
public struct Pose: Equatable {
    public var hop: Float = 0, lean: Float = 0, squash: Float = 0, shake: Float = 0
    public var flutter = Flutter()
    public init(hop: Float = 0, lean: Float = 0, squash: Float = 0, shake: Float = 0, flutter: Flutter = Flutter()) {
        self.hop = hop; self.lean = lean; self.squash = squash; self.shake = shake; self.flutter = flutter
    }
}

/// Everything the rig needs to draw one snowman; plain values, no references.
public struct SnowmanLook {
    public var foot: SIMD2<Float>            // centre of the base's bottom (before hop)
    public var radii: SIMD3<Float>           // bottom, middle, head
    public var facing: Float = 1             // +-1
    public var pose = Pose()
    public var built = 7                     // stages present, 0...7: base, middle, head, coal, nose, arms, scarf
    public var newest: Float = 1             // 0...1 eased progress of the newest stage
    public var fade: Float = 1
    public var collapsing = false            // the three balls are debris: only accessories (fading) remain
    public var headless = false              // head ball, face and scarf absent
    public var droop: Float = 0              // 0...1 arms hang down (the loser)
    public var headTilt: Float = 0           // radians the head (face, nose, scarf) is turned
    public var carrot = true                 // false: a rabbit took the nose
    public init(foot: SIMD2<Float>, radii: SIMD3<Float>, facing: Float = 1, pose: Pose = Pose(), built: Int = 7, newest: Float = 1,
                fade: Float = 1, collapsing: Bool = false, headless: Bool = false, droop: Float = 0, headTilt: Float = 0, carrot: Bool = true) {
        self.foot = foot; self.radii = radii; self.facing = facing; self.pose = pose; self.built = built; self.newest = newest
        self.fade = fade; self.collapsing = collapsing; self.headless = headless; self.droop = droop; self.headTilt = headTilt; self.carrot = carrot
    }
}

/// Pure geometry: turns looks into prims. Ball-radius units; draw order = z order.
public enum Rig {
    typealias V = SIMD2<Float>
    typealias C = SIMD4<Float>
    static func c4(_ c: SIMD3<Float>, _ a: Float = 1) -> C { C(c.x, c.y, c.z, a) }
    // Computed: they follow the light/dark blend. `shadow` carries the figure-shadow scale (callers multiply their own 0.35-0.6 on top).
    static var snow: C { c4(Palette.snow.now) }
    static var lift: C { c4(Palette.lift.now) }
    static var crest: C { c4(Palette.flake.now, Palette.crestAlpha) }
    static var shadow: C { c4(Palette.shadow.now, Palette.figureShadowK) }
    static var shadowHC: C { c4(Palette.shadowHC.now) }
    static var speckle: C { c4(Palette.speckle.now, 0.85) }
    static var shotSnow: C { c4(Palette.lift.now) }
    static var carrot: C { c4(Palette.carrot.now) }
    static var scarfRed: C { c4(Palette.red.now) }
    static var twig: C { c4(Palette.twig.now) }
    static var coal: C { c4(Palette.coal.now) }
    static var stripe: C { c4(Palette.stripe.now, 0.9) }
    /// Rolling speckles: (radius fraction, angle, size fraction).
    static let specks: [SIMD3<Float>] = [SIMD3(0.55, 0.5, 0.095), SIMD3(0.72, 2.4, 0.12), SIMD3(0.3, 4.0, 0.08),
                                         SIMD3(0.8, 5.3, 0.10), SIMD3(0.45, 3.0, 0.07), SIMD3(0.62, 1.5, 0.065)]

    static func a(_ c: C, _ k: Float) -> C { C(c.x, c.y, c.z, c.w * k) }
    static func rot(_ p: V, _ o: V, _ t: Float) -> V {
        let s = sin(t), c = cos(t), d = p - o
        return o + V(d.x * c - d.y * s, d.x * s + d.y * c)
    }

    /// Local (unit) -> world: mirror x, scale, rotate about the origin, then squash about the foot.
    struct Fr {
        var o: V, s: Float, m: Float = 1, c: Float = 1, sn: Float = 0, foot: V, sx: Float = 1, sy: Float = 1
        func p(_ x: Float, _ y: Float) -> V {
            let lx = m * x * s, ly = y * s
            let w = o + V(lx * c - ly * sn, lx * sn + ly * c)
            return foot + V((w.x - foot.x) * sx, (w.y - foot.y) * sy)
        }
        func r(_ k: Float) -> V { V(k * s * sx, k * s * sy) }
        var width: Float { s * (sx + sy) / 2 }
    }

    /// Ball body: shadow, (contrast outline), body, lit disc, optional rolling speckles, crest. Radii may be squashed.
    static func body(_ c: V, _ r: V, alpha: Float, contrast: Bool, rotation: Float, speckles: Bool, into w: inout PrimWriter) {
        let u = (r.x + r.y) / 2
        w.ellipse(center: c + V(0, -0.1 * u), radii: r, color: a(contrast ? shadowHC : shadow, (contrast ? 0.8 : 0.45) * alpha * alpha), soft: 0.16 * u)   // alpha^2: behind a fading body the shadow must go first, or it shows through as a grey ring
        var rr = r
        if contrast {
            w.ellipse(center: c, radii: r * 1.04, color: a(shadowHC, alpha * alpha))
            rr = r * 0.96
        }
        w.ellipse(center: c, radii: rr, color: a(snow, alpha))
        w.ellipse(center: c + Palette.light * 0.085 * r, radii: r * 0.945, color: a(lift, alpha))
        if speckles {
            for s in specks {
                let t = s.y + rotation
                w.ellipse(center: c + V(r.x * s.x * cos(t), r.y * s.x * sin(t)), radii: r * s.z, color: a(speckle, alpha))
            }
        }
        w.ellipse(center: c + Palette.light * 0.43 * r, radii: V(0.425 * r.x, 0.35 * r.y), color: a(crest, alpha))
    }

    static func eyes(_ f: Fr, _ al: Float, _ w: inout PrimWriter) {
        let c = a(coal, al)
        w.ellipse(center: f.p(-0.38, 0.26), radii: f.r(0.146), color: c)
        w.ellipse(center: f.p(0.38, 0.26), radii: f.r(0.146), color: c)
        for k in 0..<5 {   // smile: a shallow arc of dots
            let x = Float(k - 2) * 0.2
            w.ellipse(center: f.p(x, -0.43 + 0.875 * x * x), radii: f.r(0.07), color: c)
        }
    }

    static func nose(_ f: Fr, _ al: Float, _ w: inout PrimWriter) {
        w.triangle(f.p(0.09, 0.11), f.p(1.23, -0.09), f.p(0.09, -0.23), color: a(carrot, al))
    }

    /// Scarf: pill + two tail segments (upper about the knot, lower about the joint, lagging) + 2 stripes.
    static func scarf(_ f: Fr, flutter: Flutter, _ al: Float, _ w: inout PrimWriter) {
        let c = a(scarfRed, al)
        w.capsule(from: f.p(-0.86, -1.03), to: f.p(0.86, -1.03), width: 0.56 * f.width, color: c)
        let p1 = f.p(0.8, -1.15), p2 = f.p(0.88, -1.765)
        func t1(_ q: V) -> V { rot(q, p1, flutter.scarf) }
        func t2(_ q: V) -> V { t1(rot(q, p2, flutter.wave)) }
        w.quad(t1(f.p(0.49, -1.15)), t1(f.p(1.08, -1.15)), t1(f.p(1.17, -1.765)), t1(f.p(0.585, -1.765)), color: c)
        w.quad(t2(f.p(0.58, -1.70)), t2(f.p(1.16, -1.70)), t2(f.p(1.26, -2.38)), t2(f.p(0.68, -2.38)), color: c)
        let s = a(stripe, al)
        w.quad(f.p(-0.54, -1.31), f.p(-0.34, -1.31), f.p(-0.34, -0.75), f.p(-0.54, -0.75), color: s)
        w.quad(f.p(0.12, -1.31), f.p(0.32, -1.31), f.p(0.32, -0.75), f.p(0.12, -0.75), color: s)
    }

    /// Twig arm for world side `side` (-1 left, +1 right) rotated by `ang` about its shoulder.
    static func arm(_ f: Fr, side: Float, ang: Float, _ al: Float, _ w: inout PrimWriter) {
        let sh = f.p(side * 0.7, -0.12), c = a(twig, al), wd = 0.15 * f.width
        func q(_ x: Float, _ y: Float) -> V { rot(f.p(side * x, y), sh, ang) }
        w.capsule(from: sh, to: q(2.0, 0.7), width: wd, color: c)
        w.capsule(from: q(1.47, 0.34), to: q(1.59, 0.88), width: wd, color: c)
        w.capsule(from: q(1.76, 0.55), to: q(2.21, 0.93), width: wd, color: c)
    }

    public static func snowman(_ l: SnowmanLook, contrast: Bool, into w: inout PrimWriter) {
        guard l.built > 0 else { return }
        let sx = 1 + 0.5 * l.pose.squash, sy = 1 - 0.4 * l.pose.squash
        let rb = l.radii.x, rm = l.radii.y, rh = l.radii.z
        let foot = l.foot + V(0, l.pose.hop)
        let cb = foot + V(0, rb), cm0 = cb + V(0, rb + rm - 1.5), ch0 = cm0 + V(0, rm + rh - 1.5)
        let cm = cm0 + V(0.4 * l.pose.lean, 0), ch = ch0 + V(l.pose.lean + l.pose.shake, 0)
        // Stage i: nil when absent, else (alpha, grow); the newest one eases in.
        func st(_ i: Int) -> (Float, Float)? {
            guard l.built > i, !(l.collapsing && i < 3), !(l.headless && (i == 2 || i == 4 || i == 6)) else { return nil }
            let fade = l.collapsing ? l.fade : 1
            guard i == l.built - 1, l.newest < 1 else { return (fade, 1) }
            let e = l.newest
            return (fade * e, (i < 3 ? 0.3 : 0.85) + (i < 3 ? 0.7 : 0.15) * e)
        }
        func fr(_ c: V, _ r: Float, _ m: Float, _ g: Float, tilt: Float = 0) -> Fr { Fr(o: c, s: r * g, m: m, c: cos(tilt), sn: sin(tilt), foot: foot, sx: sx, sy: sy) }
        if let (al, g) = st(5) {   // arms first: they come out from behind the middle ball
            let f = fr(cm, rm, 1, g)
            let dr = l.droop * l.droop * (3 - 2 * l.droop) * 1.1   // eased; ~1.1 rad: arms down and out
            arm(f, side: -1, ang: l.pose.flutter.arm(side: -1) + dr, al, &w)
            arm(f, side: 1, ang: l.pose.flutter.arm(side: 1) - dr, al, &w)
        }
        for i in 0..<3 {
            guard let (al, g) = st(i) else { continue }
            let c = i == 0 ? cb : i == 1 ? cm : ch, r = i == 0 ? rb : i == 1 ? rm : rh
            let cc = foot + V((c.x - foot.x) * sx, (c.y - foot.y) * sy)
            body(cc, V(r * g * sx, r * g * sy), alpha: al, contrast: contrast, rotation: 0, speckles: false, into: &w)
        }
        if let (al, g) = st(3) {
            let m = fr(cm, rm, 1, g)
            for k in 0..<3 { w.ellipse(center: m.p(0, 0.44 - 0.425 * Float(k)), radii: m.r(0.112), color: a(coal, al)) }
            if !l.headless { eyes(fr(ch, rh, l.facing, g, tilt: l.headTilt), al, &w) }
        }
        if l.carrot, let (al, g) = st(4) { nose(fr(ch, rh, l.facing, g, tilt: l.headTilt), al, &w) }
        if let (al, g) = st(6) { scarf(fr(ch, rh, l.facing, g, tilt: l.headTilt), flutter: l.pose.flutter, al, &w) }
    }

    /// A loose ball. `face` draws eyes, smile, carrot and scarf rotated with it (a flying head); `facing` mirrors them.
    public static func ball(center: SIMD2<Float>, radius: Float, rotation: Float, fade: Float, squash: Float, contrast: Bool,
                            face: Bool, facing: Float = 1, into w: inout PrimWriter) {
        let sx = 1 + 0.5 * squash, sy = 1 - 0.4 * squash
        let c = center + V(0, radius * (sy - 1))   // squashes against the ground
        body(c, V(radius * sx, radius * sy), alpha: fade, contrast: contrast, rotation: rotation, speckles: !face, into: &w)
        guard face else { return }
        let f = Fr(o: c, s: radius, m: facing, c: cos(rotation), sn: sin(rotation), foot: c, sx: sx, sy: sy)
        eyes(f, fade, &w); nose(f, fade, &w); scarf(f, flutter: Flutter(), fade, &w)
    }

    /// A snowball in the air; on impact `squash` 1 flattens it to 1.5 x 0.6, thin along `normal`.
    public static func shot(pos: SIMD2<Float>, radius: Float, alpha: Float, squash: Float = 0, normal: SIMD2<Float> = SIMD2(0, 1), into w: inout PrimWriter) {
        let r = V(radius * (1 + 0.5 * squash), radius * (1 - 0.4 * squash)), rot = squash > 0 ? atan2(normal.y, normal.x) - .pi / 2 : 0
        w.ellipse(center: pos + V(0, -0.1 * radius), radii: r, rotation: rot, color: a(shadow, 0.5 * alpha), soft: 0.42 * radius)
        w.ellipse(center: pos, radii: r, rotation: rot, color: a(shotSnow, alpha))
    }

    /// Ghost `k` (1...4) of the trail behind a ball in flight.
    public static func shotGhost(pos: SIMD2<Float>, k: Int, radius: Float = 3.6, into w: inout PrimWriter) {
        let al: [Float] = [0.35, 0.22, 0.14, 0.08]
        let r = radius * (1 - 0.15 * Float(k))
        w.ellipse(center: pos, radii: V(r, r), color: a(shotSnow, al[k - 1]))
    }

    /// A flattened splat of snow: white 12 x 6 ellipse (x scale) with a 0.8 pt shadow rim at 0.6 alpha.
    public static func splat(center: SIMD2<Float>, scale: Float, alpha: Float, into w: inout PrimWriter) {
        let r = V(6, 3) * scale
        w.ellipse(center: center, radii: r + V(0.8, 0.8), color: a(shadow, 0.6 * alpha))
        w.ellipse(center: center, radii: r, color: a(lift, alpha))
    }
}
