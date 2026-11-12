// AGENT HEADER - Sources/NeveCore/Lights.swift  (Christmas lights: garland of arcs under the menu bar + bulbs on the Christmas tree)
// Role: `Lights` (constants, `level(id, t, calm)` = brightness 0...1 of one bulb, `treeBulb` positions) and SnowField `lightsEnabled` (the app sets it from Pref.lights), `writeLightPrims` (Overlay.writePrims, after the figures: garland wire + bulbs
//   (glow = larger low-alpha ellipse behind the dot, there is no additive blending), tree bulbs + a low-alpha coloured ellipse on the pile at each bulb's x) and `lightCode(at:)` (lit flakes: a flake within `Lights.litRadius` of a bulb gets
//   Instance.kind 7 | (colour index | strength 0...15 << 3) << 8; the flake shader mixes its colour toward Palette.lights[idx]. Only flakes in the top band and inside the tree's box are tested; the garland bulb is found by x, so no scan).
// Pattern: the three modes (twinkle, chase, pulse) alternate every `Lights.cycle` s with a `fadeT` cross-fade; phase = `SnowField.time` (stops while frozen). `calm` (Reduce Motion) = every bulb steady at full level, so nothing blinks and a still screen never has to wake.
//   Windows carry no lights. Colours: Palette.lights (Tones, light / dark). Ids: garland bulb i = i; tree bulb k = 1000 + k (colour = id % 5).
// Randomness: none (pure function of time). No allocation (static tables, loops). Tests: LightsTests. Units: local pt, y up.

import Foundation

public enum Lights {
    static let span: Float = 110, perArc = 4, sag: Float = 12   // one arc = 110 pt wide with 4 bulbs, 12 pt deep
    static let litRadius: Float = 14, band: Float = 30          // lit flakes: reach of a bulb, height of the garland band tested
    static let cycle: Float = 12, fadeT: Float = 1.5            // seconds per mode, cross-fade length
    static let treeBase = 1000
    /// Bulbs on the tree at scale 1, in the same local coordinates as Rig.tree (x across, y up from the foot); all inside the four branch layers.
    static let treeBulbs: [SIMD2<Float>] = [[-13, 12], [12, 11], [0, 17], [-4, 24], [-10, 26], [10, 25], [0, 31], [-7, 38], [7, 39], [0, 45], [-4, 50], [4, 51]]

    static func pattern(_ m: Int, _ i: Int, _ t: Float) -> Float {
        switch m {
        case 0: return 0.6 + 0.4 * sin(t * (1.1 + 0.29 * Float(i % 5)) + Float(i) * 2.3)                  // twinkle
        case 1: let ph = Float(i % 6) / 6 - t * 0.5; return 0.25 + 0.75 * max(0, 1 - (ph - floor(ph)) * 3)  // chase
        default: return 0.6 + 0.4 * sin(t * 2.4 + (i % 2 == 0 ? 0 : Float.pi))                            // pulse, two alternating groups
        }
    }
    /// Brightness of bulb `i` at time `t`; calm = constant 1.
    static func level(_ i: Int, t: Float, calm: Bool) -> Float {
        if calm { return 1 }
        let m = t / cycle, k = Int(m), w = max(0, (m - Float(k) - (1 - fadeT / cycle)) / (fadeT / cycle))
        let a = pattern(k % 3, i, t)
        return w > 0 ? a + (pattern((k + 1) % 3, i, t) - a) * w : a
    }
    static func treeBulb(foot: SIMD2<Float>, scale: Float, tilt: Float, _ k: Int) -> SIMD2<Float> {
        let b = treeBulbs[k], sn = sin(tilt), cs = cos(tilt), x = b.x * scale, y = b.y * scale
        return foot + SIMD2(x * cs - y * sn, x * sn + y * cs)
    }
}

