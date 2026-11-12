// AGENT HEADER - Tests/NeveCoreTests/LoteHTests.swift  (state bugs found in the quality review, "Lote H")
// Each test failed before its fix: a disabled tree stashed with a window does not return on a Space switch (B1); a frost-only window is stashed (B2); resize() drops the ghost windows (N2);
//   the overflow debt `owedL/R` survives a window move / resize and a Space round trip (N3); slab and heavy-impact crumbs carry volume (total snow before == after settling); a burst chunk born inside a pile is buried, and a fast piece lands before the bottom-of-screen removal (not lost); `Pile.empty()` clears
//   the pending spill and peel; a ball under a window in front is not a mouse target; debris of a tree shake / popped gift / snowball spray / broken icicle carry their window's origin z.

import CoreGraphics
import Testing
@testable import NeveCore

private func switchSpace(_ f: SnowField) { f.dropPiles(); f.markStale() }
private func everything(_ f: SnowField) -> Float {   // pile volume (height units) + snow still in the air as debris
    f.surfaces.reduce(0) { $0 + $1.pile.heights.reduce(0, +) } + f.debris.reduce(0) { $0 + $1.vol } / Tuning.binWidth
}

@Test func disablingTheTreeAlsoRemovesTheOneStashedWithAWindow() {
    let f = makeField()
    f.update(windows: [back])
    f.treeEnabled = true
    var t = Tree(pos: SIMD2(250, 400), scale: 1); t.state = .resting; t.surface = 1
    f.tree = t
    switchSpace(f)
    f.update(windows: [], now: 1)
    #expect(f.stash[1]?.tree != nil)
    f.treeEnabled = false
    #expect(!f.hasTree)
    f.update(windows: [back], now: 2)
    #expect(f.tree == nil && !f.hasTree)
}

@Test func aFrostOnlyWindowIsStashedOnASpaceSwitch() {
    let f = makeField()
    f.update(windows: [back])
    f.iceWin.append(WinIce(id: 1, acc: 0, fill: 1, frost: 1, frozen: false, w0: 300, h0: 200))
    switchSpace(f)
    f.update(windows: [], now: 1)
    #expect(f.stash[1]?.ice?.frost == 1)
}

@Test func resizeForgetsTheGhostWindows() {
    let f = makeField()
    f.goneGrace = 0.6
    f.update(windows: [back])
    f.update(windows: [], now: 0.1)
    #expect(!f.pendingGone.isEmpty)
    f.resize(size: CGSize(width: 1200, height: 800), origin: .zero, groundY: 90, visibleTop: 780)
    #expect(f.pendingGone.isEmpty)
    let g = makeField()
    g.goneGrace = 0.6
    g.update(windows: [back])
    g.update(windows: [], now: 0.1)
    g.clear()
    #expect(g.pendingGone.isEmpty)
}

@Test func theOverflowDebtSurvivesAMoveAResizeAndASpaceTrip() {
    func owed(_ f: SnowField) -> Float { let p = f.pile(id: 1)!; return p.owedL + p.owedR }
    let f = makeField()
    f.update(windows: [win(1, 100, 200, 300, 200)])
    for b in 10..<20 { f.surfaces[f.index[1]!].pile.heights[b] = 5 }   // something to stash
    f.surfaces[f.index[1]!].pile.owedL = 40; f.surfaces[f.index[1]!].pile.owedR = 25
    f.update(windows: [win(1, 130, 200, 300, 200)], now: 10)   // dragged
    #expect(owed(f) == 65)
    f.update(windows: [win(1, 130, 200, 340, 220)], now: 20)   // resized
    #expect(owed(f) == 65)
    switchSpace(f)
    f.update(windows: [], now: 21)
    f.update(windows: [win(1, 130, 200, 340, 220)], now: 22)
    #expect(owed(f) == 65)
}

@Test func aHeavyImpactKeepsItsCrumbsInTheVolumeLedger() {
    let f = makeField()
    f.update(windows: [win(1, 200, 300, 300, 200)])
    let si = f.index[1]!, top = f.surfaces[si].edgeY
    f.impact(surface: si, bin: Int(350 / Tuning.binWidth) - f.surfaces[si].c0, x: 350, top: top, fall: 400, vol: 60)
    advance(f, 6)
    #expect(f.debris.isEmpty)
    #expect(abs(everything(f) - 60 / Tuning.binWidth) < 1e-3)
}

