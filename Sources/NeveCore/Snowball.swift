// AGENT HEADER - Sources/NeveCore/Snowball.swift  (user snowballs: scoop, roll, drop, stack into snowmen)
// Covered balls: `hitTest` and `pickSnowball` skip a ball whose column is not `openAt` (under a window in front), like gifts, the tree, figures and piles.
// Origin z: `pop` stamps its debris with the ball's surface z (`originZ(id:)`, Debris.swift).
// Role: `Snowball` (id, state held / falling / resting, pos, radius, parent link for stacks, vel, spin, face for a loose head, melting, fade, surfaceID) in `SnowField.balls`, and the interaction API the overlay calls while Option is held:
//   `hitTest(point:)` (over a ball, figure, gift, the tree or visible, uncovered snow (window piles from their top edge up; covered pile / gift / tree / figure ignored via `openAt`) => the panel becomes interactive), `pickSnowball(at:)` (nearest ball with nothing on top; also the top of a stacked / headless snowman, which `demote`s into balls),
//   `scoop(at:)` (needs half a ballStart-radius disc of snow within +-8 columns, takes at most half of each column; radius Tuning.ballStart 5; above Tuning.maxBalls 6 the oldest free ball melts away), `drag(_:to:dt:)` (on a surface the ball
//   rides on top, rolls, and grows by ballGrowth 0.1 per pt up to ballMax 20 by carving a groove with Pile.carve; velocity smoothed over 60 ms), `drop(_:throwing:)` (throw velocity capped at 600 pt/s; throwing: false = just let go).
// Simulation `stepBalls` (in SnowField.step): fall (gravity, side walls; lands on a resting ball of a different stack = stacks if radius <= below and |dx| <= 0.4 r and depth < 3, else slides off; hits figures via `hitFigures`, where a head that
//   fits re-attaches to a headless body; else lands on the drawn snow via `supportTop` + standY), rest (follows the drawn pile, rolls aside when it does not fit under a low window), `follow` (stack children), promotion of three decreasing
//   balls to a user `Figure` (Figures.swift `promote`), melt fade, `transportBalls` (window moved: x shift, or knocked off), `breakBalls` / `pop` (cursor sweep breaks a ball into debris). `supportTop` is also used by gifts and penguins (the tree has its own `treeSupport`, Tree.swift; `hitTest` also covers the tree).
// `stepCovered` (called from SnowField.step) eases the draw-only `hide` of balls / gifts / the tree to 0 while their column is not `visible` (a window in front, even when only `held`); `writeBallPrims` draws with fade * hide.
// Coordinates: local AppKit pt, y up. Balls on a dragged window ride with the drag (Overlay.writePrims shift). Tests: SnowballTests, SnowmanTests, SpaceCarryTests.

import CoreGraphics
import Foundation

/// A loose snowball the user scooped from a pile, rolled and dropped (or a head knocked off). A stack of three
/// decreasing balls stands up as a `Figure` (see Figures.swift). Pure state: rendering reads it.
public struct Snowball: Equatable {
    public enum State: Equatable { case held, falling, resting }
    public let id: Int
    public internal(set) var pos: SIMD2<Float>          // centre, local coords (y up)
    public internal(set) var radius: Float
    public internal(set) var rotation: Float = 0        // radians, for the rolling speckles
    public internal(set) var state = State.held
    public internal(set) var surfaceID: Int?            // surface it rests on (a stacked ball inherits its parent's)
    public internal(set) var parent: Int?               // ball it sits on
    public internal(set) var face: Float = 0            // a loose head: ±1 = draws its face (facing), 0 = plain ball
    public internal(set) var fade: Float = 1            // 1 -> 0 while melting away
    public internal(set) var hide: Float = 1            // drawing only: 1 -> 0 (0.2 s) while a window brought to front covers its surface (SnowField.stepCovered); physics ignores it
    var vel: SIMD2<Float> = .zero
    var spin: Float = 0                                 // rad/s of a flying head; keeps turning (decaying) after it lands
    var melting = false
}

