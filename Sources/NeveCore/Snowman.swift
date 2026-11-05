import CoreGraphics
import Foundation

/// A snowman that builds itself on a deep pile, one stage at a time. Pure state: rendering reads it.
public struct Snowman {
    public static let stageCount = 7   // base, middle, head, coal, nose, arms, scarf
    /// Snowfall seconds each stage takes (~70 s in total).
    static let seconds: [Float] = [14, 14, 12, 8, 8, 8, 8]
    /// Ball (center y, radius) in points above the base, at scale 1: 23 + 17 + 13 across, total 51.
    public static let balls: [(cy: Float, r: Float)] = [(11.5, 11.5), (30.5, 8.5), (44.5, 6.5)]
    public static let height: Float = 51

    public internal(set) var x: Float                // walks, see Walkers.swift
    public internal(set) var hop: Float = 0, lean: Float = 0, facing: Float = 1   // walking pose: lift, head offset, +-1
    public internal(set) var pose = Flutter()        // scarf / arms, see Walkers.swift
    public let surfaceID: Int
    public let scale: Float
    public internal(set) var y: Float                // base y (last known pile top under it)
    public internal(set) var stage = 0               // stages that have appeared (0...7)
    public internal(set) var progress: Float = 0     // 0...1 toward the next stage
    public internal(set) var stageAge: Float = 0     // real seconds since the last stage appeared (ease-in)
    public internal(set) var collapsing = false      // balls are debris; accessories fade out
    public internal(set) var fade: Float = 1         // 1 -> 0 while collapsing
    public var complete: Bool { stage == Snowman.stageCount }
    /// Top of what is built so far, above the base, at scale 1.
    public var builtHeight: Float { stage >= 3 ? Snowman.height : stage == 2 ? 39 : stage == 1 ? 23 : 0 }
}

extension SnowField {
    /// Size factor on top of the 51pt design: 1.5 (~76pt tall) from 1000pt-wide screens up, down to 1 on small ones.
    var snowmanScale: Float { min(1.5, max(1, size.x / 1000 * 1.5)) }

    /// Snowfall time advances building; a collapse starts the cooldown. Runs from `step`.
    func stepSnowman(dt: Float) {
        guard snowmanEnabled else { return }
        let sdt = dt * config.snowmanSpeed
        guard var m = snowman else {
            if snowmanCooldown > 0 { snowmanCooldown -= sdt; return }
            snowmanScan += dt
            if snowmanScan >= 1 {
                snowmanScan = 0
                if let (id, x, y) = findSite() { snowman = Snowman(x: x, surfaceID: id, scale: snowmanScale, y: y) }
            }
            return
        }
        if m.collapsing {
            m.fade -= dt / 0.4
            snowman = m.fade > 0 ? m : nil
            return
        }
        guard let (si, avg, y, visible) = site(of: m) else { collapse(); return }   // surface gone
        if visible {
            if avg < 1 { collapse(); return }   // pile cleared / knocked off under it
            m.y = y
        }
        m.stageAge += dt
        if !m.complete {
            m.progress += sdt / Snowman.seconds[m.stage]
            if m.progress >= 1 {
                m.progress = 0; m.stage += 1; m.stageAge = 0
                scoop(si, m, stage: m.stage)
            }
        }
        snowman = m
    }

    /// Surface index, mean pile height over the base, base y, and whether the spot is visible.
    private func site(of m: Snowman) -> (Int, Float, Float, Bool)? {
        guard let si = index[m.surfaceID], let avg = meanHeight(si: si, col: column(m.x), span: 3) else { return nil }
        let s = surfaces[si], c = column(m.x) - s.c0
        return (si, avg, s.edgeY + s.pile.base[c] + avg - 2 * m.scale, s.pile.visible[c])
    }

    /// Where the base sits (x, y), nil when there is no snowman or its spot is covered by a window.
    public func snowmanPlacement() -> SIMD2<Float>? {
        guard let m = snowman, let (_, _, y, visible) = site(of: m), visible else { return nil }
        return SIMD2(m.x, y + m.hop)
    }

    /// Gathering snow for a ball: lowers the pile around the base (cosine falloff), a share of what is there.
    private func scoop(_ si: Int, _ m: Snowman, stage: Int) {
        let share: [Float] = [0.2, 0.12, 0.08, 0.03, 0.03, 0.03, 0.03]
        let rad = 20 * m.scale, s = surfaces[si]
        let lo = max(column(m.x - rad), s.c0), hi = min(column(m.x + rad), s.c0 + s.pile.heights.count - 1)
        guard lo <= hi else { return }
        for c in lo...hi {
            let d = abs(binCenter(c) - m.x)
            guard d < rad else { continue }
            surfaces[si].pile.heights[c - s.c0] *= 1 - share[stage - 1] * 0.5 * (1 + cos(.pi * d / rad))
        }
        pilesDirty = true
    }