extension SnowField {
    var garlandArcs: Int { max(Int(size.x / Lights.span), 0) }
    var garlandOffset: Float { (size.x - Float(garlandArcs) * Lights.span) / 2 }
    func garlandPoint(arc: Int, u: Float) -> SIMD2<Float> {
        SIMD2(garlandOffset + (Float(arc) + u) * Lights.span, visibleTop - 2 - Lights.sag * 4 * u * (1 - u))
    }
    func garlandBulb(_ i: Int) -> SIMD2<Float> {
        var p = garlandPoint(arc: i / Lights.perArc, u: (Float(i % Lights.perArc) + 0.5) / Float(Lights.perArc))
        p.y -= 3
        return p
    }

    /// Garland and tree lights as prims; `shift` gives the drag offset of a surface id (the tree rides with its window).
    public func writeLightPrims(_ w: inout PrimWriter, shift: (Int?) -> SIMD2<Float>) {
        guard lightsEnabled else { return }
        let t = Float(time), wire = Rig.a(Rig.c4(Palette.treeShade.now), 0.9)
        let arcs = garlandArcs
        for arc in 0..<arcs {
            var prev = garlandPoint(arc: arc, u: 0)
            for s in 1...4 {
                let q = garlandPoint(arc: arc, u: Float(s) / 4)
                w.capsule(from: prev, to: q, width: 1, color: wire)
                prev = q
            }
        }
        func bulb(_ p: SIMD2<Float>, id: Int, fade: Float, size: Float) {
            let lv = Lights.level(id, t: t, calm: calm), c = Rig.c4(Palette.lights[id % 5].now)
            w.ellipse(center: p, radii: SIMD2(repeating: 6.5 * size), color: Rig.a(c, 0.24 * lv * fade), soft: 3)
            w.ellipse(center: p, radii: SIMD2(1.9, 2.4) * size, color: Rig.a(c, (0.4 + 0.6 * lv) * fade))
        }
        for i in 0..<(arcs * Lights.perArc) { bulb(garlandBulb(i), id: i, fade: 1, size: 1) }
        if let tr = tree, tr.fade > 0.01 {
            let foot = tr.pos + shift(tr.surface)
            for k in Lights.treeBulbs.indices {
                let p = Lights.treeBulb(foot: foot, scale: tr.scale, tilt: tr.tilt, k), id = Lights.treeBase + k
                bulb(p, id: id, fade: tr.fade, size: tr.scale)
                if tr.state == .resting {   // coloured glow on the pile under the bulb
                    let lv = Lights.level(id, t: t, calm: calm)
                    w.ellipse(center: SIMD2(p.x, foot.y + 0.5 * tr.scale), radii: SIMD2(8, 2.4) * tr.scale, color: Rig.a(Rig.c4(Palette.lights[id % 5].now), 0.16 * lv * tr.fade), soft: 2)
                }
            }
        }
    }

    /// Instance.kind for a flake lit by a nearby bulb (see header), 0 when none; the caller checks `lightsEnabled`.
    func lightCode(at p: SIMD2<Float>) -> UInt32 {
        var best: Float = 0, idx = 0
        let r = Lights.litRadius, t = Float(time)
        func test(_ b: SIMD2<Float>, _ id: Int) {
            let dx = p.x - b.x, dy = p.y - b.y, d = (dx * dx + dy * dy).squareRoot()
            guard d < r else { return }
            let s = (1 - d / r) * Lights.level(id, t: t, calm: calm)
            if s > best { best = s; idx = id % 5 }
        }
        if p.y > visibleTop - Lights.band {
            let n = garlandArcs * Lights.perArc, j = Int(((p.x - garlandOffset) / (Lights.span / Float(Lights.perArc)) - 0.5).rounded())
            for k in (j - 1)...(j + 1) where k >= 0 && k < n { test(garlandBulb(k), k) }
        }
        if let tr = tree, tr.fade > 0.5, abs(p.x - tr.pos.x) < 24 * tr.scale, p.y > tr.pos.y - 4, p.y < tr.pos.y + 76 * tr.scale {
            for k in Lights.treeBulbs.indices { test(Lights.treeBulb(foot: tr.pos, scale: tr.scale, tilt: tr.tilt, k), Lights.treeBase + k) }
        }
        let q = Int(best * 15)
        return q == 0 ? 0 : 7 | UInt32(idx | q << 3) << 8
    }
}
