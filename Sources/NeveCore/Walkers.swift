import CoreGraphics
import Foundation

extension Tuning {
    public static let fightRange: Float = 250      // two snowmen on the same surface this close may start a fight
    static let maxFights = 2                       // per screen
    static let walkSpeed: Float = 14               // pt/s (x snowman scale, +-20% per walker)
    static let maxThrows = 24                      // a fight nobody wins ends after this many throws in total
    static let fightRest: Float = 12               // s a snowman stays out of fights after one ends
    static let cheerTime: Float = 2                // winner's celebration
    static let headHitsToLose = 3
    static let windPush: Float = 26                // pt/s the wind adds to / takes from a walker at a full gust
    static let windLean: Float = 9.2               // pt of head offset into a full gust (~12 degrees)
    static let shotWind: Float = 45                // pt/s a full gust moves a snowball in flight
    static let headAim: Float = 0.65               // share of throws aimed at the head
    static let throwGap: Float = 1.1               // s between throws (plus up to 0.4 random)
    /// Chance that a throw from `d` points away hits: 0.8 up to 80pt, falling linearly to 0.35 at 250pt.
    public static func hitChance(distance d: Float) -> Float { 0.8 - 0.45 * min(max((d - 80) / 170, 0), 1) }
}

/// Scarf and arm pose of a walking snowman, all radians except `up`. Layers apply it as transforms: no path rebuilds.
public struct Flutter: Equatable {
    public var scarf: Float = 0    // upper scarf tail, + = swung toward +x (downwind when the wind blows right)
    public var wave: Float = 0     // extra bend of the lower tail segment, lags the upper one
    public var sway: Float = 0     // both twig arms, + = counter-clockwise: negative = bent toward +x
    public var up: Float = 0       // 0...1 cheer: arms raised into a V
    public init() {}

    /// Pure pose from gust (-1...1), gait (0 still ... 1 walking), walking direction, flutter phase and cheer seconds left.
    /// Amplitude and (via `rate`) frequency grow with wind and walking; a full gust streams the tail ~66 degrees downwind.
    public static func make(gust g: Float, gait: Float, dir: Float, phase: Float, cheer: Float) -> Flutter {
        var f = Flutter()
        let a = 0.07 + 0.16 * abs(g) + 0.05 * gait
        f.scarf = 1.15 * g - 0.12 * dir * gait + a * sin(phase)
        f.wave = 1.8 * a * sin(phase - 1.1)
        f.sway = -0.3 * g + 0.05 * abs(g) * sin(phase * 1.3)
        if cheer > 0 {   // lift in 0.25 s, lower over the last 0.35 s
            let u = min(1, (Tuning.cheerTime - cheer) / 0.25) * min(1, cheer / 0.35)
            f.up = u * u * (3 - 2 * u)
        }
        return f
    }
    /// Radians per second the flutter phase advances.
    public static func rate(gust g: Float, gait: Float) -> Float { 2 * .pi * (1.2 + 2.2 * abs(g) + 0.8 * gait) }
    /// Rotation of each arm in the V (about its shoulder; `side` -1 left, +1 right) plus the shared sway.
    public func arm(side: Float) -> Float { sway + side * up * 0.75 }
}

/// A complete snowman (the auto one, key 0, or a user-built stack, key = bottom ball id) walking its surface.
public struct Walker {
    public let key: Int
    public internal(set) var surfaceID = 0
    public internal(set) var x: Float = 0
    public internal(set) var dir: Float = 1          // facing / walking direction
    public internal(set) var hop: Float = 0          // visual: points lifted
    public internal(set) var lean: Float = 0         // visual: sideways offset of the head
    public internal(set) var cheer: Float = 0        // seconds of celebration left
    public internal(set) var wobble: Float = 0       // seconds of hit wobble left
    public internal(set) var hits = 0                // head hits taken in the current fight
    public internal(set) var foe: Int?
    var half: Float = 12, scale: Float = 1, speed: Float = 14
    public internal(set) var pose = Flutter()
    var windLean: Float = 0, flutter: Float = 0, phase: Float = 0, gait: Float = 0, idle: Float = 0, nextIdle: Float = 6, rest: Float = 0, seen = true
    var free: Bool { foe == nil && cheer <= 0 && rest <= 0 && wobble <= 0 }
}

public struct Fight {
    public let a: Int, b: Int           // walker keys
    var turn = 0, timer: Float = 0.7, thrown = 0
}

