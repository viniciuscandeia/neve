import CoreGraphics
import Foundation

/// A snowball the user scooped from a pile, rolled and dropped. Pure state: rendering reads it.
public struct Snowball: Equatable {
    public enum State: Equatable { case held, falling, resting }
    public let id: Int
    public internal(set) var pos: SIMD2<Float>          // centre, local coords (y up)
    public internal(set) var radius: Float
    public internal(set) var rotation: Float = 0        // radians, for the rolling speckles
    public internal(set) var state = State.held
    public internal(set) var surfaceID: Int?            // surface it rests on (a stacked ball inherits its parent's)
    public internal(set) var parent: Int?               // ball it sits on
    public internal(set) var fade: Float = 1            // 1 -> 0 while melting away
    public internal(set) var snowmanAge: Float = -1     // bottom ball of a 3-stack: seconds since it became a snowman, capped at 1
    var vel: SIMD2<Float> = .zero
    var melting = false
}

extension SnowField {
    private static let sink: Float = 0.8   // a ball rests this share of its radius above the surface top
    private static let overlap: Float = 1.5

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
    private func supportTop(x: Float, fromY: Float) -> (Int, Int, Float)? {
        let c = column(x)
        var best: (Int, Int, Float)?
        for k in Int(offsets[c])..<Int(offsets[c + 1]) {
            let e = entries[k], s = Int(e.surface), lc = c - surfaces[s].c0
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
        for b in balls where !b.melting && b.state != .held {
            let d = q - b.pos
            if d.x * d.x + d.y * d.y <= (b.radius + 4) * (b.radius + 4) { return true }
        }
        return pileUnder(q) != nil
    }

    private func pileUnder(_ q: SIMD2<Float>) -> (Int, Int)? {
        let c = column(q.x)
        var best: (Int, Int, Float)?
        for k in Int(offsets[c])..<Int(offsets[c + 1]) {
            let e = entries[k], s = Int(e.surface), lc = c - surfaces[s].c0
            let h = surfaces[s].pile.heights[lc], top = e.edgeY + h
            if h >= 1.5, q.y >= e.edgeY - 4, q.y <= top + 10, top > (best?.2 ?? -.infinity) { best = (s, lc, top) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Grabs the loose ball under the point (the nearest one with nothing on top of it); it is then held.
    public func pickSnowball(at p: CGPoint) -> Int? {
        let q = SIMD2(Float(p.x), Float(p.y))
        var best: Int?, bestD = Float.infinity
        for i in balls.indices where !balls[i].melting && balls[i].state != .held && !hasChild(i) {
            let d = q - balls[i].pos, d2 = d.x * d.x + d.y * d.y, r = balls[i].radius + 4
            if d2 <= r * r, d2 < bestD { best = i; bestD = d2 }
        }
        guard let i = best else { return nil }
        balls[i].state = .held; balls[i].parent = nil; balls[i].surfaceID = nil; balls[i].vel = .zero
        balls[i].snowmanAge = -1
        ballsVersion &+= 1
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
        ballsVersion &+= 1
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
                let got = takeSnow(si, column: c, area: Float.pi * (r2 * r2 - r * r))
                b.radius = (r * r + got / .pi).squareRoot()
            }
        } else {
            b.pos = q
        }
        if dt > 0 { b.vel = b.vel * 0.5 + (b.pos - balls[i].pos) / dt * 0.5 }
        if b != balls[i] { balls[i] = b; ballsVersion &+= 1 }
    }

    /// Lets go: the ball falls (with the throw velocity) and lands on a surface or another ball.
    public func drop(_ id: Int, throwing: Bool = true) {
        guard let i = index(of: id), balls[i].state == .held else { return }
        balls[i].state = .falling
        balls[i].vel = (throwing ? balls[i].vel : .zero).limited(600)
        ballsVersion &+= 1
    }

    /// The middle and head of a snowman whose bottom ball is `bottom`.
    public func snowmanChain(of bottom: Snowball) -> (Snowball, Snowball)? {
        guard bottom.snowmanAge >= 0, let m = balls.first(where: { $0.parent == bottom.id }),
              let h = balls.first(where: { $0.parent == m.id }) else { return nil }
        return (m, h)
    }

    // MARK: Simulation

    func stepBalls(dt: Float) {
        guard !balls.isEmpty else { return }
        for i in balls.indices where balls[i].state == .falling { fall(i, dt) }
        for i in balls.indices where balls[i].state == .resting && balls[i].parent == nil { rest(i, dt) }
        for _ in 0..<2 {   // stacks are at most 3 high: two passes settle children after parents
            for i in balls.indices where balls[i].state == .resting && balls[i].parent != nil { follow(i) }
        }
        for i in balls.indices where balls[i].parent == nil {   // 3 decreasing balls = a snowman
            var b = balls[i]
            var formed = false
            if b.state == .resting, let m = balls.first(where: { $0.parent == b.id }), let h = balls.first(where: { $0.parent == m.id }) {
                formed = m.radius < b.radius - 0.5 && h.radius < m.radius - 0.5
            }
            b.snowmanAge = formed ? min(1, max(b.snowmanAge, 0) + dt) : -1
            if b != balls[i] { balls[i] = b; ballsVersion &+= 1 }
        }
        var gone = false
        for i in balls.indices where balls[i].melting {
            balls[i].fade -= dt / 0.6
            if balls[i].fade <= 0 { gone = true }
            ballsVersion &+= 1
        }
        if gone { balls.removeAll { $0.fade <= 0 } }
    }

    private func setFalling(_ i: Int, _ v: SIMD2<Float>) {
        balls[i].state = .falling; balls[i].surfaceID = nil; balls[i].parent = nil; balls[i].vel = v
        balls[i].snowmanAge = -1
        ballsVersion &+= 1
    }

    /// On a surface: follows the pile top; falls when that column is no longer visible snow ground.
    private func rest(_ i: Int, _ dt: Float) {
        guard let sid = balls[i].surfaceID, let si = surfaces.firstIndex(where: { $0.id == sid }) else { setFalling(i, .zero); return }
        let s = surfaces[si], c = column(balls[i].pos.x) - s.c0
        guard c >= 0, c < s.pile.heights.count, s.pile.visible[c] else { setFalling(i, .zero); return }
        var sum: Float = 0, n: Float = 0
        for k in max(0, c - 2)...min(s.pile.heights.count - 1, c + 2) { sum += s.pile.heights[k]; n += 1 }
        let y = s.edgeY + s.pile.base[c] + sum / n + balls[i].radius * SnowField.sink
        if abs(y - balls[i].pos.y) > 0.01 { balls[i].pos.y = y; ballsVersion &+= 1 }
    }

    private func follow(_ i: Int) {
        guard let p = balls[i].parent, let j = index(of: p) else { setFalling(i, .zero); return }
        let pos = SIMD2(balls[j].pos.x, balls[j].pos.y + balls[j].radius + balls[i].radius - SnowField.overlap)
        if pos != balls[i].pos || balls[i].surfaceID != balls[j].surfaceID { balls[i].pos = pos; balls[i].surfaceID = balls[j].surfaceID; ballsVersion &+= 1 }
    }

    private func fall(_ i: Int, _ dt: Float) {
        var b = balls[i]
        let prev = b.pos, root = rootIndex(i)
        b.vel.y = max(b.vel.y - Tuning.debrisGravity * 0.8 * dt, -1300)
        b.vel.x -= b.vel.x * 1.5 * dt
        b.pos += b.vel * dt
        b.rotation -= b.vel.x / b.radius * dt
        if b.pos.x < b.radius { b.pos.x = b.radius; b.vel.x = abs(b.vel.x) * 0.3 }
        if b.pos.x > size.x - b.radius { b.pos.x = size.x - b.radius; b.vel.x = -abs(b.vel.x) * 0.3 }
        var landed = false
        for j in balls.indices where j != i && balls[j].state == .resting && rootIndex(j) != root && !balls[j].melting {
            let o = balls[j], d = b.pos - o.pos, minD = b.radius + o.radius
            let dist = (d.x * d.x + d.y * d.y).squareRoot()
            guard dist < minD * 0.98, d.y > -o.radius * 0.2 else { continue }
            if b.radius <= o.radius + 0.01, abs(d.x) <= 0.4 * o.radius, !hasChild(j), depth(j) < 3 {   // stacks
                b.state = .resting; b.parent = o.id; b.surfaceID = o.surfaceID; b.vel = .zero
                b.pos = SIMD2(o.pos.x, o.pos.y + o.radius + b.radius - SnowField.overlap)
            } else {   // slides off the side
                let n = dist > 1e-3 ? d / dist : SIMD2<Float>(1, 0)
                b.pos = o.pos + n * minD
                b.vel = SIMD2((n.x >= 0 ? 1 : -1) * max(abs(b.vel.x), 70), min(b.vel.y, 0) * 0.2)
            }
            landed = true
            break
        }
        if !landed, let (si, _, top) = supportTop(x: b.pos.x, fromY: prev.y),
           b.pos.y <= top + b.radius * SnowField.sink {
            b.pos.y = top + b.radius * SnowField.sink
            b.state = .resting; b.surfaceID = surfaces[si].id; b.vel = .zero
        }
        if b.pos.y < -b.radius * 2 { balls[i].melting = true; balls[i].fade = 0; balls[i].state = .falling; return }
        balls[i] = b
        ballsVersion &+= 1
    }

    /// Windows moved / closed: balls on them travel along (x shift) or are knocked off, same rules as piles.
    func transportBalls(before: [Surface]) {
        guard !balls.isEmpty else { return }
        for i in balls.indices where balls[i].state == .resting && balls[i].parent == nil {
            guard let sid = balls[i].surfaceID, sid != Tuning.groundID, sid != 0 else { continue }
            guard let n = surfaces.first(where: { $0.id == sid }), let o = before.first(where: { $0.id == sid }) else { setFalling(i, .zero); continue }
            if SnowField.shedFraction(v: n.vel, prev: o.vel) > 0.5 { setFalling(i, n.vel * 0.5); continue }
            let dx = Float(n.frame.minX - o.frame.minX)
            if dx != 0 { balls[i].pos.x += dx; ballsVersion &+= 1 }
        }
    }

    /// Cursor segment a->b through a loose ball breaks it (a whole snowman breaks together) into debris chunks.
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
            let root = rootIndex(i), rid = balls[root].id
            if balls[root].snowmanAge >= 0 {
                while let j = balls.indices.first(where: { !hasChild($0) && balls[rootIndex($0)].id == rid }) { pop(j, v) }   // leaves first
            } else {
                pop(i, v)
            }
        }
        ballsVersion &+= 1
    }

    func pop(_ i: Int, _ v: SIMD2<Float>) {
        let b = balls[i]
        if CFAbsoluteTimeGetCurrent() >= silentUntil {
            for _ in 0..<(Int(b.radius * 1.5) + 4) {
                let a = Float.random(in: 0..<(2 * .pi), using: &rng), d = b.radius * Float.random(in: 0...1, using: &rng).squareRoot()
                let ox = cos(a) * d, oy = sin(a) * d
                addDebris(x: b.pos.x + ox, y: b.pos.y + oy, vx: ox * 3 + v.x * 0.3 + Float.random(in: -10...10, using: &rng),
                          fall: Float.random(in: 0...40, using: &rng) - oy * 2 - v.y * 0.3, size: Float.random(in: 4...7, using: &rng))
            }
        }
        balls.remove(at: i)
    }
}
