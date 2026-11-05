import Foundation

/// Deterministic load for perf A/B runs (`NEVE_SCENARIO=heavy`, see main.swift).
public enum Scenario { case heavy }

extension SnowField {
    /// Idempotent: Nevasca, every visible surface at >= 80% of its limit, the auto snowman complete and two
    /// 3-ball snowmen (radii 20/14/10) ~150pt apart on the ground, so fights start by themselves.
    public func stage(_ s: Scenario) {
        setIntensity(.nevasca)
        for si in surfaces.indices {
            for b in surfaces[si].pile.heights.indices where surfaces[si].pile.visible[b] {
                let p = surfaces[si].pile
                surfaces[si].pile.heights[b] = max(p.heights[b], max(p.limit(b), 0) * 0.8)
            }
        }
        pilesDirty = true
        guard let gi = index[Tuning.groundID] else { return }
        let g = surfaces[gi], n = g.pile.heights.count, clear = Int((Tuning.snowmanClearance / Tuning.binWidth).rounded(.up))
        var best = (0, 0), b = 0   // widest visible run [lo, hi) of ground bins, clear of the ends
        while b < n {
            guard g.pile.visible[b] else { b += 1; continue }
            var e = b
            while e < n && g.pile.visible[e] { e += 1 }
            if e - b > best.1 - best.0 { best = (b, e) }
            b = e
        }
        guard best.1 - best.0 > 2 * clear else { return }
        let lo = binCenter(g.c0 + best.0 + clear), hi = binCenter(g.c0 + best.1 - clear), mid = (lo + hi) / 2
        func place(_ x: Float) -> Float { min(max(x, lo), hi) }

        // Auto snowman: complete, on the ground.
        if var m = snowman, !m.collapsing {
            m.stage = Snowman.stageCount; m.progress = 0; m.stageAge = max(m.stageAge, 1); snowman = m
        } else if snowman == nil {
            let c = column(place(mid + 225)) - g.c0
            snowman = Snowman(x: place(mid + 225), surfaceID: g.id, scale: snowmanScale,
                              y: g.edgeY + g.pile.base[c] + g.pile.heights[c] - 2 * snowmanScale)
            snowman?.stage = Snowman.stageCount; snowman?.stageAge = 1
        }
        snowmanCooldown = 0

        // User snowmen: keep complete chains, drop leftovers (headless bodies, loose heads), rebuild up to two.
        func chain(_ b: Snowball) -> Bool {
            guard b.parent == nil, let m = balls.first(where: { $0.parent == b.id }) else { return false }
            return balls.contains { $0.parent == m.id }
        }
        let keep = Set(balls.filter { chain($0) && $0.surfaceID == g.id }.flatMap { b -> [Int] in
            let m = balls.first { $0.parent == b.id }!, h = balls.first { $0.parent == m.id }!
            return [b.id, m.id, h.id]
        })
        let before = balls.count
        balls.removeAll { !keep.contains($0.id) && $0.state != .held }
        let have = keep.count / 3
        var xs = [mid - 75, mid + 75]
        if have > 0, let b = balls.first(where: { chain($0) }) { xs = [b.pos.x < mid ? mid + 75 : mid - 75] }
        for x in xs.prefix(2 - have) {
            var parent: Int?
            for (k, r) in [Float(20), 14, 10].enumerated() {
                var ball = Snowball(id: nextBallID, pos: SIMD2(x, 40 + Float(k) * 30), radius: r, surfaceID: g.id)
                nextBallID += 1
                ball.state = .resting; ball.parent = parent; parent = ball.id
                balls.append(ball)
            }
        }
        if balls.count != before || have < 2 { ballsVersion &+= 1 }
    }
}