/// A snowball in flight (drawn by the overlay); lands after `dur` seconds.
public struct Shot {
    public internal(set) var pos: SIMD2<Float>
    let from: SIMD2<Float>, to: SIMD2<Float>, peak: Float, dur: Float
    var t: Float = 0
    let hit: Bool, head: Bool, target: Int
}

public struct WalkState {
    public var enabled = true
    var gustOverride: Float?    // tests
    public internal(set) var walkers: [Walker] = []
    public internal(set) var fights: [Fight] = []
    public internal(set) var shots: [Shot] = []
    init() { walkers.reserveCapacity(8); fights.reserveCapacity(4); shots.reserveCapacity(6) }
}

extension SnowField {
    /// +1 / -1: which way the snowman with this key faces (1 when it has no walker).
    public func facing(of key: Int) -> Float { walk.walkers.first { $0.key == key }?.dir ?? 1 }

    /// Scarf / arm pose of the snowman with this key (at rest when it has no walker).
    public func pose(of key: Int) -> Flutter { walk.walkers.first { $0.key == key }?.pose ?? Flutter() }

    private func wi(_ key: Int) -> Int? { walk.walkers.firstIndex { $0.key == key } }

    /// Runs from `step`: sync walkers with the complete snowmen, walk, fight, fly snowballs.
    func stepWalkers(dt: Float) {
        guard walk.enabled, !calm else {   // off / Reduce Motion: everybody stands still
            if !walk.walkers.isEmpty || !walk.shots.isEmpty {
                walk.walkers.removeAll(); walk.fights.removeAll(); walk.shots.removeAll()
                snowman?.hop = 0; snowman?.lean = 0; snowman?.pose = Flutter()
            }
            return
        }
        sync()
        for i in walk.walkers.indices { walkStep(i, dt) }
        startFights()
        stepFights(dt)
        stepShots(dt)
    }

    private func sync() {
        for i in walk.walkers.indices { walk.walkers[i].seen = false }
        func see(_ key: Int, _ sid: Int, _ x: Float, _ half: Float, _ scale: Float) {
            let i: Int
            if let k = wi(key) { i = k } else {
                var w = Walker(key: key)
                w.dir = Bool.random(using: &rng) ? 1 : -1
                w.speed = Tuning.walkSpeed * Float.random(in: 0.8...1.2, using: &rng)
                w.nextIdle = Float.random(in: 3...10, using: &rng)
                w.phase = Float.random(in: 0..<6, using: &rng)
                walk.walkers.append(w); i = walk.walkers.count - 1
            }
            walk.walkers[i].surfaceID = sid; walk.walkers[i].x = x; walk.walkers[i].half = half
            walk.walkers[i].scale = scale; walk.walkers[i].seen = true
        }
        if let m = snowman, m.complete, !m.collapsing, m.stageAge >= 0.3 { see(0, m.surfaceID, m.x, 12 * m.scale, m.scale) }
        for b in balls where b.state == .resting && b.parent == nil && b.snowmanAge >= 0.3 && !b.melting {
            if let s = b.surfaceID { see(b.id, s, b.pos.x, b.radius, b.radius / 11.5) }
        }
        walk.walkers.removeAll { !$0.seen }
    }

    /// Where a snowman may stand: the visible stretch of its surface around x, kept clear of ends, corners and covered columns.
    func walkRange(surface sid: Int, x: Float, half: Float) -> (Float, Float)? {
        guard let s = surfaces.first(where: { $0.id == sid }) else { return nil }
        let p = s.pile, n = p.heights.count, c = column(x) - s.c0
        guard c >= 0, c < n, p.visible[c] else { return nil }
        var a = c, b = c
        while a > 0 && p.visible[a - 1] { a -= 1 }
        while b < n - 1 && p.visible[b + 1] { b += 1 }
        let lo = max(Float(s.c0 + a) * Tuning.binWidth, p.x0), hi = min(Float(s.c0 + b + 1) * Tuning.binWidth, p.x1)
        return (lo + half + 8, hi - half - 8)
    }

    /// Whether there is snow (mean height over +-3 columns >= 1.5) under x on the surface.
    private func snowUnder(_ sid: Int, _ x: Float) -> Bool {
        guard let s = surfaces.first(where: { $0.id == sid }) else { return false }
        let n = s.pile.heights.count, c = column(x) - s.c0
        guard c >= 0, c < n else { return false }
        var sum: Float = 0
        for b in max(0, c - 3)...min(n - 1, c + 3) { sum += s.pile.heights[b] }
        return sum / Float(min(n - 1, c + 3) - max(0, c - 3) + 1) >= 1.5
    }

