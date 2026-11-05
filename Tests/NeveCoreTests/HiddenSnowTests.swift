import CoreGraphics
import Testing
@testable import NeveCore

// Back window 1: x 100...400, top edge y=400. Front window 2 covers x 150...350 (bins 25...125 of the back pile).
private let cover = win(2, 150, 300, 200, 300)

private func piledBack() -> (SnowField, [Float]) {
    let f = makeField()
    f.update(windows: [back])
    pileUp(f, id: 1)
    return (f, f.pile(id: 1)!.heights)
}

@Test func hiddenSnowComesBackWhenTheFrontWindowLeaves() {
    let (f, before) = piledBack()
    #expect(before[75] > 10)
    let d0 = f.debris.count
    f.update(windows: [cover, back], dt: 0.5)
    let p = f.pile(id: 1)!
    #expect(!p.visible[75] && p.heights[75] == before[75])   // frozen, not zeroed
    #expect(f.debris.count == d0)                             // nothing falls in front of the window
    f.update(windows: [back], dt: 0.5)
    #expect(zip(f.pile(id: 1)!.heights, before).allSatisfy { abs($0 - $1) < 0.01 })
}

@Test func snowBesideAFrontWindowDoesNotDrainIntoHiddenColumns() {
    let (f, _) = piledBack()
    f.update(windows: [cover, back], dt: 0.5)
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    let hiddenBefore = Array(f.pile(id: 1)!.heights[26..<124])
    for _ in 0..<40 { f.deposit(surface: i, bin: 24, volume: 4); f.deposit(surface: i, bin: 126, volume: 4) }
    #expect(Array(f.pile(id: 1)!.heights[26..<124]) == hiddenBefore)
    #expect(f.pile(id: 1)!.heights[24] > 10)   // and the neighbour keeps its snow (a wall, not a drop)
}

@Test func sweepOverHiddenColumnsRemovesNothing() {
    let (f, _) = piledBack()
    f.update(windows: [cover, back], dt: 0.5)
    let before = f.pile(id: 1)!.heights, d0 = f.debris.count
    f.sweep(from: CGPoint(x: 180, y: 405), to: CGPoint(x: 320, y: 405), radius: 10)
    #expect(f.pile(id: 1)!.heights[30..<120] == before[30..<120])
    #expect(f.debris.count == d0 || f.debris.allSatisfy { $0.pos.x < 175 || $0.pos.x > 325 })   // only the uncovered ends may throw snow
}

@Test func coveringEverythingThenUncoveringKeepsEveryPile() {
    let f = makeField()
    let big = win(9, 0, 0, 1000, 780)
    f.update(windows: [back, win(3, 600, 150, 300, 250)])
    pileUp(f, id: 1); pileUp(f, id: 3)
    for _ in 0..<30 { for b in stride(from: 0, to: 500, by: 7) { f.deposit(surface: f.surfaces.count - 1, bin: b, volume: 4) } }   // ground
    let snap = f.surfaces.map { ($0.id, $0.pile.heights) }
    let d0 = f.debris.count
    f.update(windows: [big, back, win(3, 600, 150, 300, 250)], dt: 0.5)
    f.update(windows: [big, back, win(3, 600, 150, 300, 250)], dt: 0.5)
    #expect(f.debris.count == d0)
    f.update(windows: [back, win(3, 600, 150, 300, 250)], dt: 0.5)
    for (id, h) in snap { #expect(zip(f.pile(id: id)!.heights, h).allSatisfy { abs($0 - $1) < 0.01 }, "pile \(id)") }
}

@Test func hiddenSnowTravelsWithAMovingWindow() {
    let (f, before) = piledBack()
    f.update(windows: [cover, back], dt: 0.5)
    f.update(windows: [cover, win(1, 160, 200, 300, 200)], dt: 0.5)   // slow move +60: 30 bins
    f.update(windows: [win(1, 160, 200, 300, 200)], dt: 0.5)
    let h = f.pile(id: 1)!.heights
    #expect(zip(h, before).dropFirst(3).dropLast(3).allSatisfy { abs($0 - $1) < 0.01 })
}

// MARK: walkRange / index

/// The old O(bins) implementation, kept as the oracle.
private func oldWalkRange(_ f: SnowField, surface sid: Int, x: Float, half: Float) -> (Float, Float)? {
    guard let s = f.surfaces.first(where: { $0.id == sid }) else { return nil }
    let p = s.pile, n = p.heights.count, c = f.column(x) - s.c0
    guard c >= 0, c < n, p.visible[c] else { return nil }
    var a = c, b = c
    while a > 0 && p.visible[a - 1] { a -= 1 }
    while b < n - 1 && p.visible[b + 1] { b += 1 }
    let lo = max(Float(s.c0 + a) * Tuning.binWidth, p.x0), hi = min(Float(s.c0 + b + 1) * Tuning.binWidth, p.x1)
    return (lo + half + 8, hi - half - 8)
}

@Test func walkRangeMatchesTheLinearScanOn1000RandomQueries() {
    let f = makeField()
    f.update(windows: [win(5, 300, 250, 200, 100), win(2, 150, 300, 200, 300), win(4, 700, 200, 250, 200), back, win(6, 120, 100, 60, 60)])
    var g = SplitMix64(seed: 7)
    for _ in 0..<1000 {
        let sid = [1, 2, 4, 5, 6, 7, Tuning.groundID, 0].randomElement(using: &g)!
        let x = Float.random(in: -20...1020, using: &g), half = Float.random(in: 2...20, using: &g)
        let a = f.walkRange(surface: sid, x: x, half: half), b = oldWalkRange(f, surface: sid, x: x, half: half)
        #expect(a?.0 == b?.0 && a?.1 == b?.1)
    }
}

@Test func surfaceIndexStaysValidAcrossAddRemoveReorder() {
    let f = makeField()
    let w3 = win(3, 600, 200, 200, 200)
    for list in [[back, w3], [w3, back], [front, w3], [], [w3, front, back], [back]] {
        f.update(windows: list, dt: 0.5)
        #expect(f.index.count == f.surfaces.count)
        for (i, s) in f.surfaces.enumerated() { #expect(f.surface(id: s.id) == i) }
        #expect(f.surface(id: 99) == nil)
    }
}
