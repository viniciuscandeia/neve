import CoreGraphics
import Foundation

extension SnowField {
    /// Idle melt in progress (or finished: see `meltDone`). `beginIntro` ends it, keeping whatever snow is left.
    public var isMelting: Bool { melting }
    /// The melt has run its full time: everything is gone, rendering may pause.
    public var meltDone: Bool { melting && meltT >= meltDur }
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
        if let k = figures.firstIndex(where: { $0.kind == .sleigh }) { removeFigure(k) }
        figuresVersion &+= 1
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
            if figures[i].kind != .snowman {
                figures[i].melt -= dt
                if figures[i].melt <= 0 { removeFigure(i) } else { figuresVersion &+= 1 }
                continue
            }
            guard figures[i].phase != .collapsing else { continue }
            if p >= 0.55 {   // the rest fades out (0.4 s)
                endFights(of: figures[i].id)
                figures[i].phase = .collapsing; figures[i].phaseT = 0; figures[i].fade = 1; figures[i].fight = nil; figures[i].pose = Pose()
            } else if !calm {
                figures[i].radii *= max(0, 1 - 0.9 * dt / (0.55 * meltDur))   // sags
                figures[i].built = min(figures[i].built, max(3, Snowman.stageCount - Int(p / 0.55 * 4.99)))   // scarf, arms, nose, coal go first
            }
            figuresVersion &+= 1
        }
        var started = false
        for k in balls.indices where !balls[k].melting && balls[k].state != .held && meltT >= meltDur * 0.4 * Self.hash01(balls[k].id) { balls[k].melting = true; started = true }
        if started { ballsVersion &+= 1 }
    }

    /// Whatever is left (frost lips, a held ball, stray debris) goes at once.
    private func finishMelt() {
        clear()
        iceWin.removeAll(keepingCapacity: true); icicles.removeAll(keepingCapacity: true)
        giftState.gifts.removeAll(keepingCapacity: true); giftState.confetti.removeAll(keepingCapacity: true)
        for i in flakes.indices { flakes[i].kind = .dormant }
        pilesDirty = true
    }
}