    /// -1...1: how hard the wind blows sideways. Zero below a dead zone, so only Nevasca gusts count (Leve / Media peak at 8).
    var gust: Float { if let o = walk.gustOverride { return o }; return (wind < 0 ? -1 : 1) * min(1, max(0, abs(wind) - 20) / 80) }

    private func walkStep(_ i: Int, _ dt: Float) {
        var w = walk.walkers[i]
        let old = w.x, g = gust
        w.rest = max(0, w.rest - dt)
        w.wobble = max(0, w.wobble - dt)
        var moving = false, jump: Float = 0
        let range = walkRange(surface: w.surfaceID, x: w.x, half: w.half)
        // Steps x by `dx`, never past the stretch ends (and the auto snowman never onto bare ground).
        func shift(_ dx: Float) {
            guard let (lo, hi) = range, hi > lo + 4 else { return }
            var nx = w.x + dx
            if w.x <= hi && w.x >= lo { nx = min(max(nx, lo), hi) }
            if w.key == 0 && !snowUnder(w.surfaceID, nx) { return }
            w.x = nx
        }
        if w.cheer > 0 {
            w.cheer = max(0, w.cheer - dt)
            jump = abs(sin(w.cheer * 2 * .pi * 1.5)) * 7 * w.scale * min(1, w.cheer)
        } else if w.foe == nil, w.idle <= 0, let (lo, hi) = range, hi > lo + 4 {
            w.nextIdle -= dt
            if w.nextIdle <= 0 {
                w.idle = Float.random(in: 1.5...4, using: &rng); w.nextIdle = Float.random(in: 8...18, using: &rng)
            } else {
                moving = true
                if w.x > hi { w.dir = -1 } else if w.x < lo { w.dir = 1 }
                let base = w.speed * w.scale
                // Against the wind they barely advance, with it they speed up (capped at 1.5x).
                let v = min(max(w.dir * base + g * Tuning.windPush * w.scale, -1.5 * base), 1.5 * base)
                let nx = w.x + v * dt
                // Snowmen do not walk through each other (or onto bare ground, for the auto one): turn back.
                let blocked = walk.walkers.contains { o in
                    o.key != w.key && o.surfaceID == w.surfaceID && abs(nx - o.x) < w.half + o.half + 6 && abs(nx - o.x) < abs(w.x - o.x)
                }
                if blocked || (w.key == 0 && !snowUnder(w.surfaceID, nx)) { w.dir = -w.dir } else {
                    shift(v * dt)
                    if w.x >= hi && w.dir > 0 { w.x = hi; w.dir = -1 } else if w.x <= lo && w.dir < 0 { w.x = lo; w.dir = 1 }
                }
            }
        } else {
            if w.foe == nil { w.idle = max(0, w.idle - dt) }
            if abs(g) > 0.5 { shift(g * Tuning.windPush * 0.3 * w.scale * dt) }   // a strong gust slides a standing (idle or fighting) snowman
        }
        w.windLean += (-g * Tuning.windLean * w.scale - w.windLean) * min(1, dt * 3)   // leans into the wind
        w.gait += ((moving ? 1 : 0) - w.gait) * min(1, dt * 6)
        w.phase += dt * 2 * .pi * 1.4 * w.gait
        w.hop = abs(sin(w.phase)) * 2.2 * w.scale * w.gait + jump
        w.lean = w.windLean + sin(w.phase * 0.5) * 1.4 * w.scale * w.gait + sin(w.wobble * 28) * min(w.wobble, 0.7) * 7 * w.scale
        w.flutter += dt * Flutter.rate(gust: g, gait: w.gait)
        w.pose = .make(gust: g, gait: w.gait, dir: w.dir, phase: w.flutter, cheer: w.cheer)
        walk.walkers[i] = w
        apply(w, moved: w.x != old)
    }

