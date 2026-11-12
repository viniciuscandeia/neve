// AGENT HEADER - Tests/NeveCoreTests/IceAvalancheTests.swift  (Icicles + Avalanche)
// Icicles (3 windows 100/400/700 x, piles frozen after ~200 s at 4 fps): a fast drag shatters them into slab debris, a slow move carries them, a resize breaks them, Reduce Motion fades them without debris, breaking one does not bump pileVersion.
// Avalanche (`stackedField`: a top window above a wide full one): `triggerAvalanche` feeds the lower pile, `chain.cascades` <= 3, one chain at a time with a 60 s cooldown, none under Reduce Motion, volume conserved (removed == `chain.released`,
//   carried by debris `vol`). Uses `chain` internals (started / released / cascades).

import CoreGraphics
import Testing
@testable import NeveCore

/// Three windows with piles (frozen after ~3 min of snowfall).
private func iceField(seed: UInt64 = 1) -> SnowField {
    let f = makeField(seed: seed)
    f.update(windows: [win(1, 100, 500, 200, 150), win(2, 400, 500, 200, 150), win(3, 700, 500, 200, 150)])
    for id in 1...3 { pileUp(f, id: id) }
    f.chain.cooldownUntil = .infinity   // icicles need ~200 s of undisturbed piles: since avalanches got frequent (spontaneous after 60 s full) a full window would shed first, and this suite is about icicles
    return f
}

@Test func fastDragShattersIciclesIntoSlabDebris() {
    let f = iceField()
    advance(f, 200, fps: 4)   // frozen
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
    advance(f, 200, fps: 4)   // frozen
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
    advance(f, 200, fps: 4)   // frozen
    f.update(windows: [win(1, 100, 500, 200, 150), win(2, 400, 500, 260, 150), win(3, 700, 500, 200, 150)], dt: 1)
    f.step(dt: 1.0 / 60)
    #expect(f.icicles.filter { $0.win == 2 }.isEmpty)
}

@Test func reduceMotionFadesIciclesAndSpawnsNoDebris() {
    let f = iceField()
    advance(f, 200, fps: 4)   // frozen
    f.setCalm(true)
    let d0 = f.debris.count
    for j in f.iceWin.indices where f.iceWin[j].id == 3 { f.iceWin[j].frozen = false; f.iceWin[j].acc = 0 }   // window 3 thawed
    f.surfaces[f.index[3]!].pile.empty()
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
    for seed in 1...100 as ClosedRange<UInt64> {
        let f = stackedField(seed: seed)
        let lower = f.pile(id: 2)!.heights.reduce(0, +)
        #expect(f.triggerAvalanche(near: CGPoint(x: 480, y: 550)))
        var maxCascades = 0
        for _ in 0..<(60 * 20) { f.step(dt: 1.0 / 60); maxCascades = max(maxCascades, f.chain.cascades) }
        #expect(maxCascades <= 3)
        if f.chain.started == 1, maxCascades > 0 { cascaded += 1 }
        #expect(f.chain.released > 0)
        #expect(f.pile(id: 2)!.heights.reduce(0, +) >= lower * 0.85)   // slabs land on it (it may shed at its own ends)
    }
    #expect(cascaded > 0)
}

@Test func onlyOneChainAtATimeWithCooldown() {
    let f = stackedField(seed: 3)
    #expect(f.triggerAvalanche(near: CGPoint(x: 480, y: 550)))
    #expect(!f.triggerAvalanche(near: CGPoint(x: 300, y: 550)))   // running
    for _ in 0..<(60 * 5) { f.step(dt: 1.0 / 60) }
    pileUp(f, id: 1, rounds: 14, keepSpill: true)
    #expect(!f.avalancheActive)
    #expect(!f.triggerAvalanche(near: CGPoint(x: 480, y: 550)))   // cooldown
    advance(f, 61, fps: 30)
    pileUp(f, id: 1, rounds: 14, keepSpill: true)
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

// Breaking an icicle changes no pile geometry: the pile version stays, and the slab debris still appears (and is drawn).
@Test func breakingAnIcicleDoesNotInvalidateThePiles() {
    let f = iceField()
    advance(f, 200, fps: 4)   // frozen
    #expect(!f.icicles.isEmpty)
    let p = UnsafeMutablePointer<Instance>.allocate(capacity: 8192)
    defer { p.deallocate() }
    let drawn0 = f.writeInstances(to: p)
    let v = f.pileVersion, n = f.icicles.count, d = f.debris.count
    f.breakIcicle(0, .zero)
    #expect(f.pileVersion == v && f.icicles.count == n - 1 && f.debris.count >= d + 2)
    #expect(f.writeInstances(to: p) >= drawn0 + 2)
}

/// Frequency: a full window lets go on its own within ~6 min (after the 60 s "full" wait, p = dt/240 per second) in most runs; slowly moving a full window (60..150 pt/s) also releases snow.
@Test func fullWindowLetsGoSpontaneouslyWithinSixMinutesAndOnASlowMove() {
    var went = 0
    for seed in 1...20 as ClosedRange<UInt64> {
        let f = makeField(seed: seed)
        f.update(windows: [win(1, 200, 400, 400, 150)])
        pileUp(f, id: 1, rounds: 14)
        advance(f, 360, fps: 10)
        if f.chain.started > 0 { went += 1 }
    }
    #expect(went >= 10)   // expected ~70 %; with the old 300 s wait / 600 s mean it was ~0 within 6 min
    let g = makeField(seed: 1)
    g.update(windows: [win(1, 200, 400, 400, 150)])
    pileUp(g, id: 1, rounds: 14)
    g.update(windows: [win(1, 280, 400, 400, 150)], dt: 1)   // 80 pt/s
    g.step(dt: 1.0 / 60)
    #expect(g.chain.started == 1)
}
