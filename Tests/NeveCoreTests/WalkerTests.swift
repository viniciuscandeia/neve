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

private func run(_ f: SnowField, _ s: Float) { for _ in 0..<Int(s * 60) { f.step(dt: 1 / 60) } }

/// A finished 3-ball snowman (radii 20 / 14 / 10) standing on surface `sid`; returns the bottom ball id.
@discardableResult
private func build(_ f: SnowField, x: Float, on sid: Int = Tuning.groundID) -> Int {
    var parent: Int?
    var first = 0
    for (n, r) in [Float(20), 14, 10].enumerated() {
        var b = Snowball(id: f.nextBallID, pos: SIMD2(x, 40 + Float(n) * 30), radius: r, surfaceID: sid)
        f.nextBallID += 1
        b.state = .resting; b.parent = parent; parent = b.id
        if n == 0 { first = b.id }
        f.balls.append(b)
    }
    return first
}

private func ready(_ f: SnowField) { run(f, 0.6) }
private func walker(_ f: SnowField, _ key: Int) -> Walker { f.walk.walkers.first { $0.key == key }! }
private func ball(_ f: SnowField, _ id: Int) -> Snowball { f.balls.first { $0.id == id }! }
private func headOf(_ f: SnowField, _ bottom: Int) -> Snowball? {
    guard let m = f.balls.first(where: { $0.parent == bottom }) else { return nil }
    return f.balls.first { $0.parent == m.id }
}

@Test func walkerStaysInsideItsStretchAndTurnsAround() {
    let f = field([win(1, 450, 0, 600, 60)])   // hides the ground from x = 450 on
    let id = build(f, x: 300)
    ready(f)
    var lo = Float.infinity, hi = -Float.infinity, turns = 0, dir = walker(f, id).dir
    for _ in 0..<(90 * 60) {
        f.step(dt: 1 / 60)
        let w = walker(f, id)
        lo = min(lo, w.x); hi = max(hi, w.x)
        if w.dir != dir { turns += 1; dir = w.dir }
    }
    #expect(lo >= 20 + 8 - 0.5 && hi <= 450 - 20 - 8 + 0.5)   // half width + margin from the screen edge / covering window
    #expect(hi - lo > 100 && turns >= 1)
    #expect(ball(f, id).state == .resting)   // never walked off
}

@Test func walkersMoveWithTheirWindow() {
    let f = field([win(1, 200, 300, 400, 200)])
    let id = build(f, x: 400, on: 1)
    ready(f)
    f.update(windows: [win(1, 250, 300, 400, 200)], dt: 1)
    #expect(abs(ball(f, id).pos.x - walker(f, id).x) < 60)
    run(f, 1)
    #expect(ball(f, id).state == .resting && ball(f, id).surfaceID == 1)
}

@Test func noWalkingWithReduceMotionOrWhenSwitchedOff() {
    for calm in [true, false] {
        let f = field()
        let id = build(f, x: 300)
        if calm { f.setCalm(true) } else { f.walk.enabled = false }
        run(f, 20)
        #expect(ball(f, id).pos.x == 300 && f.walk.walkers.isEmpty)
    }
}

@Test func autoSnowmanWalks() {
    let f = field()
    f.snowman = Snowman(x: 300, surfaceID: Tuning.groundID, scale: 1, y: 14)
    f.snowman!.stage = Snowman.stageCount
    run(f, 20)
    #expect(f.snowman!.x != 300 && f.snowman!.x > 28 && f.snowman!.x < 972)
}

@Test func fightsStartOnlyOnTheSameSurfaceWithinRange() {
    let near = field()
    build(near, x: 300); build(near, x: 420)
    run(near, 1)
    #expect(near.walk.fights.count == 1 && near.walk.walkers.allSatisfy { $0.foe != nil })
    #expect(near.walk.walkers[0].dir == 1 && near.walk.walkers[1].dir == -1)   // facing each other

    let far = field()
    build(far, x: 200); build(far, x: 600)   // 400pt apart
    run(far, 1)
    #expect(far.walk.fights.isEmpty)

    let apart = field([win(1, 300, 300, 400, 200)])   // one on the window top, one on the ground, 100pt apart
    build(apart, x: 400, on: 1); build(apart, x: 500)
    run(apart, 3)
    #expect(apart.walk.fights.isEmpty)
}

@Test func atMostTwoFightsAtOnce() {
    let f = field()
    for x: Float in [100, 160, 500, 560, 800, 860] { build(f, x: x) }
    run(f, 1)
    #expect(f.walk.fights.count == 2)
}

