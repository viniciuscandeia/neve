import Foundation

/// Everything the rig needs to draw one penguin (about 16 x 22 pt at scale 1).
public struct PenguinLook {
    public var foot: SIMD2<Float>
    public var facing: Float = 1
    public var scale: Float = 1
    public var hop: Float = 0
    public var angle: Float = 0     // body rotation, rad; negative = tipped forward (onto the belly)
    public var flap: Float = 0      // flipper swing -1...1
    public var fade: Float = 1
    public var lie: Float = 0       // 0...1: how far onto the belly; the pivot moves to the belly contact and the body drops onto the snow
    public var sink: Float = 0      // pt the lying body sits below the foot line (into the groove)
    public init(foot: SIMD2<Float>, facing: Float = 1, scale: Float = 1, hop: Float = 0, angle: Float = 0, flap: Float = 0, fade: Float = 1, lie: Float = 0, sink: Float = 0) {
        self.foot = foot; self.facing = facing; self.scale = scale; self.hop = hop; self.angle = angle; self.flap = flap; self.fade = fade; self.lie = lie; self.sink = sink
    }
}

extension Rig {
    static let penguinBack = C(0.12, 0.13, 0.16, 1), penguinBelly = C(0.97, 0.98, 1, 1), penguinOrange = C(0.96, 0.52, 0.12, 1)

    /// Penguin: dark back, white belly, orange beak and feet, coal eye, two flippers; the body rotates about its middle, and about the belly contact (dropped onto the snow) as it lies down.
    public static func penguin(_ l: PenguinLook, contrast: Bool, into w: inout PrimWriter) {
        let m = l.facing, s = l.scale, al = l.fade
        guard al > 0.01 else { return }
        let piv = l.foot + V(m * 6.3 * l.lie * s, l.hop + (9 + l.lie) * s), a = m * l.angle
        let off = V(-m * 5 * l.lie * s, -l.lie * (10 + l.sink) * s)   // lying: the belly point (pivot) goes to the snow, the body re-centres over the foot
        func p(_ x: Float, _ y: Float) -> V { rot(l.foot + V(m * x * s, l.hop + y * s), piv, a) + off }
        func r(_ x: Float, _ y: Float) -> V { V(x * s, y * s) }
        let back = Rig.a(penguinBack, al), white = Rig.a(penguinBelly, al), org = Rig.a(penguinOrange, al), cl = Rig.a(coal, al)
        w.ellipse(center: l.foot + V(0, 0.4 * s), radii: V(7 * s, 1.3 * s), color: Rig.a(shadow, 0.35 * al), soft: 1.6)
        func ell(_ x: Float, _ y: Float, _ rx: Float, _ ry: Float, _ c: C) { w.ellipse(center: p(x, y), radii: r(rx, ry), rotation: a, color: c) }
        let sh = Rig.a(contrast ? shadowHC : shadow, (contrast ? 0.85 : 0.5) * al)
        w.ellipse(center: p(0, 9.8 - 0.1 * 9.8), radii: r(6.9, 9.8), rotation: a, color: sh, soft: 0.5 * s)   // drop shadow 0.1 r below
        ell(-2.2, 0.8, 2.6, 1.1, org); ell(2.6, 0.8, 2.6, 1.1, org)                       // feet
        let sw = l.flap * 0.5 * m
        let fb = p(-0.5, 12.5), ft = rot(p(-5.2, 7.2), fb, sw)
        w.capsule(from: fb, to: ft, width: 2.6 * s, color: back)                          // far flipper
        w.ellipse(center: p(0, 10.6), radii: r(6.1, 9.0), rotation: a, color: Rig.a(rimLight, 0.35 * al))   // top rim light
        ell(0, 10, 6.3, 9.3, back)                                                        // body
        w.ellipse(center: p(1.2, 8.8), radii: r(4.7, 7.5), rotation: a, color: Rig.a(contrast ? shadowHC : shadow, (contrast ? 0.9 : 0.5) * al))   // blue outline so the belly reads on white
        ell(1.2, 8.8, 4.2, 7.0, white)                                                    // belly
        ell(0.5, 17.6, 4.7, 4.3, back)                                                    // head
        ell(2.9, 18.5, 0.95, 0.95, cl)                                                    // eye
        w.triangle(p(4.6, 18.0), p(4.6, 16.0), p(8.6, 16.9), color: org)                  // beak
        let nb = p(-0.8, 12.2), nt = rot(p(-5.8, 8.0), nb, sw)
        w.capsule(from: nb, to: nt, width: 2.4 * s, color: back)                          // near flipper
    }
}
