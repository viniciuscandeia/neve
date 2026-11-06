import CoreGraphics
import Foundation

/// Snow height per bin along one surface.
public struct Pile {
    var heights: [Float]
    var shown: [Float] = []      // heights as drawn: eased up toward `heights`, snapped down (see writePiles); empty until first drawn
    var visible: [Bool]
    var base: [Float]            // baseline offset per bin (<= 0): drops along rounded corners
    var cap: [Float]             // per-bin height ceiling imposed by windows in front (inf = none)
    let inset: Float
    var maxHeight = Tuning.maxPileHeight
    var maxes: [Float] = []      // optional per-column maximum (ground snowbank beside the Dock); empty = maxHeight
    let c0: Int                  // first global column, and the REAL (unclipped) window ends in x:
    let x0: Float, x1: Float     // taper and spill-off are measured against these, not the screen-clipped pile
    var spillL: Float = 0        // snow slid off each end, turned into debris by SnowField
    var spillR: Float = 0
    var boost: [Float] = []      // extra height limit per bin: snow banked against a front window (empty = none)
    var walls: [Float] = []      // x of each wall (visible bin next to a hidden one), global
    var supportL = false         // the pile end faces a drift (SeamLink): no corner dip, taper or spill there
    var supportR = false
    var peel: [Float] = []       // per bin: seconds until its excess over `limit` lets go as debris (-1 = none); empty = nothing pending
    var peeling: Bool { !peel.isEmpty }

    init(columns: Int, inset: Float, c0: Int = 0, x0: Float = 0, x1: Float? = nil) {
        self.c0 = c0; self.x0 = x0; self.x1 = x1 ?? Float(c0 + columns) * Tuning.binWidth
        cap = [Float](repeating: .infinity, count: columns)
        heights = [Float](repeating: 0, count: columns)
        visible = [Bool](repeating: true, count: columns)
        base = [Float](repeating: 0, count: columns)
        self.inset = inset
    }

    /// Column ranges (local bins) where the pile is visible, in order.
    func visibleRuns() -> [Range<Int>] {
        var r: [Range<Int>] = [], b = 0
        while b < visible.count {
            guard visible[b] else { b += 1; continue }
            var e = b
            while e < visible.count && visible[e] { e += 1 }
            r.append(b..<e); b = e
        }
        return r
    }

    mutating func empty() { for b in heights.indices { heights[b] = 0 } }

    /// Baseline follows the corner arcs within `radius` of each end.
    mutating func round(radius: Float, c0: Int, minX: Float, maxX: Float) {
        guard radius > 0 else { return }
        for b in base.indices {
            let x = binCenter(c0 + b)
            let d = max(min(supportL ? .infinity : x - minX, supportR ? .infinity : maxX - x), 0)
            if d < radius { let k = radius - d; base[b] = -(radius - (radius * radius - k * k).squareRoot()) }
        }
    }

    /// Snow banks against the front windows hiding the neighbours of visible bins (walls): the limit rises toward the wall
    /// to reach the front top (step <= maxDrift), a capped drift (<= driftFar) or a small ramp, sloping off over >= driftMinWidth.
    mutating func addWalls(hideTop: [Float], edgeY: Float) {
        let n = heights.count, bw = Tuning.binWidth
        func wall(_ top: Float, _ wx: Float, _ self_: inout Pile) {
            let step = top - edgeY
            let peak = step <= Tuning.maxDrift ? step : step <= Tuning.driftFar ? Tuning.maxDrift : self_.maxHeight + Tuning.driftFarRamp
            let amount = peak - self_.maxHeight
            self_.walls.append(wx)
            guard amount > 0 else { return }
            let width = max(Tuning.driftMinWidth, amount / Tuning.driftSlope)
            if self_.boost.isEmpty { self_.boost = [Float](repeating: 0, count: n) }
            for k in 0..<n {
                let d = abs(binCenter(self_.c0 + k) - wx)
                if d < width { self_.boost[k] = max(self_.boost[k], amount * (1 - d / width)) }
            }
        }
        for b in 0..<n where visible[b] {
            if b > 0, !visible[b - 1] { wall(hideTop[b - 1], Float(c0 + b) * bw, &self) }
            if b + 1 < n, !visible[b + 1] { wall(hideTop[b + 1], Float(c0 + b + 1) * bw, &self) }
        }
    }

    func limit(_ bin: Int) -> Float {
        var l = (maxes.isEmpty ? maxHeight : maxes[bin]) + (boost.isEmpty ? 0 : boost[bin])
        if inset > 0 {
            let x = binCenter(c0 + bin)
            l *= min(1, max(min(supportL ? .infinity : x - x0, supportR ? .infinity : x1 - x), 0) / inset)
        }
        return min(l, cap[bin])
    }

