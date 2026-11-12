// AGENT HEADER - Sources/NeveCore/Lights.swift  (Christmas lights: garland of arcs under the menu bar + a spiral of bulbs on the Christmas tree)
// Role: `Lights` (constants, `level(id, t, calm)` = brightness 0...1 of one bulb, the tree spiral `treeWire` / `treeBulbs` / `treeBulb`) and SnowField `lightsEnabled` (the app sets it from Pref.lights), `writeLightPrims` (Overlay.writePrims, after the figures:
//   garland cable = 6 short capsules per arc in two alternating greens (a twisted look) drooping in a catenary; every bulb = an elongated ellipse hanging from the cable along its normal (mostly down) with a dark socket cap, and a multi-ring glow (3 concentric
//   low-alpha ellipses `Lights.rings`, intensity = level; 1 ring in economy / Low Power; there is no additive blending); the tree carries a wire that spirals up the tiers (`treeWire`, 30 segments, x = 0.55 of the silhouette half width `Rig.treeWidth` * sin) with
//   `treeBulbs` (14 hanging bulbs on that spiral, inside the silhouette: LightsTests) + a low-alpha coloured ellipse on the pile at each bulb's x) and `lightCode(at:)` (lit flakes: a flake within `Lights.litRadius` of a bulb centre gets
//   Instance.kind 7 | (colour index | strength 0...15 << 3) << 8; the flake shader mixes its colour toward Palette.lights[idx]. Only flakes in the top band and inside the tree's box are tested; the garland bulb is found by x, so no scan; `lightCtx()` builds the bulb positions / hidden arcs once per writeInstances, not per flake).
// Pattern: the three modes (twinkle, chase, pulse) alternate every `Lights.cycle` s with a `fadeT` cross-fade; phase = `SnowField.time` (stops while frozen). `calm` (Reduce Motion) = every bulb steady at full level, so nothing blinks and a still screen never has to wake.
//   Arcs hidden by a window outline (`garlandArcHidden`: start / middle / end inside an occluder) are skipped whole (cable, bulbs, lit flakes). Windows carry no lights. Colours: Palette.lights (Tones, light / dark). Ids: garland bulb i = i; tree bulb k = 1000 + k (colour = id % 5).
// Prims: garland ~ (6 cable + 4 x (2 + rings)) per 110 pt arc; tree ~ 30 wire + 14 x (2 + rings) + 14 pile tints. Randomness: none (pure function of time). Allocation: only the two small per-frame `LightCtx` arrays. Tests: LightsTests. Units: local pt, y up.

import Foundation

public enum Lights {
    static let span: Float = 110, perArc = 4, sag: Float = 12   // one arc = 110 pt wide with 4 bulbs, 12 pt deep
    static let litRadius: Float = 14, band: Float = 30          // lit flakes: reach of a bulb, height of the garland band tested
    static let cycle: Float = 12, fadeT: Float = 1.5            // seconds per mode, cross-fade length
    static let treeBase = 1000
    static let hang: Float = 4                                  // pt from the cable to the bulb centre (at scale 1)
    static let rings: [(r: Float, a: Float)] = [(4.6, 0.16), (7.6, 0.10), (11, 0.06)]   // glow rings: radius pt, alpha at full level
    static let treeBulbCount = 14

    /// A point of the wire that spirals up the tree (scale 1, local coordinates of Rig.tree): s 0...1 = bottom to top, four turns, kept well inside the silhouette.
    static func spiral(_ s: Float) -> SIMD2<Float> {
        let y = 18 + 82 * s
        return SIMD2(0.55 * Rig.treeWidth(y) * sin(s * 2 * .pi * 4.25), y)
    }
    static let treeWire: [SIMD2<Float>] = (0...30).map { spiral(Float($0) / 30) }
    /// Bulb centres on the tree at scale 1: hanging `hang` below points along the spiral; all inside the silhouette.
    static let treeBulbs: [SIMD2<Float>] = (0..<treeBulbCount).map { spiral((Float($0) + 0.5) / Float(treeBulbCount)) - SIMD2(0, hang) }

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
    static func place(foot: SIMD2<Float>, scale: Float, tilt: Float, _ v: SIMD2<Float>) -> SIMD2<Float> {
        let sn = sin(tilt), cs = cos(tilt), x = v.x * scale, y = v.y * scale
        return foot + SIMD2(x * cs - y * sn, x * sn + y * cs)
    }
    static func treeBulb(foot: SIMD2<Float>, scale: Float, tilt: Float, _ k: Int) -> SIMD2<Float> { place(foot: foot, scale: scale, tilt: tilt, treeBulbs[k]) }
}

