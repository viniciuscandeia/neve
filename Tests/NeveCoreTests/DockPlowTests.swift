// AGENT HEADER - Tests/NeveCoreTests/DockPlowTests.swift  (cursor plow vs the Dock bar as an obstacle; heaps settle to a mound)
// 1440x900 field, Dock bar [400,1000) (top = edgeY of surface 0), ground snow 20 deep outside the span. A fast horizontal push along the ground toward the Dock never carries snow under the bar to the far side; it banks against the bar's side up to the
//   Dock top and the excess lands on the Dock's own pile at the near end (volume conserved: ground + Dock pile + debris + sweepOwed). Repeated pushes at the screen end / the Dock side leave a mound (neighbour step <= ~2x Tuning.slope), not a spike.
// A fast push crests chunks over the bar onto the Dock pile, a slow one does not (slowPushNeverCrestsOverTheDock). Related: Surfaces.swift (sweep / berm), Pile.settle.

import Testing
import CoreGraphics
@testable import NeveCore

private func dockWin() -> WindowInfo { WindowInfo(number: 0, frame: CGRect(x: 400, y: 10, width: 600, height: 84), radius: 25.2) }
private func field() -> SnowField {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 1)
    f.update(windows: [dockWin()])
    let g = f.index[Tuning.groundID]!
    for b in f.surfaces[g].pile.heights.indices where !(200..<500).contains(b) { f.surfaces[g].pile.heights[b] = 20 }
    return f
}
private func gh(_ f: SnowField) -> [Float] { f.pile(id: Tuning.groundID)!.heights }
private func vol(_ f: SnowField) -> Float {
    f.surfaces.reduce(0) { $0 + $1.pile.heights.reduce(0, +) } * Tuning.binWidth + f.debris.reduce(0) { $0 + $1.vol } + f.sweepOwed
}
private func maxStep(_ h: ArraySlice<Float>) -> Float { zip(h, h.dropFirst()).filter { min($0, $1) >= Tuning.dustDepth }.map { abs($0 - $1) }.max() ?? 0 }   // (a thin toe may step by dustSlope by design)

@Test func fastPushTowardTheDockNeverCarriesSnowToTheFarSide() {
    for dir: CGFloat in [1, -1] {
        let f = field()
        let before = vol(f), far0 = dir > 0 ? Array(gh(f)[500...]) : Array(gh(f)[..<200])
        let dockTop = Float(f.surfaces[f.index[0]!].frame.maxY), dockBefore = f.pile(id: 0)!.heights.reduce(0, +)
        var x: CGFloat = dir > 0 ? 100 : 1340
        for _ in 0..<40 {
            f.sweep(from: CGPoint(x: x, y: 14), to: CGPoint(x: x + 30 * dir, y: 14), dt: 1 / 60)
            x += 30 * dir
            if (dir > 0 && x > 390) || (dir < 0 && x < 1010) { x = dir > 0 ? 100 : 1340 }
        }
        for _ in 0..<5 { f.step(dt: 1 / 60) }
        let g = gh(f)
        // the far side of the Dock (500... / ...200 are the columns under the bar's other half and beyond) gains nothing
        let far = dir > 0 ? Array(g[500...]) : Array(g[..<200])
        for (a, b) in zip(far, far0) { #expect(a <= b + 0.01) }
        #expect(g[(dir > 0 ? 160 : 500)..<(dir > 0 ? 200 : 540)].max()! > 25 || f.pile(id: 0)!.heights.reduce(0, +) > dockBefore)
        #expect(g.max()! <= dockTop + 1)
        #expect(abs(vol(f) - before) < before * 0.005)
    }
}

@Test func excessOverTheDockTopLandsOnTheDockPile() {
    let f = field()
    let dockBefore = f.pile(id: 0)!.heights.reduce(0, +)
    var x: CGFloat = 100
    for _ in 0..<400 {
        f.sweep(from: CGPoint(x: x, y: 14), to: CGPoint(x: x + 30, y: 14), dt: 1 / 60)
        x += 30; if x > 390 { x = 100 }
        let g = f.index[Tuning.groundID]!
        for b in 0..<200 where b < 100 || b > 195 { f.surfaces[g].pile.heights[b] = max(f.surfaces[g].pile.heights[b], 20) }   // refill the plowed strip: plenty of snow to push
    }
    for _ in 0..<180 { f.step(dt: 1 / 60) }   // the chunks that crested over land
    #expect(f.pile(id: 0)!.heights.reduce(0, +) > dockBefore + 20)
}

// A fast push crests over the bar (chunks arc onto the Dock pile); a slow push only heaps against its side.
@Test func slowPushNeverCrestsOverTheDock() {
    func run(step: CGFloat) -> Float {
        let f = field()
        let dockBefore = f.pile(id: 0)!.heights.reduce(0, +)
        var x: CGFloat = 100
        for _ in 0..<400 {
            f.sweep(from: CGPoint(x: x, y: 14), to: CGPoint(x: x + step, y: 14), dt: 1 / 60)
            x += step; if x > 390 { x = 100 }
            let g = f.index[Tuning.groundID]!
            for b in 0..<200 where b < 100 || b > 195 { f.surfaces[g].pile.heights[b] = max(f.surfaces[g].pile.heights[b], 20) }
        }
        for _ in 0..<180 { f.step(dt: 1 / 60) }
        return f.pile(id: 0)!.heights.reduce(0, +) - dockBefore
    }
    #expect(run(step: 30) > 20)       // 1800 pt/s
    #expect(run(step: 5) < 1, "slow push (300 pt/s) must not cross")
}

@Test func repeatedPushesAtTheScreenEndMakeAMoundNotASpike() {
    let f = field()
    var x: CGFloat = 1100
    for _ in 0..<300 {
        f.sweep(from: CGPoint(x: x, y: 14), to: CGPoint(x: x + 30, y: 14), dt: 1 / 60)
        x += 30; if x > 1420 { x = 1100 }
        let g = f.index[Tuning.groundID]!
        for b in 560..<640 { f.surfaces[g].pile.heights[b] = max(f.surfaces[g].pile.heights[b], 20) }
    }
    for _ in 0..<240 { f.step(dt: 1 / 60) }   // the blade moves on: the heap slumps to its repose slope
    let h = gh(f)
    #expect(h.max()! > 40)
    #expect(maxStep(h[600...]) <= 2 * (Tuning.slope + Tuning.moundSlope) + 0.01)   // the compacted heap's flanks stand at ~45 degrees (slope + moundSlope per bin)
}
