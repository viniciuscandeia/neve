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
    }

    /// Snow that slid off a surface end falls as debris.
    func spill(_ si: Int) {
        let c0 = surfaces[si].c0, edgeY = surfaces[si].edgeY, last = surfaces[si].pile.heights.count - 1
        for left in [true, false] {
            let amount = left ? surfaces[si].pile.spillL : surfaces[si].pile.spillR
            guard amount > 2 else { continue }
            let sign: Float = left ? -1 : 1
            addDebris(x: Float(left ? c0 : c0 + last + 1) * Tuning.binWidth, y: edgeY + surfaces[si].pile.base[left ? 0 : last],
                      vx: sign * Float.random(in: 8...25, using: &rng), fall: Float.random(in: 10...30, using: &rng))
            if left { surfaces[si].pile.spillL = 0 } else { surfaces[si].pile.spillR = 0 }
        }
    }

    /// Rebuilds surfaces from the front-to-back window list. Returns debris spawned by knocked-off piles.
    @discardableResult
    public func update(windows: [WindowInfo], dt: Float = Tuning.shedRefDt, now: Double? = nil) -> Int {
        // Each window's dt is its own time since its last sample (`stamps`, monotonic `now`; without it a clock advanced by `dt`).
        if let now { clock = now } else { clock += Double(dt) }
        pollDt = dt
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
        return updateSurfaces(windows: effective(windows), only: dragOnlyRebuild ? movedOnly(windows, prev: prev) : nil, settle: true)
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

        seams = computeSeams(rects: rects, windows: windows)
        let before = surfaces
        dockPrev = before.first { $0.id == 0 }?.frame
        var old = before
        var built: [Surface] = []
        var spawned = 0
        // Reused surfaces keep their piles, but `cover` (what the Dock hides of a window's foot) follows the Dock: refresh it where the Dock was, is or is going.
        var reach = rects.indices.first { windows[$0].number == 0 }.map { rects[$0] }
        if only != nil { for r in [dockPrev, dockTarget?.offsetBy(dx: -ox, dy: -oy)] { if let r { reach = reach.map { $0.union(r) } ?? r } } }
        for (i, r) in rects.enumerated() {
            let id = windows[i].number, edge = Float(r.maxY)
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
            if let s = buildSurface(id: id, frame: r, edgeY: edge, radius: windows[i].radius, rects: rects, front: i, old: &old, spawned: &spawned) { built.append(s) }
            spawned += flushRuns()   // runs never span two surfaces
        }
        if let g = buildGround(rects: rects, windows: windows, old: &old, spawned: &spawned) { built.append(g) }   // behind everything: every window and the Dock hide it
        spawned += flushRuns()
        if windowsStale {   // Space switch: windows that went away are not closed, they are elsewhere: snow (and frost) set aside, balls and figures on them go, no debris
            let gone = old.filter { $0.id > 0 }
            for s in gone where s.pile.heights.contains(where: { $0 > 0 }) {
                stash[s.id] = Stashed(heights: s.pile.heights, stamp: clock, ice: iceWin.first { $0.id == s.id })
            }
            while stash.count > 64, let k = stash.min(by: { $0.value.stamp < $1.value.stamp })?.key { stash[k] = nil }
            let ids = Set(gone.map(\.id))
            balls.removeAll { $0.state != .held && $0.surfaceID.map { ids.contains($0) } ?? false }
            dropWindowFigures(on: ids)
            old.removeAll { $0.id > 0 }
        }
        for s in old { spawned += knockOff(s) }   // gone surfaces
        overhang = overhang.filter { k, _ in built.contains { $0.id == k } }
        for i in built.indices where only?.contains(built[i].id) ?? true { built[i].runs = built[i].pile.visibleRuns() }
        surfaces = built
        index.removeAll(keepingCapacity: true)
        for (i, s) in surfaces.enumerated() { index[s.id] = i }
        buildColumns()
        transportBalls(before: before)
        transportGifts(before: before)
        transportFigures(before: before)
        pilesDirty = true
        return spawned
    }

    /// Screen-bottom pile: full width, flat, no taper, edges drain nothing. Snow under covered columns stays (hidden), not knocked off.
    func buildGround(rects: [CGRect], windows: [WindowInfo], old: inout [Surface], spawned: inout Int) -> Surface? {
        let bw = Tuning.binWidth
        let frame = CGRect(x: -1e5, y: -1, width: 2e5 + CGFloat(size.x), height: 1)   // "window" extends past the screen: no edge spill
        var pile = Pile(columns: numCols, inset: 0, c0: 0, x0: Float(frame.minX), x1: Float(frame.maxX))
        pile.maxHeight = Tuning.groundMaxHeight
        // A floating bottom Dock bar (top inside the Dock strip): the bank beside it rises to its top, sloping down with distance.
        let docks = rects.indices.filter { windows[$0].number == 0 && rects[$0].minY >= -1 && rects[$0].maxY > 1 && rects[$0].minY < CGFloat(groundY) && rects[$0].width > rects[$0].height }.map { rects[$0] }
        if !docks.isEmpty {
            pile.maxes = bankMaxes(docks)
        }
        // What the ordinary windows do to each ground column (hidden / roof) only changes with their frames: cached across Dock animation frames.
        let winRects = rects.indices.filter { windows[$0].number != 0 }.map { rects[$0] }
        if winRects != groundWinKey || groundWinCeil.count != numCols {
            groundWinKey = winRects
            groundWinCeil = [Float](repeating: .infinity, count: numCols); groundWinHidden = [Bool](repeating: false, count: numCols)
            for b in 0..<numCols {
                let x = CGFloat((Float(b) + 0.5) * bw)
                for r in winRects {
                    if r.contains(CGPoint(x: x, y: 1)) { groundWinHidden[b] = true; break }
                    if r.minY > 1, x >= r.minX, x < r.maxX { groundWinCeil[b] = min(groundWinCeil[b], Float(r.minY)) }
                }
            }
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
            for b in 0..<numCols {   // a lowered limit (Dock shrank / moved) sheds the excess as debris; hidden columns keep their snow
                let keep = pile.visible[b] ? min(prev.pile.heights[b], pile.limit(b)) : prev.pile.heights[b], over = prev.pile.heights[b] - keep   // hidden snow stays as it was
                pile.heights[b] = keep
                let x = (Float(b) + 0.5) * bw
                // swept by a Dock end (or under the old end's rounded corner, which the end has since left behind): the blade pushes it ahead
                var left = false, swept = false
                if over > 0, let nd, let pd {
                    left = Float(nd.minX) < Float(pd.minX) - 0.01 && x >= Float(nd.minX) && x < Float(pd.minX) + Tuning.dockPushReach
                    swept = left || (Float(nd.maxX) > Float(pd.maxX) + 0.01 && x < Float(nd.maxX) && x >= Float(pd.maxX) - Tuning.dockPushReach)
                }
                if swept {
                    let kick = calm || over * Tuning.dockKick <= 0.5 ? 0 : over * Tuning.dockKick
                    if kick > 0 { spawned += shedBin(col: b, edgeY: 0, from: keep, amount: kick, velocity: SIMD2(left ? -Tuning.dockSpeed : Tuning.dockSpeed, 0) * 0.5) }
                    if left { push.l += over - kick } else { push.r += over - kick }
                } else if over > 0.5 { spawned += shedBin(col: b, edgeY: 0, from: keep, amount: over, velocity: .zero) }
            }
            if let nd {
                if push.l > 0 { spawned += berm(&pile, from: Int((Float(nd.minX) * invBin - 0.5).rounded(.down)), dir: -1, volume: push.l) }
                if push.r > 0 { spawned += berm(&pile, from: Int((Float(nd.maxX) * invBin - 0.5).rounded(.up)), dir: 1, volume: push.r) }
            }
        }
        return Surface(id: Tuning.groundID, frame: frame, edgeY: 0, c0: 0, anchor: 0, pile: pile)
    }

    func buildSurface(id: Int, frame: CGRect, edgeY: Float, radius: CGFloat, rects: [CGRect], front: Int,
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
        pile.round(radius: Float(min(radius, frame.width / 2, frame.height / 2)), c0: c0, minX: Float(frame.minX), maxX: Float(frame.maxX))
        let y = CGFloat(edgeY) + 1
        var hideTop = [Float](repeating: 0, count: c1 - c0)   // top of the window hiding each hidden bin
        for b in 0..<(c1 - c0) {
            let x = CGFloat(binCenter(c0 + b))
            var hidden = false
            var ceiling = Float.infinity   // lowest underside of a front window above the edge in this column
            for j in 0..<front {
                let r = rects[j]
                if r.contains(CGPoint(x: x, y: y)) { hidden = true; hideTop[b] = Float(r.maxY); break }
                if r.minY > y, x >= r.minX, x < r.maxX { ceiling = min(ceiling, Float(r.minY)) }
            }
            pile.visible[b] = !hidden
            pile.cap[b] = max(ceiling - edgeY - pile.base[b], 0)
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
                    if k >= 0, k < prev.pile.heights.count { h = prev.pile.heights[k]; wasVisible = prev.pile.visible[k]; shown[b] = eased ? prev.pile.shown[k] : h }
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
            if id == 0 {   // Dock bar resizes when apps come and go: keep snow by global column
                carry(shift: 0)
            } else if sameSize, shift == 0, abs(d.y) < 0.5, prev.pile.heights.count == pile.heights.count {
                var kept = prev.pile
                kept.visible = pile.visible
                kept.cap = pile.cap
                kept.base = pile.base; kept.boost = pile.boost; kept.walls = pile.walls
                kept.supportL = pile.supportL; kept.supportR = pile.supportR
                for b in kept.heights.indices where pile.visible[b] {   // hidden bins stay frozen; uncovered ones shed what no longer fits
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
        else if let e = stash.removeValue(forKey: id), clock - e.stamp < 1800, e.heights.count == pile.heights.count {   // back from another Space: same width, same snow
            for b in pile.heights.indices { pile.heights[b] = pile.visible[b] ? min(e.heights[b], pile.limit(b)) : e.heights[b] }
            pile.shown = pile.heights
            if var ice = e.ice {   // frost and icicles come back with the snow (stalactites regrow from the next frost step)
                ice.w0 = Float(frame.width); ice.h0 = Float(frame.height)
                if ice.frozen { ice.frozen = false; ice.acc = Tuning.frozenAfter }
                iceWin.removeAll { $0.id == id }; iceWin.append(ice)
            }
        }
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

    /// Cursor wipe: snow within `radius` of the segment a->b (local coords) above the cursor's lower edge is pushed off
    /// as debris flying along the cursor's motion (`dt` = time the move took). The dragged window's pile is left alone.
    public func sweep(from a: CGPoint, to b: CGPoint, radius: Float = 10, dt: Float = 1.0 / 60) {
        let ax = Float(a.x), ay = Float(a.y), dx = Float(b.x) - ax, dy = Float(b.y) - ay
        let len2 = dx * dx + dy * dy, r = radius
        guard len2 > 0, dt > 0 else { return }
        let v = (SIMD2(dx, dy) / dt).limited()
        let lo = min(ay, ay + dy) - r, hi = max(ay, ay + dy) + r
        let first = debris.count
        let speed = len2.squareRoot() / dt, share = min(len2.squareRoot() / (1.33 * r), 1)
        let depth = min(max(speed / 150, 0.6), 6)   // total dent depth of a pass (pt): a slow brush barely marks, a fast swipe cuts
        var owed: Float = 0, cx: Float = 0, cy: Float = 0, sum: Float = 0
        sweepFigures(ax, ay, Float(b.x), Float(b.y), r, v)
        breakBalls(ax, ay, Float(b.x), Float(b.y), r, v)
        breakGifts(ax, ay, Float(b.x), Float(b.y), r, v)
        breakIcicles(ax, ay, Float(b.x), Float(b.y), r, v)
        defer { flushRuns(); for j in first..<debris.count { debris[j].phase = 0.5 } }
        for si in surfaces.indices where surfaces[si].id != draggingID {
            let c = surfaces[si].c0, edgeY = surfaces[si].edgeY   // no `let s = surfaces[si]`: a live copy would force a copy of the heights on write
            guard hi >= edgeY - Tuning.maxPileHeight, lo <= edgeY + Tuning.maxPileHeight else { continue }
            let b0 = max(0, Int((min(ax, ax + dx) - r) * invBin) - c), b1 = min(surfaces[si].pile.heights.count - 1, Int((max(ax, ax + dx) + r) * invBin) - c)
            guard b0 <= b1 else { continue }
            var removed: Float = 0, wx: Float = 0, wy: Float = 0
            for k in b0...b1 {
                let h = surfaces[si].pile.heights[k]
                guard h > 0.5, surfaces[si].pile.visible[k] else { continue }
                let x = binCenter(c + k), bottom = edgeY + surfaces[si].pile.base[k], my = bottom + h / 2
                let t = min(max(((x - ax) * dx + (my - ay) * dy) / len2, 0), 1)
                let qx = ax + t * dx, qy = ay + t * dy
                guard abs(qx - x) <= r, abs(qy - my) <= r + h / 2 else { continue }
                let u = (x - qx) / r
                // Mostly horizontal path: integrate the parabola along it, so a bin's total over a pass is the same however the frames sample it (smooth dent).
                let cover: Float
                if abs(dx) >= abs(dy) {
                    let p0 = min(max(ax - x, -r), r), p1 = min(max(ax + dx - x, -r), r)
                    cover = abs((p1 - p0) - (p1 * p1 * p1 - p0 * p0 * p0) / (3 * r * r)) / (1.3333 * r)
                } else { cover = (1 - u * u) * share }
                let keep = min(max(qy - r - bottom, 0), h)   // snow below the cursor's lower edge stays
                let dh = min(depth * cover, h - keep)   // soft parabolic dent: nothing pops, the edges stay round
                guard dh > 0.01 else { continue }
                surfaces[si].pile.heights[k] = h - dh
                pilesDirty = true
                let a = dh * Tuning.binWidth
                removed += a; wx += x * a; wy += (bottom + h) * a
            }
            if removed > 0 {
                let banked = berm(si, atX: (dx > 0 ? max(ax, ax + dx) + r : min(ax, ax + dx) - r), dir: dx > 0 ? 1 : -1, area: 0.12 * removed)
                owed += removed - banked; cx += wx; cy += wy; sum += removed
            }
        }
        guard sum > 0, !calm, !silent else { return }
        sweepOwed = min(sweepOwed + owed, 600)
        launchSweepDebris(x: cx / sum, y: cy / sum, v: v, speed: speed, r: r)
    }

    /// Banks `area` (pt^2) on the four bins ahead of global x in direction `dir` (the lip ahead of the cursor, tapering off), capped by the pile limit.
    /// Returns the area actually banked.
    func berm(_ si: Int, atX x: Float, dir: Int, area: Float) -> Float {
        var banked: Float = 0
        for (n, w) in [Float(0.15), 0.35, 0.35, 0.15].enumerated() {
            let k = Int(x * invBin) - surfaces[si].c0 + dir * (n + 1)
            guard k >= 0, k < surfaces[si].pile.heights.count, surfaces[si].pile.visible[k] else { continue }
            let h = surfaces[si].pile.heights[k], lim = max(surfaces[si].pile.limit(k), h)
            let nh = min(h + w * area / Tuning.binWidth, lim)
            surfaces[si].pile.heights[k] = nh; banked += (nh - h) * Tuning.binWidth
        }
        return banked
    }

    /// Turns the owed volume into debris launched along the cursor: fine powder plus a few clumps (fast), or a gentle sift (slow hover).
    /// Each carries its own volume (`vol`), so what leaves the pile lands again.
    func launchSweepDebris(x: Float, y: Float, v: SIMD2<Float>, speed: Float, r: Float) {
        let fast = speed > 120, dir: Float = v.x >= 0 ? 1 : -1
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
        if fast, Float.random(in: 0..<1, using: &rng) < 0.25 { addPuff(x: x, y: y + 3) }
        if fast, Float.random(in: 0..<1, using: &rng) < 0.08, !economy, !lowPower, glints.count < Tuning.maxGlints {   // fresh crest catches the light
            glints.append(Flake(pos: [x, y], vx: 0, fall: 0, phase: 0, amp: 0, freq: 0, size: Float.random(in: 4...6, using: &rng), alpha: 1, kind: .debris,
                                seed: Float.random(in: 0..<1, using: &rng), fade: 1, delay: Tuning.glintLife, shape: 4))
        }
    }

    /// A vanished surface's pile falls as a few intact blocks (`dropBlocks`), not as a spray: each run of snow is cut into ~60pt slabs.
    func knockOff(_ s: Surface, velocity v: SIMD2<Float> = .zero) -> Int {
        guard !silent else { return 0 }
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