extension SnowField {
    var garlandArcs: Int { max(Int(size.x / Lights.span), 0) }
    var garlandOffset: Float { (size.x - Float(garlandArcs) * Lights.span) / 2 }
    func garlandPoint(arc: Int, u: Float) -> SIMD2<Float> {
        SIMD2(garlandOffset + (Float(arc) + u) * Lights.span, visibleTop - 2 - Lights.sag * 4 * u * (1 - u))
    }
    /// An arc whose start, middle or end lies inside a window outline (`occluders`, any z: a window reaching the menu bar hides the cable and bulbs behind it) is skipped whole.
    func garlandArcHidden(_ arc: Int) -> Bool {
        guard !occluders.isEmpty else { return false }
        return [0, 0.5, 1].contains { u in let p = garlandPoint(arc: arc, u: Float(u)); return occluders.contains { $0.hides(x: p.x, y: p.y) } }
    }
    /// Where bulb `i` hangs from the cable and the unit direction it hangs along (the cable's normal blended with gravity).
    func garlandHang(_ i: Int) -> (anchor: SIMD2<Float>, dir: SIMD2<Float>) {
        let u = (Float(i % Lights.perArc) + 0.5) / Float(Lights.perArc)
        let n = SIMD2(-Lights.sag * 4 * (1 - 2 * u), -Lights.span), m = n / (n.x * n.x + n.y * n.y).squareRoot() * 0.5 + SIMD2(0, -0.5)
        return (garlandPoint(arc: i / Lights.perArc, u: u), m / (m.x * m.x + m.y * m.y).squareRoot())
    }
    func garlandBulb(_ i: Int) -> SIMD2<Float> { let h = garlandHang(i); return h.anchor + h.dir * Lights.hang }

    /// Garland and tree lights as prims; `shift` gives the drag offset of a surface id (the tree rides with its window).
    public func writeLightPrims(_ w: inout PrimWriter, shift: (Int?) -> SIMD2<Float>) {
        guard lightsEnabled else { return }
        let t = Float(time), cableA = Rig.a(Rig.c4(Palette.treeShade.now), 0.95), cableB = Rig.a(Rig.c4(Palette.treeGreen.now), 0.9), socket = Rig.c4(Palette.coal.now)
        let arcs = garlandArcs, ringN = economy || lowPower ? 1 : 3
        let steps = 6
        for arc in 0..<arcs where !garlandArcHidden(arc) {   // cable: short capsules alternating two greens (the twist), a hair thicker than the old wire
            var prev = garlandPoint(arc: arc, u: 0)
            for s in 1...steps {
                let q = garlandPoint(arc: arc, u: Float(s) / Float(steps))
                w.capsule(from: prev, to: q, width: 1.4, color: s % 2 == 0 ? cableA : cableB)
                prev = q
            }
        }
        func bulb(anchor: SIMD2<Float>, dir: SIMD2<Float>, id: Int, fade: Float, size: Float) {
            let lv = Lights.level(id, t: t, calm: calm), c = Rig.c4(Palette.lights[id % 5].now), ctr = anchor + dir * (Lights.hang * size)
            for k in 0..<ringN {   // glow: concentric low-alpha ellipses (economy: only the middle one, a little stronger)
                let ring = ringN == 1 ? (r: Lights.rings[1].r, a: Lights.rings[1].a * 1.4) : Lights.rings[k]
                w.ellipse(center: ctr, radii: SIMD2(repeating: ring.r * size), color: Rig.a(c, ring.a * lv * fade), soft: 3)
            }
            w.ellipse(center: ctr, radii: SIMD2(1.6, 2.5) * size, rotation: atan2(-dir.x, dir.y), color: Rig.a(c, (0.4 + 0.6 * lv) * fade))
            w.capsule(from: anchor, to: anchor + dir * (1.9 * size), width: 2.1 * size, color: Rig.a(socket, 0.95 * fade))
        }
        for i in 0..<(arcs * Lights.perArc) where !garlandArcHidden(i / Lights.perArc) { let h = garlandHang(i); bulb(anchor: h.anchor, dir: h.dir, id: i, fade: 1, size: 1) }
        if let tr = tree, tr.fade > 0.01 {
            let foot = tr.pos + shift(tr.surface), wire = Rig.a(socket, 0.6 * tr.fade), dir = SIMD2(sin(tr.tilt), -cos(tr.tilt))
            var prev = Lights.place(foot: foot, scale: tr.scale, tilt: tr.tilt, Lights.treeWire[0])
            for j in 1..<Lights.treeWire.count {
                let q = Lights.place(foot: foot, scale: tr.scale, tilt: tr.tilt, Lights.treeWire[j])
                w.capsule(from: prev, to: q, width: 1.1 * tr.scale, color: wire)
                prev = q
            }
            for k in Lights.treeBulbs.indices {
                let p = Lights.treeBulb(foot: foot, scale: tr.scale, tilt: tr.tilt, k), id = Lights.treeBase + k
                bulb(anchor: p - dir * (Lights.hang * tr.scale), dir: dir, id: id, fade: tr.fade, size: tr.scale)
                if tr.state == .resting {   // coloured glow on the pile under the bulb
                    let lv = Lights.level(id, t: t, calm: calm)
                    w.ellipse(center: SIMD2(p.x, foot.y + 0.5 * tr.scale), radii: SIMD2(9, 2.6) * tr.scale, color: Rig.a(Rig.c4(Palette.lights[id % 5].now), 0.16 * lv * tr.fade), soft: 2)
                }
            }
        }
    }

