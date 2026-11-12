// AGENT HEADER - Sources/NeveCore/Snowman.swift  (the auto snowman: design, build, site selection)
// Role: `Snowman` design constants (7 stages: base, middle, head, coal, nose, arms, scarf; stage seconds [14,14,12,8,8,8,8] of snowfall; balls 23+17+13 pt, total height 51 at scale 1; snow shares gathered per stage), and SnowField: `snowmanScale` (1...1.5 by
//   screen width), `stepBuilder` (runs in SnowField.step while no auto snowman exists; starts a build where `findSite` finds a >= snowmanStretch 70 pt stretch whose mean pile height >= SimConfig.snowmanDepth, clearance 20 pt, cooldown 120 s of snowfall), `advanceBuild`, `scoop` (lowers the pile around the base
//   with cosine falloff), `sweepFigures` (cursor segment shatters a standing figure), `collapse(velocity:)` (auto snowman shatters, cooldown starts; also called by Figures.swift when its surface is gone, its pile is cleared, or it has stood headless past Tuning.headlessLife). Builds only during snowfall time (SimConfig.snowmanSpeed speeds it for NEVE_SNOWMAN_FAST demos). Tests: SnowmanTests.

import CoreGraphics
import Foundation

/// The auto snowman's design: it builds itself on a deep pile, one stage at a time, as a `Figure` (fromBalls: false).
public enum Snowman {
    public static let stageCount = 7   // base, middle, head, coal, nose, arms, scarf
    /// Snowfall seconds each stage takes (~70 s in total).
    static let seconds: [Float] = [14, 14, 12, 8, 8, 8, 8]
    /// Ball (center y, radius) in points above the base, at scale 1: 23 + 17 + 13 across, total 51.
    public static let balls: [(cy: Float, r: Float)] = [(11.5, 11.5), (30.5, 8.5), (44.5, 6.5)]
    public static let height: Float = 51
    static let radii = SIMD3<Float>(11.5, 8.5, 6.5)
    static let share: [Float] = [0.2, 0.12, 0.08, 0.03, 0.03, 0.03, 0.03]   // of the snow around the base each stage gathers
}

extension SnowField {
    /// Size factor on top of the 51pt design: 1.5 (~76pt tall) from 1000pt-wide screens up, down to 1 on small ones.
    var snowmanScale: Float { min(1.5, max(1, size.x / 1000 * 1.5)) }

    var autoFigure: Int? { figures.firstIndex { !$0.fromBalls } }

    /// Starts a snowman where the pile is deep: runs from `step` while there is none (the cooldown counts snowfall time).
    func stepBuilder(dt: Float) {
        guard snowmanEnabled, !melting, autoFigure == nil else { return }
        if snowmanCooldown > 0 { snowmanCooldown -= dt * config.snowmanSpeed; return }
        guard canSpawnFigure else { return }
        snowmanScan += dt
        guard snowmanScan >= 1 else { return }
        snowmanScan = 0
        if let (id, x, y) = findSite() {
            addFigure(fromBalls: false, radii: Snowman.radii * snowmanScale, built: 0, surface: id, x: x, y: y)
        }
    }

    /// Snowfall time advances the build of a standing auto figure `f` on surface index `si`.
    func advanceBuild(_ f: inout Figure, si: Int, dt: Float) {
        guard !melting, f.built < Snowman.stageCount else { return }   // frozen while the idle melt sags it
        f.progress += dt * config.snowmanSpeed / Snowman.seconds[f.built]
        if f.progress >= 1 {
            f.progress = 0; f.built += 1; f.stageAge = 0
            f.vol += scoop(si, x: f.foot.x, scale: f.scale, stage: f.built)
        }
    }

    /// Gathering snow for a ball: lowers the pile around the base (cosine falloff), a share of what is there.
    @discardableResult private func scoop(_ si: Int, x: Float, scale: Float, stage: Int) -> Float {
        let rad = 20 * scale, s = surfaces[si], share = Snowman.share[stage - 1]
        let lo = max(column(x - rad), s.c0), hi = min(column(x + rad), s.c0 + s.pile.heights.count - 1)
        guard lo <= hi else { return 0 }
        var took: Float = 0
        for c in lo...hi {
            let d = abs(binCenter(c) - x)
            guard d < rad else { continue }
            let h = surfaces[si].pile.heights[c - s.c0], k = share * 0.5 * (1 + cos(.pi * d / rad))
            took += h * k * Tuning.binWidth
            surfaces[si].pile.heights[c - s.c0] = h * (1 - k)
        }
        pilesDirty = true
        return took
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

    /// Cursor segment a->b (radius r) through a standing figure's balls shatters it whole.
    func sweepFigures(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ r: Float, _ v: SIMD2<Float>) {
        guard !figures.isEmpty else { return }
        sweepPenguins(ax, ay, bx, by, r)
        let dx = bx - ax, dy = by - ay, len2 = max(dx * dx + dy * dy, 1e-6)
        var i = figures.count - 1
        while i >= 0 {
            defer { i -= 1 }
            guard i < figures.count, figures[i].kind == .snowman, figures[i].phase != .collapsing, figures[i].phase != .hidden else { continue }
            let f = figures[i], a = anchors(of: f)
            for k in 0..<ballCount(f) {
                let (c, rad) = circle(a, f, k)
                let t = min(max(((c.x - ax) * dx + (c.y - ay) * dy) / len2, 0), 1)
                let ex = ax + t * dx - c.x, ey = ay + t * dy - c.y
                if let sid = f.surfaceID, sid > 0, let si = index[sid], ay + t * dy < surfaces[si].edgeY { continue }   // on a window: only a cursor above its top edge bursts it
                if ex * ex + ey * ey <= (r + rad) * (r + rad) { shatter(f.id, velocity: v, burst: true); break }
            }
        }
    }

    /// The auto snowman breaks (its cooldown starts). Used by tests and the outro.
    func collapse(velocity v: SIMD2<Float> = .zero) {
        guard let i = autoFigure, figures[i].phase != .collapsing else { return }
        shatter(figures[i].id, velocity: v)
    }
}