extension SnowField {

    private func index(of id: Int) -> Int? { balls.firstIndex { $0.id == id } }

    private func rootIndex(_ i: Int) -> Int {
        var i = i
        while let p = balls[i].parent, let j = index(of: p) { i = j }
        return i
    }

    private func depth(_ i: Int) -> Int {
        var n = 1, i = i
        while let p = balls[i].parent, let j = index(of: p) { n += 1; i = j }
        return n
    }

    private func hasChild(_ i: Int) -> Bool { balls.contains { $0.parent == balls[i].id } }

    /// Highest surface top under x whose base is at or below `fromY`: (surface, local column, top y).
    func supportTop(x: Float, fromY: Float) -> (Int, Int, Float)? {
        let c = column(x)
        var best: (Int, Int, Float)?
        for k in Int(offsets[c])..<Int(offsets[c + 1]) {
            let e = entries[k], s = Int(e.surface), lc = c - surfaces[s].c0
            guard landable(s), surfaces[s].pile.open(lc) else { continue }   // never on a covered bin or a stale window (as tryLand / treeSupport)
            let top = e.edgeY + surfaces[s].pile.heights[lc]
            if fromY >= e.edgeY, top > (best?.2 ?? -.infinity) { best = (s, lc, top) }
        }
        return best
    }

    /// Takes up to `area` of snow from the columns around `c` (at most half of each); 0 when less than `minimum` is within reach.
    @discardableResult
    private func takeSnow(_ si: Int, column c: Int, area: Float, minimum: Float = 0) -> Float {
        let p = surfaces[si].pile, lo = max(0, c - 8), hi = min(p.heights.count - 1, c + 8)
        var avail: Float = 0
        for i in lo...hi where p.visible[i] { avail += p.heights[i] * 0.5 * Tuning.binWidth }
        guard avail > 0.01, avail >= minimum else { return 0 }
        let q = min(1, area / avail) * 0.5
        for i in lo...hi where p.visible[i] { surfaces[si].pile.heights[i] -= p.heights[i] * q }
        pilesDirty = true
        return avail * q * 2
    }

    // MARK: API

    /// Whether a point is over a snowball or on / just above visible snow (where the overlay becomes interactive).
    public func hitTest(point p: CGPoint) -> Bool {
        let q = SIMD2(Float(p.x), Float(p.y))
        for b in balls where !b.melting && b.state != .held && openAt(surface: b.surfaceID, x: b.pos.x) {
            let d = q - b.pos
            if d.x * d.x + d.y * d.y <= (b.radius + 4) * (b.radius + 4) { return true }
        }
        return overFigure(q) || giftUnder(q) != nil || treeUnder(q) || pileUnder(q) != nil
    }

    /// Whether the snow column under global x of surface `sid` is open (visible, not under a window); true for no surface (airborne) or an unknown one.
    func openAt(surface sid: Int?, x: Float) -> Bool {
        guard let sid, let si = index[sid] else { return true }
        let lc = column(x) - surfaces[si].c0
        return lc < 0 || lc >= surfaces[si].pile.heights.count || surfaces[si].pile.open(lc)
    }

    /// Whether the column under global x of surface `sid` is DRAWN (`visible`, so false under a window merely brought to front, where `alive` stays true for physics); true for no surface or an unknown one.
    func shownAt(surface sid: Int?, x: Float) -> Bool {
        guard let sid, let si = index[sid] else { return true }
        let lc = column(x) - surfaces[si].c0
        return lc < 0 || lc >= surfaces[si].pile.visible.count || surfaces[si].pile.visible[lc]
    }

