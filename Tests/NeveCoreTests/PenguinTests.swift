import CoreGraphics
import Testing
@testable import NeveCore

private func field(speed: Float = 1, seed: UInt64 = 1, windows: [WindowInfo] = [win(1, 100, 300, 800, 200)], height: Float = 12) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0,
                      config: SimConfig(directorSpeed: speed), seed: seed)
    f.update(windows: windows)
    for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = height } }
    f.visitorsEnabled = true
    return f
}

private func penguins(_ f: SnowField) -> [Figure] { f.figures.filter { $0.kind == .penguin } }
private func heights(_ f: SnowField, _ sid: Int = 1) -> [Float] { f.pile(id: sid)!.heights }

/// Steps until `done` (or `limit` s); returns whether it came true.
@discardableResult
private func run(_ f: SnowField, limit: Float = 60, until done: () -> Bool) -> Bool {
    for _ in 0..<Int(limit * 60) { f.step(dt: 1 / 60); if done() { return true } }
    return false
}

@Test func penguinSlideCarvesAContinuousGrooveWithBerms() {
    let f = field()
    let before = heights(f)
    #expect(f.startPenguin())
    var sliding = false, x0: Float = 0, x1: Float = 0
    run(f) {
        guard let p = penguins(f).first else { return true }
        if p.penguin.stage == .slide { if !sliding { x0 = p.foot.x }; sliding = true; x1 = p.foot.x }
        return sliding && p.penguin.stage != .slide
    }
    #expect(sliding && abs(x1 - x0) > 40)
    let h = heights(f), s = f.surfaces[f.index[1]!]
    let lo = min(x0, x1), hi = max(x0, x1)
    var worst = -Float.infinity
    var x = lo + 6
    while x <= hi - 6 {   // every column along the path is lower than before: no gaps
        let c = f.column(x) - s.c0
        worst = max(worst, h[c] - before[c])
        x += Tuning.binWidth
    }
    #expect(worst < -0.5)
    let ahead = x0 < x1 ? hi : lo, sd: Float = x0 < x1 ? 1 : -1
    var berm: Float = 0
    for k in 0..<20 { let c = f.column(ahead + sd * Float(k) * 2) - s.c0; berm = max(berm, h[c] - before[c]) }
    #expect(berm > 0)   // plowed snow banked ahead of where it stopped
}

