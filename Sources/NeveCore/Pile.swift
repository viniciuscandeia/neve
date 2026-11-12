// AGENT HEADER - Sources/NeveCore/Pile.swift  (snow height profile of ONE surface + deposit/relax/plow rules)
// Role: `Pile` (public struct, value type stored in `Surface.pile`): per-bin arrays along one window top / the Dock bar / the ground. Units: pt heights, bins of Tuning.binWidth (2 pt), LOCAL bin index b <-> global column c0 + b; x0 / x1 = the REAL
//   (unclipped) window ends in x, used for taper and spill-off. y up.
// Arrays (count = heights.count unless empty = "none"): heights (real), shown (drawn, eased toward heights by Render.writePiles; empty until first drawn), visible (false = hidden under a window in front: frozen, not lost), base (<= 0, follows rounded
//   corners), cap (ceiling imposed by windows in front, inf = none), maxes (per-column max, ground bank beside the Dock), wobble (two long waves ~500 / ~150 pt, +-9 % / +-6 %, phases from the window id), boost (extra limit banked against a front window:
//   drift), mound (extra allowance for cursor-pushed heaps; only `cap` bounds it), peel (seconds until a bin's excess over `limit` lets go as debris, -1 = none), walls (global x of each wall = visible bin next to a hidden one), hold (order-only change: existing snow pinned over the new limit), held (hidden only by a stacking-order change: `alive`).
//   `limit(b) = max(min(rawLimit(b) + mound, cap), hold)`; `rawLimit` = (maxes or maxHeight) * wobble + boost, tapered to 0 over `inset` from x0 / x1 unless supportL / supportR (end faces a drift / seam: no taper, dip or spill).
// Age: `age` per bin (s, cap Tuning.ageFull; ageStep twice a second from SnowField.step; deposit mixes in fresh snow with weight Tuning.ageFresh, relax / Seams mix flowed snow); `reposeStep(age:heap:)` = the step the donor bin holds (slope 0.7 fresh -> Tuning.ageSlope old; the larger of that and slope + moundSlope in a heap) inside `transfer`.
// Cost notes (Nevasca sweep): `settle` scans the whole range once, then only the neighbourhood of what moved (exactly the same result as a full rescan; the scan end extends as a move feeds bins to its right in the same pass); `relax` returns early when the drop is under Tuning.slope; `stepVar` is a table.
// Heap shape: heap repose step varies per column (`stepVar`, +-Tuning.moundStepVar, stable, slow along x) and `settle` runs `roundHeap` (curvature limit Tuning.moundRound: rounded crest, soft shoulders); Render.jitter grows with height so big heaps get bigger lumps.
// Gap: `gapLo...gapHi` / `gapT` = the scooped trail of a cursor push; its walls slump to repose over Tuning.plowSlumpTime (stepSlump settles them), spilling snow back into the gap.
// Cornice: `eaveL` / `eaveR` (pt^2) = snow overhanging a bare window end (`eaveEnd`), fed / drained by SnowField.stepEaves (Effects.swift: released as a block `dropEave` at Tuning.eaveMax); drawn in Contour.swift; `empty()` clears it; kept by an unchanged-window rebuild, lost (falls) when the window moves / resizes.
// Operations: deposit(bin:volume:powder:) spreads 1/2-1/4-1/4 (softness: full sticking up to 80 % of limit, tapering to 15 %; powder on bare bins lands as a one-bin speck) then relaxes +-8 bins (6 passes: Tuning.relaxReach / relaxPasses, slope <= Tuning.slope; bins inside a pushed heap, mound > 0.5, are skipped: `settle` owns them); relax allows Tuning.moundSlope extra step when either bin is inside a pushed heap (compacted snow, ~45 degrees); relax moves half the
//   excess (the rule is `Pile.transfer`, shared with Seams.stepSeams) to a lower visible neighbour, hidden neighbours are walls, past the ends it goes to spillL / spillR (SnowField turns that into debris). deposit first clamps a stale `mound` over bin +-9 to the pushed excess actually still there (snow lost by melt / release / take / slide never regrows a heap), then trims anything over `limit` (the part trimmed at the end bins is kept as spill, in a middle bin it is owed (`owedL/R`) to the nearest unsupported end and drips off as lumps, SnowField.stepOverflow); carve / plow dig grooves with berms and return the area removed (plow returns what is NOT banked, for the caller to spray as debris); settle rounds pushed heaps (and re-syncs `mound` to the slumped snow); round(radius:) follows corner arcs; addWalls builds drifts from the GEOMETRY of the higher windows over the pile (`hideTop`, no stacking order; limit rises to the front top at the wall for step <= maxDrift, also against the wobble) (the drawn bank / fillet is Contour.swift's slope limit across owner changes, not here);
//   visibleRuns() = visible bin ranges. `open(b)` = visible AND not under another window's body (`hideTop`, geometry, any stacking order): the only bins snowfall lands on / relax flows into (so a grown field is the same in every stacking order). supportL/R are also set for the HIGHER window's end over a lower window's top edge (any step): no taper / dip / bare corner there; the group exchange across such ends lives in Seams.swift.
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
    var hideTop: [Float] = []    // per bin: absolute top y of the window that GEOMETRICALLY covers it (a window whose rect holds the bin's edge point, whatever the stacking order), 0 = none; empty = none. Order independent: walls / draw derive from it
    var walls: [Float] = []      // x of each wall (uncovered bin next to a geometrically covered one), global
    var supportL = false         // the pile end faces a drift (SeamLink): no corner dip, taper or spill there
    var supportR = false
    var gapLo = 0, gapHi = -1    // bins a cursor push scooped (walls still to slump), and gapT = seconds the walls keep slumping (Surfaces.stepSlump)
    var gapT: Float = 0
    var mound: [Float] = []      // per bin: extra height allowed by snow the cursor pushed into a heap (only `cap` bounds it); empty = none
    var hold: [Float] = []       // per bin: snow kept over the new limit after a stacking-order-only change (limit never drops below it); cleared by the next real rebuild; empty = none
    var held: [Bool] = []        // per bin: hidden only by a stacking-order change (draw-only): physics still treats it as alive (`alive`); cleared by the next real rebuild; empty = none
    var age: [Float] = []        // per bin: seconds the snow has lain (0 = fresh, capped at Tuning.ageFull): older snow holds a steeper face (`Pile.reposeStep`); mixes with what lands / flows in; travels wherever heights do
    var eaveL: Float = 0         // cornice store (pt^2) of snow overhanging each UNSUPPORTED window end (`eaveEnd`): fed by SnowField.stepEaves, capped by Tuning.eaveMax (released as a block), drawn by Contour.swift
    var eaveR: Float = 0
    var owedL: Float = 0         // volume (height units) a full pile could not hold in a MIDDLE bin (deposit trimmed it / refused it), owed to the nearest unsupported end: SnowField.stepOverflow drips it off as lumps (drops, never continuous rain); `empty()` clears it
    var owedR: Float = 0
    var peel: [Float] = []       // per bin: seconds until its excess over `limit` lets go as debris (-1 = none); empty = nothing pending
    var peeling: Bool { !peel.isEmpty }

    init(columns: Int, inset: Float, c0: Int = 0, x0: Float = 0, x1: Float? = nil) {
        self.c0 = c0; self.x0 = x0; self.x1 = x1 ?? Float(c0 + columns) * Tuning.binWidth
        cap = [Float](repeating: .infinity, count: columns)
        heights = [Float](repeating: 0, count: columns)
        visible = [Bool](repeating: true, count: columns)
        base = [Float](repeating: 0, count: columns)
        age = [Float](repeating: 0, count: columns)
        self.inset = inset
    }

    /// Whether snow / things on bin `b` still count for physics: visible, or hidden only by the stacking order.
    func alive(_ b: Int) -> Bool { visible[b] || (!held.isEmpty && held[b]) }

    /// Whether snow may land on / flow into bin `b`: visible AND not under another window's body (`hideTop`, geometry, any stacking order). Snowfall and relax use this, so a grown field never depends on z.
    @inline(__always) func open(_ b: Int) -> Bool { visible[b] && (hideTop.isEmpty || hideTop[b] <= 0) }

    /// Column ranges (local bins) where the pile is visible (`alive`: or held), in order.
    func visibleRuns(alive a: Bool = false) -> [Range<Int>] {
        var r: [Range<Int>] = [], b = 0
        while b < visible.count {
            guard visible[b] || (a && alive(b)) else { b += 1; continue }
            var e = b
            while e < visible.count && (visible[e] || (a && alive(e))) { e += 1 }
            r.append(b..<e); b = e
        }
        return r
    }

    mutating func empty() { for b in heights.indices { heights[b] = 0; age[b] = 0 }; mound = []; eaveL = 0; eaveR = 0; owedL = 0; owedR = 0 }

    /// Snow a full pile cannot keep in a middle bin `bin` is owed to the nearest end that is not a seam / drift (`supportL/R`); lost only when both ends are supported.
    static let owedCap: Float = 1500  // per end: a long idle full window cannot build a landslide debt
    mutating func owe(_ v: Float, from bin: Int) {
        let left = bin < heights.count / 2
        if left, !supportL { owedL = min(owedL + v, Self.owedCap) } else if !left, !supportR { owedR = min(owedR + v, Self.owedCap) } else if !supportL { owedL = min(owedL + v, Self.owedCap) } else if !supportR { owedR = min(owedR + v, Self.owedCap) }
    }

    /// Whether that end is a bare, on-screen, uncovered window corner: the only place a cornice forms.
    func eaveEnd(left: Bool) -> Bool { !heights.isEmpty && !(left ? supportL : supportR) && !continuesPastScreen(left: left) && open(left ? 0 : heights.count - 1) }
    /// Drawn reach past the window edge (pt) and thickness (pt) of a cornice of `e` pt^2.
    static func eaveReach(_ e: Float) -> Float { min(1.5 + 0.25 * e, 5) }
    static func eaveThickness(_ e: Float) -> Float { e / (0.75 * eaveReach(e)) }

    /// Snow lies longer: every bin holding snow ages by `dt` (up to Tuning.ageFull); bare bins stay fresh.
    mutating func ageStep(_ dt: Float) { for b in heights.indices { age[b] = heights[b] > 0 ? min(age[b] + dt, Tuning.ageFull) : 0 } }

    /// Bin `b` gains `v` of snow of age `a` (0 = fresh): its age becomes the volume-weighted mean (fresh snow counts `Tuning.ageFresh` times; flowed-in snow its own weight, `w` 1).
    @inline(__always) mutating func mixAge(_ b: Int, added v: Float, age a: Float, weight w: Float = 1) {
        guard v > 0 else { return }
        let h = heights[b] - v, wv = v * w
        age[b] = h <= 0 ? a : (age[b] * h + a * wv) / (h + wv)
    }

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
        self.hideTop = hideTop.contains { $0 > 0 } ? hideTop : []
        func wall(_ k0: Int, _ wx: Float, _ self_: inout Pile) {
            let top = hideTop[k0], step = top - edgeY
            let peak = step <= Tuning.maxDrift ? max(step, 0) : step <= Tuning.driftFar ? Tuning.maxDrift : self_.maxHeight + Tuning.driftFarRamp
            self_.walls.append(wx)
            // The ceiling (wavy: down to ~85 % of maxHeight) must reach the peak AT the wall, so the bank limit is what is missing there.
            let wk = min(max(Int((wx / bw).rounded()) - self_.c0, 0), n - 1)
            let amount = peak - self_.maxHeight * (self_.wobble.isEmpty ? 1 : self_.wobble[wk])
            guard amount > 0 else { return }
            let width = max(Tuning.driftMinWidth, amount / Tuning.driftSlope)
            if self_.boost.isEmpty { self_.boost = [Float](repeating: 0, count: n) }
            for k in 0..<n {
                let d = abs(binCenter(self_.c0 + k) - wx)
                if d < width { self_.boost[k] = max(self_.boost[k], amount * (1 - d / width)) }
            }
        }
        for b in 0..<n where hideTop[b] <= 0 {   // geometry only (a higher window's rect over the bin's edge point), never the stacking order
            if b > 0, hideTop[b - 1] > 0 { wall(b - 1, Float(c0 + b) * bw, &self) }
            if b + 1 < n, hideTop[b + 1] > 0 { wall(b + 1, Float(c0 + b + 1) * bw, &self) }
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

    func limit(_ bin: Int) -> Float { let l = min(rawLimit(bin) + (mound.isEmpty ? 0 : mound[bin]), cap[bin]); return hold.isEmpty ? l : max(l, hold[bin]) }

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
        guard bin >= 0, bin < heights.count, open(bin), cap[bin] >= Tuning.minRoom else {
            if !powder, volume > 0, bin >= 0, bin < heights.count, open(bin) { owe(volume, from: bin) }   // a chunk landing under a ceiling is not thrown away
            return false
        }
        var changed = false
        // Fresh powder barely sticks to a clean surface and lands as a one-bin speck (no wide footprint); the grip grows as snow builds up under it.
        if !mound.isEmpty {   // self-correcting allowance: snow that left by any path (melt, release, take, slide) must not let snowfall regrow the old heap
            for i in max(0, bin - Tuning.moundReach)...min(heights.count - 1, bin + Tuning.moundReach) { mound[i] = min(mound[i], max(0, heights[i] - rawLimit(i))) }
        }
        let h0 = heights[bin]
        if powder, h0 < Tuning.speckFloor {
            let v = volume * softness(bin) * (Tuning.speckStick + (1 - Tuning.speckStick) * h0 / Tuning.speckFloor)
            heights[bin] = max(h0, min(h0 + v, limit(bin)))
            mixAge(bin, added: heights[bin] - h0, age: 0, weight: Tuning.ageFresh)
            changed = heights[bin] != h0
        } else {
            // Overflow owed to the nearest end: a chunk (powder false) owes everything the pile does not keep; a powder flake owes only what the ceiling cut (softness bounce is the old, silent loss), so a window that is merely
            // 80-90 % full does not trickle.
            var lost: Float = 0
            for o in -1...1 {
                var i = bin + o
                if i < 0 || i >= heights.count || !open(i) { i = bin }
                let w: Float = o == 0 ? 0.5 : 0.25
                guard cap[i] >= Tuning.minRoom else { if !powder { lost += volume * w }; continue }
                let before = heights[i], want = before + volume * softness(i) * w, lim = limit(i)
                heights[i] = max(before, min(want, lim))
                lost += powder ? max(0, want - max(before, lim)) : volume * w - (heights[i] - before)
                if heights[i] != before { changed = true; mixAge(i, added: heights[i] - before, age: 0, weight: Tuning.ageFresh) }
            }
            if lost > 1e-4 { owe(lost, from: bin) }
        }
        let lo = max(0, bin - Tuning.relaxReach), hi = min(heights.count - 1, bin + Tuning.relaxReach)
        for _ in 0..<Tuning.relaxPasses {
            var moved = false
            for i in lo...hi where open(i) && (mound.isEmpty || mound[i] <= 0.5) {   // hidden bins are frozen: no flow out of them (nor into them, see relax); a pushed heap is left to `settle` (a local relax of its steep flank would cut a cliff at the edge of the window)
                if relax(i, i - 1) { moved = true }
                if relax(i, i + 1) { moved = true }
            }
            guard moved else { break }   // a pass that moves nothing leaves the state as it was: every later pass would do the same
            changed = true
        }
        for i in max(lo - 1, 0)...min(hi + 1, heights.count - 1) {   // relaxation reaches one bin past the window
            let over = heights[i] - max(limit(i), 0)
            guard open(i), over > 0, peel.isEmpty || peel[i] < 0 else { continue }
            heights[i] -= over
            if i == 0 { spillL += over } else if i == heights.count - 1 { spillR += over } else { owe(over, from: i) }
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
        var lo = a, hi = b   // after the first pass only the neighbourhood of what moved can move again (a bin that did not move sees the same inputs: relax is then a no-op), so later passes rescan just that (same result as a full rescan, much cheaper for a long gap trail)
        for _ in 0..<(3 + min(Int(tall / Tuning.slope), 30)) {
            var first = Int.max, last = -1
            var i = lo, end = hi
            while i <= end {   // a move at i feeds bins to its right within this same pass (the scan is ascending): extend the end as the wave travels
                if visible[i] {
                    let m0 = relax(i, i - 1), m1 = relax(i, i + 1)
                    if m0 || m1 { first = min(first, i); last = i; end = max(end, min(b, i + 2)) }
                }
                i += 1
            }
            if last < 0 { break }
            lo = max(a, first - 2); hi = min(b, last + 2)
        }
        if !mound.isEmpty { roundHeap(a, b); for i in a...b { trackMound(i) } }   // the heap's allowance follows the slumped snow, or the next snowfall would trim the moved snow back to the old allowance
    }

    /// Stable per-column factor on a heap's repose step (1 +- Tuning.moundStepVar, smooth over ~10 columns): the face is not one straight line, its steepness drifts slowly along x and travels with the column.
    static func stepVar(_ col: Int) -> Float { col >= 0 && col < stepVarTable.count ? stepVarTable[col] : stepVarCompute(col) }
    private static let stepVarTable: [Float] = (0..<8192).map(stepVarCompute)   // two hash noises + a smoothstep per relax was the hot spot of stepSlump (Nevasca sweep)
    private static func stepVarCompute(_ col: Int) -> Float {
        let r = ((col % 10) + 10) % 10, g = col - r, u = Float(r) / 10, w = u * u * (3 - 2 * u)
        return 1 + Tuning.moundStepVar * (Float(noise(g)) * (1 - w) + Float(noise(g + 10)) * w)
    }

    /// One mass-conserving curvature pass over a pushed heap: a bin whose second difference (on baseline + height) exceeds `Tuning.moundRound` hands the excess to / takes it from its neighbours (rate 0.2),
    /// so a knife apex rounds off and the foot / shoulder kinks soften while the straight face between stays. Only bins in or next to a heap (mound > 0.5), only open neighbours.
    mutating func roundHeap(_ a: Int, _ b: Int) {
        guard b - a >= 2 else { return }
        for i in (a + 1)..<b where open(i) && open(i - 1) && open(i + 1) && (mound[i] > 0.5 || mound[i - 1] > 0.5 || mound[i + 1] > 0.5) {
            let d2 = (base[i - 1] + heights[i - 1]) + (base[i + 1] + heights[i + 1]) - 2 * (base[i] + heights[i])
            let m = 0.2 * (abs(d2) - Tuning.moundRound)
            guard m > 0 else { continue }
            if d2 < 0 {   // peak: shed half each side (never past a neighbour's cap)
                let t = min(m, heights[i], 2 * min(cap[i - 1] - heights[i - 1], cap[i + 1] - heights[i + 1]))
                guard t > 0 else { continue }
                heights[i] -= t; heights[i - 1] += t / 2; heights[i + 1] += t / 2
                mixAge(i - 1, added: t / 2, age: age[i]); mixAge(i + 1, added: t / 2, age: age[i])
            } else {   // dip: fill from both sides
                let t = min(m, 2 * min(heights[i - 1], heights[i + 1]), 2 * (cap[i] - heights[i]))
                guard t > 0 else { continue }
                heights[i] += t; heights[i - 1] -= t / 2; heights[i + 1] -= t / 2
                mixAge(i, added: t, age: age[i - 1])
            }
        }
    }

    /// The window continues past the screen edge on that side, so the end of the pile there is not a drop-off.
    func continuesPastScreen(left: Bool) -> Bool {
        left ? x0 < Float(c0 - 1) * Tuning.binWidth : x1 > Float(c0 + heights.count + 1) * Tuning.binWidth
    }

    /// The step (pt per bin) snow of `age` s holds: Tuning.slope fresh, rising to Tuning.ageSlope as it compacts; inside a pushed heap the larger of that and slope + moundSlope wins.
    static func reposeStep(age: Float, heap: Bool = false) -> Float {
        let aged = Tuning.slope + (Tuning.ageSlope - Tuning.slope) * min(max(age / Tuning.ageFull, 0), 1)
        return heap ? max(aged, Tuning.slope + Tuning.moundSlope) : aged
    }

    /// THE transfer rule between two neighbouring bins (Pile.relax within a pile, Seams.stepSeams across a joint): the snow that moves from a bin of height `hf` whose absolute top is `drop` above the receiver's.
    /// Half the excess over `reposeStep(age:heap:)` (Tuning.slope fresh, up to ageSlope for the donor's `age`; the larger of that and slope + moundSlope inside a pushed heap `heap`), + `dustSlope` fading out as the receiver, of height `ht`, fills to `dustDepth`: fresh snow stays in small mounds; ht nil = past the end, no dust term),
    /// nothing from a bin at or under `speckFloor`, at most `hf`, and at most the room under the receiver's `toCap` (a roofed / under-Dock column takes no more than its room: nothing is lost there). 0 = no transfer.
    static func transfer(drop: Float, from hf: Float, to ht: Float?, toCap: Float = .infinity, heap: Bool = false, age: Float = 0, stepScale: Float = 1) -> Float {
        let excess = drop - reposeStep(age: age, heap: heap) * (heap ? stepScale : 1) - (ht.map { Tuning.dustSlope * max(0, 1 - $0 / Tuning.dustDepth) } ?? 0)
        guard excess > 0, hf > Tuning.speckFloor else { return 0 }
        var m = min(excess * 0.5, hf)
        if let ht, toCap.isFinite { m = min(m, max(toCap - ht, 0)) }
        return max(m, 0)
    }

    /// Moves half the excess slope (on baseline + height) from bin i to lower neighbour j.
    /// A hidden j is a wall (no flow, nothing lost); past the ends the snow spills off as debris.
    mutating func relax(_ i: Int, _ j: Int) -> Bool {
        let inRange = j >= 0 && j < heights.count
        if !inRange && (continuesPastScreen(left: j < 0) || (j < 0 ? supportL : supportR)) { return false }
        if inRange && !open(j) { return false }
        let ok = inRange
        let tj = ok ? base[j] + heights[j] : base[i] - 4
        // Fresh snow on bare ground sticks where it lands (steeper step allowed onto an almost empty bin): a dusting of specks, not an instant wide film.
        let drop = base[i] + heights[i] - tj
        if drop <= Tuning.slope { return false }   // no repose step (fresh slope is the smallest; heap steps are larger) is under this: `transfer` would return 0 (the common case on a flat stretch)
        let m = Self.transfer(drop: drop, from: heights[i], to: ok ? heights[j] : nil, toCap: ok ? cap[j] : .infinity, heap: !mound.isEmpty && (mound[i] > 0.5 || (ok && mound[j] > 0.5)), age: age[i], stepScale: Self.stepVar(c0 + i))
        guard m > 0 else { return false }
        heights[i] -= m
        if ok { heights[j] += m; mixAge(j, added: m, age: age[i]) } else if !inRange { if j < 0 { spillL += m } else { spillR += m } }
        if !mound.isEmpty, mound[i] > 0 || (ok && mound[j] > 0) { trackMound(i); if ok { trackMound(j) } }   // heap snow keeps its allowance as it spreads
        return true
    }
}
