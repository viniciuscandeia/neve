import CoreGraphics
import Testing
@testable import NeveCore

// Space switches and the carrying of snow when windows move / resize (L3).

private func dockWin() -> WindowInfo { WindowInfo(number: 0, frame: CGRect(x: 300, y: 10, width: 400, height: 84), radius: 25.2) }
private func total(_ p: Pile) -> Float { p.heights.reduce(0, +) }
private func switchSpace(_ f: SnowField) { f.dropPiles(); f.markStale() }

@Test func spaceSwitchKeepsTheDockPileAndWhatStandsOnIt() {
    let f = makeField()
    f.update(windows: [dockWin(), back])
    pileUp(f, id: 0)
    let h = f.pile(id: 0)!.heights
    #expect(h.max()! > 0)
    let g = stand(f, x: 500, on: 0)
    stackBalls(f, x: 400, on: 0)
    let nb = f.balls.count
    switchSpace(f)
    f.update(windows: [dockWin()], now: 1)   // the window is gone, the Dock is not
    #expect(f.pile(id: 0)!.heights == h)
    #expect(f.figures.map(\.id) == [g])
    #expect(f.balls.count == nb)
}

@Test func windowPresentBeforeAndAfterASpaceSwitchKeepsItsSnow() {
    let f = makeField()
    f.update(windows: [front, back])
    pileUp(f, id: 1)
    let h = f.pile(id: 1)!.heights
    let g = stand(f, x: 150, on: 1)
    switchSpace(f)
    f.update(windows: [back, win(3, 600, 300, 200, 100)], now: 1)   // `front` left, `back` stayed (an all-Spaces window, say)
    #expect(f.pile(id: 1)!.heights.count == h.count)
    #expect(f.pile(id: 1)!.heights.max()! > 0)
    #expect(f.figures.map(\.id) == [g])
    #expect(f.stash[2] == nil)   // no snow of its own: nothing to set aside
}

@Test func vanishedWindowComesBackAtAnotherXWithTheSameWidth() {
    let f = makeField()
    f.update(windows: [back])
    pileUp(f, id: 1)
    let n = f.pile(id: 1)!.heights.count, vol = total(f.pile(id: 1)!)
    switchSpace(f)
    let before = f.debris.count
    f.update(windows: [], now: 1)
    #expect(f.debris.count == before && f.stash[1] != nil)
    f.update(windows: [win(1, 500, 200, 300, 200)], now: 2)
    #expect(f.pile(id: 1)!.heights.count == n)
    #expect(total(f.pile(id: 1)!) > vol * 0.8)
    #expect(f.stash[1] == nil)
}

@Test func frostAndIciclesSurviveASpaceRoundTrip() {
    let f = makeField()
    f.update(windows: [back])
    pileUp(f, id: 1)
    f.iceWin.append(WinIce(id: 1, acc: Tuning.frozenAfter, fill: 1, frost: 1, frozen: true, w0: 300, h0: 200))
    switchSpace(f)
    f.update(windows: [], now: 1)
    #expect(f.stash[1]?.ice?.frozen == true)
    f.update(windows: [back], now: 2)
    #expect(f.iceWin.first { $0.id == 1 }?.frost == 1)
    f.setIntensity(.leve)
    advance(f, 2)
    #expect(f.iceWin.first { $0.id == 1 }?.frozen == true)
    #expect(f.icicles.contains { $0.win == 1 })
}

@Test func movingAndResizingTogetherCarriesSnowByTheShiftWhenTheWidthIsKept() {
    let f = makeField()
    f.update(windows: [win(1, 100, 200, 300, 200)], now: 0)
    pileUp(f, id: 1)
    let before = f.pile(id: 1)!
    f.update(windows: [win(1, 200, 200, 300, 260)], now: 10)   // 100 pt right, 60 pt taller
    let after = f.pile(id: 1)!
    #expect(after.c0 == before.c0 + 50)
    let mid = before.heights.count / 2
    #expect(abs(after.heights[mid] - before.heights[mid]) < 1.5)   // snow rode along instead of staying at the old screen x
}

@Test func carryShedsWhatNoLongerFitsAsDebrisAndConservesVolume() {
    let f = makeField()
    f.update(windows: [back], now: 0)
    pileUp(f, id: 1)
    let before = total(f.pile(id: 1)!)
    f.update(windows: [win(3, 100, 408, 300, 100), win(1, 110, 200, 300, 200)], now: 10)   // a window now hangs 8 pt above its edge while it slides: the pile no longer fits
    f.step(dt: 1 / 60)
    let kept = total(f.pile(id: 1)!)
    let debris = f.debris.reduce(0) { $0 + $1.vol }
    #expect(kept < before)
    #expect(debris > 0)
    #expect(abs(kept * Tuning.binWidth + debris - before * Tuning.binWidth) < before * Tuning.binWidth * 0.1 + 2)
}

@Test func piledSnowKeepsItsEasedHeightsAcrossAMoveAndTheGroundRebuild() {
    let f = makeField()
    f.update(windows: [back, dockWin()], now: 0)
    pileUp(f, id: 1)
    pileUp(f, id: Tuning.groundID)
    let i = f.index[1]!, g = f.index[Tuning.groundID]!
    f.surfaces[i].pile.shown = f.surfaces[i].pile.heights.map { $0 * 0.5 }
    f.surfaces[g].pile.shown = f.surfaces[g].pile.heights.map { $0 * 0.5 }
    let gs = f.surfaces[g].pile.shown
    f.update(windows: [win(1, 140, 200, 300, 200), dockWin()], now: 10)
    let after = f.pile(id: 1)!
    let mid = after.heights.count / 2
    #expect(after.shown.count == after.heights.count)
    #expect(after.shown[mid] < after.heights[mid] * 0.7)   // still mid-ease, not snapped
    #expect(f.pile(id: Tuning.groundID)!.shown == gs)
}

@Test func anUnchangedWindowKeepsItsVelocityWhenAnotherOneMoves() {
    let f = makeField()
    f.update(windows: [win(1, 100, 200, 300, 200), win(2, 600, 200, 200, 200)], now: 0)
    f.update(windows: [win(1, 130, 200, 300, 200), win(2, 600, 200, 200, 200)], now: 0.1)
    let v = f.surfaces[f.index[1]!].vel.x
    #expect(v > 10)
    f.update(windows: [win(1, 130, 200, 300, 200), win(2, 620, 200, 200, 200)], now: 0.12)   // only window 2 moved
    #expect(f.surfaces[f.index[1]!].vel.x > v * 0.5)
}

@Test func snowPastTheScreenEdgeIsKeptAndComesBack() {
    let f = makeField()
    f.update(windows: [win(1, 100, 200, 300, 200)], now: 0)
    pileUp(f, id: 1)
    let before = f.pile(id: 1)!
    f.update(windows: [win(1, -100, 200, 300, 200)], now: 10)   // 200 pt pushed past the left edge
    #expect(f.pile(id: 1)!.heights.count < before.heights.count)
    f.update(windows: [win(1, 100, 200, 300, 200)], now: 20)
    let after = f.pile(id: 1)!
    #expect(after.heights.count == before.heights.count)
    #expect(abs(total(after) - total(before)) < total(before) * 0.1)
}
