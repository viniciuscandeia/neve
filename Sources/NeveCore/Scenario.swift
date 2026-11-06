import Foundation

/// Deterministic load for perf A/B runs (`NEVE_SCENARIO=heavy`, see main.swift).
public enum Scenario { case heavy }

extension SnowField {
    /// Idempotent: Nevasca, every visible surface at >= 80% of its limit, the auto snowman complete and two
    /// 3-ball snowmen (radii 20/14/10) ~150pt apart on the ground, so fights start by themselves.
    public func stage(_ s: Scenario) {
        setIntensity(.nevasca)
        fillPiles(0.8)
        guard let (g, lo, hi, mid) = groundStretch() else { return }
        func place(_ x: Float) -> Float { min(max(x, lo), hi) }

        // Auto snowman: complete, on the ground.
        if let i = autoFigure, figures[i].phase != .collapsing {
            figures[i].built = Snowman.stageCount; figures[i].progress = 0; figures[i].stageAge = max(figures[i].stageAge, 1)
        } else if autoFigure == nil {
            addFigure(fromBalls: false, radii: Snowman.radii * snowmanScale, built: Snowman.stageCount, surface: g.id, x: place(mid + 225))
            if let i = autoFigure { figures[i].stageAge = 1 }
        }
        snowmanCooldown = 0

        // User snowmen: keep whole ones on the ground, drop leftovers (headless bodies, loose heads), rebuild up to two.
        var i = figures.count - 1
        while i >= 0 {
            if figures[i].kind != .snowman { i -= 1; continue }   // visitors are not user snowmen
            if figures[i].fromBalls && !figures[i].headless && figures[i].surfaceID == g.id { i -= 1; continue }
            if figures[i].fromBalls || figures[i].headless { removeFigure(i) }
            i -= 1
        }
        let before = balls.count
        balls.removeAll { $0.state != .held }
        if balls.count != before { ballsVersion &+= 1 }
        let kept = figures.filter { $0.fromBalls && $0.kind == .snowman }
        var xs = [mid - 75, mid + 75]
        if let k = kept.first { xs = [k.foot.x < mid ? mid + 75 : mid - 75] }
        for x in xs.prefix(2 - kept.count) {
            addFigure(fromBalls: true, radii: SIMD3(20, 14, 10), built: Snowman.stageCount, surface: g.id, x: x)
        }
    }
}

extension SnowField {
    /// Every visible column of every surface rises to at least `k` of its limit.
    func fillPiles(_ k: Float) {
        for si in surfaces.indices {
            for b in surfaces[si].pile.heights.indices where surfaces[si].pile.visible[b] {
                let p = surfaces[si].pile
                surfaces[si].pile.heights[b] = max(p.heights[b], max(p.limit(b), 0) * k)
            }
        }
        pilesDirty = true
    }

    /// The widest visible run of ground columns, kept `snowmanClearance` away from its ends: (ground surface, lo x, hi x, mid x).
    func groundStretch() -> (g: Surface, lo: Float, hi: Float, mid: Float)? {
        guard let gi = index[Tuning.groundID] else { return nil }
        let g = surfaces[gi], n = g.pile.heights.count, clear = Int((Tuning.snowmanClearance / Tuning.binWidth).rounded(.up))
        var best = (0, 0), b = 0
        while b < n {
            guard g.pile.visible[b] else { b += 1; continue }
            var e = b
            while e < n && g.pile.visible[e] { e += 1 }
            if e - b > best.1 - best.0 { best = (b, e) }
            b = e
        }
        guard best.1 - best.0 > 2 * clear else { return nil }
        let lo = binCenter(g.c0 + best.0 + clear), hi = binCenter(g.c0 + best.1 - clear)
        return (g, lo, hi, (lo + hi) / 2)
    }
}
