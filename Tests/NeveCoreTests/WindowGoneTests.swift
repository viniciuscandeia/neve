// AGENT HEADER - Tests/NeveCoreTests/WindowGoneTests.swift  (a window that disappears, with the PRODUCTION goneGrace of 0.6 s; makeField sets 0 so other suites close windows at once)
// Covers: the pile of a missing window stays in `surfaces` (drawn, no hole) until the grace ends and then falls even when the window list is unchanged; balls, gifts, user snowmen and the tree on it are RELEASED
//   at the deadline (fall / break into balls) instead of being discarded; a window back inside the grace keeps everything; a window zoomed up to the menu bar (`minHeadroom`) goes the same way.
// Related: Surfaces.update (`pendingGone`, `goneGrace`), Surfaces.knockOff, transportBalls/Gifts/Tree/Figures. Run: Tests/run.sh [-r] WindowGone.

import CoreGraphics
import Testing
@testable import NeveCore

private let a = win(1, 200, 300, 400, 200), b = win(2, 700, 100, 100, 50)

private func gracefulField() -> SnowField {
    let f = makeField()
    f.goneGrace = Tuning.goneGrace
    f.update(windows: [a, b]); pileUp(f, id: 1, rounds: 60)
    return f
}

@Test func theSnowOfAClosedWindowStaysDrawnUntilItFalls() {
    let f = gracefulField()
    let d0 = f.debris.count
    f.update(windows: [b], dt: 0.1)
    #expect(f.pile(id: 1) != nil && f.debris.count == d0)   // no hole while the grace runs
    f.update(windows: [b], dt: 0.3)
    #expect(f.pile(id: 1) != nil && f.debris.count == d0)
    f.update(windows: [b], dt: 0.3)   // unchanged list after the deadline: it still falls
    #expect(f.pile(id: 1) == nil && f.debris.count > d0)
}

@Test func ballsGiftsSnowmenAndTheTreeFallWhenTheirWindowIsReallyGone() {
    let f = gracefulField()
    f.treeEnabled = true
    stackBalls(f, x: 300, on: 1)
    stand(f, x: 400, on: 1)
    f.giftState.gifts.append(Gift(pos: SIMD2(450, 520), vel: .zero, surface: 1, rot: 0, spin: 0, color: 0, scale: 1))
    f.tree = Tree(pos: SIMD2(500, 500), state: .resting, surface: 1)
    f.update(windows: [b], dt: 0.1)
    f.update(windows: [b, win(3, 800, 600, 50, 50)], dt: 0.7)
    #expect(f.pile(id: 1) == nil)
    advance(f, 0.05)   // the stack's upper balls let go with their bottom one
    #expect(!f.balls.isEmpty && !f.balls.contains { $0.surfaceID == 1 })
    #expect(!f.figures.contains { $0.surfaceID == 1 })
    #expect(f.gifts.count == 1 && f.gifts[0].surface == nil)
    #expect(f.tree?.state == .falling && f.tree?.surface == nil)
}

@Test func aWindowBackInsideTheGraceKeepsSnowAndFigures() {
    let f = gracefulField()
    stackBalls(f, x: 300, on: 1)
    f.giftState.gifts.append(Gift(pos: SIMD2(450, 520), vel: .zero, surface: 1, rot: 0, spin: 0, color: 0, scale: 1))
    let h0 = f.pile(id: 1)!.heights, d0 = f.debris.count
    f.update(windows: [b], dt: 0.2)
    f.update(windows: [a, b], dt: 0.2)
    #expect(f.pile(id: 1)!.heights == h0 && f.debris.count == d0)
    #expect(f.balls.allSatisfy { $0.surfaceID == 1 } && f.gifts[0].surface == 1)
    f.update(windows: [a, b], dt: 1)
    #expect(f.pile(id: 1) != nil && f.debris.count == d0)
}

@Test func aWindowZoomedUpToTheMenuBarFallsAfterTheGrace() {
    let f = gracefulField()
    let d0 = f.debris.count
    let zoomed = win(1, 0, 0, 1000, 790)   // top within minHeadroom of the menu bar: carries no snow
    f.update(windows: [zoomed, b], dt: 0.1)
    #expect(f.pile(id: 1) != nil && f.debris.count == d0)
    f.update(windows: [zoomed, b], dt: 0.7)
    #expect(f.pile(id: 1) == nil && f.debris.count > d0)
}

// Supports: tree rest uses the three foot columns (a seam counts as one pile); balls / gifts / penguins never land on a covered bin.

@Test func aTreeWhoseFootHangsOffTheWindowEndFallsButOneOnAJoinedWindowStays() {
    let f = makeField(); f.treeEnabled = true
    f.update(windows: [win(1, 200, 300, 200, 200), win(2, 800, 300, 100, 200)])   // 1: x 200...400, top 500; 2 far away
    f.tree = Tree(pos: SIMD2(395, 500), state: .resting, surface: 1)   // centre on the pile, right foot column past its end, nothing joined
    f.step(dt: 1 / 60)
    #expect(f.tree?.state == .falling)
    let g = makeField(); g.treeEnabled = true
    g.update(windows: [win(1, 200, 300, 200, 200), win(2, 400, 300, 200, 200)])   // touching, same top: one mass
    g.tree = Tree(pos: SIMD2(395, 500), state: .resting, surface: 1)
    g.step(dt: 1 / 60)
    #expect(g.tree?.state == .resting && g.tree?.surface == 1)
}

@Test func nothingLandsOnABinUnderAnotherWindowsBody() {
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 200, 200), win(2, 200, 300, 400, 400)])   // 1 in front, top 500; 2 behind, top 700: 1's overlapped bins are visible but sit under 2's body
    let i = f.index[1]!
    #expect(f.surfaces[i].pile.visible[f.column(400) - f.surfaces[i].c0] && !f.surfaces[i].pile.open(f.column(400) - f.surfaces[i].c0))
    #expect(f.supportTop(x: 400, fromY: 600).map { f.surfaces[$0.0].id } == Tuning.groundID)   // between the two tops: the covered bin is skipped, only the ground is below
}