    /// Adds snow around `bin` (spread 1/4-1/2-1/4 so no single-bin spikes), then relaxes locally.
    /// Returns whether anything changed.
    @discardableResult
    mutating func deposit(bin: Int, volume: Float) -> Bool {
        guard bin >= 0, bin < heights.count, visible[bin], cap[bin] >= Tuning.minRoom else { return false }
        var changed = false
        for o in -1...1 {
            var i = bin + o
            if i < 0 || i >= heights.count || !visible[i] { i = bin }
            guard cap[i] >= Tuning.minRoom else { continue }
            let before = heights[i]
            heights[i] = max(before, min(before + volume * (o == 0 ? 0.5 : 0.25), limit(i)))
            if heights[i] != before { changed = true }
        }
        let lo = max(0, bin - 8), hi = min(heights.count - 1, bin + 8)
        for _ in 0..<6 {
            for i in lo...hi where visible[i] {   // hidden bins are frozen: no flow out of them (nor into them, see relax)
                if relax(i, i - 1) { changed = true }
                if relax(i, i + 1) { changed = true }
            }
        }
        for i in max(lo - 1, 0)...min(hi + 1, heights.count - 1) {   // relaxation reaches one bin past the window
            let over = heights[i] - max(limit(i), 0)
            guard visible[i], over > 0, peel.isEmpty || peel[i] < 0 else { continue }
            heights[i] -= over
            if i == 0 { spillL += over } else if i == heights.count - 1 { spillR += over }
            changed = true
        }
        return changed
    }

    /// Carves a groove centred at global x `centerX`: depth * (1 - (d/halfWidth)^2) off each visible bin within halfWidth (never below 0),
    /// and `berm` (a share, 0.15) of the carved area piled onto the bins at halfWidth ... halfWidth + 2 on both sides (capped by `limit`).
    /// Returns the carved area (pt^2).
    @discardableResult
    mutating func carve(centerX: Float, halfWidth w: Float, depth: Float, berm: Float) -> Float {
        guard w > 0, depth > 0 else { return 0 }
        let bw = Tuning.binWidth
        let lo = max(0, Int(((centerX - w - 2) / bw).rounded(.down)) - c0), hi = min(heights.count - 1, Int(((centerX + w + 2) / bw).rounded(.up)) - c0)
        guard lo <= hi else { return 0 }
        var removed: Float = 0, edges = 0
        for i in lo...hi where visible[i] {
            let d = abs(binCenter(c0 + i) - centerX)
            if d < w {
                let dh = min(depth * (1 - (d / w) * (d / w)), heights[i])
                heights[i] -= dh; removed += dh * bw
            } else if d <= w + 2 + 0.01 { edges += 1 }
        }
        guard removed > 0, edges > 0 else { return removed }
        let add = berm * removed / (Float(edges) * bw)
        for i in lo...hi where visible[i] {
            let d = abs(binCenter(c0 + i) - centerX)
            if d >= w, d <= w + 2 + 0.01 { heights[i] = min(heights[i] + add, max(limit(i), heights[i])) }
        }
        return removed
    }

    /// The window continues past the screen edge on that side, so the end of the pile there is not a drop-off.
    private func continuesPastScreen(left: Bool) -> Bool {
        left ? x0 < Float(c0 - 1) * Tuning.binWidth : x1 > Float(c0 + heights.count + 1) * Tuning.binWidth
    }

    /// Moves half the excess slope (on baseline + height) from bin i to lower neighbour j.
    /// A hidden j is a wall (no flow, nothing lost); past the ends the snow spills off as debris.
    private mutating func relax(_ i: Int, _ j: Int) -> Bool {
        let inRange = j >= 0 && j < heights.count
        if !inRange && (continuesPastScreen(left: j < 0) || (j < 0 ? supportL : supportR)) { return false }
        if inRange && !visible[j] { return false }
        let ok = inRange
        let tj = ok ? base[j] + heights[j] : base[i] - 4
        let excess = base[i] + heights[i] - tj - Tuning.slope
        guard excess > 0, heights[i] > 0 else { return false }
        var m = min(excess * 0.5, heights[i])
        if ok, cap[j].isFinite { m = min(m, max(cap[j] - heights[j], 0)) }   // a roofed / under-Dock column takes no more than its room: nothing is lost there
        guard m > 0 else { return false }
        heights[i] -= m
        if ok { heights[j] += m } else if !inRange { if j < 0 { spillL += m } else { spillR += m } }
        return true
    }
}
