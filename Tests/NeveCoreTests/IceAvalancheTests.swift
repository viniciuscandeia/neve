import CoreGraphics
import Testing
@testable import NeveCore

/// Three windows with piles (so there are enough icicle slots), each >= 8pt tall at the ends.
private func iceField(seed: UInt64 = 1) -> SnowField {
    let f = makeField(seed: seed)
    f.update(windows: [win(1, 100, 500, 200, 150), win(2, 400, 500, 200, 150), win(3, 700, 500, 200, 150)])
    for id in 1...3 { pileUp(f, id: id) }
    return f
}

@Test func icicleGrowsPast10ptInTenMinutesWhereThePileIsTall() {
    let f = iceField()
    advance(f, 600, fps: 4)
    #expect(!f.icicles.isEmpty)
    for c in f.icicles { #expect(c.len >= min(c.maxLen, 10) - 0.5) }
    #expect(f.icicles.contains { $0.len >= 10 })
    for c in f.icicles { #expect(c.len <= c.maxLen && c.maxLen >= 6 && c.maxLen <= 18) }
}

@Test func noIciclesWhereThePileIsLowAndCapsHold() {
    let f = makeField()
    f.update(windows: [win(1, 100, 500, 200, 150)])
    pileUp(f, id: 1, rounds: 1, volume: 1)   // < 8pt
    advance(f, 600, fps: 4)
    #expect(f.icicles.isEmpty)
    let g = iceField()
    advance(g, 120, fps: 4)
    #expect(g.icicles.count <= 24)
    for id in 1...3 { #expect(g.icicles.filter { $0.win == id }.count <= 6) }
}

@Test func fastDragShattersIciclesIntoSlabDebris() {
    let f = iceField()
    advance(f, 5, fps: 4)
    let n = f.icicles.filter { $0.win == 2 }.count
    #expect(n > 0)
    let d0 = f.debris.count
    f.update(windows: [win(1, 100, 500, 200, 150), win(2, 400 + 150, 500, 200, 150), win(3, 700, 500, 200, 150)], dt: 0.1)   // 1500 pt/s
    f.step(dt: 1.0 / 60)
    #expect(f.icicles.filter { $0.win == 2 }.isEmpty)
    #expect(f.debris.count >= d0 + 2 * n)
}

@Test func slowMoveCarriesIciclesAlong() {
    let f = iceField()
    advance(f, 5, fps: 4)
    let before = f.icicles.filter { $0.win == 2 }
    #expect(!before.isEmpty)
    f.update(windows: [win(1, 100, 500, 200, 150), win(2, 410, 500, 200, 150), win(3, 700, 500, 200, 150)], dt: 1)   // 10 pt/s
    f.step(dt: 1.0 / 60)
    let after = f.icicles.filter { $0.win == 2 }
    #expect(after.count == before.count)
    for (a, b) in zip(after, before) { #expect(abs(a.x - b.x - 10) < 0.5) }
}

@Test func resizeBreaksIcicles() {
    let f = iceField()
    advance(f, 5, fps: 4)
    f.update(windows: [win(1, 100, 500, 200, 150), win(2, 400, 500, 260, 150), win(3, 700, 500, 200, 150)], dt: 1)
    f.step(dt: 1.0 / 60)
    #expect(f.icicles.filter { $0.win == 2 }.isEmpty)
}

@Test func reduceMotionFadesIciclesAndSpawnsNoDebris() {
    let f = iceField()
    advance(f, 5, fps: 4)
    f.setCalm(true)
    let d0 = f.debris.count
    f.surfaces[f.index[3]!].pile.empty()   // the snow under window 3's icicles is gone
    f.step(dt: 1.0 / 60)
    #expect(f.icicles.contains { $0.dying && $0.win == 3 })
    #expect(f.debris.count == d0)
    advance(f, 1, fps: 30)
    #expect(!f.icicles.contains { $0.win == 3 })
}

/// Top window above a wide, full lower one: slabs from the top pile fall on the lower pile.
private func stackedField(seed: UInt64) -> SnowField {
    let f = makeField(seed: seed)
    f.update(windows: [win(1, 200, 400, 400, 150), win(2, 100, 100, 700, 150)])   // tops at 550 and 250
    pileUp(f, id: 1, rounds: 14); pileUp(f, id: 2, rounds: 14)
    return f
}

@Test func avalancheFeedsTheLowerPileAndCascadeDepthIsBounded() {
    var cascaded = 0
    for seed in 1...30 as ClosedRange<UInt64> {
        let f = stackedField(seed: seed)
        let lower = f.pile(id: 2)!.heights.reduce(0, +)
        #expect(f.triggerAvalanche(near: CGPoint(x: 480, y: 550)))
        var maxCascades = 0
        for _ in 0..<(60 * 20) { f.step(dt: 1.0 / 60); maxCascades = max(maxCascades, f.chain.cascades) }
        #expect(maxCascades <= 3)
        if f.chain.started == 1, maxCascades > 0 { cascaded += 1 }
        #expect(f.chain.released > 0)
        #expect(f.pile(id: 2)!.heights.reduce(0, +) >= lower * 0.9)   // slabs land on it (it may shed at its own ends)
    }
    #expect(cascaded > 0)
}

@Test func onlyOneChainAtATimeWithCooldown() {
    let f = stackedField(seed: 3)
    #expect(f.triggerAvalanche(near: CGPoint(x: 480, y: 550)))
    #expect(!f.triggerAvalanche(near: CGPoint(x: 300, y: 550)))   // running
    for _ in 0..<(60 * 5) { f.step(dt: 1.0 / 60) }
    pileUp(f, id: 1, rounds: 14)
    #expect(!f.avalancheActive)
    #expect(!f.triggerAvalanche(near: CGPoint(x: 480, y: 550)))   // cooldown
    advance(f, 61, fps: 30)
    pileUp(f, id: 1, rounds: 14)
    #expect(f.triggerAvalanche(near: CGPoint(x: 480, y: 550)))
}

@Test func reduceMotionHasNoAvalanche() {
    let f = stackedField(seed: 3)
    f.setCalm(true)
    #expect(!f.triggerAvalanche(near: CGPoint(x: 480, y: 550)))
}

@Test func avalancheConservesVolume() {
    let f = makeField(seed: 5)
    f.update(windows: [win(1, 200, 400, 400, 150)])
    pileUp(f, id: 1, rounds: 14)
    let before = f.pile(id: 1)!.heights.reduce(0, +) * Tuning.binWidth
    #expect(f.triggerAvalanche(near: CGPoint(x: 480, y: 550)))
    for _ in 0..<120 { f.stepAvalanche(dt: 1.0 / 60) }   // debris not stepped: nothing lands yet
    let removed = before - f.pile(id: 1)!.heights.reduce(0, +) * Tuning.binWidth
    let carried = f.debris.reduce(0) { $0 + $1.vol }
    #expect(removed > 100)
    #expect(carried <= removed * 1.001 && carried > 0.8 * removed)   // the rest (thin end columns) leaves as plain dots
    #expect(abs(removed - f.chain.released) < 0.001 * removed)
}