@Test func aShedSlabsCrumbsKeepTheVolumeLedger() {
    let f = makeField()
    f.update(windows: [win(1, 200, 300, 300, 200)])
    let c0 = f.surfaces[f.index[1]!].c0
    for k in 0..<8 { _ = f.shedBin(col: c0 + 40 + k, edgeY: 500, from: 0, amount: 10, velocity: .zero) }   // one run is at most 8 bins: a single slab + crumbs
    _ = f.flushRuns()
    advance(f, 6)
    #expect(f.debris.isEmpty)
    #expect(abs(everything(f) - 80) < 0.05)
}

@Test func clearForgetsPendingSpillAndPeel() {
    let f = makeField()
    f.update(windows: [back])
    let si = f.index[1]!
    f.surfaces[si].pile.spillL = 30; f.surfaces[si].pile.spillR = 30; f.surfaces[si].pile.peel = [Float](repeating: 0.1, count: f.surfaces[si].pile.heights.count)
    f.clear()
    #expect(f.surfaces[si].pile.spillL == 0 && f.surfaces[si].pile.spillR == 0 && !f.surfaces[si].pile.peeling)
    advance(f, 1)
    #expect(f.debris.isEmpty)
}

@Test func aBallUnderAWindowInFrontIsNotAMouseTarget() {
    let f = makeField()
    f.update(windows: [win(1, 200, 300, 300, 200)])
    var b = Snowball(id: f.nextBallID, pos: SIMD2(350, 520), radius: 18, surfaceID: 1)
    f.nextBallID += 1; b.state = .resting
    f.balls.append(b)
    #expect(f.hitTest(point: CGPoint(x: 350, y: 520)))
    f.update(windows: [win(2, 150, 280, 450, 300), win(1, 200, 300, 300, 200)])   // 2 covers the ball's column
    #expect(!f.hitTest(point: CGPoint(x: 350, y: 520)))
    #expect(f.pickSnowball(at: CGPoint(x: 350, y: 520)) == nil)
}

@Test func debrisFromATreeAGiftASprayAndAnIcicleCarryTheirWindowsZ() {
    let f = makeField()
    f.update(windows: [win(2, 600, 300, 200, 200), win(1, 100, 200, 300, 200)])   // 2 in front (z 0), 1 behind (z 1)
    let z2 = f.originZ(id: 2)
    #expect(z2 != .max)
    func check(_ what: String, _ body: () -> Void) {
        f.debris.removeAll()
        body()
        #expect(!f.debris.isEmpty, "\(what): no debris")
        #expect(f.debris.allSatisfy { $0.oz == z2 }, "\(what): origin z")
    }
    check("tree") {
        var t = Tree(pos: SIMD2(700, 500), scale: 1); t.state = .resting; t.surface = 2; t.snow = SIMD4(repeating: 1)
        f.shakeTree(&t, fraction: 1)
    }
    check("gift") {
        f.giftState.gifts = [Gift(pos: SIMD2(700, 520), vel: .zero, surface: 2, spin: 0, color: 0, scale: 1)]
        f.breakGifts(690, 520, 710, 520, 10, .zero)
    }
    check("spray") {
        var s = Shot(pos: .zero, from: SIMD2(650, 520), to: SIMD2(700, 500), peak: 20, dur: 0.6, hit: false, head: false, target: 0, surface: 2)
        f.land(&s)
    }
    check("icicle") {
        f.icicles = [Icicle(win: 2, slot: 0, dx: 0, len: 12, maxLen: 20, width: 3, tilt: 0, w0: 200, x: 700, y: 500)]
        f.breakIcicle(0, .zero)
    }
}


@Test func aBurstOnTheGroundLosesNoVolume() {
    let f = makeField()
    f.update(windows: [])
    let id = standAuto(f, x: 500)
    func area() -> Float { f.surfaces.reduce(0) { $0 + ($1.pile.heights.reduce(0, +) + $1.pile.spillL + $1.pile.spillR + $1.pile.owedL + $1.pile.owedR) * Tuning.binWidth } }
    let a0 = area()
    f.shatter(id, velocity: .zero, burst: true)
    let carried = f.debris.reduce(0) { $0 + $1.vol }
    advance(f, 10)
    let accounted = area() - a0 + f.bankRefused + f.debris.reduce(0) { $0 + $1.vol }
    #expect(accounted >= carried * 0.98 && accounted <= carried * 1.02)
}
