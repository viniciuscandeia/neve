import CoreGraphics
import Foundation

extension SnowField {
    /// Idle melt in progress (or finished: see `meltDone`). `beginIntro` ends it, keeping whatever snow is left.
    public var isMelting: Bool { melting }
    /// The melt has run its full time: everything is gone, rendering may pause.
    /// Airborne debris, dust, glints and meltwater are let finish first (finishMelt keeps them), so nothing vanishes in the last frame.
    public var meltDone: Bool { melting && meltT >= meltDur && debris.isEmpty && puffs.isEmpty && glints.isEmpty && drops.isEmpty }
    /// Speed-up of every fade-out while melting, so the latest one (a ball / snowman / gift starting at 40-55% of a short Reduce Motion melt)
    /// is still done when the melt ends. 1 for a normal melt, and outside melting.
    var fadeK: Float { melting ? max(1, 1.34 / meltDur) : 1 }
    /// Total pile snow (pt^2), all surfaces.
    public var pileVolume: Float {
        var v: Float = 0
        for s in surfaces { for h in s.pile.heights { v += h } }
        return v * Tuning.binWidth
    }

    /// Melt: spawning stops, flakes fade as they fall, every pile sinks at a constant rate (thin edges vanish first, the contour keeps its shape),
    /// snowmen sag and lose their accessories, balls / visitors / icicles fade. Everything is gone after `duration` seconds of stepping
    /// (Reduce Motion: 0.6 s, no sag). Deterministic: sim time only.
    public func beginMelt(duration: Float) {
        guard !melting else { return }
        melting = true; introDur = 0
        meltT = 0; meltDur = calm ? 0.6 : max(duration, 0.01)
        var hmax: Float = 0
        for s in surfaces { for h in s.pile.heights { hmax = max(hmax, h) } }
        meltRate = hmax / (meltDur * 0.85)
        snowmanCooldown = .infinity
        fights.removeAll(keepingCapacity: true); shots.removeAll(keepingCapacity: true); carrots.removeAll(keepingCapacity: true)
        for i in icicles.indices { icicles[i].dying = true }
    }

    func stepMelt(dt: Float) {
        guard melting, meltT < meltDur else { return }
        meltT += dt
        if meltT >= meltDur { finishMelt(); return }
        let p = meltT / meltDur
        var changed = false
        for si in surfaces.indices {
            for b in surfaces[si].pile.heights.indices where surfaces[si].pile.heights[b] > 0 {
                surfaces[si].pile.heights[b] = max(0, surfaces[si].pile.heights[b] - meltRate * dt)
                changed = true
            }
        }
        if changed { pilesDirty = true }
        var i = figures.count - 1
        while i >= 0 {
            defer { i -= 1 }
            guard i < figures.count else { continue }
            if figures[i].kind != .snowman { continue }   // visitors fade in stepFigures
            guard figures[i].phase != .collapsing else { continue }
            if p >= 0.55 {   // the rest fades out (0.4 s)
                endFights(of: figures[i].id)
                figures[i].phase = .collapsing; figures[i].phaseT = 0; figures[i].fade = 1; figures[i].fight = nil; figures[i].pose = Pose()
            } else if !calm {
                if figures[i].preMelt == nil { figures[i].preMelt = (figures[i].radii, figures[i].built) }
                let k = figures[i].preMelt!
                figures[i].radii = k.radii * exp(-0.9 * p / 0.55)   // sags
                figures[i].built = min(k.built, max(3, Snowman.stageCount - Int(p / 0.55 * 4.99)))   // scarf, arms, nose, coal go first
            }
        }
        for k in balls.indices where !balls[k].melting && balls[k].state != .held && meltT >= meltDur * 0.4 * Self.hash01(balls[k].id) { balls[k].melting = true }
    }

    /// Whatever is left (frost lips, a held ball) goes at once; airborne debris, dust, glints and drops finish their flight (nothing lands while melting).
    private func finishMelt() {
        let air = (debris, puffs, glints, drops)
        clear()
        (debris, puffs, glints, drops) = air
        for i in flakes.indices { flakes[i].kind = .dormant }
        pilesDirty = true
    }
}
