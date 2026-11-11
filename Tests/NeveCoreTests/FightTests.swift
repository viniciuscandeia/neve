// AGENT HEADER - Tests/NeveCoreTests/FightTests.swift  (Fights.swift rules)
// Fights start only on the same surface within Tuning.fightRange, at most 2 at once, shots alternate, the third head hit ends the fight, putting the head back restores the snowman, the fight ends when distance grows / one is knocked off / the surface changes, rest and maxThrows, hitChance falls with distance,
// the auto snowman loses its head as a loose ball. Helpers: FigureHelpers.swift (stackBalls, stand, advance).

import CoreGraphics
import Testing
@testable import NeveCore

private func field(_ windows: [WindowInfo] = []) -> SnowField {
    let f = makeField()
    f.update(windows: windows)
    let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in 0..<500 { f.surfaces[i].pile.heights[b] = 12 }
    return f
}

private func run(_ f: SnowField, _ s: Float) { advance(f, s) }

private func loose(_ f: SnowField, radius: Float = 10) -> Snowball? { f.balls.first { $0.parent == nil && $0.radius == radius } }

@Test func fightsStartOnlyOnTheSameSurfaceWithinRange() {
    let near = field()
    stand(near, x: 300); stand(near, x: 420)
    run(near, 1)
    #expect(near.fights.count == 1 && near.figures.allSatisfy { $0.fight != nil && $0.phase == .fighting })
    #expect(near.figures[0].facing == 1 && near.figures[1].facing == -1)   // facing each other

    let far = field()
    stand(far, x: 200); stand(far, x: 600)   // 400pt apart
    run(far, 1)
    #expect(far.fights.isEmpty)

    let apart = field([win(1, 300, 300, 400, 200)])   // one on the window top, one on the ground, 100pt apart
    stand(apart, x: 400, on: 1); stand(apart, x: 500)
    run(apart, 3)
    #expect(apart.fights.isEmpty)
}

@Test func atMostTwoFightsAtOnce() {
    let f = field()
    for x: Float in [100, 160, 500, 560, 800, 860] { stackBalls(f, x: x) }   // the cap lets only three of them stand up
    run(f, 1)
    #expect(f.figures.count == Tuning.maxFigures && f.fights.count == 1)
    #expect(Tuning.maxFights == 2)
}

@Test func shotsAlternateAndFlyInRange() {
    let f = field()
    let a = stand(f, x: 300), b = stand(f, x: 420)
    var targets: [Int] = [], seen = 0
    for _ in 0..<(20 * 60) {
        f.step(dt: 1 / 60)
        if f.shots.count > seen { targets.append(f.shots[f.shots.count - 1].target) }
        seen = f.shots.count
        if f.fights.isEmpty, f.time > 2 { break }
    }
    #expect(targets.count >= 4 && Set(targets) == [a, b])
    #expect(zip(targets, targets.dropFirst()).allSatisfy { $0 != $1 })   // alternate throws
    #expect(Tuning.fightRange == 250)
}

@Test func thirdHeadHitKnocksTheHeadOffAndEndsTheFight() {
    let f = field()
    let a = stand(f, x: 300), b = stand(f, x: 420)
    run(f, 1)
    f.registerHit(b, head: true); f.registerHit(b, head: false)   // body hits do not count
    #expect(f.fights.count == 1 && fig(f, b).motion.wobble > 0 && fig(f, b).fight?.hits == 1)
    f.registerHit(b, head: true); f.registerHit(b, head: true)
    #expect(f.fights.isEmpty && fig(f, a).motion.cheer > 1.9 && fig(f, a).fight == nil)
    let head = loose(f)!
    #expect(head.state == .falling && head.pos.x > 420)   // kicked away from the winner
    #expect(fig(f, b).headless)
    run(f, 1)
    // The loser stands headless (arms drooped), takes no part in fights; the head lies loose and can be picked up.
    #expect(f.figures.count == 2 && fig(f, b).phase == .idle && fig(f, b).fight == nil && fig(f, b).droop > 0.9)
    #expect(ball(f, head.id).state == .resting)
    #expect(f.pickSnowball(at: CGPoint(x: CGFloat(ball(f, head.id).pos.x), y: CGFloat(ball(f, head.id).pos.y))) == head.id)
    run(f, 3)   // the winner celebrates, then walks again
    #expect(fig(f, a).motion.cheer == 0 && f.fights.isEmpty && fig(f, a).phase != .cheering)
}

@Test func puttingTheHeadBackRestoresTheSnowman() {
    let f = field()
    stand(f, x: 300)
    let b = stand(f, x: 420)
    run(f, 1)
    f.registerHit(b, head: true); f.registerHit(b, head: true); f.registerHit(b, head: true)
    run(f, 1)
    let head = loose(f)!
    let body = f.anchors(of: fig(f, b)).body
    #expect(f.pickSnowball(at: CGPoint(x: CGFloat(head.pos.x), y: CGFloat(head.pos.y))) == head.id)
    f.drag(head.id, to: CGPoint(x: CGFloat(body.x), y: CGFloat(body.y) + 120), dt: 1 / 60)
    f.drop(head.id, throwing: false)
    run(f, 2)
    #expect(!fig(f, b).headless && f.balls.isEmpty && fig(f, b).stageAge >= 0.3)
    #expect(fig(f, b).droop < 0.1)
    run(f, 20)
    #expect([Phase.idle, .walking, .fighting, .cheering].contains(fig(f, b).phase))   // walks (and may fight) again
}