    /// Per-frame lookup tables for `lightCode`: garland bulb centres (nil = hidden arc) and tree bulb centres, built once per writeInstances instead of per flake.
    struct LightCtx {
        var garland: [SIMD2<Float>?] = [], tree: [SIMD2<Float>] = [], t: Float = 0
        var treeBox: (x: Float, y0: Float, y1: Float, w: Float)? = nil
    }
    func lightCtx() -> LightCtx {
        var c = LightCtx(); c.t = Float(time)
        let n = garlandArcs * Lights.perArc
        c.garland.reserveCapacity(n)
        var hid = [Bool](repeating: false, count: garlandArcs)
        for a in 0..<garlandArcs { hid[a] = garlandArcHidden(a) }
        for k in 0..<n { c.garland.append(hid[k / Lights.perArc] ? nil : garlandBulb(k)) }
        if let tr = tree, tr.fade > 0.5 {
            c.treeBox = (tr.pos.x, tr.pos.y - 4, tr.pos.y + 126 * tr.scale, 40 * tr.scale)
            c.tree = Lights.treeBulbs.indices.map { Lights.treeBulb(foot: tr.pos, scale: tr.scale, tilt: tr.tilt, $0) }
        }
        return c
    }

    /// Instance.kind for a flake lit by a nearby bulb (see header), 0 when none; the caller checks `lightsEnabled`.
    func lightCode(at p: SIMD2<Float>) -> UInt32 { lightCode(at: p, lightCtx()) }
    func lightCode(at p: SIMD2<Float>, _ c: LightCtx) -> UInt32 {
        let inBand = p.y > visibleTop - Lights.band
        var inTree = false
        if let b = c.treeBox { inTree = abs(p.x - b.x) < b.w && p.y > b.y0 && p.y < b.y1 }
        if !inBand && !inTree { return 0 }
        var best: Float = 0, idx = 0
        let r = Lights.litRadius, t = c.t
        func test(_ b: SIMD2<Float>, _ id: Int) {
            let dx = p.x - b.x, dy = p.y - b.y, d = (dx * dx + dy * dy).squareRoot()
            guard d < r else { return }
            let s = (1 - d / r) * Lights.level(id, t: t, calm: calm)
            if s > best { best = s; idx = id % 5 }
        }
        if inBand {
            let n = c.garland.count, j = Int(((p.x - garlandOffset) / (Lights.span / Float(Lights.perArc)) - 0.5).rounded())
            for k in (j - 1)...(j + 1) where k >= 0 && k < n { if let b = c.garland[k] { test(b, k) } }
        }
        if inTree { for k in c.tree.indices { test(c.tree[k], Lights.treeBase + k) } }
        let q = Int(best * 15)
        return q == 0 ? 0 : 7 | UInt32(idx | q << 3) << 8
    }
}
