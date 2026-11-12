// AGENT HEADER - Tests/NeveCoreTests/RobinTests.swift  (Figures+Robin.swift)
// Perch -> shake -> stay -> leave, a shot landing near a perched robin startles it and a full pile may loosen an avalanche, a fast cursor startles (a slow one does not), a moving window startles, none in Reduce Motion / compact mode, director starts robins within the caps, the story stages a robin before the rabbit steals and shots miss closer to the robin.

import CoreGraphics
import Testing
@testable import NeveCore

private func field(speed: Float = 1, seed: UInt64 = 1, windows: [WindowInfo] = [win(1, 200, 300, 500, 200)], height: Float = 12) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0,
                      config: SimConfig(directorSpeed: speed), seed: seed)
    f.update(windows: windows)
    for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = height } }
    f.visitorsEnabled = true
    return f
}

private func robin(_ f: SnowField) -> Figure? { f.figures.first { $0.kind == .robin } }
private func rabbit(_ f: SnowField) -> Figure? { f.figures.first { $0.kind == .rabbit } }

/// Steps until `until` holds (or `limit` seconds); true when it did.
@discardableResult
private func run(_ f: SnowField, limit: Float = 60, fps: Float = 60, _ until: () -> Bool) -> Bool {
    for _ in 0..<Int(limit * fps) { if until() { return true }; f.step(dt: 1 / fps) }
    return until()
}

private func perched(_ f: SnowField) -> Bool { robin(f).map { $0.robin.stage == .perch || $0.robin.stage == .shake } ?? false }

private func fill(_ f: SnowField) {
    for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = f.surfaces[si].pile.limit(b) } }
}

@Test func robinPerchesShakesStaysAndLeaves() {
    let f = field()
    #expect(f.startRobin())
    #expect(!f.startRobin())   // one at a time
    #expect(run(f) { perched(f) })
    let x = robin(f)!.foot.x, si = f.index[1]!, c = f.column(x) - f.surfaces[si].c0
    #expect(robin(f)!.surfaceID == 1 && robin(f)!.robin.landedT < 1)
    let before = f.surfaces[si].pile.heights[c]
    #expect(run(f) { robin(f)!.robin.shook })
    let r = robin(f)!.robin
    #expect(r.carved > 0 && f.surfaces[si].pile.heights[c] < before - 1.0)   // dent ~1.5pt deep at the centre
    let t0 = f.time
    #expect(run(f, limit: 40) { robin(f) == nil })
    #expect(f.time - t0 > 4 && !r.startled)   // stayed 8...20 s after landing
    #expect(f.figures.isEmpty)
}

@Test func shotLandingNearAPerchedRobinStartlesItAndAFullPileLoosensAnAvalanche() {
    func play(full: Bool) -> (SnowField, Bool) {
        let f = field(height: 6)   // 6: clearly below avaFullFraction (0.7) of the limit, which the default 12 now reaches
        if full { fill(f) }
        _ = f.startRobin()
        run(f) { perched(f) }
        let r = robin(f)!, from = SIMD2(r.foot.x - 150, r.foot.y + 20), to = SIMD2(r.foot.x + 40, r.foot.y)
        f.shots.append(Shot(pos: from, from: from, to: to, peak: 10, dur: 0.1, hit: false, head: false, target: -1, surface: 1))
        var left = false
        for _ in 0..<30 { f.step(dt: 1 / 60); if let q = robin(f), q.robin.stage == .leave, q.robin.startled { left = true; break } }
        return (f, left)
    }
    let (a, leftA) = play(full: false)
    #expect(leftA && a.chain.started == 0)
    let (b, leftB) = play(full: true)
    #expect(leftB && b.chain.started == 1)
    advance(b, 1)
    #expect(b.chain.released > 0)
    #expect(run(b, limit: 10) { robin(b) == nil })   // burst takeoff: gone fast
}

@Test func fastCursorNearStartlesButASlowOneDoesNot() {
    for (speed, startles) in [(Float(100), false), (Float(450), true)] {
        let f = field()
        _ = f.startRobin()
        run(f) { perched(f) }
        let r = robin(f)!
        f.setPointer(SIMD2(r.foot.x + 25, r.foot.y + 4), velocity: SIMD2(speed, 0))
        advance(f, 0.1)
        #expect((robin(f)!.robin.stage == .leave) == startles)
    }
}

