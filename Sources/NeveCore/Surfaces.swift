// AGENT HEADER - Sources/NeveCore/Surfaces.swift  (window list -> surfaces + piles; deposit, shed, cursor sweep)
// Origin z: the spawn sites here (stepOverflow lumps, `spill`, the Dock-over burst chunks, Dock sheds with `oz: .max`) stamp Flake.oz so debris leaving a front window crosses the windows behind it (Debris.swift); shed runs infer it in `shedBin`.
// Role: (also fills `occluders` / `zOf` / `groundZ` for the pile clip) turns the app's front-to-back [WindowInfo] snapshot into `surfaces` and keeps their piles alive across snapshots. `update(windows:dt:now:)` is THE entry point (poll rate, called by Overlay.update): ignores identical snapshots (only
//   decays velocity), else `updateSurfaces` -> per-window `buildSurface` (columns c0..c1 clipped to the screen, visibility / ceiling / cap vs windows in FRONT (true occlusion), drift walls from the GEOMETRY of the higher windows over the pile (`Pile.hideTop`, any stacking), `cap` = lowest underside of ANY window whose body lies above the bin (geometry, not z; only windows in front HIDE bins), wobble, corner rounding) and `buildGround` (full-width ground pile, banked against the side of a window standing on it via `Pile.addWalls` (`groundWinTop`), wavy downward only (0.85...1 x groundMaxHeight) except beside walls and within the Dock bank's widest reach,
//   bank beside the Dock). Surface ids: window number (> 0), 0 = Dock bar, Tuning.groundID (-1) = ground. Occluder-only windows hide piles but get no surface. It then rebuilds the column index and runs transportBalls / Gifts / Tree / Figures.
// Pile carry-over: a surface with the same id keeps its heights shifted by whole columns (`anchor` difference, so rounding never accumulates); a moved window sheds snow by speed (`shedFraction` / `shed` -> debris, velocity low-passed with
//   Tuning.velSmoothing); a resized one remaps; snow past the screen edge is parked in `overhang`; windows that vanish without closing (Space switch, resolution) are stashed by id (`stashAway` / `restoreStashed`: piles, frost, balls, figures,
//   gifts, the Christmas tree (Stashed.tree; knockOff of a window that never returns drops it); cap 64, 30 min); a window that is gone for good goes through `knockOff` (pile falls as intact slabs via dropBlocks). `movedOnly` limits a drag sample to the moved window and windows within +-8 pt in x unless `dragOnlyRebuild` is false (tests).
// Stacking order only (`orderOnly`, same windows and frames, e.g. Cmd-Tab): the unmoved-window path rebuilds visibility / cap / walls / seams for drawing but trims, peels and sheds nothing (Pile.hold pins snow over the new limit; bins newly covered only by the order are `Pile.held`: draw-hidden but still `alive` for balls, gifts, figures, walkers, frost). A window missing from the poll (close, minimise, hide, zoom up to the menu bar) stays in `surfaces` as a GHOST (`pendingGone`: pile, balls, gifts, figures, tree in place and drawn; it returns clean-or-not by simply reappearing) and is knocked off only after `goneGrace` (0.6 s; an expired ghost forces a rebuild even on an unchanged list; the app guarantees a read after the deadline via PollScheduler.settleRead; tests via makeField set 0). knockOff then lets transportBalls/Gifts/Tree/Figures release what stood on it. Tests: StackOrderTests, WindowGoneTests.
// Other API here: deposit(surface:bin:volume:powder:) (no-op when `landable` is false: window surfaces after a Space switch), spill (end overflow -> one debris lump carrying vol = the spilled volume; what addDebris refuses stays owed), `stepOverflow` (every 3rd 0.5 s tick: snow a full window pile could not keep in a middle bin, `Pile.owedL/R`, drips off the nearest end as one lump per end; the Dock bar / ground refuse it into `bankRefused`), stepPeel (drift excess lets go; in SnowField.step), `releasePiles` (outro),
//   `sweep(from:to:radius:dt:)` = cursor plow (first acts on figures, balls, gifts and icicles regardless of prefs; then, only with pointerPush and not calm / silent, lifts snow within radius of the segment into a berm ahead / to both sides (blade radius Tuning.plowRadius 14 pt: below plowSlowSpeed 40 pt/s a hover dents plowHoverDepth 0.6 pt, else a push scoops ALL snow under the blade down to Tuning.plowFloor with soft edges)
//   (cursor `berm`, not DockPush.berm; on the GROUND the Dock bar is an obstacle: `dockSpan`, the blade skips snow under the bar, the berm walk stops at the bar's side, banks a repose wedge (`bankWedge`, shared with the higher-window side) up to the Dock top and heaps the excess onto the Dock pile's near end via a recursive berm; a run ending at a seam, or at a higher window's side mid-pile (banks a wedge up its side to its top, the rest goes on its pile), continues onto the touching neighbour surface via `neighbor`, Seams.swift); Push feel: scooped bins keep a `gapT` (Tuning.plowSlumpTime): `stepSlump` settles the gap's walls to repose even while the blade moves (snow spills back in); a push faster than 300 pt/s holds back up to 15 % of the scooped snow as powder (debris from the blade front, + puffs; none in economy / Low Power; calm never sweeps); against the Dock bar a push >= Tuning.dockOverSpeed with the heap at the bar's top throws a speed-scaled share as arcing chunks that land on the Dock pile (slower: only heaps up to 40 pt over the bar); `stepSlump` (in SnowField.step) settles pushed heaps (compacted, Tuning.slope + moundSlope ~45 degrees; fixed 1/60 s substeps, at most 2 a frame) 0.25 s after the last sweep (`sweptAt`); only the overflow flies as debris via launchSweepDebris; ignores the dragged window's pile), roundedUnderside (corner-following ceiling).
// Time: per-window dt = own time since last sample via `stamps` and the monotonic `clock` (NOT sim time): a drag sampled at 25 Hz sheds the same as at 10 Hz.
// Gotchas: window frames are LOCAL AppKit y-up pt; hot path during drags (surfaces rebuilt at poll rate, up to ~25-30/s): avoid whole-array copies of piles (`let s = surfaces[si]` copies heights on write: use index access);
//   scene mode (NEVE_DEMO_VANISH) filters a window out here. Tests: SurfaceMapTests, DragOnlyRebuildTests, SpaceCarryTests, DockGapTests, SweepTests.

import CoreGraphics
import Foundation

extension SnowField {
    /// One flake lands on a surface (also the test entry point for building piles without simulating snowfall).
    /// Whether snow may land on / hit surface `s`: after a Space switch (`windowsStale`) window surfaces are not trusted until the next snapshot. The ground and the Dock stay.
    func landable(_ s: Int) -> Bool { !(windowsStale && time < staleUntil && surfaces[s].id > 0) }

    func deposit(surface: Int, bin: Int, volume: Float, powder: Bool = false) {
        guard landable(surface) else { return }
        if surfaces[surface].pile.deposit(bin: bin, volume: volume, powder: powder) { pilesDirty = true }
        if surfaces[surface].pile.spillL > 2 || surfaces[surface].pile.spillR > 2 { spill(surface) }
        if surfaces[surface].id <= 0 { bankRefused += (surfaces[surface].pile.owedL + surfaces[surface].pile.owedR) * Tuning.binWidth; surfaces[surface].pile.owedL = 0; surfaces[surface].pile.owedR = 0 }   // only window tops pass overflow on to their ends; the Dock bar / ground heap ceiling has nowhere to send it (counted in bankRefused)
    }

    /// Every 3rd 0.5 s tick (SnowField.step): what full window piles could not keep in a middle bin (`Pile.owedL/R`) drips off the nearest end as ONE lump per end once >= overflowMin
    /// (the debt, 40...80 height units, at most every 1.5 s per end, so a burst's debt drains over ~half a minute): drops, not continuous rain. The lump carries its volume and lands again (hash noise: draws no random number, so neither `rng` nor `fxRng` shifts).
    static let overflowMin: Float = 40
    func stepOverflow() {
        guard !quiet, !calm else { return }
        overflowTick += 1
        guard overflowTick >= 3 else { return }
        overflowTick = 0
        for si in surfaces.indices where surfaces[si].id > 0 && surfaces[si].id != draggingID && landable(si) {
            let p = surfaces[si].pile, last = p.heights.count - 1
            guard last > 0, p.owedL >= Self.overflowMin || p.owedR >= Self.overflowMin else { continue }
            for left in [true, false] {
                let owed = left ? p.owedL : p.owedR
                guard owed >= Self.overflowMin else { continue }
                let take = min(owed, 80), sign: Float = left ? -1 : 1, seed = si &* 7919 &+ Int(time * 997) &+ (left ? 1 : 2)
                func u(_ k: Int) -> Float { Float(noise(seed &* 31 &+ k) + 1) * 0.5 }
                guard withSpawnZ(originZ(si: si), { put(Flake(pos: [Float(left ? surfaces[si].c0 : surfaces[si].c0 + last + 1) * Tuning.binWidth, surfaces[si].edgeY + p.base[left ? 0 : last]],
                                vx: sign * (8 + 17 * u(1)), fall: 10 + 20 * u(2), phase: 0, amp: 0, freq: 0, size: 3 + 2 * u(3),
                                alpha: 0.95, kind: .debris, seed: u(4), fade: 1, vol: take * Tuning.binWidth)) }) else { continue }
                if left { surfaces[si].pile.owedL -= take } else { surfaces[si].pile.owedR -= take }
            }
        }
    }

