import CoreGraphics
import Foundation

public struct Fight {
    public let a: Int, b: Int           // figure ids
    var turn = 0, timer: Float = 0.7, thrown = 0
}

/// A snowball in flight (drawn by the overlay); lands after `dur` seconds.
public struct Shot {
    public internal(set) var pos: SIMD2<Float>
    let from: SIMD2<Float>, to: SIMD2<Float>, peak: Float, dur: Float
    var t: Float = 0
    let hit: Bool, head: Bool, target: Int, surface: Int
    var radius: Float = 3.6                          // ball radius (scaled with the snowmen)
    var impactT: Float = -1                          // < 0 in flight; else seconds of the squashed hold left after landing
    public internal(set) var normal = SIMD2<Float>(0, 1)   // impact normal (valid while impacting)
    public var impacting: Bool { impactT >= 0 }

    /// Where the ball was `k` trail steps (0.035 of the flight each) ago; nil before take-off or once it has landed.
    public func ghost(_ k: Int) -> SIMD2<Float>? {
        let u = t / dur - Float(k) * 0.035
        guard !impacting, u > 0 else { return nil }
        return from + (to - from) * u + SIMD2(0, 4 * peak * u * (1 - u))
    }
}

/// A flattened splat of snow, stuck to a figure (`target` >= 0: `rel` is the offset from its foot) or lying on a pile.
public struct Splat {
    public let target: Int, surface: Int
    public let rel: SIMD2<Float>, scale: Float
    public internal(set) var age: Float = 0
    var life: Float = Tuning.splatLife
    public var alpha: Float { max(0, 1 - age / life) }
}

extension Tuning {
    static let maxSplats = 8
    static let splatLife: Float = 1.2        // s a splat takes to fade
    static let impactHold: Float = 0.07      // s a landed ball stays squashed (1.5 x 0.6) before it is hidden
    static let squashTime: Float = 0.12      // s of the hit wobble squash
    static let headSpin: Float = 14          // rad/s of a flying head
}

extension SnowField {
    private func free(_ f: Figure) -> Bool { f.active && f.fight == nil && f.motion.cheer <= 0 && f.motion.rest <= 0 && f.motion.wobble <= 0 && f.motion.xfer == nil }

    func startFights() {
        guard fights.count < Tuning.maxFights else { return }
        let n = figures.count
        for i in 0..<n where free(figures[i]) {
            for j in (i + 1)..<n where free(figures[j]) && figures[j].surfaceID == figures[i].surfaceID {
                let d = abs(figures[j].foot.x - figures[i].foot.x)
                guard d <= Tuning.fightRange, d >= figures[i].radii.x + figures[j].radii.x + 6 else { continue }
                figures[i].fight = (figures[j].id, 0); figures[j].fight = (figures[i].id, 0)
                let right: Float = figures[j].foot.x >= figures[i].foot.x ? 1 : -1
                figures[i].facing = right; figures[j].facing = -right
                fights.append(Fight(a: figures[i].id, b: figures[j].id))
                break
            }
            if fights.count >= Tuning.maxFights { return }
        }
    }

    private func endFight(_ k: Int) {
        let f = fights.remove(at: k)
        for id in [f.a, f.b] { if let i = figureIndex(id) { figures[i].fight = nil; figures[i].motion.rest = Tuning.fightRest } }
    }

    /// A figure left the world (or can no longer fight): its fight ends.
    func endFights(of id: Int) {
        var k = fights.count - 1
        while k >= 0 {
            if fights[k].a == id || fights[k].b == id { endFight(k) }
            k -= 1
        }
    }

    func stepFights(_ dt: Float) {
        var k = fights.count - 1
        while k >= 0 {
            defer { k -= 1 }
            let f = fights[k]
            guard let ia = figureIndex(f.a), let ib = figureIndex(f.b), figures[ia].active, figures[ib].active,
                  figures[ia].surfaceID == figures[ib].surfaceID,
                  abs(figures[ia].foot.x - figures[ib].foot.x) <= Tuning.fightRange else { endFight(k); continue }   // surface changed, hidden, or one is gone
            fights[k].timer -= dt
            guard fights[k].timer <= 0 else { continue }
            if f.thrown >= Tuning.maxThrows { endFight(k); continue }
            launch(k)
        }
    }

