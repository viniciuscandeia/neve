// AGENT HEADER - Tests/NeveCoreTests/ActorsLoteGTests.swift  (Figures+Penguin.swift, Figures+Robin.swift, Walk.swift actorBlocked)
// Penguin always crosses a seam to the touching window (never sinks / launches there); it spawns on the backmost eligible window; penguin and robin never start on / walk into a snowman, tree or gift (`actorBlocked`); the penguin ducks when its window moves faster
// than robinSurfaceSpeed or an avalanche `impactAt` lands near.

import CoreGraphics
import Testing
@testable import NeveCore

private func field(seed: UInt64 = 1, windows: [WindowInfo] = [win(1, 100, 300, 800, 200)]) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0, seed: seed)
    f.update(windows: windows)
    for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = 12 } }
    f.visitorsEnabled = true
    return f
}
/// A finished user snowman, already `active` (past its 0.3 s build-up).
@discardableResult private func snowman(_ f: SnowField, x: Float) -> Int { let id = stand(f, x: x, on: 1); f.figures[f.figureIndex(id)!].stageAge = 1; return id }
private func penguin(_ f: SnowField) -> Figure? { f.figures.first { $0.kind == .penguin } }

@Test func penguinAtASeamAlwaysCrossesToTheNeighbour() {
    for seed in 1...12 as ClosedRange<UInt64> {
        let f = field(seed: seed, windows: [win(1, 100, 300, 300, 200), win(2, 403, 300, 300, 200)])
        #expect(f.startPenguin())
        let i = f.figures.firstIndex { $0.kind == .penguin }!
        f.figures[i].foot.x = 385; f.figures[i].at = .surface(id: 1, x: 385); f.figures[i].foot.y = f.standY(si: f.index[1]!, x: 385)
        f.figures[i].penguin.stage = .waddle; f.figures[i].penguin.dir = 1; f.figures[i].penguin.life = 100
        advance(f, 2)
        let p = penguin(f)
        #expect(p != nil && p!.surfaceID == 2 && p!.penguin.stage != .sink && p!.penguin.launches == 0, "seed \(seed): \(String(describing: p?.surfaceID)) \(String(describing: p?.penguin.stage))")
    }
}

@Test func penguinSpawnsOnTheBackWindowNotTheFrontOne() {
    for seed in 1...6 as ClosedRange<UInt64> {
        let f = field(seed: seed, windows: [win(1, 100, 300, 300, 200), win(2, 600, 300, 300, 200)])   // 1 = front
        #expect(f.startPenguin())
        #expect(penguin(f)?.surfaceID == 2, "seed \(seed)")
    }
}

@Test func penguinDoesNotSpawnOnASnowmanTreeOrGift() {
    for kind in 0..<3 {
        var probe: Float = 0
        do { let f = field(); #expect(f.startPenguin()); probe = penguin(f)!.foot.x }
        let f = field()
        switch kind {
        case 0: snowman(f, x: probe)
        case 1: f.tree = Tree(pos: SIMD2(probe, 100), state: .resting, surface: 1, scale: 1)
        default: f.giftState.gifts.append(Gift(pos: SIMD2(probe, 100), vel: .zero, surface: 1, spin: 0, color: 0, scale: 1))
        }
        let ok = f.startPenguin()
        #expect(!ok || abs(penguin(f)!.foot.x - probe) > 20, "kind \(kind)")
    }
}

@Test func penguinTurnsBackAtASnowman() {
    let f = field()
    let sid = snowman(f, x: 310), si = f.figureIndex(sid)!
    f.figures[si].motion.idle = 100
    #expect(f.startPenguin())
    let i = f.figures.firstIndex { $0.kind == .penguin }!
    f.figures[i].foot.x = 250; f.figures[i].at = .surface(id: 1, x: 250)
    f.figures[i].penguin.stage = .waddle; f.figures[i].penguin.dir = 1; f.figures[i].penguin.life = 100; f.figures[i].penguin.sinceSlide = -100
    for _ in 0..<(60 * 6) { f.step(dt: 1 / 60); if let p = penguin(f) { #expect(p.foot.x < 310) } }
}

@Test func robinNeverPicksASpotOnTheSnowman() {
    for seed in 1...10 as ClosedRange<UInt64> {
        let f = field(seed: seed, windows: [win(1, 200, 300, 500, 200)])
        snowman(f, x: 450)
        #expect(f.startRobin())
        #expect(abs(f.figures.first { $0.kind == .robin }!.robin.to.x - 450) > 30, "seed \(seed)")
    }
}

@Test func penguinDucksWhenItsWindowMovesFastOrAnAvalancheLandsNear() {
    let f = field()
    #expect(f.startPenguin())
    advance(f, 1)
    #expect(penguin(f)!.penguin.duck == 0)
    let i = f.figures.firstIndex { $0.kind == .penguin }!, si = f.index[1]!
    f.surfaces[si].vel = SIMD2(100, 0)
    f.step(dt: 1 / 60)
    #expect(penguin(f)!.penguin.duck > 0)
    f.surfaces[si].vel = .zero
    advance(f, 1)
    #expect(penguin(f)!.penguin.duck == 0)
    f.impactAt = (f.figures[i].foot.x + 10, f.figures[i].foot.y, f.time)
    f.step(dt: 1 / 60)
    #expect(penguin(f)!.penguin.duck > 0)
}
