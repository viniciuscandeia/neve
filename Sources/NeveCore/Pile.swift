import CoreGraphics
import Foundation

/// Snow height per bin along one surface.
public struct Pile {
    var heights: [Float]
    var visible: [Bool]
    var base: [Float]            // baseline offset per bin (<= 0): drops along rounded corners
    var cap: [Float]             // per-bin height ceiling imposed by windows in front (inf = none)
    let inset: Float
    var maxHeight = Tuning.maxPileHeight
    var maxes: [Float] = []      // optional per-column maximum (ground snowbank beside the Dock); empty = maxHeight
    var splits: Set<Int> = []    // columns where drawing starts a new run (ground at the Dock bar ends, so the bank can merge with the Dock pile)
    let c0: Int                  // first global column, and the REAL (unclipped) window ends in x:
    let x0: Float, x1: Float     // taper and spill-off are measured against these, not the screen-clipped pile
    var spillL: Float = 0        // snow slid off each end, turned into debris by SnowField
    var spillR: Float = 0

    init(columns: Int, inset: Float, c0: Int = 0, x0: Float = 0, x1: Float? = nil) {
        self.c0 = c0; self.x0 = x0; self.x1 = x1 ?? Float(c0 + columns) * Tuning.binWidth
        cap = [Float](repeating: .infinity, count: columns)
        heights = [Float](repeating: 0, count: columns)
        visible = [Bool](repeating: true, count: columns)
        base = [Float](repeating: 0, count: columns)
        self.inset = inset
    }

    mutating func empty() { for b in heights.indices { heights[b] = 0 } }

    /// Baseline follows the corner arcs within `radius` of each end.
    mutating func round(radius: Float, c0: Int, minX: Float, maxX: Float) {
        guard radius > 0 else { return }
        for b in base.indices {
            let x = binCenter(c0 + b)
            let d = max(min(x - minX, maxX - x), 0)
            if d < radius { let k = radius - d; base[b] = -(radius - (radius * radius - k * k).squareRoot()) }
        }
    }

    func limit(_ bin: Int) -> Float {
        var l = maxes.isEmpty ? maxHeight : maxes[bin]
        if inset > 0 {
            let x = binCenter(c0 + bin)
            l *= min(1, max(min(x - x0, x1 - x), 0) / inset)
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
            for i in lo...hi {
                if relax(i, i - 1) { changed = true }
                if relax(i, i + 1) { changed = true }
            }
        }
        for i in max(lo - 1, 0)...min(hi + 1, heights.count - 1) {   // relaxation reaches one bin past the window
            let over = heights[i] - max(limit(i), 0)
            guard over > 0 else { continue }
            heights[i] -= over
            if i == 0 { spillL += over } else if i == heights.count - 1 { spillR += over }
            changed = true
        }
        return changed
    }

    /// The window continues past the screen edge on that side, so the end of the pile there is not a drop-off.
    private func continuesPastScreen(left: Bool) -> Bool {
        left ? x0 < Float(c0 - 1) * Tuning.binWidth : x1 > Float(c0 + heights.count + 1) * Tuning.binWidth
    }

    /// Moves half the excess slope (on baseline + height) from bin i to lower neighbour j.
    /// Hidden j drains silently; past the ends the snow spills off as debris.
    private mutating func relax(_ i: Int, _ j: Int) -> Bool {
        let inRange = j >= 0 && j < heights.count
        if !inRange && continuesPastScreen(left: j < 0) { return false }
        let ok = inRange && visible[j]
        let tj = ok ? base[j] + heights[j] : (inRange ? base[i] : base[i] - 4)
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