@Test func thirdHeadHitKnocksTheHeadOffAndEndsTheFight() {
    let f = field()
    let a = build(f, x: 300), b = build(f, x: 420)
    run(f, 1)
    f.registerHit(b, head: true); f.registerHit(b, head: false)   // body hits do not count
    #expect(f.walk.fights.count == 1 && walker(f, b).wobble > 0)
    f.registerHit(b, head: true); f.registerHit(b, head: true)
    #expect(f.walk.fights.isEmpty && walker(f, a).cheer > 1.9)
    let loose = f.balls.first { $0.parent == nil && $0.radius == 10 }!
    #expect(loose.state == .falling && loose.pos.x > 420)   // kicked away from the winner
    run(f, 1)
    #expect(f.walk.walkers.map(\.key) == [a])   // the loser stands headless: no walker, no fight
    #expect(ball(f, b).snowmanAge < 0 && ball(f, loose.id).state == .resting)
    #expect(f.pickSnowball(at: CGPoint(x: CGFloat(ball(f, loose.id).pos.x), y: CGFloat(ball(f, loose.id).pos.y))) == loose.id)
    run(f, 3)   // the winner celebrates, then walks again
    #expect(walker(f, a).cheer == 0 && f.walk.fights.isEmpty)
}

@Test func puttingTheHeadBackRestoresTheSnowman() {
    let f = field()
    build(f, x: 300)
    let b = build(f, x: 420)
    run(f, 1)
    f.registerHit(b, head: true); f.registerHit(b, head: true); f.registerHit(b, head: true)
    run(f, 1)
    let head = f.balls.first { $0.parent == nil && $0.radius == 10 }!
    let mid = f.balls.first { $0.parent == b }!
    #expect(f.pickSnowball(at: CGPoint(x: CGFloat(head.pos.x), y: CGFloat(head.pos.y))) == head.id)
    f.drag(head.id, to: CGPoint(x: CGFloat(mid.pos.x), y: CGFloat(mid.pos.y) + 120), dt: 1 / 60)
    f.drop(head.id, throwing: false)
    run(f, 2)
    #expect(headOf(f, b)?.id == head.id && ball(f, b).snowmanAge >= 0.3)
    #expect(f.walk.walkers.contains { $0.key == b })   // walks (and may fight) again
}

@Test func fightEndsWhenTheDistanceGrowsOrOneIsKnockedOff() {
    let f = field()
    let a = build(f, x: 300), b = build(f, x: 420)
    run(f, 1)
    #expect(f.walk.fights.count == 1)
    f.balls[f.balls.firstIndex { $0.id == b }!].pos.x += 300   // e.g. the window was resized under them
    run(f, 0.1)
    #expect(f.walk.fights.isEmpty && walker(f, a).foe == nil && f.balls.contains { $0.id == b && $0.state == .resting })

    let g = field()
    let c = build(g, x: 300); build(g, x: 400)
    run(g, 1)
    #expect(g.walk.fights.count == 1)
    g.sweep(from: CGPoint(x: 395, y: 60), to: CGPoint(x: 405, y: 60), radius: 10)   // cursor through the second one
    run(g, 0.1)
    #expect(g.walk.fights.isEmpty && g.walk.walkers.map(\.key) == [c] && walker(g, c).foe == nil)
}

@Test func fightsKeepGoingUntilSomeoneLosesTheirHead() {
    for seed in UInt64(1)...4 {
        let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0, seed: seed)
        f.update(windows: [])
        let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
        for b in 0..<500 { f.surfaces[i].pile.heights[b] = 12 }
        build(f, x: 300); build(f, x: 420)
        run(f, 1)
        #expect(f.walk.fights.count == 1)
        var t: Float = 0
        while t < 400, !f.balls.contains(where: { $0.parent == nil && $0.radius == 10 }) { run(f, 1); t += 1 }
        #expect(t < 400 && f.walk.fights.isEmpty && f.walk.walkers.count == 1)
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
    f.snowman = Snowman(x: 300, surfaceID: Tuning.groundID, scale: 1, y: 14)
    f.snowman!.stage = Snowman.stageCount
    f.snowman!.stageAge = 1
    build(f, x: 420)
    run(f, 1)
    f.decapitate(0, away: 1, range: nil)
    #expect(f.snowman == nil && f.balls.count == 6)
    run(f, 2)
    let head = f.balls.first { $0.radius == Snowman.balls[2].r }!
    #expect(head.parent == nil && head.state == .resting && f.balls.filter { $0.parent != nil }.count == 3)
    #expect(f.walk.walkers.count == 1)   // only the user-built one is complete
}