@Test func penguinLaunchesOffARestingBallAndLands() {
    let f = field()
    #expect(f.startPenguin())
    advance(f, 1)
    let p0 = penguins(f)[0], sid = p0.surfaceID!, si = f.index[sid]!
    let bx = p0.foot.x + p0.penguin.dir * 20
    var b = Snowball(id: f.nextBallID, pos: SIMD2(bx, f.standY(si: si, x: bx) + 8), radius: 10, surfaceID: sid)
    f.nextBallID += 1; b.state = .resting
    f.balls.append(b)
    var launched = false, vy: Float = 0, spin: Float = 0
    run(f, limit: 10) {
        guard let p = penguins(f).first else { return true }
        if p.penguin.stage == .air, !launched { launched = true; vy = p.penguin.vel.y; spin = p.penguin.spin }
        return launched
    }
    #expect(launched && vy > 0 && spin != 0)
    let ended = run(f, limit: 10) { penguins(f).first.map { $0.penguin.stage != .air } ?? true }
    #expect(ended)
    if let p = penguins(f).first { #expect(p.surfaceID != nil) }   // landed on a surface (else it left the screen)
}

@Test func penguinOffTheWindowEndLandsOnTheGroundOrLeaves() {
    let f = field(windows: [win(1, 100, 300, 300, 200)])
    #expect(f.startPenguin())
    var flew = false, landedLower = false
    run(f, limit: 90) {
        guard let p = penguins(f).first else { return true }
        if p.penguin.stage == .air { flew = true }
        if flew, p.penguin.stage == .waddle, let s = p.surfaceID, s <= 0 { landedLower = true; return true }
        return false
    }
    #expect(flew || landedLower || penguins(f).isEmpty)   // flew off, landed on the ground, or hopped down: always ends
    if flew { #expect(landedLower || penguins(f).isEmpty) }
}

@Test func penguinIsWindowOnlyAndNeedsASnowyWideRun() {
    #expect(!field(windows: [win(1, 100, 300, 190, 200)]).startPenguin())      // run under 200pt
    #expect(!field(height: 2).startPenguin())                                  // mean h < 3
    let g = field(); g.groundOnlyActors = true
    #expect(!g.startPenguin())
    let c = field(); c.areaScale = 0.4
    #expect(!c.startPenguin())
    let none = field(windows: [])
    #expect(!none.startPenguin())                                              // ground only: no window top
    for mode in 0..<2 {   // the director never picks it in compact / behind-windows mode
        let f = field(speed: 30, seed: 5)
        if mode == 0 { f.groundOnlyActors = true } else { f.areaScale = 0.4 }
        for _ in 0..<(10 * 60 * 20) { f.step(dt: 1 / 20); #expect(penguins(f).isEmpty) }
    }
}

@Test func penguinNeverSpawnsInReduceMotionAndLeavesWhenItStarts() {
    let f = field(speed: 30)
    f.setCalm(true)
    advance(f, 120, fps: 20)
    #expect(f.director.started == 0 && penguins(f).isEmpty)
    let g = field(speed: 30)
    #expect(g.startPenguin())
    advance(g, 1)
    g.setCalm(true)
    advance(g, 0.5)
    #expect(penguins(g).isEmpty)
}

@Test func penguinCountsAgainstTheAmbientCapAndOnlyOneAtATime() {
    let f = field()
    #expect(f.startPenguin() && !f.startPenguin())
    f.economy = true   // one ambient at a time
    f.request(.penguin, after: 0)
    advance(f, 3, fps: 20)
    #expect(f.director.started == 0 && penguins(f).count == 1)
    let g = field()
    g.visitorsEnabled = true
    g.director.lastStart = g.time
    g.request(.penguin, after: 0)   // follow-ups skip the gap
    advance(g, 3, fps: 20)
    #expect(penguins(g).count == 1 && g.director.started == 1)
}

@Test func penguinDucksUnderTheCursorInsteadOfBreaking() {
    let f = field()
    #expect(f.startPenguin())
    advance(f, 1)
    let p = penguins(f)[0]
    f.sweepFigures(p.foot.x - 30, p.foot.y + 8, p.foot.x + 30, p.foot.y + 8, 12, SIMD2(300, 0))
    advance(f, 0.1)
    #expect(penguins(f).count == 1 && penguins(f)[0].penguin.duck > 0 && penguins(f)[0].pose.hop > 0)
}

@Test func penguinVisitsAreDeterministic() {
    func go() -> (Int, Int, Float, Float) {
        let f = field(speed: 30, seed: 11)
        for _ in 0..<(5 * 60 * 20) { f.step(dt: 1 / 20) }
        return (f.director.started, f.figures.count, f.figures.reduce(0) { $0 + $1.foot.x }, heights(f).reduce(0, +))
    }
    let a = go(), b = go()
    #expect(a == b && a.0 > 0)
}

@Test func penguinSlidePlowsAShallowGrooveAndConservesSnow() {
    let f = field()
    let area: () -> Float = { f.pile(id: 1)!.heights.reduce(0, +) * Tuning.binWidth }
    let flying: () -> Float = { f.debris.reduce(0) { $0 + $1.size * Tuning.depositScale * Tuning.binWidth } }
    let before = area(), start = heights(f)
    #expect(f.startPenguin())
    var prev = start, maxDrop: Float = 0, sliding = false, x0: Float = 0, x1: Float = 0
    for _ in 0..<(60 * 60) {
        f.step(dt: 1 / 60)
        let h = heights(f)
        guard let p = penguins(f).first else { break }
        if p.penguin.stage == .slide {
            if !sliding { x0 = p.foot.x }
            sliding = true; x1 = p.foot.x
            for b in h.indices { maxDrop = max(maxDrop, prev[b] - h[b]) }
        } else if sliding { break }
        prev = h
    }
    #expect(sliding && abs(x1 - x0) > 40)
    #expect(maxDrop < 3)   // eased in over a few pt of travel: no column pops
    let c0 = f.surfaces[f.index[1]!].c0, lo = f.column(min(x0, x1) + 8) - c0, hi = f.column(max(x0, x1) - 8) - c0
    let h = heights(f), depth = (lo...hi).map { 12 - h[$0] }
    #expect(depth.min()! > 0.5 && depth.max()! <= Tuning.penguinGroove + 0.01)
    run(f, limit: 10) { f.debris.isEmpty }
    let after = area() + flying()
    #expect(abs(after - before) < Tuning.penguinPuff + 0.03 * before)
}