    private func launch(_ k: Int) {
        let f = fights[k], me = f.turn == 0 ? f.a : f.b, you = f.turn == 0 ? f.b : f.a
        guard let i = figureIndex(me), let j = figureIndex(you) else { endFight(k); return }
        let from = anchors(of: figures[i]), at = anchors(of: figures[j]), dir = figures[i].facing
        let d = abs(at.body.x - from.arm.x), head = Float.random(in: 0..<1, using: &rng) < Tuning.headAim
        let dur = 0.6 + 0.4 * min(d / Tuning.fightRange, 1), drift = gust * Tuning.shotWind * dur
        var hit = Float.random(in: 0..<1, using: &rng) < Tuning.hitChance(distance: d)
        if abs(drift) > 14 { hit = false }   // blown off course
        var to = head ? at.head : at.body
        if !hit { to = SIMD2(at.body.x + dir * Float.random(in: 28...70, using: &rng), at.ground) }   // sails past
        to.x += drift
        shots.append(Shot(pos: from.arm, from: from.arm, to: to, peak: 18 + 0.18 * d, dur: dur, hit: hit, head: head, target: you, surface: figures[i].surfaceID ?? Tuning.groundID, radius: 3.6 * snowmanScale))
        fights[k].turn = 1 - f.turn; fights[k].thrown += 1
        fights[k].timer = Tuning.throwGap + Float.random(in: 0...0.4, using: &rng)
    }

    func stepShots(_ dt: Float) {
        var k = shots.count - 1
        while k >= 0 {
            defer { k -= 1 }
            var s = shots[k]
            if s.impacting {
                s.impactT -= dt
                if s.impactT <= 0 { shots.remove(at: k) } else { shots[k] = s }
                continue
            }
            s.t += dt
            let u = min(s.t / s.dur, 1)
            s.pos = s.from + (s.to - s.from) * u + SIMD2(0, 4 * s.peak * u * (1 - u))
            guard u >= 1 else { shots[k] = s; continue }
            s.impactT = Tuning.impactHold
            land(&s)
            shots[k] = s
        }
    }

    /// The ball touches down: splat (on the target, or on the pile), spray fanned around the reflected direction, a puff,
    /// and the hit itself. Sets the impact normal for the squash.
    func land(_ s: inout Shot) {
        let v = (s.to - s.from) / s.dur + SIMD2(0, -4 * s.peak / s.dur)   // velocity at touch-down
        let j = figureIndex(s.target)
        let onBody = s.hit && j != nil
        s.normal = onBody ? SIMD2(v.x >= 0 ? -1 : 1, 0) : SIMD2(0, 1)
        s.pos = s.to
        shotLand = (s.to, time)
        let refl = v - 2 * (v.x * s.normal.x + v.y * s.normal.y) * s.normal
        var rel = s.to + SIMD2(0, 1), scale = snowmanScale
        if onBody, let j { rel = s.to - figures[j].foot; scale = figures[j].scale }
        let cursor = s.target == SnowField.cursorTarget   // a throw at the cursor: bigger blot, longer fade
        addSplat(Splat(target: onBody ? s.target : -1, surface: s.surface, rel: rel, scale: cursor && s.hit ? 14.0 / 12 * snowmanScale : scale, life: cursor && s.hit ? 1.5 : Tuning.splatLife))
        spray(at: s.to, reflected: refl, count: s.hit ? Int.random(in: 8...12, using: &rng) : 5)
        if onBody, let j, figures[j].fight != nil { registerHit(s.target, head: s.head) }
        if onBody, let j, figures[j].kind == .rabbit { rabbitHit(j) }
    }

    private func addSplat(_ p: Splat) {
        if splats.count >= Tuning.maxSplats { splats.removeFirst() }
        splats.append(p)
    }

    func stepSplats(_ dt: Float) {
        var i = splats.count - 1
        while i >= 0 {
            splats[i].age += dt
            if splats[i].age >= splats[i].life { splats.remove(at: i) }
            i -= 1
        }
    }