    /// Writes position, hop and lean onto the snowman (after the ball simulation has put it on its surface this frame).
    private func apply(_ w: Walker, moved: Bool) {
        if w.key == 0 { snowman?.x = w.x; snowman?.hop = w.hop; snowman?.lean = w.lean; snowman?.facing = w.dir; snowman?.pose = w.pose; return }
        guard moved || w.hop != 0 || w.lean != 0,
              let bi = balls.firstIndex(where: { $0.id == w.key }), let mi = balls.firstIndex(where: { $0.parent == w.key }),
              let hi = balls.firstIndex(where: { $0.parent == balls[mi].id }) else { return }
        balls[bi].pos.x = w.x; balls[bi].pos.y += w.hop
        balls[mi].pos = SIMD2(w.x + w.lean * 0.4, balls[mi].pos.y + w.hop)
        balls[hi].pos = SIMD2(w.x + w.lean, balls[hi].pos.y + w.hop)
        ballsVersion &+= 1
    }

    // MARK: Fights

    private func startFights() {
        guard walk.fights.count < Tuning.maxFights else { return }
        let n = walk.walkers.count
        for i in 0..<n where walk.walkers[i].free {
            for j in (i + 1)..<n where walk.walkers[j].free && walk.walkers[j].surfaceID == walk.walkers[i].surfaceID {
                let d = abs(walk.walkers[j].x - walk.walkers[i].x)
                guard d <= Tuning.fightRange, d >= walk.walkers[i].half + walk.walkers[j].half + 6 else { continue }
                walk.walkers[i].foe = walk.walkers[j].key; walk.walkers[j].foe = walk.walkers[i].key
                walk.walkers[i].hits = 0; walk.walkers[j].hits = 0
                let right: Float = walk.walkers[j].x >= walk.walkers[i].x ? 1 : -1
                walk.walkers[i].dir = right; walk.walkers[j].dir = -right
                walk.fights.append(Fight(a: walk.walkers[i].key, b: walk.walkers[j].key))
                ballsVersion &+= 1   // facing changed
                break
            }
            if walk.fights.count >= Tuning.maxFights { return }
        }
    }

    private func endFight(_ k: Int) {
        let f = walk.fights.remove(at: k)
        for key in [f.a, f.b] { if let i = wi(key) { walk.walkers[i].foe = nil; walk.walkers[i].rest = Tuning.fightRest; walk.walkers[i].hits = 0 } }
    }

    private func stepFights(_ dt: Float) {
        var k = walk.fights.count - 1
        while k >= 0 {
            defer { k -= 1 }
            let f = walk.fights[k]
            guard let ia = wi(f.a), let ib = wi(f.b), walk.walkers[ia].surfaceID == walk.walkers[ib].surfaceID,
                  abs(walk.walkers[ia].x - walk.walkers[ib].x) <= Tuning.fightRange else { endFight(k); continue }   // surface changed, or one is gone
            walk.fights[k].timer -= dt
            guard walk.fights[k].timer <= 0 else { continue }
            if f.thrown >= Tuning.maxThrows { endFight(k); continue }
            launch(k)
        }
    }

    /// Key points of a snowman: throwing hand, body and head centres, and the surface top under it.
    private func anchors(_ key: Int, facing: Float) -> (arm: SIMD2<Float>, body: SIMD2<Float>, head: SIMD2<Float>, ground: Float)? {
        if key == 0 {
            guard let m = snowman else { return nil }
            let s = m.scale
            return (SIMD2(m.x + facing * 8 * s, m.y + 33 * s), SIMD2(m.x, m.y + 25 * s), SIMD2(m.x, m.y + 44.5 * s), m.y + 2 * s)
        }
        guard let b = balls.first(where: { $0.id == key }), let m = balls.first(where: { $0.parent == key }),
              let h = balls.first(where: { $0.parent == m.id }) else { return nil }
        return (SIMD2(m.pos.x + facing * m.radius * 0.8, m.pos.y + m.radius * 0.2), m.pos, h.pos, b.pos.y - b.radius * 0.8)
    }

    private func launch(_ k: Int) {
        let f = walk.fights[k], me = f.turn == 0 ? f.a : f.b, you = f.turn == 0 ? f.b : f.a
        guard let i = wi(me), let j = wi(you), let from = anchors(me, facing: walk.walkers[i].dir),
              let at = anchors(you, facing: walk.walkers[j].dir) else { endFight(k); return }
        let d = abs(at.body.x - from.arm.x), head = Float.random(in: 0..<1, using: &rng) < Tuning.headAim
        let dur = 0.6 + 0.4 * min(d / Tuning.fightRange, 1), drift = gust * Tuning.shotWind * dur
        var hit = Float.random(in: 0..<1, using: &rng) < Tuning.hitChance(distance: d)
        if abs(drift) > 14 { hit = false }   // blown off course
        var to = head ? at.head : at.body
        if !hit { to = SIMD2(at.body.x + walk.walkers[i].dir * Float.random(in: 28...70, using: &rng), at.ground) }   // sails past
        to.x += drift
        walk.shots.append(Shot(pos: from.arm, from: from.arm, to: to, peak: 18 + 0.18 * d, dur: dur, hit: hit, head: head, target: you))
        walk.fights[k].turn = 1 - f.turn; walk.fights[k].thrown += 1
        walk.fights[k].timer = Tuning.throwGap + Float.random(in: 0...0.4, using: &rng)
    }

