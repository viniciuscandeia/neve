// AGENT HEADER - Sources/NeveCore/Melt.swift  (idle melt: snow thaws away)
// Role: `beginMelt(duration:)` (Overlay.melt uses 12 s; Reduce Motion 0.6 s with no sag): sets melting, stops intro, snowmanCooldown = infinity, clears fights / carrots, marks icicles dying; `stepMelt(dt:)` (every pile bin sinks at a constant
//   per-surface rate (`meltRates` by surface id, tallest bin gone at 85 % of the run; `meltRate` = the max, for surfaces born mid-melt; cornices eaveL/R sink at `meltEaveRates`) so thin edges vanish first and the contour keeps its shape; from 55 % of the run snowmen collapse (before that they sag and lose accessories); balls start melting at a hash-staggered 0-40 % of the run); `meltDone` = full time run AND
//   airborne debris / puffs / glints / drops finished (or hard cap `meltGrace` 2 s past the end) => the overlay may pause rendering; `finishMelt` calls clear() but keeps that airborne set; `isMelting`, `pileVolume` (pt^2), `fadeK` (speeds
//   fade-outs of late starters so they finish; 1 outside a melt). Visitors fade in stepFigures, flakes fade in stepFlakes (`quiet` = outro || melting). `beginIntro` (SnowField.swift) ends a melt keeping the snow left.
// Caller chain: AppController.startIdleMelt (Sources/Neve/main.swift) -> Overlay.melt -> field.beginMelt; the overlay polls meltDone each tick. Deterministic: sim time only. Tests: MeltTests. Units: sim seconds, pt^2 for pile volume.

import CoreGraphics
import Foundation

extension SnowField {
    /// Idle melt in progress (or finished: see `meltDone`). `beginIntro` ends it, keeping whatever snow is left.
    public var isMelting: Bool { melting }
    /// The melt has run its full time: everything is gone, rendering may pause.
    /// Airborne debris, dust, glints and meltwater are let finish first (finishMelt keeps them), so nothing vanishes in the last frame.
    /// A hard cap (`meltGrace` s past the duration) finishes it even if some element never expires.
    public var meltDone: Bool { melting && meltT >= meltDur && (meltT >= meltDur + Self.meltGrace || debris.isEmpty && puffs.isEmpty && glints.isEmpty && drops.isEmpty) }
    static let meltGrace: Float = 2
    /// Speed-up of every fade-out while melting, so the latest one (a ball / snowman / gift starting at 40-55% of a short Reduce Motion melt)
    /// is still done when the melt ends. 1 for a normal melt, and outside melting.
    var fadeK: Float { melting ? max(1, 1.34 / meltDur) : 1 }
    /// Total pile snow (pt^2), all surfaces (heights + cornices).
    public var pileVolume: Float {
        var v: Float = 0
        for s in surfaces { for h in s.pile.heights { v += h } }
        return v * Tuning.binWidth + surfaces.reduce(0) { $0 + $1.pile.eaveL + $1.pile.eaveR }   // + the cornices (pt^2): snow that crept off the end bins
    }

    /// Melt: spawning stops, flakes fade as they fall, every pile sinks at a constant rate (thin edges vanish first, the contour keeps its shape),
    /// snowmen sag and lose their accessories, balls / visitors / icicles fade. Everything is gone after `duration` seconds of stepping
    /// (Reduce Motion: 0.6 s, no sag). Deterministic: sim time only.
    public func beginMelt(duration: Float) {
        guard !melting else { return }
        melting = true; introDur = 0
        meltT = 0; meltDur = calm ? 0.6 : max(duration, 0.01)
        meltRate = 0; meltRates.removeAll(); meltEaveRates.removeAll()
        for s in surfaces {   // each surface thaws on its own schedule: its tallest bin / cornice is gone at 85 % of the run (a Dock bank or tall heap elsewhere must not empty the window piles early)
            let h = s.pile.heights.max() ?? 0, e = max(s.pile.eaveL, s.pile.eaveR)
            meltRates[s.id] = h / (meltDur * 0.85); meltEaveRates[s.id] = e / (meltDur * 0.85)
            meltRate = max(meltRate, h / (meltDur * 0.85))
        }
        snowmanCooldown = .infinity
        clearFights(); clearCarrots()
        for i in icicles.indices { icicles[i].dying = true }
    }

    func stepMelt(dt: Float) {
        guard melting else { return }
        if meltT >= meltDur {   // finished: the airborne leftovers get `meltGrace` s, then they go too
            meltT += dt
            if meltT >= meltDur + Self.meltGrace { debris.removeAll(); puffs.removeAll(); glints.removeAll(); drops.removeAll() }
            return
        }
        meltT += dt
        if meltT >= meltDur { finishMelt(); return }
        let p = meltT / meltDur
        var changed = false
        for si in surfaces.indices {
            let rate = meltRates[surfaces[si].id] ?? meltRate   // a surface born mid-melt follows the fastest one
            for b in surfaces[si].pile.heights.indices where surfaces[si].pile.heights[b] > 0 {
                surfaces[si].pile.heights[b] = max(0, surfaces[si].pile.heights[b] - rate * dt)
                changed = true
            }
            let er = meltEaveRates[surfaces[si].id] ?? 0   // the cornice sinks with the snow under it (stepEaves does not run while quiet)
            if surfaces[si].pile.eaveL > 0 { surfaces[si].pile.eaveL = max(0, surfaces[si].pile.eaveL - er * dt); changed = true }
            if surfaces[si].pile.eaveR > 0 { surfaces[si].pile.eaveR = max(0, surfaces[si].pile.eaveR - er * dt); changed = true }
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
