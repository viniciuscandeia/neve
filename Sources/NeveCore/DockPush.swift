// AGENT HEADER - Sources/NeveCore/DockPush.swift  (Dock bar resize pushes the ground snow)
// Role: the Dock's frame read by Sources/Neve (`dockTarget`, arrives in the window list as WindowInfo number 0) is approached by the animated `dockCur` (minX/maxX move at Tuning.dockSpeed 800 pt/s) so a jump reads as a gradual push.
//   `effective(_:)` (called from Surfaces.swift's window update) swaps the animated Dock rect into the window list; a new, vertically moved, disjoint or `frozen` Dock snaps. `stepDock` (in SnowField.step) advances dockCur, rebuilds surfaces
//   (`dockIsolated`: only Dock + ground when no later window overlaps its reach) and, for Tuning.dockSlumpTime, relaxes the bank around both ends via zero-volume deposits. `berm` banks plowed ground snow ahead of a growing end through
//   Pile.deposit (what does not fit is shed as debris via shedBin, dropped in calm). `bankMaxes`/`stepBank`: the ground's per-column limit is a repose ramp beside the bar (Tuning.bankLimit); every 0.25 s, once the snow at the bar end has
//   filled the ramp, `bankLevel` (per side) rises 1 pt up to Tuning.bankLevelMax (a shelf flush with the Dock top).
// Side effects: sets pilesDirty; mutates pollDt temporarily inside stepDock. Tests: DockGapTests, DockPushTests, DockPerfTests, DockSpillTests. Units: pt, pt/s, y up.

import CoreGraphics
import Foundation

/// The Dock bar resizes when apps come and go. The sim moves each end toward the frame it was told at `Tuning.dockSpeed` (so a single jump, or the
/// Dock's own animation sampled a few times, reads as a gradual push). A growing end plows the ground snow ahead of it into a berm (`berm`) and
/// kicks some up; a shrinking end drops its Dock-top snow as clumps (buildSurface) and the bank slumps into the freed space (`stepDock`).
extension SnowField {
    /// The window list with the Dock at its animated frame; a new, vertically moved or disjoint Dock snaps (nothing to push).
    func effective(_ w: [WindowInfo]) -> [WindowInfo] {
        guard let k = w.firstIndex(where: { $0.number == 0 }) else { dockTarget = nil; dockCur = nil; return w }
        let t = w[k].frame
        if !frozen, let c = dockCur, abs(c.minY - t.minY) < 0.5, abs(c.height - t.height) < 0.5, c.maxX > t.minX, c.minX < t.maxX {
            dockCur = CGRect(x: c.minX, y: t.minY, width: c.width, height: t.height)
        } else { dockCur = t }
        dockTarget = t
        var e = w
        e[k] = WindowInfo(number: 0, frame: dockCur!, radius: w[k].radius)
        return e
    }

    func stepDock(dt: Float) {
        if let t = dockTarget, let c = dockCur, c.minX != t.minX || c.maxX != t.maxX {
            let m = CGFloat(Tuning.dockSpeed * dt)
            func toward(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + min(max(b - a, -m), m) }
            let l = toward(c.minX, t.minX), r = max(toward(c.maxX, t.maxX), l + 1)
            dockCur = CGRect(x: l, y: c.minY, width: r - l, height: c.height)
            let prevDock = c   // the frame the surfaces were last built for: windows it touched hold values that frame produced
            dockSlump = Tuning.dockSlumpTime
            let keep = pollDt
            pollDt = dt
            let w = effective(lastWindows)
            _ = updateSurfaces(windows: w, only: dockIsolated(w, prev: prevDock) ? [0, Tuning.groundID] : nil)   // the bar and the ground are all that moves
            pollDt = keep
        }
        guard dockSlump > 0, let c = dockCur, let g = index[Tuning.groundID] else { return }
        dockSlump -= dt
        for x in [c.minX, c.maxX] {   // the bank relaxes (via deposit's local relax) around both ends: berm spreads, freed span fills
            let b = column(Float(x - origin.x))
            for _ in 0..<3 { for o in stride(from: -64, through: 64, by: 8) { if surfaces[g].pile.deposit(bin: min(max(b + o, 0), numCols - 1), volume: 0) { pilesDirty = true } } }   // dirty only on a real change
        }
    }