    /// Widest visible stretch of ground (Dock pile only when no ground is visible) holding a window of
    /// `snowmanStretch` points whose mean height reaches the depth; centre of its deepest window.
    private func findSite() -> (Int, Float, Float)? {
        let w = Int(Tuning.snowmanStretch * snowmanScale / Tuning.binWidth)
        let need = config.snowmanDepth * Float(w), room = (Snowman.height + 20) * snowmanScale
        let clear = Int((Tuning.snowmanClearance / Tuning.binWidth).rounded(.up))
        for id in [Tuning.groundID, 0] {
            guard let si = index[id] else { continue }
            let p = surfaces[si].pile, n = p.heights.count
            var seen = false, bestRun = 0, bestAt = 0
            var b = 0
            while b < n {
                guard p.visible[b] else { b += 1; continue }
                var e = b
                while e < n && p.visible[e] { e += 1 }
                let (rb, re) = (b + clear, e - clear)   // keep clear of the Dock ends, covering windows and screen edges: wait rather than squeeze
                if re - rb >= w {
                    seen = true
                    var sum: Float = 0, tight = 0, top: Float = 0, at = -1
                    for i in rb..<re {
                        sum += p.heights[i]; if p.cap[i] < room { tight += 1 }
                        if i - rb >= w { sum -= p.heights[i - w]; if p.cap[i - w] < room { tight -= 1 } }
                        if i - rb >= w - 1, tight == 0, sum >= need, sum > top { top = sum; at = i - w + 1 }
                    }
                    if at >= 0, re - rb > bestRun { bestRun = re - rb; bestAt = at }
                }
                b = e
            }
            if bestRun > 0 {
                let c = bestAt + w / 2
                return (id, binCenter(surfaces[si].c0 + c), surfaces[si].edgeY + p.base[c] + p.heights[c])
            }
            if seen { return nil }   // ground is visible, just not deep enough yet
        }
        return nil
    }

    /// Cursor segment a->b (radius r) through the standing snowman collapses it.
    func collapseIfSwept(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ r: Float, _ v: SIMD2<Float>) {
        guard let m = snowman, !m.collapsing, m.stage > 0 else { return }
        let hw = 12 * m.scale + r
        let (x0, x1, y0, y1) = (m.x - hw, m.x + hw, m.y - r, m.y + m.builtHeight * m.scale + r)
        var t0: Float = 0, t1: Float = 1
        func clip(_ p: Float, _ q: Float) -> Bool {   // Liang-Barsky slab
            if p == 0 { return q >= 0 }
            let t = q / p
            if p < 0 { if t > t1 { return false }; t0 = max(t0, t) } else { if t < t0 { return false }; t1 = min(t1, t) }
            return true
        }
        let dx = bx - ax, dy = by - ay
        if clip(-dx, ax - x0), clip(dx, x1 - ax), clip(-dy, ay - y0), clip(dy, y1 - ay) { collapse(velocity: v) }
    }

    /// Balls become heavy debris (a few dozen chunks each, thrown outward), accessories fade out; cooldown starts.
    func collapse(velocity v: SIMD2<Float> = .zero) {
        guard var m = snowman, !m.collapsing else { return }
        if !silent {
            for k in 0..<min(m.stage, 3) {
                let (cy, r) = Snowman.balls[k]
                for _ in 0..<(k == 0 ? 36 : k == 1 ? 28 : 20) {
                    let a = Float.random(in: 0..<(2 * .pi), using: &rng), d = r * m.scale * Float.random(in: 0...1, using: &rng).squareRoot()
                    let dx = cos(a) * d, dy = sin(a) * d
                    addDebris(x: m.x + dx, y: m.y + cy * m.scale + dy, vx: dx * 3 + v.x * 0.3 + Float.random(in: -10...10, using: &rng),
                              fall: Float.random(in: 0...40, using: &rng) - dy * 2 - v.y * 0.3, size: Float.random(in: 5...8, using: &rng))
                }
            }
        }
        m.collapsing = true
        m.fade = 1
        snowman = m
        snowmanCooldown = Tuning.snowmanCooldown
    }
}