@Test func fightEndsWhenTheDistanceGrowsOrOneIsKnockedOff() {
    let f = field()
    let a = stand(f, x: 300), b = stand(f, x: 420)
    run(f, 1)
    #expect(f.fights.count == 1)
    f.figures[f.figureIndex(b)!].foot.x += 300   // e.g. the window was resized under them
    run(f, 0.1)
    #expect(f.fights.isEmpty && fig(f, a).fight == nil && fig(f, b).phase != .hidden)

    let g = field()
    let c = stand(g, x: 300); stand(g, x: 400)
    run(g, 1)
    #expect(g.fights.count == 1)
    g.sweep(from: CGPoint(x: 395, y: 60), to: CGPoint(x: 405, y: 60), radius: 10)   // cursor through the second one
    run(g, 0.1)
    #expect(g.fights.isEmpty && g.figures.map(\.id) == [c] && fig(g, c).fight == nil)
}

@Test func surfaceChangeEndsTheFight() {
    let f = field([win(1, 300, 300, 600, 200)])
    let a = stand(f, x: 400, on: 1), b = stand(f, x: 520, on: 1)
    run(f, 1)
    #expect(f.fights.count == 1)
    f.figures[f.figureIndex(b)!].at = .surface(id: Tuning.groundID, x: 520)   // one ends up on another surface
    run(f, 0.1)
    #expect(f.fights.isEmpty && fig(f, a).fight == nil)
}

@Test func fightsRestAfterwardsAndStopAfterMaxThrows() {
    let f = field()
    let a = stand(f, x: 300), b = stand(f, x: 420)
    run(f, 1)
    f.fights[0].thrown = Tuning.maxThrows   // nobody won: the fight just ends at its next throw
    run(f, 2)
    #expect(f.fights.isEmpty && fig(f, a).fight == nil && fig(f, b).fight == nil)
    #expect(fig(f, a).motion.rest > 0 && fig(f, a).motion.rest <= Tuning.fightRest)   // rests, so no immediate rematch
    run(f, Tuning.fightRest - 4)
    #expect(f.fights.isEmpty)
}

@Test func fightsKeepGoingUntilSomeoneLosesTheirHead() {
    for seed in UInt64(1)...4 {
        let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0, seed: seed)
        f.update(windows: [])
        let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
        for b in 0..<500 { f.surfaces[i].pile.heights[b] = 12 }
        stand(f, x: 300); stand(f, x: 420)
        run(f, 1)
        #expect(f.fights.count == 1)
        var t: Float = 0
        while t < 400, loose(f) == nil { run(f, 1); t += 1 }
        #expect(t < 400 && f.fights.isEmpty && f.figures.filter(\.fromBalls).count == 2 && f.figures.filter(\.headless).count == 1)   // (the auto snowman may start building from the puffs' snow)
    }
}

@Test func hitChanceFallsWithDistance() {
    #expect(Tuning.hitChance(distance: 40) == 0.8 && Tuning.hitChance(distance: 80) == 0.8)
    #expect(abs(Tuning.hitChance(distance: 250) - 0.35) < 1e-5 && Tuning.hitChance(distance: 400) == Tuning.hitChance(distance: 250))
    var rng = SplitMix64(seed: 7), rates: [Float] = []
    for d: Float in [60, 120, 180, 250] {
        var hits = 0
        for _ in 0..<4000 where Float.random(in: 0..<1, using: &rng) < Tuning.hitChance(distance: d) { hits += 1 }
        rates.append(Float(hits) / 4000)
    }
    #expect(zip(rates, rates.dropFirst()).allSatisfy { $0 > $1 })
}

@Test func autoSnowmanLosesItsHeadAsALooseBall() {
    let f = field()
    let auto = standAuto(f, x: 300)
    stand(f, x: 420)
    run(f, 1)
    f.decapitate(auto, away: 1, range: nil)
    #expect(fig(f, auto).headless && !fig(f, auto).fromBalls && f.snowmanCooldown == Tuning.snowmanCooldown)
    run(f, 2)
    let head = f.balls.first { $0.radius == Snowman.balls[2].r * f.snowmanScale }!
    #expect(head.parent == nil && head.state == .resting && f.figures.count == 2)
    #expect(f.fights.isEmpty && fig(f, auto).phase == .idle)   // the headless one takes no part
}

@Test func windBlowsShotsOffCourse() {
    var hits = 0, total = 0
    for seed in UInt64(1)...6 {
        let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0, seed: seed)
        f.update(windows: [])
        let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
        for b in 0..<500 { f.surfaces[i].pile.heights[b] = 12 }
        f.gustOverride = 1
        stand(f, x: 300); stand(f, x: 420)
        for _ in 0..<(30 * 60) {
            f.step(dt: 1 / 60)
            for s in f.shots where s.t == 1 / 60 { total += 1; if s.hit { hits += 1 } }
        }
    }
    #expect(total > 10 && hits == 0)   // a full gust drifts the ball more than 14pt: every throw misses
}