    /// Eases the draw-only `hide` of balls, gifts and the tree toward 0 while their column is covered by a window in front (0.2 s, like the snowman's); nothing physical changes.
    func stepCovered(dt: Float) {
        func ease(_ h: inout Float, _ shown: Bool) { h = shown ? min(1, h + dt / 0.2) : max(0, h - dt / 0.2) }
        for i in balls.indices { ease(&balls[i].hide, shownAt(surface: balls[i].surfaceID, x: balls[i].pos.x)) }
        for i in giftState.gifts.indices { ease(&giftState.gifts[i].hide, shownAt(surface: giftState.gifts[i].surface, x: giftState.gifts[i].pos.x)) }
        if tree != nil { ease(&tree!.hide, shownAt(surface: tree!.surface, x: tree!.pos.x)) }
    }

    /// Loose balls (drawn only where their column shows).
    public func writeBallPrims(_ w: inout PrimWriter, contrast: Bool = false, shift: (Int?) -> SIMD2<Float>) {
        for b in balls where b.hide > 0.001 {
            Rig.ball(center: b.pos + shift(b.surfaceID), radius: b.radius, rotation: b.rotation, fade: b.fade * b.hide, squash: 0, contrast: contrast,
                     face: b.face != 0, facing: b.face == 0 ? 1 : b.face, into: &w)
        }
    }