    /// Clumps fanned +-70 degrees around `dir` at 60-160 pt/s, plus one puff.
    /// Crumbs fly as clumps (instance kind 1) plus one powder puff.
    private func spray(at p: SIMD2<Float>, reflected dir: SIMD2<Float>, count: Int) {
        guard !silent else { return }
        let base = atan2(dir.y, dir.x), fan: Float = 70 * .pi / 180
        for _ in 0..<count {
            let a = base + Float.random(in: -fan...fan, using: &rng), sp = Float.random(in: 60...160, using: &rng)
            _ = put(Flake(pos: p, vx: cos(a) * sp, fall: -sin(a) * sp, phase: 0, amp: 0, freq: 0, size: Float.random(in: 2.5...4, using: &rng),
                          alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1, spin: Float.random(in: -2...2, using: &rng), shape: 1))
        }
        if !calm { addPuff(x: p.x, y: p.y) }
    }

    /// Splat position now (it follows its figure), or nil when the figure is gone.
    public func position(of s: Splat) -> SIMD2<Float>? {
        guard s.target >= 0 else { return s.rel }
        return figureIndex(s.target).map { figures[$0].foot + s.rel }
    }

    /// Splats, trails and shots as prims. `shift` gives the drag offset of a surface id (windows being dragged).
    public func writeShotPrims(_ w: inout PrimWriter, trails: Bool, shift: (Int?) -> SIMD2<Float>) {
        for s in splats {
            guard let p = position(of: s) else { continue }
            let sid = s.target >= 0 ? figureIndex(s.target).flatMap { figures[$0].surfaceID } : s.surface
            Rig.splat(center: p + shift(sid), scale: s.scale, alpha: s.alpha, into: &w)
        }
        for s in shots {
            if trails { for k in 1...4 { if let g = s.ghost(k) { Rig.shotGhost(pos: g + shift(s.surface), k: k, radius: s.radius, into: &w) } } }
            Rig.shot(pos: s.pos + shift(s.surface), radius: s.radius, alpha: 1, squash: s.impacting ? 1 : 0, normal: s.normal, into: &w)
        }
    }

    /// A snowball hit figure `id`: it wobbles; the third head hit knocks the head off and ends the fight with the other as winner.
    func registerHit(_ id: Int, head: Bool) {
        guard let j = figureIndex(id) else { return }
        figures[j].motion.wobble = 0.7
        figures[j].motion.squash = Tuning.squashTime
        if head { figures[j].motion.headHit = 0.7 }
        guard head, var fight = figures[j].fight else { return }
        fight.hits += 1
        figures[j].fight = fight
        guard fight.hits >= Tuning.headHitsToLose, let k = fights.firstIndex(where: { $0.a == id || $0.b == id }) else { return }
        let winner = fights[k].a == id ? fights[k].b : fights[k].a
        endFight(k)
        var away: Float = 1
        if let w = figureIndex(winner) { figures[w].motion.cheer = Tuning.cheerTime; away = figures[j].foot.x >= figures[w].foot.x ? 1 : -1 }
        decapitate(id, away: away, range: walkRange(surface: figures[j].surfaceID ?? Tuning.groundID, x: figures[j].foot.x, half: figures[j].radii.x, height: Snowman.height * figures[j].scale))
    }

    /// The head leaves the body as a loose ball (kicked away from the winner, kept on the surface); the body stays,
    /// headless with its arms drooped. The auto snowman starts its rebuild cooldown.
    func decapitate(_ id: Int, away: Float, range: (Float, Float)?) {
        guard let j = figureIndex(id), !figures[j].headless else { return }
        var dir = away
        if let (lo, hi) = range {
            let x = figures[j].foot.x
            if dir > 0, x + 70 > hi + 8 { dir = -1 } else if dir < 0, x - 70 < lo - 8 { dir = 1 }
        }
        let a = anchors(of: figures[j]), r = figures[j].radii
        var b = Snowball(id: nextBallID, pos: SIMD2(a.body.x + dir * (r.y + r.z + 1), a.body.y + r.y * 0.4), radius: r.z, surfaceID: nil)
        nextBallID += 1
        b.state = .falling
        b.face = figures[j].facing
        b.spin = -dir * Tuning.headSpin
        b.vel = SIMD2(dir * 110, 200)
        balls.append(b)
        figures[j].headless = true
        figures[j].motion.cheer = 0
        if !figures[j].fromBalls { snowmanCooldown = Tuning.snowmanCooldown }
    }
}