    /// No window behind the Dock in the list (so none it can hide or roof over) lies within its horizontal reach, old or new, at or below its top:
    /// then only the Dock and the ground surfaces depend on its frame.
    func dockIsolated(_ w: [WindowInfo], prev p: CGRect) -> Bool {
        guard let k = w.firstIndex(where: { $0.number == 0 }), let t = dockTarget else { return false }
        let c = w[k].frame, lo = min(c.minX, t.minX, p.minX), hi = max(c.maxX, t.maxX, p.maxX)
        for j in (k + 1)..<w.count where w[j].frame.maxX > lo && w[j].frame.minX < hi && w[j].frame.maxY < c.maxY + 2 { return false }
        return true
    }

    /// Banks `volume` (summed height) on the ground from column `b0` outward (`dir` +-1): chunks go in through `Pile.deposit` (spread + relax, capped
    /// by the bank limit); a chunk that does not fit moves the drop point further out. What still does not fit is thrown as debris (dropped in calm).
    func berm(_ pile: inout Pile, from b0: Int, dir: Int, volume: Float) -> Int {
        var left = volume, b = b0, tries = 0, n = 0
        while left > 0.05, tries < 12, b >= 0, b < numCols, n < 200 {
            n += 1
            let chunk = min(left, 2), lo = max(0, b - 9), hi = min(numCols - 1, b + 9)
            var s0: Float = 0
            for i in lo...hi { s0 += pile.heights[i] }
            pile.deposit(bin: b, volume: chunk)
            var s1: Float = 0
            for i in lo...hi { s1 += pile.heights[i] }
            left -= max(s1 - s0, 0)
            if s1 - s0 < chunk * 0.5 { b += dir * 6; tries += 1 }
        }
        guard left > 0.5, !calm else { return 0 }
        let c = min(max(b0, 0), numCols - 1)
        return shedBin(col: c, edgeY: 0, from: pile.heights[c], amount: left, velocity: SIMD2(Float(dir) * Tuning.dockSpeed * 0.5, 0))
    }
}

extension SnowField {
    /// Per-column ground limit beside the bar(s): the repose ramp from `bankLevel` (see Tuning.bankLimit).
    func bankMaxes(_ docks: [CGRect]) -> [Float] {
        let bw = Tuning.binWidth
        return (0..<numCols).map { b in
            let cx = (Float(b) + 0.5) * bw
            var m = Tuning.groundMaxHeight
            for r in docks {
                let left = cx < Float(r.minX)
                m = max(m, Tuning.bankLimit(dockTop: Float(r.maxY), distance: max(Float(r.minX) - cx, cx - Float(r.maxX), 0), level: left ? bankLevel.l : bankLevel.r))
            }
            return m
        }
    }

    /// Every 0.25 s: once the snow beside a Dock end has filled the ramp at its bar end, the ramp rises 1pt (up to the full shelf). The bank then fills
    /// by the ordinary deposit / relax rules: drifts deepest against the Dock first, a ramp, then a level shelf flush with the Dock top.
    func stepBank(dt: Float) {
        bankT += dt
        guard bankT >= 0.25, let si = index[0], let gi = index[Tuning.groundID] else { return }
        bankT = 0
        let r = surfaces[si].frame, top = Float(r.maxY)
        guard top > Tuning.groundMaxHeight else { return }
        var changed = false
        for left in [true, false] {
            let gap = left ? Float(r.minX) : size.x - Float(r.maxX)
            guard gap >= 4 else { continue }
            let apex = column(left ? Float(r.minX) - 3 : Float(r.maxX) + 3)
            let p = surfaces[gi].pile
            guard p.visible[apex], p.heights[apex] >= p.limit(apex) - 0.5 else { continue }
            let level = min((left ? bankLevel.l : bankLevel.r) + 1, Tuning.bankLevelMax(dockTop: top, gap: gap))
            if left { if level != bankLevel.l { bankLevel.l = level; changed = true } } else if level != bankLevel.r { bankLevel.r = level; changed = true }
        }
        if changed { surfaces[gi].pile.maxes = bankMaxes([r]); pilesDirty = true }
    }
}