    private func stepShots(_ dt: Float) {
        var k = walk.shots.count - 1
        while k >= 0 {
            defer { k -= 1 }
            var s = walk.shots[k]
            s.t += dt
            let u = min(s.t / s.dur, 1)
            s.pos = s.from + (s.to - s.from) * u + SIMD2(0, 4 * s.peak * u * (1 - u))
            guard u >= 1 else { walk.shots[k] = s; continue }
            walk.shots.remove(at: k)
            puff(s.to, big: s.hit)
            if s.hit, let j = wi(s.target), walk.walkers[j].foe != nil { registerHit(s.target, head: s.head) }
        }
    }

    private func puff(_ p: SIMD2<Float>, big: Bool) {
        guard CFAbsoluteTimeGetCurrent() >= silentUntil else { return }
        for _ in 0..<(big ? 9 : 5) {
            addDebris(x: p.x, y: p.y, vx: Float.random(in: -70...70, using: &rng), fall: Float.random(in: 0...25, using: &rng), size: Float.random(in: 2.5...4, using: &rng))
        }
    }

    /// A snowball hit `key`: it wobbles; the third head hit knocks the head off and ends the fight with the other as winner.
    func registerHit(_ key: Int, head: Bool) {
        guard let j = wi(key) else { return }
        walk.walkers[j].wobble = 0.7
        guard head else { return }
        walk.walkers[j].hits += 1
        guard walk.walkers[j].hits >= Tuning.headHitsToLose, let k = walk.fights.firstIndex(where: { $0.a == key || $0.b == key }) else { return }
        let winner = walk.fights[k].a == key ? walk.fights[k].b : walk.fights[k].a
        endFight(k)
        var away: Float = 1
        if let w = wi(winner) { walk.walkers[w].cheer = Tuning.cheerTime; away = walk.walkers[j].x >= walk.walkers[w].x ? 1 : -1 }
        decapitate(key, away: away, range: walkRange(surface: walk.walkers[j].surfaceID, x: walk.walkers[j].x, half: walk.walkers[j].half))
    }

    /// The head leaves the body as a loose ball (kicked away from the winner, kept on the surface); the body stays.
    /// The auto snowman becomes the same 2-ball stack first.
    func decapitate(_ key: Int, away: Float, range: (Float, Float)?) {
        var dir = away
        let x = wi(key).map { walk.walkers[$0].x } ?? 0
        if let (lo, hi) = range {
            if dir > 0, x + 70 > hi + 8 { dir = -1 } else if dir < 0, x - 70 < lo - 8 { dir = 1 }
        }
        var bottom = key
        if key == 0 {
            guard let m = snowman else { return }
            guard balls.count + 3 <= Tuning.maxBalls + 2 else { collapse(); return }   // no room for the loose balls
            var parent: Int?
            for (n, (_, r)) in Snowman.balls.enumerated() {
                var b = Snowball(id: nextBallID, pos: SIMD2(m.x, m.y + 2 * m.scale + 0.8 * r * m.scale + Float(n) * r), radius: r * m.scale, surfaceID: m.surfaceID)
                nextBallID += 1
                b.state = .resting
                b.parent = parent
                parent = b.id
                if n == 0 { bottom = b.id }
                balls.append(b)
            }
            snowman = nil
            snowmanCooldown = Tuning.snowmanCooldown
        }
        guard let mi = balls.firstIndex(where: { $0.parent == bottom }), let hi = balls.firstIndex(where: { $0.parent == balls[mi].id }) else { return }
        let (m, h) = (balls[mi], balls[hi])
        balls[hi].parent = nil; balls[hi].surfaceID = nil; balls[hi].state = .falling
        balls[hi].pos = SIMD2(m.pos.x + dir * (m.radius + h.radius + 1), m.pos.y + m.radius * 0.4)
        balls[hi].vel = SIMD2(dir * 110, 200)
        balls[hi].snowmanAge = -1
        ballsVersion &+= 1
    }
}