    /// Snow that slid off a surface end falls as debris.
    func spill(_ si: Int) {
        let c0 = surfaces[si].c0, edgeY = surfaces[si].edgeY, last = surfaces[si].pile.heights.count - 1
        for left in [true, false] {
            let amount = left ? surfaces[si].pile.spillL : surfaces[si].pile.spillR
            guard amount > 2 else { continue }
            let sign: Float = left ? -1 : 1
            // The lump carries the spilled volume (heights are pt, `vol` is pt^2) and lands again; when the debris cap refuses it the snow stays owed.
            guard addDebris(x: Float(left ? c0 : c0 + last + 1) * Tuning.binWidth, y: edgeY + surfaces[si].pile.base[left ? 0 : last],
                            vx: sign * Float.random(in: 8...25, using: &rng), fall: Float.random(in: 10...30, using: &rng), vol: amount * Tuning.binWidth, oz: originZ(si: si)) else { continue }
            if left { surfaces[si].pile.spillL = 0 } else { surfaces[si].pile.spillR = 0 }
        }
    }

    /// Rebuilds surfaces from the front-to-back window list. Returns debris spawned by knocked-off piles.
    @discardableResult
    public func update(windows: [WindowInfo], dt: Float = Tuning.shedRefDt, now: Double? = nil) -> Int {
        // Each window's dt is its own time since its last sample (`stamps`, monotonic `now`; without it a clock advanced by `dt`).
        if let now { clock = now } else { clock += Double(dt) }
        pollDt = dt
        if pendingGone.values.contains(where: { clock - $0.since >= goneGrace }) { boundsDirty = true }   // a ghost's deadline passed: the rebuild below knocks it off even when the list is unchanged
        defer { stamps.removeAll(keepingCapacity: true); for w in windows { stamps[w.number] = clock } }
        guard windows != lastWindows || boundsDirty else {
            if windowsStale, time >= staleUntil { windowsStale = false }   // an unchanged list right after a switch may be the pre-switch one: only a changed one settles it, or time
            for i in surfaces.indices {   // an identical snapshot decays velocity with elapsed time instead of zeroing it
                let v = surfaces[i].vel * exp(-windowDt(surfaces[i].id) / Tuning.velSmoothing)
                surfaces[i].vel = v.x * v.x + v.y * v.y < 0.25 ? .zero : v
            }
            return 0
        }
        boundsDirty = false
        let prev = lastWindows
        lastWindows = windows
        defer { windowsStale = false }
        orderOnly = !windowsStale && Self.sameWindowsReordered(windows, prev)
        defer { orderOnly = false }
        return updateSurfaces(windows: effective(windows), only: dragOnlyRebuild ? movedOnly(windows, prev: prev) : nil, settle: true)
    }

    /// Same windows (ids, frames +-0.5 pt, radius, kind) in a different stacking order (Cmd-Tab): only the drawing may change, never the snow.
    static func sameWindowsReordered(_ a: [WindowInfo], _ b: [WindowInfo]) -> Bool {
        guard a.count == b.count, a.map(\.number) != b.map(\.number) else { return false }
        let a = a.sorted { $0.number < $1.number }, b = b.sorted { $0.number < $1.number }
        return zip(a, b).allSatisfy { x, y in
            x.number == y.number && x.radius == y.radius && x.occluderOnly == y.occluderOnly
                && abs(x.frame.minX - y.frame.minX) < 0.5 && abs(x.frame.minY - y.frame.minY) < 0.5 && abs(x.frame.width - y.frame.width) < 0.5 && abs(x.frame.height - y.frame.height) < 0.5
        }
    }

    /// When the only change between two snapshots is one window's frame (a drag sample): the surfaces that can depend on it, the window and every
    /// window whose x-range (+-8pt, the seam reach) meets its old or new one (front windows hide / roof, seams link; the ceiling check looks at any height).
    /// nil = rebuild everything (list changed, Dock moved, Space switch).
    func movedOnly(_ w: [WindowInfo], prev p: [WindowInfo]) -> Set<Int>? {
        guard !windowsStale, w.count == p.count else { return nil }
        var k = -1
        for i in w.indices where w[i] != p[i] {
            guard k < 0, w[i].number == p[i].number, w[i].number != 0 else { return nil }
            k = i
        }
        guard k >= 0 else { return nil }
        let lo = min(w[k].frame.minX, p[k].frame.minX) - 8, hi = max(w[k].frame.maxX, p[k].frame.maxX) + 8
        return Set(w.filter { $0.frame.maxX > lo && $0.frame.minX < hi }.map(\.number)).union([w[k].number, Tuning.groundID])
    }

    func windowDt(_ id: Int) -> Float { stamps[id].map { Float(min(max(clock - $0, 1.0 / 240), 0.5)) } ?? pollDt }