// MARK: Wind

@Test func walkingAgainstTheWindIsSlowerThanWithIt() {
    func advance(_ g: Float) -> Float {   // distance walked along its heading in 2 s; gust sign relative to the heading
        let f = field()
        let id = build(f, x: 500)
        ready(f)
        f.walk.walkers[0].nextIdle = 100   // no pauses
        let dir = walker(f, id).dir, x0 = walker(f, id).x
        f.walk.gustOverride = g * dir
        run(f, 2)
        return (walker(f, id).x - x0) * dir
    }
    let against = advance(-1), calm = advance(0), with = advance(1)
    #expect(against < calm * 0.2 && with > calm && with <= calm * 1.5 + 0.5)
}

@Test func windNeverPushesAWalkerPastTheEnds() {
    for g: Float in [1, -1] {
        let f = field([win(1, 450, 0, 600, 60)])
        let id = build(f, x: 300)
        f.walk.gustOverride = g
        var lo = Float.infinity, hi = -Float.infinity
        for _ in 0..<(120 * 60) { f.step(dt: 1 / 60); let x = ball(f, id).pos.x; lo = min(lo, x); hi = max(hi, x) }
        #expect(lo >= 27.5 && hi <= 450 - 28 + 0.5 && ball(f, id).state == .resting)
    }
}

@Test func lightBreezesDoNotMoveSnowmenButNevascaGustsDo() {
    for level in [Intensity.leve, .media] {
        let f = field()
        f.setIntensity(level, immediate: true)
        var peak: Float = 0
        for _ in 0..<(40 * 60) { f.step(dt: 1 / 60); peak = max(peak, abs(f.gust)) }
        #expect(peak == 0)
    }
    let f = field()
    f.setIntensity(.nevasca, immediate: true)
    var peak: Float = 0
    for _ in 0..<(90 * 60) { f.step(dt: 1 / 60); peak = max(peak, abs(f.gust)) }
    #expect(peak > 0.3)
}

@Test func snowmenDoNotWalkThroughEachOther() {
    let f = field()
    let a = build(f, x: 300), b = build(f, x: 360)
    ready(f)
    f.walk.fights.removeAll()
    for i in f.walk.walkers.indices { f.walk.walkers[i].foe = nil; f.walk.walkers[i].rest = 1e6; f.walk.walkers[i].nextIdle = 1e6 }
    var closest = Float.infinity
    for _ in 0..<(60 * 60) { f.step(dt: 1 / 60); closest = min(closest, abs(ball(f, a).pos.x - ball(f, b).pos.x)) }
    #expect(closest >= 20 + 20 - 1)   // never closer than the two base balls touching
}

@Test func scarfFlutterGrowsWithWindAndStreamsDownwind() {
    func peak(_ g: Float) -> Float {   // largest wave of the lower tail over a flutter cycle
        (0..<64).map { abs(Flutter.make(gust: g, gait: 0, dir: 1, phase: Float($0) * 0.1, cheer: 0).wave) }.max()!
    }
    #expect(peak(1) > peak(0) * 2 && peak(0) > 0)   // calm air still flutters a little
    #expect(Flutter.rate(gust: 1, gait: 0) > Flutter.rate(gust: 0, gait: 0) && Flutter.rate(gust: 0, gait: 1) > Flutter.rate(gust: 0, gait: 0))
    for g: Float in [1, -1] {
        let p = Flutter.make(gust: g, gait: 0, dir: 1, phase: 0, cheer: 0)
        #expect(p.scarf * g > 1 && p.sway * g < 0)   // tail streams downwind (> 57 degrees), arms bend with it
    }
}

@Test func armsRaiseDuringTheCheerAndRestAfterwards() {
    func up(_ cheer: Float) -> Float { Flutter.make(gust: 0, gait: 0, dir: 1, phase: 0, cheer: cheer).up }
    #expect(up(0) == 0 && up(Tuning.cheerTime) == 0)
    #expect(up(1) == 1 && up(0.1) < 1)   // full V mid-cheer, lowering at the end
    let f = field()
    let a = build(f, x: 300), b = build(f, x: 420)
    run(f, 1)
    for _ in 0..<3 { f.registerHit(b, head: true) }
    run(f, 1)
    #expect(f.pose(of: a).up > 0.9 && f.pose(of: b).up == 0)
    run(f, 3)
    #expect(f.pose(of: a).up == 0)
}
