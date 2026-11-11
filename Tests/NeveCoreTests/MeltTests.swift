// AGENT HEADER - Tests/NeveCoreTests/MeltTests.swift  (Melt.swift + Drips.swift)
// Piles drain monotonically within the duration, nothing spawns or lands and actors are gone during a melt, intro cancels a melt and keeps what is left, resume starts from the top with no flake on screen, deterministic, Reduce Motion melt = quick fade, drops form only while melting and respect the cap (none in calm/economy/low power), resumed melt restores the stack, closing the window terminates.

import CoreGraphics
import Testing
@testable import NeveCore

private func snowy(seed: UInt64 = 7, calm: Bool = false) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 200, seed: seed)
    f.setCalm(calm)
    f.update(windows: [win(1, 300, 400, 300, 150)])
    f.stage(.heavy)
    return f
}

private func trace(_ f: SnowField, seconds: Float, dt: Float = 1.0 / 60) -> [Float] {
    var v: [Float] = []
    for _ in 0..<Int(seconds / dt) { f.step(dt: dt); v.append(f.pileVolume) }
    return v
}

@Test func meltDrainsPilesMonotonicallyWithinDuration() {
    let f = snowy()
    advance(f, 1)
    #expect(f.pileVolume > 0)
    f.beginMelt(duration: 5)
    #expect(f.isMelting)
    let v = trace(f, seconds: 5.5)
    for k in 1..<v.count { #expect(v[k] <= v[k - 1] + 1e-3) }
    #expect(v.last == 0)
    #expect(f.meltDone)
}

@Test func nothingSpawnsOrLandsDuringMeltAndActorsAreGone() {
    let f = snowy()
    advance(f, 3)
    #expect(f.activeFlakes > 0)
    f.beginMelt(duration: 5)
    advance(f, 1.6)
    #expect(f.flakes.allSatisfy { $0.kind == .dormant || $0.kind == .debris || $0.fade < 0.01 || $0.pos.y > 0 })
    var maxActive = f.activeFlakes
    for _ in 0..<240 { f.step(dt: 1 / 60); maxActive = max(maxActive, f.activeFlakes) }
    #expect(maxActive <= 5)   // no new flakes; the fading ones are nearly out
    advance(f, 2)
    #expect(f.figures.isEmpty && f.balls.isEmpty && f.icicles.isEmpty && f.gifts.isEmpty && f.debris.isEmpty)
    #expect(f.activeFlakes == 0 && f.pileVolume == 0 && f.meltDone)
}

@Test func introCancelsMeltAndKeepsWhatIsLeft() {
    let f = snowy()
    advance(f, 1)
    let before = f.pileVolume
    f.beginMelt(duration: 5)
    advance(f, 2)
    let mid = f.pileVolume
    #expect(mid < before && mid > 0)
    f.beginIntro(duration: 2.5)
    #expect(!f.isMelting)
    advance(f, 1)
    #expect(f.pileVolume >= mid - 1e-3)   // not melting anymore (new snow may add)
}

@Test func resumeStartsFromTheTopWithNoFlakeOnScreen() {
    let f = snowy()
    advance(f, 3)
    f.beginMelt(duration: 5)
    advance(f, 5.1)
    #expect(f.meltDone)
    f.beginIntro(duration: 2.5)
    #expect(f.activeFlakes == 0)
    for _ in 0..<12 {   // 0.2 s: still entering, nowhere near mid-screen
        f.step(dt: 1 / 60)
        for fl in f.flakes where fl.kind != .dormant { #expect(fl.pos.y >= 780 - 25) }
    }
    advance(f, 3)
    #expect(f.activeFlakes > 20)
}

@Test func meltIsDeterministic() {
    func run() -> [Float] { let f = snowy(seed: 3); advance(f, 2); f.beginMelt(duration: 4); return trace(f, seconds: 4.2) }
    #expect(run() == run())
}

@Test func reduceMotionMeltIsAQuickFade() {
    let f = snowy(calm: true)
    advance(f, 2)
    f.beginMelt(duration: 5)
    advance(f, 1.1)
    #expect(f.meltDone && f.pileVolume == 0 && f.figures.isEmpty)
}

private func dripCount(_ f: SnowField) -> Int { f.drops.count }

@Test func dropsFormOnlyWhileMeltingAndRespectTheCap() {
    let f = snowy()
    advance(f, 3)
    #expect(dripCount(f) == 0)
    f.beginMelt(duration: 5)
    var peak = 0, total = 0, last = 0
    for _ in 0..<(60 * 6) {
        f.step(dt: 1 / 60)
        peak = max(peak, dripCount(f)); #expect(dripCount(f) <= Tuning.maxDrops)
        if dripCount(f) > last { total += dripCount(f) - last }
        last = dripCount(f)
    }
    #expect(peak > 0 && total >= 4)
    #expect(dripCount(f) == 0)   // melt done
    f.beginIntro(duration: 2); f.step(dt: 1 / 60)
    #expect(dripCount(f) == 0)
}

@Test func noDropsInCalmEconomyOrLowPower() {
    for mode in 0..<3 {
        let f = snowy(calm: mode == 0)
        f.economy = mode == 1
        if mode == 2 { f.setLowPower(true) }
        advance(f, 2)
        f.beginMelt(duration: 5)
        var n = 0
        for _ in 0..<300 { f.step(dt: 1 / 60); n += dripCount(f) }
        #expect(n == 0)
    }
}

@Test func dropsAreDeterministicAndEmitInstances() {
    func run() -> [Float] {
        let f = snowy(seed: 3)
        advance(f, 3); f.beginMelt(duration: 5); advance(f, 2.5)
        return f.drops.flatMap { [$0.pos.x, $0.pos.y] }
    }
    #expect(run() == run())
    let f = snowy(seed: 3)
    advance(f, 3); f.beginMelt(duration: 5); advance(f, 2.5)
    let p = UnsafeMutablePointer<Instance>.allocate(capacity: f.capacity); defer { p.deallocate() }
    let n = f.writeInstances(to: p)
    #expect(n <= f.capacity)
    #expect((0..<n).filter { p[$0].kind == 5 }.count == f.drops.count)
}

@Test func resumedMeltRestoresStackAndClosingItsWindowTerminates() {
    let f = makeField()
    f.update(windows: [win(1, 200, 300, 300, 200)])
    let w = f.surfaces.firstIndex { $0.id == 1 }!
    for b in f.surfaces[w].pile.heights.indices { f.surfaces[w].pile.heights[b] = 12 }
    let id = stand(f, x: 350, on: 1)
    let (r0, b0) = (fig(f, id).radii, fig(f, id).built)
    f.beginMelt(duration: 12)
    advance(f, 2)
    #expect(fig(f, id).built < Snowman.stageCount || fig(f, id).radii.x < r0.x)
    f.beginIntro(duration: 2)
    #expect(fig(f, id).built == b0 && fig(f, id).radii.x < r0.x)   // accessories return at once, the sag eases back (no snap)
    advance(f, 2)
    #expect(fig(f, id).radii == r0)
    // a partial stack that cannot demote must be removed when its window closes, not loop forever
    f.figures[f.figureIndex(id)!].built = 5
    f.update(windows: [])
    var steps = 0
    while f.figures.contains(where: { $0.id == id }) && steps < 600 { f.step(dt: 1 / 60); steps += 1 }
    #expect(steps < 600)
}

@Test func clearRemovesEveryAccumulatedEffectButKeepsCooldowns() {
    let f = makeField()
    f.update(windows: [win(1, 300, 400, 300, 150)])
    f.stage(.heavy)
    advance(f, 1)
    let gi = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in 0..<500 { f.surfaces[gi].pile.heights[b] = 12 }
    f.figures.removeAll()   // the field may have grown its own auto snowman
    standAuto(f, x: 400)
    f.iceWin.append(WinIce(id: 1, acc: 1, fill: 1, frost: 1, frozen: true, w0: 300, h0: 150))
    f.icicles.append(Icicle(win: 1, slot: 0, dx: 0, len: 10, maxLen: 20, width: 3, tilt: 0, w0: 300))
    f.dropGift(at: SIMD2(400, 300), dir: 1)
    f.drops.append(Drop(pos: SIMD2(350, 300), size: 2, src: 1))
    f.debris.append(Flake(pos: [100, 100], vx: 0, fall: 0, phase: 0, amp: 0, freq: 0, size: 4, alpha: 1, kind: .debris))
    f.snowmanCooldown = 123
    #expect(!f.gifts.isEmpty && !f.figures.isEmpty && !f.drops.isEmpty && !f.iceWin.isEmpty)
    f.clear()
    #expect(f.gifts.isEmpty && f.figures.isEmpty && f.drops.isEmpty && f.iceWin.isEmpty && f.icicles.isEmpty && f.debris.isEmpty && f.pileVolume == 0)
    #expect(f.snowmanCooldown == 123)
}

// MARK: clear() vs. director visits and emission debts

private func clearField(speed: Float = 30) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0,
                      config: SimConfig(directorSpeed: speed), seed: 3)
    f.update(windows: [win(1, 200, 300, 500, 200)])
    for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = 12 } }
    f.visitorsEnabled = true
    return f
}