    /// 0...1 share of a pile that falls off when its window moves with velocity `v` (previous poll's velocity `prev`).
    static func shedFraction(v: SIMD2<Float>, prev: SIMD2<Float>) -> Float {
        var s = (v.x * v.x + (v.y > 0 ? Tuning.shedUp : Tuning.shedDown) * (v.y > 0 ? Tuning.shedUp : Tuning.shedDown) * v.y * v.y).squareRoot()
        if v.x * prev.x + v.y * prev.y < 0 {   // sharp shake: reversal at speed
            let d = v - prev
            s = max(s, Tuning.shakeGain * (d.x * d.x + d.y * d.y).squareRoot())
        }
        let t = min(max((s - Tuning.shedStart) / (Tuning.shedFull - Tuning.shedStart), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Share removed per update, scaled so shedding depends on elapsed time, not update rate (reference: the old 10 Hz drag poll).
    static func perUpdate(_ f: Float, dt: Float) -> Float { dt >= Tuning.shedRefDt ? f : 1 - pow(1 - f, dt / Tuning.shedRefDt) }

    @discardableResult
    func updateSurfaces(windows: [WindowInfo], only: Set<Int>? = nil, settle: Bool = false) -> Int {   // `only`: rebuild just these surface ids (the rest are reused as they are)
        let windows = scene?.vanished.map { id in windows.filter { $0.number != id } } ?? windows   // NEVE_DEMO_VANISH: that scene window is treated as minimised
        let ox = origin.x, oy = origin.y
        var rects: [CGRect] = []
        rects.reserveCapacity(windows.count)
        for w in windows { rects.append(w.frame.offsetBy(dx: -ox, dy: -oy)) }

        sset.beginRebuild(rects: rects, windows: windows, maxOccluders: Self.maxOccluders)
        let before = surfaces
        dockPrev = before.first { $0.id == 0 }?.frame
        var old = before
        var built: [Surface] = []
        var spawned = 0
        // Reused surfaces keep their piles, but `cover` (what the Dock hides of a window's foot) follows the Dock: refresh it where the Dock was, is or is going.
        var reach = rects.indices.first { windows[$0].number == 0 }.map { rects[$0] }
        if only != nil { for r in [dockPrev, dockTarget?.offsetBy(dx: -ox, dy: -oy)] { if let r { reach = reach.map { $0.union(r) } ?? r } } }
        let radii = windows.map(\.radius)   // once per rebuild, not per window
        for (i, r) in rects.enumerated() {
            let id = windows[i].number, edge = Float(r.maxY)
            if windows[i].occluderOnly { continue }   // hides piles and ground (it stays in `rects`) but carries no snow
            // Dock bar (id 0) sits below the visible frame's bottom; hidden/offscreen Dock has minY < 0.
            let lowOk = id == 0 ? r.minY >= -1 : edge > groundY
            guard lowOk, visibleTop - edge >= Tuning.minHeadroom, r.maxX > 0, r.minX < CGFloat(size.x) else { continue }
            if let only, !only.contains(id), let k = old.firstIndex(where: { $0.id == id }) {
                var s = old.swapRemove(k)
                if settle {   // what a full rebuild does to an unmoved window: its velocity keeps decaying
                    let v = s.vel * exp(-windowDt(id) / Tuning.velSmoothing)
                    s.vel = v.x * v.x + v.y * v.y < 0.25 ? .zero : v
                }
                if let reach, r.intersects(reach) { s.cover = rects[0..<i].filter { $0.intersects(s.frame) } }
                built.append(s); continue
            }
            if let s = buildSurface(id: id, frame: r, edgeY: edge, radius: windows[i].radius, rects: rects, radii: radii, windows: windows, front: i, old: &old, spawned: &spawned) { built.append(s) }
            spawned += flushRuns()   // runs never span two surfaces
        }
        if let g = buildGround(rects: rects, windows: windows, old: &old, spawned: &spawned) { built.append(g) }   // behind everything: every window and the Dock hide it
        spawned += flushRuns()
        if clock >= spaceSwitchUntil { spaceSwitchIDs = [] }
        let gone = old.filter { $0.id > 0 && spaceSwitchIDs.contains($0.id) }
        if !gone.isEmpty {   // Space switch: windows that went away are not closed, they are elsewhere: snow (and frost) set aside, balls and figures on them go, no debris
            let ids = Set(gone.map(\.id))
            stashAway(gone)
            spaceSwitchIDs.subtract(gone.map(\.id))
            old.removeAll { ids.contains($0.id) }
        }
        var ghosts: Set<Int> = []
        for s in old {   // gone surfaces: a window absent for one poll (Mission Control, Stage Manager, minimise animation, a close, a zoom up to the menu bar) stays as a GHOST (pile, figures, balls, gifts, tree in place and drawn) for Tuning.goneGrace, then falls
            if s.id > 0, !silent, goneGrace > 0, pendingGone[s.id].map({ clock - $0.since < goneGrace }) ?? true {
                if pendingGone[s.id] == nil { pendingGone[s.id] = (s, clock) }
                built.append(s); ghosts.insert(s.id)
            } else { pendingGone[s.id] = nil; spawned += knockOff(s) }
        }
        pendingGone = pendingGone.filter { k, _ in ghosts.contains(k) || !built.contains { $0.id == k } }   // rebuilt from a real window again: not missing any more
        overhang = overhang.filter { k, _ in built.contains { $0.id == k } }
        for i in built.indices where only?.contains(built[i].id) ?? true { built[i].runs = built[i].pile.visibleRuns(); built[i].aliveRuns = built[i].pile.held.isEmpty ? built[i].runs : built[i].pile.visibleRuns(alive: true) }
        sset.install(built)
        transportBalls(before: before)
        transportGifts(before: before)
        transportTree(before: before)
        transportFigures(before: before)
        restoreStashed()
        pilesDirty = true
        return spawned
    }

    /// Windows that went away without closing (another Space, a resolution change): their snow (and frost) is set aside by id, balls / figures / gifts on them go with it (kept in the stash), no debris.
    func stashAway(_ gone: [Surface]) {
        let ids = Set(gone.map(\.id))
        let onIt = { (sid: Int?) in sid.map { ids.contains($0) } ?? false }
        let keptFigures = dropWindowFigures(on: ids)
        let keptBalls = balls.filter { $0.state != .held && onIt($0.surfaceID) }   // resting stacks go with the window (a falling ball has no surface)
        balls.removeAll { $0.state != .held && onIt($0.surfaceID) }
        let keptGifts = giftState.gifts.filter { onIt($0.surface) }
        giftState.gifts.removeAll { onIt($0.surface) }
        let keptTree = tree.flatMap { onIt($0.surface) && $0.state == .resting ? $0 : nil }
        if keptTree != nil { tree = nil }
        for s in gone {
            let fs = keptFigures.filter { $0.surfaceID == s.id }, bs = keptBalls.filter { $0.surfaceID == s.id }, gs = keptGifts.filter { $0.surface == s.id }, tr = keptTree?.surface == s.id ? keptTree : nil
            guard s.pile.heights.contains(where: { $0 > 0 }) || !fs.isEmpty || !bs.isEmpty || !gs.isEmpty || tr != nil else { continue }
            stash[s.id] = Stashed(heights: s.pile.heights, stamp: clock, age: s.pile.age, mound: s.pile.mound, ice: iceWin.first { $0.id == s.id },
                                  overhang: Dictionary(uniqueKeysWithValues: (overhang[s.id] ?? [:]).map { ($0.key - s.c0, $0.value) }),
                                  topY: Float(s.frame.maxY), minX: Float(s.frame.minX), balls: bs, figures: fs, gifts: gs, tree: tr)
        }
        while stash.count > 64, let k = stash.min(by: { $0.value.stamp < $1.value.stamp })?.key { stash[k] = nil }
    }

    /// What stood on a window that came back from another Space returns with it (shifted by the window's move), without the transports above knocking it off.
    private func restoreStashed() {
        for (dx, dy, xr, e) in stashBack {   // shifted by the window's move (x and y), clamped onto its (maybe narrower) new span; caps respected
            let cx = { (x: Float) in min(max(x + dx, xr.lowerBound), xr.upperBound) }
            for var b in e.balls where balls.lazy.filter({ !$0.melting }).count < Tuning.maxBalls { b.pos = SIMD2(cx(b.pos.x), b.pos.y + dy); balls.append(b) }
            for var f in e.figures where canSpawnFigure { f.foot.x = cx(f.foot.x); f.foot.y += dy; f.critter.fetchX = nil; f.at = f.surfaceID.map { .surface(id: $0, x: f.foot.x) } ?? .air; figures.append(f) }
            for var g in e.gifts where giftState.gifts.count < Tuning.maxGifts { g.pos = SIMD2(cx(g.pos.x), g.pos.y + dy); giftState.gifts.append(g) }
            if var t = e.tree, tree == nil { t.pos = SIMD2(cx(t.pos.x), t.pos.y + dy); tree = t }
        }
        stashBack.removeAll()
    }

    /// Screen-bottom pile: full width, flat, no taper, edges drain nothing. Snow under covered columns stays (hidden), not knocked off.
    func buildGround(rects: [CGRect], windows: [WindowInfo], old: inout [Surface], spawned: inout Int) -> Surface? {
        let bw = Tuning.binWidth
        let frame = CGRect(x: -1e5, y: -1, width: 2e5 + CGFloat(size.x), height: 1)   // "window" extends past the screen: no edge spill
        var pile = Pile(columns: numCols, inset: 0, c0: 0, x0: Float(frame.minX), x1: Float(frame.maxX))
        pile.maxHeight = Tuning.groundMaxHeight
        // A floating bottom Dock bar (top inside the Dock strip): the bank beside it rises to its top, sloping down with distance.
        let docks = rects.indices.filter { windows[$0].number == 0 && rects[$0].minY >= -1 && rects[$0].maxY > 1 && rects[$0].minY < CGFloat(groundY) && rects[$0].width > rects[$0].height }.map { rects[$0] }
        // What the ordinary windows do to each ground column (hidden / roof) only changes with their frames: cached across Dock animation frames.
        let winIdx = rects.indices.filter { windows[$0].number != 0 }, winRects = winIdx.map { rects[$0] }
        if winRects != groundWinKey || groundWinCeil.count != numCols || groundWinTop.count != numCols {
            groundWinKey = winRects
            groundWinCeil = [Float](repeating: .infinity, count: numCols); groundWinHidden = [Bool](repeating: false, count: numCols); groundWinTop = [Float](repeating: 0, count: numCols)
            for b in 0..<numCols {
                let x = CGFloat((Float(b) + 0.5) * bw)
                for i in winIdx {
                    let r = rects[i]
                    if r.contains(CGPoint(x: x, y: 1)) { groundWinHidden[b] = true; groundWinTop[b] = max(groundWinTop[b], Float(r.maxY)); continue }   // every window over the column: the highest top is the wall (as in buildSurface)
                    if r.minY > 1 { groundWinCeil[b] = min(groundWinCeil[b], Self.roundedUnderside(x: Float(x), r, radius: windows[i].radius)) }
                }
            }
        }
        pile.addWalls(hideTop: groundWinTop, edgeY: 0)   // snow banks against the side of a window that stands on the ground (before `maxes`: walls read maxHeight)
        if !docks.isEmpty { pile.maxes = bankMaxes(docks) }   // after the window ceilings: a roofed-over Dock top has no shelf (bankTop)
        pile.setWobble(id: Tuning.groundID, anchor: 0)   // wavy ground, downward only (0.85...1 x the ceiling): never above groundMaxHeight; walls and the Dock bank keep their exact levels. After addWalls (it reads the wobble)
        for b in 0..<numCols {
            let x = (Float(b) + 0.5) * bw   // the bank can grow (stepBank) up to bankLevelMax: no wave anywhere within its widest reach of a Dock end
            let bank = docks.contains { r in let reach = (max(Float(r.maxY), Tuning.groundMaxHeight) - Tuning.groundMaxHeight) / Tuning.bankSlope + Tuning.bankShelf + bw; return x > Float(r.minX) - reach && x < Float(r.maxX) + reach }, wall = !pile.boost.isEmpty && pile.boost[b] > 0
            pile.wobble[b] = bank || wall ? 1 : 0.925 + (pile.wobble[b] - 1) * 0.5
        }
        for b in 0..<numCols {
            let x = CGFloat((Float(b) + 0.5) * bw)
            var ceiling = groundWinCeil[b], barBelow = false
            if groundWinHidden[b] { pile.visible[b] = false }
            for (i, r) in rects.enumerated() where windows[i].number == 0 {
                // The floating Dock bar hovers a few points above the screen bottom: it still hides the ground under it.
                do {   // Dock bar: snow may flow under it, up to its rounded underside (the overlay sits above the Dock)
                    if r.maxY > 1 {
                        // Inside the bar: lowest underside within a bin either side (a column just outside it stays free: the bank rises beside the bar end): the straight contour between bin centres then stays below the arc (it is convex).
                        for dx in [-bw, 0, bw] where dx == 0 || (x >= r.minX && x < r.maxX) { if let u = Tuning.barUnderside(x: Float(x) + dx, minX: Float(r.minX), maxX: Float(r.maxX), minY: Float(r.minY), radius: Float(min(windows[i].radius, r.height / 2))) { ceiling = min(ceiling, u); barBelow = true } }
                    }
                }
            }
            pile.cap[b] = ceiling.isFinite ? max(ceiling - (barBelow ? Tuning.barMargin : 0), 0) : ceiling
        }
        if let k = old.firstIndex(where: { $0.id == Tuning.groundID }) {
            let prev = old.swapRemove(k)
            let nd = docks.first, pd = dockPrev
            var push: (l: Float, r: Float) = (0, 0)
            if prev.pile.shown.count == numCols { pile.shown = prev.pile.shown }   // the eased drawn heights ride along: the bank does not jump mid-ease
            if prev.pile.mound.count == numCols { pile.mound = prev.pile.mound }   // and so does a pushed heap
            for b in 0..<numCols {   // a lowered limit (Dock shrank / moved) sheds the excess as debris; hidden columns keep their snow
                let keep = pile.visible[b] ? min(prev.pile.heights[b], pile.limit(b)) : prev.pile.heights[b], over = prev.pile.heights[b] - keep   // hidden snow stays as it was
                pile.heights[b] = keep; pile.age[b] = prev.pile.age[b]
                let x = (Float(b) + 0.5) * bw
                // swept by a Dock end (or under the old end's rounded corner, which the end has since left behind): the blade pushes it ahead
                var left = false, swept = false
                if over > 0, let nd, let pd {
                    left = Float(nd.minX) < Float(pd.minX) - 0.01 && x >= Float(nd.minX) && x < Float(pd.minX) + Tuning.dockPushReach
                    swept = left || (Float(nd.maxX) > Float(pd.maxX) + 0.01 && x < Float(nd.maxX) && x >= Float(pd.maxX) - Tuning.dockPushReach)
                }
                if swept {
                    let kick = calm || over * Tuning.dockKick <= 0.5 ? 0 : over * Tuning.dockKick
                    if kick > 0 { spawned += shedBin(col: b, edgeY: 0, from: keep, amount: kick, velocity: SIMD2(left ? -Tuning.dockSpeed : Tuning.dockSpeed, 0) * 0.5, oz: .max) }
                    if left { push.l += over - kick } else { push.r += over - kick }
                } else if over > 0.5 { spawned += shedBin(col: b, edgeY: 0, from: keep, amount: over, velocity: .zero, oz: .max) }
            }
            if let nd {
                if push.l > 0 { spawned += berm(&pile, from: Int((Float(nd.minX) * invBin - 0.5).rounded(.down)), dir: -1, volume: push.l) }
                if push.r > 0 { spawned += berm(&pile, from: Int((Float(nd.maxX) * invBin - 0.5).rounded(.up)), dir: 1, volume: push.r) }
            }
        }
        return Surface(id: Tuning.groundID, frame: frame, edgeY: 0, c0: 0, anchor: 0, pile: pile)
    }

    /// Underside of a front window over column centre `x` (inf outside it): its bottom edge, rising along the rounded corners, so snow under a
    /// window follows the corner curve instead of stopping at a straight line. The lowest value across the bin (centre and both half-bin edges) keeps
    /// the straight contour between bin centres close under the arc without the full-bin step that left a gap along the steep part.
    static func roundedUnderside(x: Float, _ r: CGRect, radius: CGFloat) -> Float {
        let bw = Tuning.binWidth, rad = Float(min(radius, r.width / 2, r.height / 2))
        var u = Float.infinity
        for k in -1...1 {   // centre and both half-bin edges
            let dx = Float(k) * bw / 2
            guard dx == 0 || (CGFloat(x + dx) >= r.minX && CGFloat(x + dx) < r.maxX) else { continue }
            if let v = Tuning.barUnderside(x: x + dx, minX: Float(r.minX), maxX: Float(r.maxX), minY: Float(r.minY), radius: rad) { u = min(u, v) }
        }
        return u
    }

    func buildSurface(id: Int, frame: CGRect, edgeY: Float, radius: CGFloat, rects: [CGRect], radii: [CGFloat], windows: [WindowInfo], front: Int,
                              old: inout [Surface], spawned: inout Int) -> Surface? {
        let bw = Tuning.binWidth
        let c0 = max(0, Int(((Float(frame.minX) - bw / 2) / bw).rounded(.up)))
        let c1 = min(numCols, Int(((Float(frame.maxX) - bw / 2) / bw).rounded(.down)) + 1)
        guard c1 > c0 else { return nil }
        let anchor = Int((Float(frame.minX) / bw).rounded())
        var pile = Pile(columns: c1 - c0, inset: Tuning.cornerInset, c0: c0, x0: Float(frame.minX), x1: Float(frame.maxX))
        pile.setWobble(id: id, anchor: anchor)
        for l in seams {   // an end facing a drift (or a neighbour window at the same height) is a wall: no dip, taper or spill
            if l.right == id, l.rightSupported { pile.supportL = true }
            if l.left == id, l.leftSupported { pile.supportR = true }
        }
        if id > 0 {   // wall relation (any step, any stacking): this window is the HIGHER one and its end lies over a lower window's top edge (its bottom at or below that top): the end is part of the group, no taper / dip / bare corner
            for (j, r) in rects.enumerated() where windows[j].number > 0 && windows[j].number != id && !windows[j].occluderOnly && frame.maxY - r.maxY > 1 && frame.minY <= r.maxY + 1 {
                if r.minX < frame.minX - 2, frame.minX < r.maxX - 2 { pile.supportL = true }
                if frame.maxX < r.maxX - 2, frame.maxX > r.minX + 2 { pile.supportR = true }
            }
        }
        pile.round(radius: Float(min(radius, frame.width / 2, frame.height / 2)), c0: c0, minX: Float(frame.minX), maxX: Float(frame.maxX))
        let y = CGFloat(edgeY) + 1
        var hideTop = [Float](repeating: 0, count: c1 - c0)   // top of the window hiding each hidden bin
        for b in 0..<(c1 - c0) {
            let x = CGFloat(binCenter(c0 + b))
            var hidden = false
            var ceiling = Float.infinity   // lowest underside of any window whose body lies above the bin (geometry, any stacking order)
            for j in rects.indices where j != front && (j < front || !windows[j].occluderOnly) {
                let r = rects[j]
                if j < front, r.contains(CGPoint(x: x, y: y)) { hidden = true }   // true occlusion: only windows in front hide (freeze) the bin
                if r.minY > y { ceiling = min(ceiling, Self.roundedUnderside(x: Float(x), r, radius: radii[j])) }   // the other window's own radius (the Dock bar's is larger)
            }
            // Walls are geometry: the highest window whose rect holds the edge point acts as the wall (any stacking order; an occluder-only window behind us is no wall).
            var best = -1
            for j in rects.indices where j != front && (j < front || !windows[j].occluderOnly) && rects[j].contains(CGPoint(x: x, y: y)) {
                if best < 0 || rects[j].maxY > rects[best].maxY || (rects[j].maxY == rects[best].maxY && windows[j].number < windows[best].number) { best = j }
            }
            if best >= 0 { hideTop[b] = Float(rects[best].maxY) }
            pile.visible[b] = !hidden
            pile.cap[b] = max(ceiling - edgeY - pile.base[b], 0)
            if windows[front].number == 0, ceiling - edgeY < Tuning.minRoom { pile.cap[b] = max(ceiling - edgeY, 0) }   // a roofed-over Dock bar: no snow on its corner arcs either (a film there ends in a cliff beside the bank)
        }
        pile.addWalls(hideTop: hideTop, edgeY: edgeY)
        var vel = SIMD2<Float>.zero
        if let k = old.firstIndex(where: { $0.id == id }) {
            let prev = old.swapRemove(k)
            let d = SIMD2(Float(frame.minX - prev.frame.minX), Float(frame.minY - prev.frame.minY))
            let sameSize = abs(prev.frame.width - frame.width) < 0.5 && abs(prev.frame.height - frame.height) < 0.5
            let sameWidth = abs(prev.frame.width - frame.width) < 0.5
            let shift = anchor - prev.anchor
            let u0 = Int(((Float(frame.minX) - bw / 2) / bw).rounded(.up)), u1 = Int(((Float(frame.maxX) - bw / 2) / bw).rounded(.down)) + 1   // the window's columns, screen or not
            let oh = overhang[id] ?? [:]
            func carry(shift: Int) {   // heights by global column; hidden bins travel too (frozen), visible ones are clipped to what fits and the excess is shed
                var shown = pile.heights
                let eased = !prev.pile.shown.isEmpty && prev.pile.shown.count == prev.pile.heights.count
                for b in pile.heights.indices {
                    let pc = c0 + b - shift, k = pc - prev.c0   // the column in the previous surface's coordinates
                    var h: Float, wasVisible = true
                    if k >= 0, k < prev.pile.heights.count {
                        h = prev.pile.heights[k]; pile.age[b] = prev.pile.age[k]; wasVisible = prev.pile.visible[k]; shown[b] = eased ? prev.pile.shown[k] : h
                        if !prev.pile.mound.isEmpty, prev.pile.mound[k] > 0 { if pile.mound.isEmpty { pile.mound = [Float](repeating: 0, count: pile.heights.count) }; pile.mound[b] = prev.pile.mound[k] }   // a pushed heap rides with its window
                    }
                    else if let o = oh[pc] { h = o; shown[b] = o }   // came back from past the screen edge
                    else { continue }
                    guard pile.visible[b] else { pile.heights[b] = h; continue }
                    if !wasVisible || id == 0 {   // uncovered (or the Dock's new rounded end): the excess falls
                        let keep = min(h, pile.limit(b))
                        pile.heights[b] = keep
                        spawned += shedBin(col: c0 + b, edgeY: edgeY + pile.base[b], from: keep, amount: h - keep, velocity: .zero)
                        continue
                    }
                    let keep = min(h, pile.cap[b])   // squeezed under a window in front: falls; a drift above the limit lets go from where its wall was
                    pile.heights[b] = keep
                    spawned += shedBin(col: c0 + b, edgeY: edgeY + pile.base[b], from: keep, amount: h - keep, velocity: .zero)
                    if keep > pile.limit(b) + 0.05, pile.peel.isEmpty || pile.peel[b] < 0 {
                        if pile.peel.isEmpty { pile.peel = [Float](repeating: -1, count: pile.heights.count) }
                        var dist: Float = 0
                        if !prev.pile.walls.isEmpty { dist = .infinity; for w in prev.pile.walls { dist = min(dist, abs(binCenter(c0 + b) - w)) } }
                        pile.peel[b] = dist / Tuning.peelSpeed
                    }
                }
                if !prev.pile.shown.isEmpty { pile.shown = shown }
                var out: [Int: Float] = [:]   // what now lies past the screen edge but still under the window waits there
                func park(_ col: Int, _ h: Float) { let nc = col + shift; if h > 0, nc < c0 || nc >= c1, nc >= u0, nc < u1 { out[nc] = h } }
                for k in prev.pile.heights.indices { park(prev.c0 + k, prev.pile.heights[k]) }
                for (col, h) in oh { park(col, h) }
                overhang[id] = out.isEmpty ? nil : out
            }
            if id == 0, !orderOnly {   // Dock bar resizes when apps come and go: keep snow by global column
                carry(shift: 0)
            } else if sameSize, shift == 0, abs(d.y) < 0.5, prev.pile.heights.count == pile.heights.count {
                var kept = prev.pile
                kept.visible = pile.visible
                kept.cap = pile.cap
                kept.base = pile.base; kept.boost = pile.boost; kept.walls = pile.walls; kept.hideTop = pile.hideTop
                kept.supportL = pile.supportL; kept.supportR = pile.supportR
                kept.hold = []; kept.held = []
                if orderOnly {   // stacking order only: no trim, no peel, no shed. Snow that no longer fits the new limit is pinned by `hold` (existing snow only: growth still follows the new limit); a real change drops it
                    var hold = [Float](repeating: 0, count: kept.heights.count), any = false
                    for b in hold.indices where kept.heights[b] > kept.limit(b) + 0.001 { hold[b] = kept.heights[b]; any = true }
                    if any { kept.hold = hold }
                    let held = kept.visible.indices.map { !kept.visible[$0] && prev.pile.alive($0) }
                    if held.contains(true) { kept.held = held }
                }
                for b in kept.heights.indices where pile.visible[b] && !orderOnly {   // hidden bins stay frozen; uncovered ones shed what no longer fits
                    let h = kept.heights[b], keep = min(h, kept.cap[b])
                    kept.heights[b] = keep
                    if !prev.pile.visible[b] { spawned += shedBin(col: c0 + b, edgeY: edgeY + kept.base[b], from: keep, amount: h - keep, velocity: .zero) }
                    else if keep > kept.limit(b) + 0.05, kept.peel.isEmpty || kept.peel[b] < 0 {   // a drift lost its wall: it lets go from where the wall was, outward
                        if kept.peel.isEmpty { kept.peel = [Float](repeating: -1, count: kept.heights.count) }
                        var d: Float = 0
                        if !prev.pile.walls.isEmpty { d = .infinity; for w in prev.pile.walls { d = min(d, abs(binCenter(c0 + b) - w)) } }
                        kept.peel[b] = d / Tuning.peelSpeed
                    }
                }
                let a = exp(-windowDt(id) / Tuning.velSmoothing)   // an unchanged window keeps its (decaying) velocity: another surface's rebuild must not zero it
                let v = prev.vel * a
                vel = v.x * v.x + v.y * v.y < 0.25 ? .zero : v
                pile = kept
            } else if sameSize {   // moved: the pile travels with the window; a speed-dependent share falls off
                // Smooth over ~100 ms: at frame-rate updates raw d/dt is noisy; at the old 0.1-0.5 s polls this is ~raw.
                let wdt = windowDt(id)
                let a = exp(-wdt / Tuning.velSmoothing)
                vel = prev.vel * a + d / wdt * (1 - a)
                carry(shift: shift)
                spawned += shed(&pile, c0: c0, edgeY: edgeY, frame: frame, fraction: SnowField.perUpdate(SnowField.shedFraction(v: vel, prev: prev.vel), dt: wdt), velocity: vel)
            } else {   // resized: snow stays where it is in x, unless the window kept its width and only slid (zoom, tiling): then it rides along. The part no longer over the window falls
                let s = sameWidth ? shift : 0
                carry(shift: s)
                let v = (d / windowDt(id)).limited()
                for k in prev.pile.heights.indices where prev.pile.visible[k] {
                    let col = prev.c0 + k, nc = col + s
                    if (nc < c0 || nc >= c1) && (nc < u0 || nc >= u1) { spawned += shedBin(col: col, edgeY: prev.edgeY + prev.pile.base[k], from: 0, amount: prev.pile.heights[k], velocity: v) }
                }
            }
        }
        else if let e = stash.removeValue(forKey: id) {   // back from another Space: same width -> same snow; always what stood on it (a different width / a long absence only loses the snow)
            stashBack.append((dx: Float(frame.minX) - e.minX, dy: Float(frame.maxY) - e.topY, x: Float(frame.minX)...Float(frame.maxX), e: e))
            if clock - e.stamp < 1800, e.heights.count == pile.heights.count {
            if e.mound.count == pile.heights.count { pile.mound = e.mound }
            if e.age.count == pile.heights.count { pile.age = e.age }
            for b in pile.heights.indices { pile.heights[b] = pile.visible[b] ? min(e.heights[b], pile.limit(b)) : e.heights[b] }
            pile.shown = pile.heights
            let u0 = Int(((Float(frame.minX) - bw / 2) / bw).rounded(.up)), u1 = Int(((Float(frame.maxX) - bw / 2) / bw).rounded(.down)) + 1
            let oh = e.overhang.compactMap { r, h -> (Int, Float)? in let nc = c0 + r; return (nc < c0 || nc >= c0 + pile.heights.count) && nc >= u0 && nc < u1 ? (nc, h) : nil }
            if !oh.isEmpty { overhang[id] = Dictionary(uniqueKeysWithValues: oh) }
            if var ice = e.ice {   // frost and icicles come back with the snow (stalactites regrow from the next frost step)
                ice.w0 = Float(frame.width); ice.h0 = Float(frame.height)
                if ice.frozen { ice.frozen = false; ice.acc = Tuning.frozenAfter }
                iceWin.removeAll { $0.id == id }; iceWin.append(ice)
            }
            }
        }
        else if id == 0, !dockCarry.isEmpty, time <= dockCarryUntil {   // the Dock pile carried across a screen resize
            if dockMoundCarry.count == dockCarry.count { pile.mound = (0..<pile.heights.count).map { c0 + $0 >= 0 && c0 + $0 < dockCarry.count && dockMoundCarry[c0 + $0] > 0 ? max(0, dockCarry[c0 + $0] - pile.rawLimit($0)) : 0 } }   // heap allowance = carried height over the ceiling
            for b in pile.heights.indices where c0 + b >= 0 && c0 + b < dockCarry.count { pile.heights[b] = pile.visible[b] ? min(dockCarry[c0 + b], pile.limit(b)) : dockCarry[c0 + b] }
            if dockAgeCarry.count == dockCarry.count { for b in pile.heights.indices where c0 + b >= 0 && c0 + b < dockCarry.count { pile.age[b] = dockAgeCarry[c0 + b] } }
            pile.shown = pile.heights
        }
        if id == 0 { dockCarry = []; dockMoundCarry = []; dockAgeCarry = [] }
        return Surface(id: id, frame: frame, edgeY: edgeY, c0: c0, anchor: anchor, pile: pile, vel: vel, radius: Float(min(radius, frame.width / 2, frame.height / 2)),
                       cover: rects[0..<front].filter { $0.intersects(frame) })
    }

    /// Drift excess whose delay ran out turns into debris (wall first, so the ramp unzips); volume is conserved.
    func stepPeel(dt: Float) {
        for si in surfaces.indices where surfaces[si].pile.peeling {
            let c0 = surfaces[si].c0, edgeY = surfaces[si].edgeY
            var pending = false
            for b in surfaces[si].pile.heights.indices {
                let t = surfaces[si].pile.peel[b]
                guard t >= 0 else { continue }
                let over = surfaces[si].pile.heights[b] - surfaces[si].pile.limit(b)
                guard over > 0.05, surfaces[si].pile.visible[b] else { surfaces[si].pile.peel[b] = -1; continue }
                if t > dt { surfaces[si].pile.peel[b] = t - dt; pending = true; continue }
                surfaces[si].pile.peel[b] = -1
                surfaces[si].pile.heights[b] -= over
                peeledVolume += over
                _ = shedBin(col: c0 + b, edgeY: edgeY + surfaces[si].pile.base[b], from: surfaces[si].pile.heights[b], amount: over, velocity: .zero)
                pilesDirty = true
            }
            if !pending { surfaces[si].pile.peel = [] }
        }
        _ = flushRuns()   // peeled bins leave as slabs, like every other release
    }

    /// Takes `fraction` of the pile off as debris, preferring the tops and the window ends.
    func shed(_ pile: inout Pile, c0: Int, edgeY: Float, frame: CGRect, fraction: Float, velocity v: SIMD2<Float>) -> Int {
        guard fraction > 0 else { return 0 }
        let v = v.limited()
        let zone = max(Float(frame.width) * Tuning.shedEdgeZone, 1)
        var n = 0
        for b in pile.heights.indices where pile.heights[b] > 0.5 && pile.visible[b] {
            let x = binCenter(c0 + b)
            let edge = max(0, 1 - min(x - Float(frame.minX), Float(frame.maxX) - x) / zone)
            let h = pile.heights[b], r = h * min(1, fraction * (1 + Tuning.shedEdgeBias * edge))
            n += shedBin(col: c0 + b, edgeY: edgeY + pile.base[b], from: h - r, amount: r, velocity: v)
            pile.heights[b] = h - r
        }
        return n + flushRuns()
    }

    /// Once the blade has moved on (0.25 s), every pushed heap keeps slumping a few relax passes per frame until its flanks are at the angle of repose (a mound, never a spike).
    func stepSlump(dt: Float) {
        for si in surfaces.indices where surfaces[si].pile.gapT > 0 {   // walls of a scooped gap slump over plowSlumpTime (also while the blade is moving: the trail behind it collapses)
            let n = surfaces[si].pile.heights.count
            surfaces[si].pile.gapT -= dt
            let lo = max(0, surfaces[si].pile.gapLo - 12), hi = min(n - 1, surfaces[si].pile.gapHi + 12)
            if lo <= hi { surfaces[si].pile.settle(lo, hi); pilesDirty = true }
        }
        guard time - sweptAt > 0.25 else { slumpClock = 0; return }
        slumpClock = min(slumpClock + dt, 2.0 / 60)   // at most 2 substeps a frame
        guard slumpClock >= 1.0 / 60 else { return }
        slumpClock -= 1.0 / 60
        for si in surfaces.indices where !surfaces[si].pile.mound.isEmpty && surfaces[si].id != draggingID {
            let n = surfaces[si].pile.heights.count
            var i = 0
            while i < n {
                guard surfaces[si].pile.mound[i] > 0.5 else { i += 1; continue }
                var e = i
                while e + 1 < n, surfaces[si].pile.mound[e + 1] > 0.5 { e += 1 }
                let before = surfaces[si].pile.heights[max(i - 1, 0)...min(e + 1, n - 1)].reduce(0, +)
                surfaces[si].pile.settle(i, e)
                if surfaces[si].pile.heights[max(i - 1, 0)...min(e + 1, n - 1)].reduce(0, +) != before { pilesDirty = true }
                i = e + 1
            }
            if (surfaces[si].pile.mound.max() ?? 0) <= 0.5 { surfaces[si].pile.mound = [] }   // the heap has slumped flat: back to "no mound" (else this scan runs forever)
        }
    }

    /// Cursor plow: snow within `radius` of the segment a->b (local coords) above the cursor's lower edge is lifted off the pile and carried to a rounded berm just
    /// ahead of the motion (horizontal pass) or split to both sides (|dy| > |dx|); only what no longer fits (pile limit, run end) flies off as debris along the
    /// cursor (`dt` = time the move took). Needs `pointerPush`; figures, balls, gifts and icicles react regardless. The dragged window's pile is left alone.
    public func sweep(from a: CGPoint, to b: CGPoint, radius: Float = Tuning.plowRadius, dt: Float = 1.0 / 60) {
        let ax = Float(a.x), ay = Float(a.y), dx = Float(b.x) - ax, dy = Float(b.y) - ay
        let len2 = dx * dx + dy * dy, r = radius
        guard len2 > 0, dt > 0 else { return }
        let v = (SIMD2(dx, dy) / dt).limited()
        let lo = min(ay, ay + dy) - r, hi = max(ay, ay + dy) + r
        let first = debris.count
        let speed = len2.squareRoot() / dt, share = min(len2.squareRoot() / (1.33 * r), 1)
        let hover = speed < Tuning.plowSlowSpeed   // a hover barely marks (parabolic dent of plowHoverDepth); a push scoops everything under the blade down to the keep level
        let horizontal = abs(dx) >= abs(dy)
        let powder: Float = !hover && !economy && !lowPower && speed > 300 ? min(0.04 + speed / 20000, 0.15) : 0   // share of a push's snow thrown as powder
        var owed: Float = 0, ox: Float = 0, oy: Float = 0, cx: Float = 0, cy: Float = 0, sum: Float = 0
        sweepFigures(ax, ay, Float(b.x), Float(b.y), r, v)
        breakBalls(ax, ay, Float(b.x), Float(b.y), r, v)
        breakGifts(ax, ay, Float(b.x), Float(b.y), r, v)
        breakIcicles(ax, ay, Float(b.x), Float(b.y), r, v)
        guard pointerPush, !calm, !silent else { return }   // Reduce Motion / silent: piles stay put (no overflow could fly off, so nothing may be cut)
        sweptAt = time; sweepSpeed = speed
        defer { flushRuns(); for j in first..<debris.count { debris[j].phase = 0.5 } }
        for si in surfaces.indices where surfaces[si].id != draggingID {
            let c = surfaces[si].c0, edgeY = surfaces[si].edgeY   // no `let s = surfaces[si]`: a live copy would force a copy of the heights on write
            guard hi >= edgeY - Tuning.maxPileHeight else { continue }
            if lo > edgeY + Tuning.maxPileHeight, lo > edgeY + Tuning.maxPileHeight + (surfaces[si].pile.mound.max() ?? 0) { continue }   // a heap can stand far above the usual pile (looked up only when the cursor is above the plain pile)
            let b0 = max(0, Int((min(ax, ax + dx) - r) * invBin) - c), b1 = min(surfaces[si].pile.heights.count - 1, Int((max(ax, ax + dx) + r) * invBin) - c)
            guard b0 <= b1 else { continue }
            var removed: Float = 0, wx: Float = 0, wy: Float = 0
            let bar = surfaces[si].id == Tuning.groundID ? dockSpan() : nil   // the Dock is an obstacle: snow under it is out of the blade's reach
            for k in b0...b1 {
                let h = surfaces[si].pile.heights[k]
                guard h > 0.5, surfaces[si].pile.visible[k] else { continue }
                if let bar, bar.contains(binCenter(c + k)) { continue }
                let x = binCenter(c + k), bottom = edgeY + surfaces[si].pile.base[k], my = bottom + h / 2
                let t = min(max(((x - ax) * dx + (my - ay) * dy) / len2, 0), 1)
                let qx = ax + t * dx, qy = ay + t * dy
                guard abs(qx - x) <= r, abs(qy - my) <= r + h / 2 else { continue }
                if surfaces[si].id > 0, qy < edgeY { continue }   // a window's snow is only worked from above its top edge (the title bar below it is not a plow)
                let u = (x - qx) / r
                let keep = min(max(qy - r - bottom, Tuning.plowFloor), h)   // snow below the cursor's lower edge stays, and a plow never scrapes the window bare (a thin layer stays)
                let dh: Float
                if hover {
                    // Integrate the parabola along a horizontal path, so a bin's total over a pass is the same however the frames sample it (smooth dent).
                    let cover: Float
                    if horizontal {
                        let p0 = min(max(ax - x, -r), r), p1 = min(max(ax + dx - x, -r), r)
                        cover = abs((p1 - p0) - (p1 * p1 * p1 - p0 * p0 * p0) / (3 * r * r)) / (1.3333 * r)
                    } else { cover = (1 - u * u) * share }
                    dh = min(Tuning.plowHoverDepth * cover, h - keep)
                } else {
                    // Blade: full-depth scoop, soft rounded edge. `qx` is the closest point of the whole segment, so the weight is a swept envelope: same result at any frame rate.
                    let t = min(max((1 - abs(u)) / 0.45, 0), 1)
                    dh = (h - keep) * t * t * (3 - 2 * t)
                }
                guard dh > 0.01 else { continue }
                surfaces[si].pile.heights[k] = h - dh
                if !surfaces[si].pile.mound.isEmpty { surfaces[si].pile.trackMound(k) }   // pushing a heap on: its allowance moves with the snow
                pilesDirty = true
                let a = dh * Tuning.binWidth
                removed += a; wx += x * a; wy += (bottom + h) * a
            }
            if removed > 0 {
                let xl = min(ax, ax + dx) - r, xr = max(ax, ax + dx) + r
                var lowK = b0, highK = b1, banked: Float = 0, ex: Float = 0, ey: Float = 0
                let nSides = horizontal ? 1 : 2   // horizontal: the leading side only; else left (-1) then right (+1)
                for k in 0..<nSides {   // each leftover (nothing fits before the run ends) flies off at that run end, never at the cursor
                    let bx = horizontal ? (dx > 0 ? xr : xl) : (k == 0 ? xl : xr), dir = horizontal ? (dx > 0 ? 1 : -1) : (k == 0 ? -1 : 1)
                    let part = removed * (1 - powder) / Float(nSides)
                    let got = berm(si, atX: bx, dir: dir, area: part, lo: &lowK, hi: &highK, end: &ex, endY: &ey)
                    banked += got; ox += (part - got) * ex; oy += (part - got) * ey
                }
                if !hover { let p = surfaces[si].pile; surfaces[si].pile.gapLo = p.gapT > 0 ? min(p.gapLo, b0) : b0; surfaces[si].pile.gapHi = p.gapT > 0 ? max(p.gapHi, b1) : b1; surfaces[si].pile.gapT = Tuning.plowSlumpTime }   // (the copy is of 5 scalars' worth: no array write)
                surfaces[si].pile.settle(max(lowK - 2, 0), min(highK + 2, surfaces[si].pile.heights.count - 1))   // round the groove and the lip: no 1-bin spikes
                let thrown = removed * powder
                if thrown > 0 { ox += thrown * (ax + dx); oy += thrown * (ay + dy) }   // powder leaves the front of the blade
                owed += removed - banked; cx += wx; cy += wy; sum += removed
            }
        }
        guard sum > 0 else { return }
        if speed > 600, Float.random(in: 0..<1, using: &rng) < 0.3 { addPuff(x: cx / sum, y: cy / sum + 3) }   // fast swipe: a light powder puff as feedback
        if powder > 0 {   // powder off the front of the blade, scaled by speed and the depth scooped (the flakes are the `powder` share held back from the berm: it flies as debris below, lands again)
            let depth = sum / (2 * r * Tuning.binWidth)
            let n = min(1 + Int(speed / 400 + depth / 8), 4)
            let fx = ax + dx + (horizontal ? (dx > 0 ? r : -r) : 0), fy = ay + dy
            for _ in 0..<n where puffs.count < Tuning.maxPuffs { addPuff(x: fx + Float.random(in: -r...r, using: &rng) * 0.5, y: fy - r * 0.5) }
        }
        guard owed > 0.01 else { return }
        sweepOwed += owed   // (no cap: a backlog goes out in growing pieces, see launchSweepDebris; the old 600 cap silently dropped snow)
        launchSweepDebris(x: ox / owed, y: oy / owed, v: v, speed: speed, r: r, dir: horizontal ? (v.x >= 0 ? 1 : -1) : (ox / owed >= ax ? 1 : -1))   // a parting spills outward at each end
    }

    /// Banks `area` (pt^2) ahead of global x in direction `dir`: a rounded berm (taper over nine bins) that may heap up to 25% over the pile limit
    /// (never over a window's `cap`), then whatever is left fills bins further along the run. Returns the area banked; the rest hit the run end at global
    /// (`end`, `endY`). `lo`/`hi` grow to the touched bins. Overfill is bounded by the 1.25 ceiling however many passes pile onto it.
    static let bermWeights: [Float] = [0.07, 0.13, 0.17, 0.17, 0.15, 0.12, 0.09, 0.06, 0.04]   // taper over nine bins, sums to 1
    /// x range and top height of the Dock bar (the obstacle for the ground push); nil when there is none.
    struct DockSpan { let lower: Float, upper: Float, top: Float; func contains(_ x: Float) -> Bool { x >= lower && x < upper } }
    func dockSpan() -> DockSpan? {
        guard let di = index[0], surfaces[di].frame.width > surfaces[di].frame.height, surfaces[di].frame.minY >= -1 else { return nil }
        let f = surfaces[di].frame, lo = Float(f.minX), hi = Float(f.maxX)
        return DockSpan(lower: lo, upper: hi, top: surfaces[di].edgeY)
    }
    /// Banks snow against a side as a repose wedge: from bin `k0` walking by `step` (away from the wall), each bin takes up to `top - slope * j` (j = bins from the wall) until `area` (pt^2, `banked` counts what is already in) is placed or the pile / run ends.
    /// `underWindows` (the wall is a higher window's side): the walk stays on open bins, `top` is relative to this surface's edge (the bin's base is subtracted) and a window's cap bounds it; else (the Dock's side on the ground) visible bins, `top` is absolute and no cap.
    func bankWedge(_ si: Int, from k0: Int, step: Int, top: Float, area: Float, banked: inout Float, last: inout Int, lo: inout Int, hi: inout Int, underWindows: Bool) {
        let n = surfaces[si].pile.heights.count
        var k = k0, j = 0
        while banked < area - 0.01, k >= 0, k < n, underWindows ? surfaces[si].pile.open(k) : surfaces[si].pile.visible[k], j < 400 {
            let h = surfaces[si].pile.heights[k]
            let room = underWindows ? max(min(top - surfaces[si].pile.base[k] - Tuning.slope * Float(j), surfaces[si].pile.cap[k]) - h, 0) : max(top - Tuning.slope * Float(j) - h, 0)
            let put = min(room, (area - banked) / Tuning.binWidth)
            if put > 0 {
                surfaces[si].pile.heights[k] = h + put; banked += put * Tuning.binWidth; surfaces[si].pile.trackMound(k)
                lo = min(lo, k); hi = max(hi, k); pilesDirty = true
            }
            last = k; k += step; j += 1
        }
    }
    func berm(_ si: Int, atX x: Float, dir: Int, area: Float, lo: inout Int, hi: inout Int, end: inout Float, endY: inout Float) -> Float {
        let n = surfaces[si].pile.heights.count, c = surfaces[si].c0, start = Int(x * invBin) - c + dir
        var banked: Float = 0, last = min(max(start - dir, 0), n - 1)
        func add(_ k: Int, _ want: Float) -> Bool {   // false: ran into the end of the run
            guard k >= 0, k < n, surfaces[si].pile.open(k) else { return false }   // a bin under a higher window is a wall (geometry, any stacking order)
            let h = surfaces[si].pile.heights[k]
            let nh = min(h + want / Tuning.binWidth, max(min(surfaces[si].pile.cap[k], Tuning.moundMax), h))   // the pushed heap has no height limit but a window's cap
            last = k
            guard nh > h else { return true }   // already at the heap ceiling: walk on without touching it
            surfaces[si].pile.heights[k] = nh; banked += (nh - h) * Tuning.binWidth
            surfaces[si].pile.trackMound(k)
            lo = min(lo, k); hi = max(hi, k); pilesDirty = true
            return true
        }
        let bar = surfaces[si].id == Tuning.groundID ? dockSpan() : nil
        func wall(_ k: Int) -> Bool { bar?.contains(binCenter(c + k)) ?? false }
        var open = true, hit = false, failK: Int?
        for (i, wi) in Self.bermWeights.enumerated() {
            let k = start + dir * i
            if wall(k) { open = false; hit = true; break }   // the push stops at the Dock's side: snow never passes under the bar to the far side
            if !add(k, wi * area) { open = false; failK = k; break }
        }
        var m = 9
        while open, banked < area - 0.01 {
            let k = start + dir * m
            if wall(k) { hit = true; break }
            if add(k, area - banked) { m += 1 } else { open = false; failK = k }
        }
        if let k = failK, banked < area - 0.01 {   // the run ends at a seam, or at a higher window's side (a wall mid-pile): the heap goes on onto the touching neighbour (one group), no debris at the joint
            let atEnd = k < 0 || k >= n
            if let nx = neighbor(si: si, dir: dir, bin: atEnd ? nil : k - dir), surfaces[nx.si].id != draggingID, landable(nx.si) {
                if !atEnd {   // like the Dock: bank against the side as a repose wedge up to the higher window's top, the rest goes on top of its pile
                    let top = surfaces[nx.si].edgeY + surfaces[nx.si].pile.base[nx.bin] - surfaces[si].edgeY
                    bankWedge(si, from: k - dir, step: -dir, top: top, area: area, banked: &banked, last: &last, lo: &lo, hi: &hi, underWindows: true)
                }
                if banked < area - 0.01 {
                    var dlo = Int.max, dhi = Int.min, e: Float = 0, ey: Float = 0
                    banked += berm(nx.si, atX: (Float(surfaces[nx.si].c0 + nx.bin - dir) + 0.5) * Tuning.binWidth, dir: dir, area: area - banked, lo: &dlo, hi: &dhi, end: &e, endY: &ey)
                    if dlo <= dhi { surfaces[nx.si].pile.settle(max(dlo - 2, 0), min(dhi + 2, surfaces[nx.si].pile.heights.count - 1)) }
                    if banked < area - 0.01 { end = e; endY = ey; return banked }   // (the far end spilled: the remainder flies off there)
                }
            }
        }
        if hit, let bar, banked < area - 0.01 {   // bank the rest against the bar's side as a repose wedge up to the Dock top; what rises above goes onto the Dock's own pile
            var k = start + dir * m
            while wall(k) { k -= dir }
            let rise = surfaces[si].edgeY + surfaces[si].pile.base[k] + surfaces[si].pile.heights[k] - bar.top   // how far the heap against the bar already stands over its top
            if sweepSpeed >= Tuning.dockOverSpeed, rise > -1 {   // fast and the heap is at the bar's top: a speed- and rise-scaled share crests over as a burst of chunks that land on the Dock pile (slower: it only heaps higher against the side)
                let over = (area - banked) * min(1, 0.2 + (sweepSpeed - Tuning.dockOverSpeed) / (2 * Tuning.dockOverSpeed)) * min(1, 0.3 + max(rise, 0) / 20)
                let n = min(6, Int(over / 3) + 1), per = over / Float(n), hy = bar.top + max(rise, 0)   // chunks leave from the crest of the heap
                for _ in 0..<n {
                    debris.append(Flake(pos: [(dir > 0 ? bar.lower - 2 : bar.upper + 2) + Float.random(in: -4...4, using: &rng), hy + Float.random(in: 4...10, using: &rng)],
                                        vx: Float(dir) * Float.random(in: 120...220, using: &rng), fall: -Float.random(in: 120...220, using: &rng), phase: 0.5, amp: 0, freq: 0,
                                        size: per > 5 ? 4 : 3, alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1, spin: Float.random(in: -3...3, using: &rng), vol: per, shape: per > 5 ? 1 : 0, oz: spawnZ))
                    banked += per   // (appended past maxDebris on purpose: <= 6 chunks a call, dropping them would lose the snow)
                }
                if !economy, !lowPower { addPuff(x: dir > 0 ? bar.lower : bar.upper, y: bar.top + max(rise, 0) + 6) }
            }
            bankWedge(si, from: k, step: -dir, top: bar.top + (sweepSpeed >= Tuning.dockOverSpeed ? 0 : 40), area: area, banked: &banked, last: &last, lo: &lo, hi: &hi, underWindows: false)   // the rest banks against the bar's side as a repose wedge (fast: up to its top, the excess went over; slow: up to 40 pt over its top)
        }
        end = binCenter(c + last); endY = surfaces[si].edgeY + surfaces[si].pile.base[last] + surfaces[si].pile.heights[last]
        return banked
    }

    /// Turns the owed volume into debris launched along the cursor: fine powder plus a few clumps (fast), or a gentle sift (slow hover).
    /// Each carries its own volume (`vol`), so what leaves the pile lands again.
    func launchSweepDebris(x: Float, y: Float, v: SIMD2<Float>, speed: Float, r: Float, dir: Float) {
        let fast = speed > 120
        var spawned = 0
        while sweepOwed >= 1.5, spawned < 8 {
            let grow = max(1, sweepOwed / 40)   // a big backlog goes out in bigger pieces: volume is carried, not dropped
            let clump = fast && sweepOwed >= 6 && Float.random(in: 0..<1, using: &rng) < 0.3
            let area = (clump ? Float.random(in: 4...7, using: &rng) : Float.random(in: 1.2...2.2, using: &rng)) * grow
            let along = fast ? min(speed * 0.3, 360) * Float.random(in: 0.5...1.2, using: &rng) : Float.random(in: -10...10, using: &rng)
            var f = Flake(pos: [x + Float.random(in: -r...r, using: &rng), y + Float.random(in: 0...2, using: &rng)],
                          vx: (fast ? dir * along : along) + Float.random(in: -15...15, using: &rng),
                          fall: fast ? -Float.random(in: 20...90, using: &rng) : Float.random(in: 0...12, using: &rng),
                          phase: 0.5, amp: 0, freq: 0, size: (clump ? Float.random(in: 3.5...5, using: &rng) : Float.random(in: 2.2...3.2, using: &rng)) * min(grow.squareRoot(), 2),
                          alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1, spin: Float.random(in: -3...3, using: &rng), vol: area, shape: clump ? 1 : 0)
            f.fall -= max(min(v.y, 200), -200) * 0.2   // a cursor moving up kicks the snow up
            guard put(f) else { break }
            sweepOwed -= area; spawned += 1
        }
        if fast, Float.random(in: 0..<1, using: &rng) < 0.08, !economy, !lowPower, glints.count < Tuning.maxGlints {   // fresh crest catches the light
            glints.append(Flake(pos: [x, y], vx: 0, fall: 0, phase: 0, amp: 0, freq: 0, size: Float.random(in: 4...6, using: &rng), alpha: 1, kind: .debris,
                                seed: Float.random(in: 0..<1, using: &rng), fade: 1, delay: Tuning.glintLife, shape: 4))
        }
    }

    /// A vanished surface's pile falls as a few intact blocks (`dropBlocks`), not as a spray: each run of snow is cut into ~60pt slabs.
    func knockOff(_ s: Surface, velocity v: SIMD2<Float> = .zero) -> Int {
        guard !silent else { return 0 }
        if var t = stash[s.id]?.tree, tree == nil { t.state = .falling; t.surface = nil; t.vel = .zero; tree = t }   // its tree never came back: it falls from where it stood
        stash[s.id] = nil   // it left on its own: its snow falls, nothing to bring back
        var n = 0, b = 0
        let count = s.pile.heights.count
        let origin = [Float(s.frame.midX), Float(s.frame.minX), Float(s.frame.maxX)][Int.random(in: 0..<3, using: &rng)]   // the ripple starts mid-window or at one end
        func solid(_ k: Int) -> Bool { s.pile.visible[k] && s.pile.heights[k] > 0.5 }
        while b < count {
            guard solid(b) else { b += 1; continue }
            var e = b
            while e < count, solid(e) { e += 1 }
            n += dropBlocks(s, from: b, to: e, velocity: v, originX: origin)
            b = e
        }
        return n
    }

    /// Releases the bins whose (x-ordered, jittered) rank lies in (from, to].
    func releasePiles(from: Float, to: Float) {
        for si in surfaces.indices {
            let c0 = surfaces[si].c0, edgeY = surfaces[si].edgeY
            for b in surfaces[si].pile.heights.indices {
                let h = surfaces[si].pile.heights[b], col = c0 + b
                guard h > 0 else { continue }
                if !surfaces[si].pile.visible[b] { surfaces[si].pile.heights[b] = 0; continue }   // hidden: gone without debris over the front window
                let rank = 0.7 * binCenter(col) / size.x + 0.3 * Float(UInt32(truncatingIfNeeded: (col >> 3) &* 2654435761) % 1000) / 1000   // jitter per 8-column group, so the bins of a slab go together
                guard rank > from, rank <= to else { continue }
                surfaces[si].pile.heights[b] = 0
                _ = shedBin(col: col, edgeY: edgeY + surfaces[si].pile.base[b], from: 0, amount: h, velocity: .zero)
            }
        }
        flushRuns()
        pilesDirty = true
    }
}
