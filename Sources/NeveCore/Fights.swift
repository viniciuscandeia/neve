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
    let hit: Bool, head: Bool, target: Int
}

extension SnowField {
    private func free(_ f: Figure) -> Bool { f.active && f.fight == nil && f.motion.cheer <= 0 && f.motion.rest <= 0 && f.motion.wobble <= 0 }

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
                figuresVersion &+= 1   // facing changed
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
        shots.append(Shot(pos: from.arm, from: from.arm, to: to, peak: 18 + 0.18 * d, dur: dur, hit: hit, head: head, target: you))
        fights[k].turn = 1 - f.turn; fights[k].thrown += 1
        fights[k].timer = Tuning.throwGap + Float.random(in: 0...0.4, using: &rng)
    }

    func stepShots(_ dt: Float) {
        var k = shots.count - 1
        while k >= 0 {
            defer { k -= 1 }
            var s = shots[k]
            s.t += dt
            let u = min(s.t / s.dur, 1)
            s.pos = s.from + (s.to - s.from) * u + SIMD2(0, 4 * s.peak * u * (1 - u))
            guard u >= 1 else { shots[k] = s; continue }
            shots.remove(at: k)
            puff(s.to, big: s.hit)
            if s.hit, let j = figureIndex(s.target), figures[j].fight != nil { registerHit(s.target, head: s.head) }
        }
    }

    private func puff(_ p: SIMD2<Float>, big: Bool) {
        guard !silent else { return }
        for _ in 0..<(big ? 9 : 5) {
            addDebris(x: p.x, y: p.y, vx: Float.random(in: -70...70, using: &rng), fall: Float.random(in: 0...25, using: &rng), size: Float.random(in: 2.5...4, using: &rng))
        }
    }

    /// A snowball hit figure `id`: it wobbles; the third head hit knocks the head off and ends the fight with the other as winner.
    func registerHit(_ id: Int, head: Bool) {
        guard let j = figureIndex(id) else { return }
        figures[j].motion.wobble = 0.7
        guard head, var fight = figures[j].fight else { return }
        fight.hits += 1
        figures[j].fight = fight
        guard fight.hits >= Tuning.headHitsToLose, let k = fights.firstIndex(where: { $0.a == id || $0.b == id }) else { return }
        let winner = fights[k].a == id ? fights[k].b : fights[k].a
        endFight(k)
        var away: Float = 1
        if let w = figureIndex(winner) { figures[w].motion.cheer = Tuning.cheerTime; away = figures[j].foot.x >= figures[w].foot.x ? 1 : -1 }
        decapitate(id, away: away, range: walkRange(surface: figures[j].surfaceID ?? Tuning.groundID, x: figures[j].foot.x, half: figures[j].radii.x))
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
        b.vel = SIMD2(dir * 110, 200)
        balls.append(b)
        ballsVersion &+= 1
        figures[j].headless = true
        figures[j].motion.cheer = 0
        figuresVersion &+= 1
        if !figures[j].fromBalls { snowmanCooldown = Tuning.snowmanCooldown }
    }
}