@Test func clearDuringDirectorVisitLeavesFiniteCooldownAndVisitsResume() {
    let f = clearField()
    var kind: FigureKind?
    for _ in 0..<20_000 {
        directorRun(f, seconds: 1, visit: 1e9)
        if let g = f.figures.first(where: { $0.kind != .snowman }) { kind = g.kind; break }
    }
    let k = try! #require(kind)
    #expect(f.director.cooldownUntil[Int(k.rawValue)] == .infinity)
    f.clear()
    let cd = f.director.cooldownUntil[Int(k.rawValue)]
    #expect(cd.isFinite && f.figures.isEmpty)
    let started = f.director.started
    directorRun(f, seconds: 20_000)
    #expect(f.director.started > started)
}

@Test func clearKeepsAlreadyFiniteCooldowns() {
    let f = clearField()
    f.director.cooldownUntil[Int(FigureKind.penguin.rawValue)] = 1234
    f.clear()
    #expect(f.director.cooldownUntil[Int(FigureKind.penguin.rawValue)] == 1234)
}

@Test func clearDropsPendingDockVolumeAndSweepDebt() {
    let f = clearField()
    f.dockTrickle.vol = (20, 20); f.sweepOwed = 300
    f.clear()
    #expect(f.dockTrickle.vol == (0, 0) && f.sweepOwed == 0)
    advance(f, 20)
    #expect(f.pileVolume == 0 && f.debris.isEmpty)
}

@Test func meltFinishesEvenIfAnAirborneElementNeverExpires() {
    let f = snowy()
    advance(f, 1)
    f.beginMelt(duration: 2)
    advance(f, 2.1)
    f.puffs.append(Flake(pos: [500, 400], vx: 0, fall: 0, phase: 0, amp: 0, freq: 0, size: 4, alpha: 1, kind: .debris, fade: 1, delay: 1e9, shape: 3))
    #expect(!f.meltDone)
    advance(f, 2.5)
    #expect(f.meltDone && f.puffs.isEmpty)
}