@Test func movingWindowStartlesTheRobin() {
    let f = field()
    _ = f.startRobin()
    run(f) { perched(f) }
    f.surfaces[f.index[1]!].vel = SIMD2(120, 0)
    advance(f, 0.1)
    #expect(robin(f)!.robin.stage == .leave && robin(f)!.robin.startled)
}

@Test func noRobinInReduceMotionAndNoneInCompactMode() {
    let f = field(speed: 30)
    f.setCalm(true)
    advance(f, 300, fps: 20)
    #expect(f.director.started == 0 && robin(f) == nil)
    let g = field(speed: 30, seed: 4)
    g.areaScale = 0.4
    #expect(!g.startRobin())
    advance(g, 300, fps: 20)
    #expect(g.figures.allSatisfy { $0.kind != .robin })
    let h = field(speed: 30, seed: 4)
    h.groundOnlyActors = true
    #expect(!h.startRobin())
    let shorty = field(windows: [win(1, 200, 300, 70, 200)])   // 70pt of top: under 80
    #expect(!shorty.startRobin())
}

@Test func directorStartsRobinsAndKeepsTheCaps() {
    let f = field(speed: 30, seed: 9)
    _ = stand(f, x: 450, on: 1)
    advance(f, 0.5)
    var seen = false, most = 0
    directorRun(f, seconds: 20 * 60) {
        if robin(f) != nil { seen = true }
        most = max(most, f.figures.filter { $0.kind != .snowman }.count)
    }
    #expect(seen && most <= EventDirector.maxAmbient)
    let g = field()
    g.economy = true
    _ = stand(g, x: 450, on: 1)
    advance(g, 0.5)
    #expect(g.startRabbit())
    g.request(.robin, after: 0)
    advance(g, 3, fps: 20)
    #expect(robin(g) == nil)   // economy: one at a time
}

@Test func storyStagesARobinBeforeTheRabbitSteals() {
    let f = field()
    f.director.story.chance = 1
    let sn = stand(f, x: 450, on: 1)
    advance(f, 0.5)
    f.request(.rabbit, after: 0)
    advance(f, 3, fps: 20)
    #expect(rabbit(f) != nil && f.director.story.active)
    #expect(run(f) { perched(f) })
    #expect(rabbit(f)!.critter.stage != .snatch || !fig(f, sn).carrot)
    #expect(fig(f, sn).carrot || rabbit(f)!.critter.stage != .flee)   // the rabbit waited (still sniffing) until the robin landed
    #expect(run(f) { !fig(f, sn).carrot })
    // no robin possible (compact): the story degrades to a normal visit
    let g = field()
    g.director.story.chance = 1
    g.areaScale = 0.4
    _ = stand(g, x: 450, on: 1)
    advance(g, 0.5)
    g.request(.rabbit, after: 0)
    advance(g, 3, fps: 20)
    #expect(rabbit(g) == nil || !g.director.story.active)
}

@Test func storyMissesLandCloserToTheRobinThanWithoutTheBias() {
    func meanDistance(story: Bool) -> (Float, Int) {
        var sum: Float = 0, n = 0
        for seed in 1...30 {
            let f = field(seed: UInt64(seed))
            f.rabbitHitScale = 0
            _ = stand(f, x: 450, on: 1)
            advance(f, 0.5)
            f.director.story.x = 300; f.director.story.surface = 1
            _ = f.startRobin()
            run(f) { perched(f) }
            f.director.story.active = story
            _ = f.startRabbit()
            var last: Double = -1
            for _ in 0..<(30 * 60) {
                f.step(dt: 1 / 60)
                guard let s = f.shotLand, s.t != last else { if rabbit(f) == nil { break }; continue }
                last = s.t
                if let r = robin(f), !r.robin.flying, let q = rabbit(f), abs(q.foot.x - r.foot.x) <= 200 { sum += abs(s.p.x - r.foot.x); n += 1 }
            }
        }
        return (sum / Float(max(n, 1)), n)
    }
    let on = meanDistance(story: true), off = meanDistance(story: false)
    #expect(on.1 >= 8 && off.1 >= 8)
    #expect(on.0 < off.0 - 15)
    let again = meanDistance(story: true)
    #expect(again == on)   // deterministic
}
