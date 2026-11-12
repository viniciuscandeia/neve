// AGENT HEADER - Tests/NeveCoreTests/CorniceTests.swift  (lot 8: cornice at unsupported window ends, Pile.eaveL/R + stepEaves / dropEave + Contour eave slices)
// A lone snowy window grows a cornice at both bare ends (volume taken from the end bins, so snow is conserved), it is capped and released as ONE block (debris, store back to 0); wind toward an end feeds it faster;
//   it melts away where the snow is gone; a supported end (touching neighbour) never grows one; it is drawn past the real window edge with a rounded underside, and nothing is drawn without it.
// Related: Effects.swift (cornice), Contour.swift (eave slices), Pile.eaveEnd.

import CoreGraphics
import Testing
@testable import NeveCore

private func lone() -> (SnowField, Int) {
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    pileUp(f, id: 1, rounds: 40)
    return (f, f.surfaces.firstIndex { $0.id == 1 }!)
}

@Test func aBareEndGrowsACorniceConservingSnowAndDropsItAsOneBlock() {
    let (f, i) = lone()
    let before = f.surfaces[i].pile.heights.reduce(0, +) * Tuning.binWidth
    var peak: Float = 0, dropped = false, blocks = 0
    for _ in 0..<(60 * 90) {
        let d0 = f.debris.filter { $0.shape == 2 && $0.amp > 0 }.count
        f.step(dt: 1.0 / 60)
        blocks += max(0, f.debris.filter { $0.shape == 2 && $0.amp > 0 }.count - d0)
        let p = f.surfaces[i].pile
        peak = max(peak, p.eaveL, p.eaveR)
        if peak > 0, p.eaveL == 0 || p.eaveR == 0 { dropped = true }
        #expect(p.eaveL <= Tuning.eaveMax && p.eaveR <= Tuning.eaveMax)
    }
    #expect(peak > 4, "grew to \(peak)")
    #expect(dropped && blocks >= 1, "released as a block")
    let p = f.surfaces[i].pile
    #expect(p.heights.reduce(0, +) * Tuning.binWidth < before)   // the cornice and its blocks took snow out of the end bins
}

@Test func windTowardAnEndFeedsItFaster() {
    func eave(wind: Float) -> Float {
        let (f, i) = lone()
        f.windSlow = wind
        f.stepEaves(dt: 0.5)
        return f.surfaces[i].pile.eaveR
    }
    #expect(eave(wind: Tuning.windBiasRef) > eave(wind: 0) * 1.5)
    #expect(eave(wind: -Tuning.windBiasRef) < eave(wind: Tuning.windBiasRef))
}

@Test func aSupportedEndNeverGrowsOne() {
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 200, 200), win(2, 504, 300, 200, 200)])
    pileUp(f, id: 1, rounds: 40); pileUp(f, id: 2, rounds: 40)
    for _ in 0..<200 { f.stepEaves(dt: 0.5) }
    let a = f.surfaces.first { $0.id == 1 }!.pile, b = f.surfaces.first { $0.id == 2 }!.pile
    #expect(a.supportR ? a.eaveR == 0 : true)
    #expect(b.supportL ? b.eaveL == 0 : true)
}

@Test func theCorniceMeltsAwayWhereTheSnowIsGone() {
    let (f, i) = lone()
    f.surfaces[i].pile.eaveL = 5
    f.surfaces[i].pile.empty(); f.surfaces[i].pile.eaveL = 5
    for _ in 0..<40 { f.stepEaves(dt: 0.5) }
    #expect(f.surfaces[i].pile.eaveL == 0)
}

@Test func theCorniceIsDrawnPastTheWindowEdgeWithARoundedUndersideAndNotWithoutIt() {
    let (f, i) = lone()
    let plain = pileSegs(f)
    #expect(plain.allSatisfy { $0.x1 <= f.surfaces[i].pile.x1 + 2.01 && $0.x0 >= f.surfaces[i].pile.x0 - 2.01 })
    f.surfaces[i].pile.eaveR = Tuning.eaveMax * 0.8
    let x1 = f.surfaces[i].pile.x1
    let out = pileSegs(f).filter { $0.x1 > x1 + 0.5 }
    #expect(out.count >= 3)
    let tip = out.max { $0.x1 < $1.x1 }!
    #expect(tip.x1 > x1 + 3 && tip.x1 <= x1 + 5.01)
    #expect(out.contains { $0.base1 < $0.top1 - 0.4 }, "has body")
    let lowest = out.map { min($0.base0, $0.base1) }.min()!
    #expect(tip.base1 > lowest + 0.2, "underside curves up to the tip")
    for q in out { #expect(abs(q.top1 - q.top0) <= abs(q.base1 - q.base0) + 4) }
}
