import CoreGraphics
import Foundation

extension SnowField {
    /// One flake lands on a surface (also the test entry point for building piles without simulating snowfall).
    func deposit(surface: Int, bin: Int, volume: Float) {
        if surfaces[surface].pile.deposit(bin: bin, volume: volume) { pilesDirty = true }
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
    public func update(windows: [WindowInfo], dt: Float = Tuning.shedRefDt) -> Int {
        // `dt` = time since the last *change* (the caller measures it): identical lists must not shrink it, or velocity is overestimated.
        pollDt = dt
        guard windows != lastWindows || boundsDirty else {
            if draggingID != nil { draggingID = nil; pilesDirty = true }
            for i in surfaces.indices { surfaces[i].vel = .zero }
            return 0
        }
        boundsDirty = false
        lastWindows = windows
        return updateSurfaces(windows: windows)
    }

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
    func updateSurfaces(windows: [WindowInfo]) -> Int {
        let ox = origin.x, oy = origin.y
        var rects: [CGRect] = []
        rects.reserveCapacity(windows.count)
        for w in windows { rects.append(w.frame.offsetBy(dx: -ox, dy: -oy)) }

        seams = computeSeams(rects: rects, windows: windows)
        let before = surfaces
        var old = before
        var built: [Surface] = []
        var spawned = 0
        moved = nil
        for (i, r) in rects.enumerated() {
            let id = windows[i].number, edge = Float(r.maxY)
            // Dock bar (id 0) sits below the visible frame's bottom; hidden/offscreen Dock has minY < 0.
            let lowOk = id == 0 ? r.minY >= -1 : edge > groundY
            guard lowOk, visibleTop - edge >= Tuning.minHeadroom, r.maxX > 0, r.minX < CGFloat(size.x) else { continue }
            if let s = buildSurface(id: id, frame: r, edgeY: edge, radius: windows[i].radius, rects: rects, front: i, old: &old, spawned: &spawned) { built.append(s) }
            spawned += flushRuns()   // runs never span two surfaces
        }
        if let g = buildGround(rects: rects, windows: windows, old: &old, spawned: &spawned) { built.append(g) }   // behind everything: every window and the Dock hide it
        spawned += flushRuns()
        for s in old { spawned += knockOff(s) }   // gone surfaces
        draggingID = moved
        for i in built.indices { built[i].runs = built[i].pile.visibleRuns() }
        surfaces = built
        index.removeAll(keepingCapacity: true)
        for (i, s) in surfaces.enumerated() { index[s.id] = i }
        buildColumns()
        transportBalls(before: before)
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
            for r in docks { pile.splits.insert(Int(Float(r.minX) / bw)); pile.splits.insert(Int(Float(r.maxX) / bw)) }
            pile.maxes = (0..<numCols).map { b in
                let x = Float(b) + 0.5, cx = x * bw
                var m = Tuning.groundMaxHeight
                for r in docks {
                    let d = max(Float(r.minX) - cx, cx - Float(r.maxX), 0)
                    m = max(m, min(Float(r.maxY) - Tuning.bankSlope * d, groundY))
                }
                return m
            }
        }
        for b in 0..<numCols {
            let x = CGFloat((Float(b) + 0.5) * bw)
            var ceiling = Float.infinity
            for (i, r) in rects.enumerated() {
                // The floating Dock bar hovers a few points above the screen bottom: it still hides the ground under it.
                if windows[i].number == 0 {   // Dock bar: snow may flow under it, up to its bottom edge (the overlay sits above the Dock)
                    if r.maxY > 1, x >= r.minX, x < r.maxX { ceiling = min(ceiling, max(Float(r.minY), 0)) }
                    continue
                }
                if r.contains(CGPoint(x: x, y: 1)) { pile.visible[b] = false; break }
                if r.minY > 1, x >= r.minX, x < r.maxX { ceiling = min(ceiling, Float(r.minY)) }
            }
            pile.cap[b] = ceiling
        }
        if let k = old.firstIndex(where: { $0.id == Tuning.groundID }) {
            let prev = old.swapRemove(k)
            for b in 0..<numCols {   // a lowered limit (Dock shrank / moved) sheds the excess as debris; hidden columns keep their snow
                let keep = pile.visible[b] ? min(prev.pile.heights[b], pile.limit(b)) : prev.pile.heights[b], over = prev.pile.heights[b] - keep   // hidden snow stays as it was
                if over > 0.5 { spawned += shedBin(col: b, edgeY: 0, from: keep, amount: over, velocity: .zero) }
                pile.heights[b] = keep
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
            let shift = anchor - prev.anchor
            func carry(shift: Int) {   // heights by global column; hidden bins travel too (frozen), visible ones are clipped to the limit
                for b in pile.heights.indices {
                    let k = c0 + b - shift - prev.c0
                    guard k >= 0, k < prev.pile.heights.count else { continue }
                    let h = prev.pile.heights[k]
                    guard pile.visible[b] else { pile.heights[b] = h; continue }
                    let keep = min(h, pile.limit(b))
                    pile.heights[b] = keep
                    if !prev.pile.visible[k] { spawned += shedBin(col: c0 + b, edgeY: edgeY + pile.base[b], from: keep, amount: h - keep, velocity: .zero) }   // uncovered: the excess falls
                }
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
                pile = kept
            } else if sameSize {   // moved: the pile travels with the window; a speed-dependent share falls off
                // Smooth over ~100 ms: at frame-rate updates raw d/dt is noisy; at the old 0.1-0.5 s polls this is ~raw.
                let a = exp(-pollDt / Tuning.velSmoothing)
                vel = prev.vel * a + d / pollDt * (1 - a)
                if moved == nil { moved = id }
                carry(shift: shift)
                spawned += shed(&pile, c0: c0, edgeY: edgeY, frame: frame, fraction: SnowField.perUpdate(SnowField.shedFraction(v: vel, prev: prev.vel), dt: pollDt), velocity: vel)
            } else {   // resized: snow stays where it is in x; the part no longer over the window falls
                carry(shift: 0)
                let v = (d / pollDt).limited()
                for k in prev.pile.heights.indices where prev.pile.visible[k] {
                    let col = prev.c0 + k
                    if col < c0 || col >= c1 { spawned += shedBin(col: col, edgeY: prev.edgeY + prev.pile.base[k], from: 0, amount: prev.pile.heights[k], velocity: v) }
                }
            }
        }
        return Surface(id: id, frame: frame, edgeY: edgeY, c0: c0, anchor: anchor, pile: pile, vel: vel)
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
        sweepFigures(ax, ay, Float(b.x), Float(b.y), r, v)
        breakBalls(ax, ay, Float(b.x), Float(b.y), r, v)
        defer { flushRuns(); for j in first..<debris.count { debris[j].phase = 0.5 } }
        for si in surfaces.indices where surfaces[si].id != draggingID {
            let c = surfaces[si].c0, edgeY = surfaces[si].edgeY   // no `let s = surfaces[si]`: a live copy would force a copy of the heights on write
            guard hi >= edgeY - Tuning.maxPileHeight, lo <= edgeY + Tuning.maxPileHeight else { continue }
            let b0 = max(0, Int((min(ax, ax + dx) - r) * invBin) - c), b1 = min(surfaces[si].pile.heights.count - 1, Int((max(ax, ax + dx) + r) * invBin) - c)
            guard b0 <= b1 else { continue }
            for k in b0...b1 {
                let h = surfaces[si].pile.heights[k]
                guard h > 0.5, surfaces[si].pile.visible[k] else { continue }
                let x = binCenter(c + k), bottom = edgeY + surfaces[si].pile.base[k], my = bottom + h / 2
                let t = min(max(((x - ax) * dx + (my - ay) * dy) / len2, 0), 1)
                let qx = ax + t * dx, qy = ay + t * dy
                guard abs(qx - x) <= r, abs(qy - my) <= r + h / 2 else { continue }
                let keep = min(max(qy - r - bottom, 0), h)
                guard keep < h else { continue }
                surfaces[si].pile.heights[k] = keep
                _ = shedBin(col: c + k, edgeY: bottom, from: keep, amount: h - keep, velocity: v)
            }
        }
    }

    /// Turns a whole pile into falling debris, inheriting some of the surface's motion.
    func knockOff(_ s: Surface, velocity v: SIMD2<Float> = .zero) -> Int {
        var n = 0
        for (b, h) in s.pile.heights.enumerated() where s.pile.visible[b] { n += shedBin(col: s.c0 + b, edgeY: s.edgeY + s.pile.base[b], from: 0, amount: h, velocity: v) }
        return n + flushRuns()
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
