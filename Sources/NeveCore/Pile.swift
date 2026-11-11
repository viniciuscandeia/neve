// AGENT HEADER - Sources/NeveCore/Pile.swift  (snow height profile of ONE surface + deposit/relax/plow rules)
// Role: `Pile` (public struct, value type stored in `Surface.pile`): per-bin arrays along one window top / the Dock bar / the ground. Units: pt heights, bins of Tuning.binWidth (2 pt), LOCAL bin index b <-> global column c0 + b; x0 / x1 = the REAL
//   (unclipped) window ends in x, used for taper and spill-off. y up.
// Arrays (count = heights.count unless empty = "none"): heights (real), shown (drawn, eased toward heights by Render.writePiles; empty until first drawn), visible (false = hidden under a window in front: frozen, not lost), base (<= 0, follows rounded
//   corners), cap (ceiling imposed by windows in front, inf = none), maxes (per-column max, ground bank beside the Dock), wobble (two long waves ~500 / ~150 pt, +-9 % / +-6 %, phases from the window id), boost (extra limit banked against a front window:
//   drift), mound (extra allowance for cursor-pushed heaps; only `cap` bounds it), peel (seconds until a bin's excess over `limit` lets go as debris, -1 = none), walls (global x of each wall = visible bin next to a hidden one).
//   `limit(b) = min(rawLimit(b) + mound, cap)`; `rawLimit` = (maxes or maxHeight) * wobble + boost, tapered to 0 over `inset` from x0 / x1 unless supportL / supportR (end faces a drift / seam: no taper, dip or spill).
// Operations: deposit(bin:volume:powder:) spreads 1/2-1/4-1/4 (softness: full sticking up to 80 % of limit, tapering to 15 %; powder on bare bins lands as a one-bin speck) then relaxes +-8 bins (6 passes, slope <= Tuning.slope); relax moves half the
//   excess to a lower visible neighbour, hidden neighbours are walls, past the ends it goes to spillL / spillR (SnowField turns that into debris). deposit trims anything over `limit` (only the part trimmed at the end bins is kept as spill, elsewhere it
//   is dropped); carve / plow dig grooves with berms and return the area removed (plow returns what is NOT banked, for the caller to spray as debris); settle rounds pushed heaps; round(radius:) follows corner arcs; addWalls builds drifts;
//   visibleRuns() = visible bin ranges.
// Pile is a struct: avoid copying whole arrays in hot code (mutate surfaces[si].pile in place, see Surfaces.sweep). Callers: Surfaces.swift (build / deposit / shed), SurfaceMap.swift, Render.swift (writePiles reads it), and read or mutated directly by
//   Avalanche, Frost, Melt, Walk, Snowball, Figures*. Tests: PileLogicTests, SurfaceMapTests, PhysicsTests and others. Changing slope / limit math changes visuals everywhere and many tuned tests.

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
    var wobble: [Float] = []     // per-bin multiplier on the ceiling (long waves along the pile, see setWobble); empty = 1
    var boost: [Float] = []      // extra height limit per bin: snow banked against a front window (empty = none)
    var walls: [Float] = []      // x of each wall (visible bin next to a hidden one), global
    var supportL = false         // the pile end faces a drift (SeamLink): no corner dip, taper or spill there
    var supportR = false
    var mound: [Float] = []      // per bin: extra height allowed by snow the cursor pushed into a heap (only `cap` bounds it); empty = none
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

    mutating func empty() { for b in heights.indices { heights[b] = 0 }; mound = [] }

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

    /// Two long waves (~500 and ~150 pt, +-9% and +-6%) along the window (from its anchor bin), phases from the window number: stable across rebuilds.
    mutating func setWobble(id: Int, anchor: Int) {
        let p1 = Float(id % 997) * 2.399963, p2 = Float(id % 991) * 4.188790
        wobble = (0..<heights.count).map { b in
            let x = binCenter(c0 + b) - Float(anchor) * Tuning.binWidth   // window-local on the bin grid: the shape travels with the pile when the window is dragged
            return 1 + 0.09 * sinf(2 * .pi * x / 500 + p1) + 0.06 * sinf(2 * .pi * x / 150 + p2)
        }
    }

    /// Share of a deposit that still sticks at bin `i`: full up to 80% of the limit, then tapers to 15% as the height nears it.
    @inline(__always) private func softness(_ i: Int) -> Float {
        let l = limit(i)
        guard l > 0 else { return 0.15 }
        let t = min(max((heights[i] / l - 0.8) / 0.2, 0), 1)
        return max(0.15, 1 - t * t)
    }

    func limit(_ bin: Int) -> Float { min(rawLimit(bin) + (mound.isEmpty ? 0 : mound[bin]), cap[bin]) }

    /// The ceiling snowfall builds to (wavy, tapered, drift-raised), before any pushed heap allowance and the front-window cap.
    func rawLimit(_ bin: Int) -> Float {
        var l = (maxes.isEmpty ? maxHeight : maxes[bin]) * (wobble.isEmpty ? 1 : wobble[bin]) + (boost.isEmpty ? 0 : boost[bin])
        if inset > 0 {
            let x = binCenter(c0 + bin)
            l *= min(1, max(min(supportL ? .infinity : x - x0, supportR ? .infinity : x1 - x), 0) / inset)
        }
        return l
    }

    /// Keeps bin k's heap allowance equal to its pushed excess: it grows as a heap forms and spreads, and shrinks as the heap is pushed on.
    mutating func trackMound(_ k: Int) {
        if mound.isEmpty { mound = [Float](repeating: 0, count: heights.count) }
        mound[k] = max(0, heights[k] - rawLimit(k))
    }

    /// Adds snow around `bin` (spread 1/4-1/2-1/4 so no single-bin spikes), then relaxes locally.
    /// Returns whether anything changed.
    @discardableResult
    mutating func deposit(bin: Int, volume: Float, powder: Bool = false) -> Bool {
        guard bin >= 0, bin < heights.count, visible[bin], cap[bin] >= Tuning.minRoom else { return false }
        var changed = false
        // Fresh powder barely sticks to a clean surface and lands as a one-bin speck (no wide footprint); the grip grows as snow builds up under it.
        let h0 = heights[bin]
        if powder, h0 < Tuning.speckFloor {
            let v = volume * softness(bin) * (Tuning.speckStick + (1 - Tuning.speckStick) * h0 / Tuning.speckFloor)
            heights[bin] = max(h0, min(h0 + v, limit(bin)))
            changed = heights[bin] != h0
        } else {
            for o in -1...1 {
                var i = bin + o
                if i < 0 || i >= heights.count || !visible[i] { i = bin }
                guard cap[i] >= Tuning.minRoom else { continue }
                let before = heights[i]
                heights[i] = max(before, min(before + volume * softness(i) * (o == 0 ? 0.5 : 0.25), limit(i)))
                if heights[i] != before { changed = true }
            }
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
    /// and `berm` (a share, 0.15) of the carved area piled onto the bins at halfWidth ... halfWidth + 2 on both sides, or only on the `side` (+-1) ahead of the blade (capped by `limit`).
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

    /// Plows a shallow trench: lowers every visible bin within `w` of `centerX` to at most `ref - depth * (1 - (d/w)^2)` (idempotent, so a
    /// moving blade can call it every frame without digging deeper). `berm` of the removed area is banked on the bins at w ... w + 2 on both
    /// sides (capped by `limit`); the rest, which the caller sprays as debris, is returned (pt^2). `maxStep` caps what one call takes from a bin (the rest follows next call: no pops).
    mutating func plow(centerX: Float, halfWidth w: Float, depth: Float, ref: Float, berm: Float, side: Float = 0, maxStep: Float = .infinity) -> Float {
        guard w > 0, depth > 0 else { return 0 }
        let bw = Tuning.binWidth
        let lo = max(0, Int(((centerX - w - 2) / bw).rounded(.down)) - c0), hi = min(heights.count - 1, Int(((centerX + w + 2) / bw).rounded(.up)) - c0)
        guard lo <= hi else { return 0 }
        func onSide(_ i: Int) -> Bool { side == 0 || (binCenter(c0 + i) - centerX) * side > 0 }   // side: +-1 banks only ahead of the blade, 0 both
        var removed: Float = 0, edges = 0
        for i in lo...hi where visible[i] {
            let d = abs(binCenter(c0 + i) - centerX)
            if d < w {
                let dh = heights[i] - max(ref - depth * (1 - (d / w) * (d / w)), 0)
                if dh > 0 { let c = min(dh, maxStep); heights[i] -= c; removed += c * bw }
            } else if d <= w + 2 + 0.01, onSide(i) { edges += 1 }
        }
        guard removed > 0 else { return 0 }
        guard edges > 0 else { return removed }
        let add = berm * removed / (Float(edges) * bw)
        var banked: Float = 0
        for i in lo...hi where visible[i] {
            let d = abs(binCenter(c0 + i) - centerX)
            guard d >= w, d <= w + 2 + 0.01, onSide(i) else { continue }
            let h = min(heights[i] + add, max(limit(i), heights[i]))
            banked += (h - heights[i]) * bw; heights[i] = h
        }
        return removed - banked
    }

    /// Light relaxation of bins lo...hi (a few passes): rounds what a push left steep.
    mutating func settle(_ lo: Int, _ hi: Int) {
        guard lo <= hi else { return }
        let tall = mound.isEmpty ? 0 : (mound[lo...hi].max() ?? 0)   // a tall heap needs more passes (and room) to reach its slope: a mound, never a spike
        let a = max(0, lo - Int(tall / Tuning.slope) - 2), b = min(heights.count - 1, hi + Int(tall / Tuning.slope) + 2)
        for _ in 0..<(3 + min(Int(tall / Tuning.slope), 30)) {
            var moved = false
            for i in a...b where visible[i] { if relax(i, i - 1) { moved = true }; if relax(i, i + 1) { moved = true } }
            if !moved { break }
        }
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
        // Fresh snow on bare ground sticks where it lands (steeper step allowed onto an almost empty bin): a dusting of specks, not an instant wide film.
        let excess = base[i] + heights[i] - tj - Tuning.slope - (ok ? Tuning.dustSlope * max(0, 1 - heights[j] / Tuning.dustDepth) : 0)
        guard excess > 0, heights[i] > Tuning.speckFloor else { return false }
        var m = min(excess * 0.5, heights[i])
        if ok, cap[j].isFinite { m = min(m, max(cap[j] - heights[j], 0)) }   // a roofed / under-Dock column takes no more than its room: nothing is lost there
        guard m > 0 else { return false }
        heights[i] -= m
        if ok { heights[j] += m } else if !inRange { if j < 0 { spillL += m } else { spillR += m } }
        if !mound.isEmpty, mound[i] > 0 || (ok && mound[j] > 0) { trackMound(i); if ok { trackMound(j) } }   // heap snow keeps its allowance as it spreads
        return true
    }
}