    private func pileUnder(_ q: SIMD2<Float>) -> (Int, Int)? {
        let c = column(q.x)
        var best: (Int, Int, Float)?
        for k in Int(offsets[c])..<Int(offsets[c + 1]) {
            let e = entries[k], s = Int(e.surface), lc = c - surfaces[s].c0
            let h = surfaces[s].pile.heights[lc], top = e.edgeY + h
            guard surfaces[s].pile.open(lc) else { continue }   // covered snow is not grabbable
            if h >= 1.5, q.y >= e.edgeY - (surfaces[s].id > 0 ? 0 : 4), q.y <= top + 10, top > (best?.2 ?? -.infinity) { best = (s, lc, top) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Grabs the loose ball under the point (the nearest one with nothing on top of it); it is then held. The head of a
    /// stacked snowman (or the top of a headless one) works too: the figure turns back into balls and that ball is held.
    public func pickSnowball(at p: CGPoint) -> Int? {
        let q = SIMD2(Float(p.x), Float(p.y))
        var best: Int?, bestD = Float.infinity
        for i in balls.indices where !balls[i].melting && balls[i].state != .held && !hasChild(i) && openAt(surface: balls[i].surfaceID, x: balls[i].pos.x) {
            let d = q - balls[i].pos, d2 = d.x * d.x + d.y * d.y, r = balls[i].radius + 4
            if d2 <= r * r, d2 < bestD { best = i; bestD = d2 }
        }
        if let (j, d2) = figureTop(at: q, slack: 4), d2 < bestD, let ids = demote(figures[j].id), let k = index(of: ids.top) { best = k }
        guard let i = best else { return nil }
        balls[i].state = .held; balls[i].parent = nil; balls[i].surfaceID = nil; balls[i].vel = .zero; balls[i].spin = 0
        return balls[i].id
    }

    /// Scoops a small ball out of the pile under the point; nil when there is no snow there.
    public func scoop(at p: CGPoint) -> Int? {
        let q = SIMD2(Float(p.x), Float(p.y)), area = Float.pi * Tuning.ballStart * Tuning.ballStart
        guard let (si, c) = pileUnder(q), takeSnow(si, column: c, area: area, minimum: area * 0.5) > 0 else { return nil }
        let b = Snowball(id: nextBallID, pos: q, radius: Tuning.ballStart, surfaceID: nil)
        nextBallID += 1
        balls.append(b)
        var live = 0
        for x in balls where !x.melting { live += 1 }
        if live > Tuning.maxBalls, let k = balls.firstIndex(where: { !$0.melting && $0.state != .held }) { balls[k].melting = true }
        return b.id
    }

    /// Moves a held ball to `p`. Along a surface it rides on top, rolls (spins) and grows by taking snow from the pile; in the air it is carried.
    public func drag(_ id: Int, to p: CGPoint, dt: Float) {
        guard let i = index(of: id), balls[i].state == .held else { return }
        var b = balls[i]
        let q = SIMD2(Float(p.x), Float(p.y)), dx = q.x - b.pos.x
        if let (si, c, top) = supportTop(x: q.x, fromY: q.y), q.y <= top + b.radius + 6 {
            b.pos = SIMD2(q.x, top + b.radius * SnowField.sink)
            b.rotation -= dx / b.radius
            if abs(dx) > 0, b.radius < Tuning.ballMax {
                let r = b.radius, r2 = min(r + abs(dx) * Tuning.ballGrowth, Tuning.ballMax)
                // A groove as wide as the ball's footprint: parabola area 4/3 w depth = what the ball grows by, never below 0.5 pt of snow.
                let w = r * 0.6, need = Float.pi * (r2 * r2 - r * r), h = surfaces[si].pile.heights[c]
                let depth = min(need / (4 / 3 * w), max(h - 0.5, 0))
                if depth > 0.01 {
                    let got = surfaces[si].pile.carve(centerX: q.x, halfWidth: w, depth: depth, berm: 0.15)
                    pilesDirty = true
                    b.radius = (r * r + got / .pi).squareRoot()
                }
            }
        } else {
            b.pos = q
        }
        if dt > 0 { b.vel += ((b.pos - balls[i].pos) / dt - b.vel) * (1 - exp(-dt / 0.06)) }   // time-constant smoothing (60 ms): the throw does not depend on the mouse event rate
        balls[i] = b
    }

    /// Lets go: the ball falls (with the throw velocity) and lands on a surface or another ball.
    public func drop(_ id: Int, throwing: Bool = true) {
        guard let i = index(of: id), balls[i].state == .held else { return }
        balls[i].state = .falling
        balls[i].vel = (throwing ? balls[i].vel : .zero).limited(600)
    }

    // MARK: Simulation

    func stepBalls(dt: Float) {
        guard !balls.isEmpty else { return }
        for i in balls.indices where balls[i].state == .falling { fall(i, dt) }
        for i in balls.indices where balls[i].state == .resting && balls[i].parent == nil { rest(i, dt) }
        for i in balls.indices where balls[i].spin != 0 && balls[i].state == .resting {   // a landed head keeps turning, then lies crooked
            balls[i].rotation += balls[i].spin * dt
            balls[i].spin *= exp(-4 * dt)
            if abs(balls[i].spin) < 0.2 { balls[i].spin = 0 }
        }
        for _ in 0..<2 {   // stacks are at most 3 high: two passes settle children after parents
            for i in balls.indices where balls[i].state == .resting && balls[i].parent != nil { follow(i) }
        }
        if balls.count >= 3, canSpawnFigure {   // 3 decreasing balls = a snowman: it stands up as a figure
            for i in balls.indices where balls[i].parent == nil && balls[i].state == .resting {
                if promote(bottomBall: balls[i].id) != nil { break }
            }
        }
        var gone = false
        for i in balls.indices where balls[i].melting {
            balls[i].fade -= dt * fadeK / 0.6
            if balls[i].fade <= 0 { gone = true }
        }
        if gone { balls.removeAll { $0.fade <= 0 } }
    }

    private func setFalling(_ i: Int, _ v: SIMD2<Float>) {
        balls[i].state = .falling; balls[i].surfaceID = nil; balls[i].parent = nil; balls[i].vel = v
    }

    /// On a surface: follows the pile top; falls when that column is no longer visible snow ground.
    private func rest(_ i: Int, _ dt: Float) {
        guard let sid = balls[i].surfaceID, let si = index[sid] else { setFalling(i, .zero); return }
        let s = surfaces[si], c = column(balls[i].pos.x) - s.c0
        guard c >= 0, c < s.pile.heights.count, s.pile.alive(c) else { setFalling(i, .zero); return }
        let need = balls[i].radius * (1 + SnowField.sink), span = Int((balls[i].radius / Tuning.binWidth).rounded(.up))
        // Room over the ball's whole width (the ceiling under a window's rounded corner is not flat: the centre column alone overstates it).
        func room(_ k: Int) -> Float {
            var m = Float.infinity
            for j in max(0, k - span)...min(s.pile.heights.count - 1, k + span) { m = min(m, s.pile.cap[j] - s.pile.heights[j]) }
            return m
        }
        if room(c) < need {   // too big to fit under the Dock bar / a low window: rolls to the nearest column where it fits
            var d = 1, dir: Float = 0
            while dir == 0, c - d >= 0 || c + d < s.pile.heights.count {
                if c - d >= 0, s.pile.alive(c - d), room(c - d) >= need { dir = -1 }
                else if c + d < s.pile.heights.count, s.pile.alive(c + d), room(c + d) >= need { dir = 1 }
                d += 1
            }
            if dir != 0 { balls[i].pos.x += dir * 90 * dt; balls[i].rotation += dir * 90 * dt / balls[i].radius }
        }
        let y = standY(si: si, x: balls[i].pos.x) + balls[i].radius * SnowField.sink   // the drawn snow, like the figures
        if abs(y - balls[i].pos.y) > 0.01 { balls[i].pos.y = y }
    }

    private func follow(_ i: Int) {
        guard let p = balls[i].parent, let j = index(of: p) else { setFalling(i, .zero); return }
        let pos = SIMD2(balls[j].pos.x, balls[j].pos.y + balls[j].radius + balls[i].radius - SnowField.stackOverlap)
        if pos != balls[i].pos || balls[i].surfaceID != balls[j].surfaceID { balls[i].pos = pos; balls[i].surfaceID = balls[j].surfaceID }
    }

    private func fall(_ i: Int, _ dt: Float) {
        var b = balls[i]
        let prev = b.pos, root = rootIndex(i)
        b.vel.y = max(b.vel.y - Tuning.debrisGravity * 0.8 * dt, -1300)
        b.vel.x -= b.vel.x * 1.5 * dt
        b.pos += b.vel * dt
        if b.spin != 0 { b.rotation += b.spin * dt } else { b.rotation -= b.vel.x / b.radius * dt }
        if b.pos.x < b.radius { b.pos.x = b.radius; b.vel.x = abs(b.vel.x) * 0.3 }
        if b.pos.x > size.x - b.radius { b.pos.x = size.x - b.radius; b.vel.x = -abs(b.vel.x) * 0.3 }
        var landed = false
        for j in balls.indices where j != i && balls[j].state == .resting && rootIndex(j) != root && !balls[j].melting {
            let o = balls[j], d = b.pos - o.pos, minD = b.radius + o.radius
            let dist = (d.x * d.x + d.y * d.y).squareRoot()
            guard dist < minD * 0.98, d.y > -o.radius * 0.2 else { continue }
            if b.radius <= o.radius + 0.01, abs(d.x) <= 0.4 * o.radius, !hasChild(j), depth(j) < 3 {   // stacks
                b.state = .resting; b.parent = o.id; b.surfaceID = o.surfaceID; b.vel = .zero
                b.pos = SIMD2(o.pos.x, o.pos.y + o.radius + b.radius - SnowField.stackOverlap)
            } else {   // slides off the side
                let n = dist > 1e-3 ? d / dist : SIMD2<Float>(1, 0)
                b.pos = o.pos + n * minD
                b.vel = SIMD2((n.x >= 0 ? 1 : -1) * max(abs(b.vel.x), 70), min(b.vel.y, 0) * 0.2)
            }
            landed = true
            break
        }
        if !landed, hitFigures(&b) { landed = true; if b.melting { balls[i] = b; return } }
        if !landed, let (si, _, _) = supportTop(x: b.pos.x, fromY: prev.y),
           case let rest = standY(si: si, x: b.pos.x) + b.radius * SnowField.sink, b.pos.y <= rest {   // contact test and resting height are the same drawn-snow function
            b.pos.y = rest   // lands on the drawn snow: no hop when `rest` takes over
            b.state = .resting; b.surfaceID = surfaces[si].id; b.vel = .zero
        }
        if b.pos.y < -b.radius * 2 { balls[i].melting = true; balls[i].fade = 0; balls[i].state = .falling; return }
        balls[i] = b
    }

    /// A falling ball against the standing figures: a head that fits lands back on a headless body (and is used up),
    /// anything else slides off the side. True when it touched one.
    private func hitFigures(_ b: inout Snowball) -> Bool {
        for j in figures.indices where figures[j].phase != .hidden && figures[j].phase != .collapsing {
            let f = figures[j], a = anchors(of: f)
            for k in 0..<ballCount(f) {
                let (c, r) = circle(a, f, k), d = b.pos - c, minD = b.radius + r
                let dist = (d.x * d.x + d.y * d.y).squareRoot()
                guard dist < minD * 0.98, d.y > -r * 0.2 else { continue }
                if f.headless, k == 1, b.radius <= r + 0.01, abs(d.x) <= 0.4 * r {
                    reattach(j, radius: b.radius, tilt: b.rotation)
                    b.melting = true; b.fade = 0; b.state = .resting   // used up: removed at the end of this step
                } else {
                    let n = dist > 1e-3 ? d / dist : SIMD2<Float>(1, 0)
                    b.pos = c + n * minD
                    b.vel = SIMD2((n.x >= 0 ? 1 : -1) * max(abs(b.vel.x), 70), min(b.vel.y, 0) * 0.2)
                }
                return true
            }
        }
        return false
    }

    /// Windows moved / closed: balls on them travel along (x shift) or are knocked off, same rules as piles.
    func transportBalls(before: [Surface]) {
        guard !balls.isEmpty else { return }
        for i in balls.indices where balls[i].state == .resting && balls[i].parent == nil {
            guard let sid = balls[i].surfaceID, sid != Tuning.groundID, sid != 0 else { continue }
            guard let ni = index[sid], let o = before.first(where: { $0.id == sid }) else { setFalling(i, .zero); continue }
            let n = surfaces[ni]
            if SnowField.shedFraction(v: n.vel, prev: o.vel) > 0.5 { setFalling(i, n.vel * 0.5); continue }
            let dx = Float(n.frame.minX - o.frame.minX)
            if dx != 0 { balls[i].pos.x += dx }
        }
    }

    /// Cursor segment a->b through a loose ball breaks it into debris chunks (a figure breaks whole, see `sweepFigures`).
    func breakBalls(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ r: Float, _ v: SIMD2<Float>) {
        guard !balls.isEmpty else { return }
        let dx = bx - ax, dy = by - ay, len2 = max(dx * dx + dy * dy, 1e-6)
        var i = balls.count - 1
        while i >= 0 {
            defer { i -= 1 }
            guard i < balls.count, balls[i].state != .held, !balls[i].melting else { continue }
            let c = balls[i].pos, t = min(max(((c.x - ax) * dx + (c.y - ay) * dy) / len2, 0), 1)
            let ex = ax + t * dx - c.x, ey = ay + t * dy - c.y
            guard ex * ex + ey * ey <= (r + balls[i].radius) * (r + balls[i].radius) else { continue }
            pop(i, v)
        }
    }

    func pop(_ i: Int, _ v: SIMD2<Float>) {
        let b = balls[i]
        if !silent {
            for _ in 0..<(Int(b.radius * 1.5) + 4) {
                let a = Float.random(in: 0..<(2 * .pi), using: &rng), d = b.radius * Float.random(in: 0...1, using: &rng).squareRoot()
                let ox = cos(a) * d, oy = sin(a) * d
                addDebris(x: b.pos.x + ox, y: b.pos.y + oy, vx: ox * 3 + v.x * 0.3 + Float.random(in: -10...10, using: &rng),
                          fall: Float.random(in: 0...40, using: &rng) - oy * 2 - v.y * 0.3, size: Float.random(in: 4...7, using: &rng), oz: originZ(id: b.surfaceID))
            }
        }
        balls.remove(at: i)
    }
}
