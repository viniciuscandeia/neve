import Testing
import CoreGraphics
@testable import NeveCore

private func dock(_ x0: CGFloat, _ x1: CGFloat) -> WindowInfo { WindowInfo(number: 0, frame: CGRect(x: x0, y: 10, width: x1 - x0, height: 84), radius: 25.2) }

/// Ground snow 20 deep everywhere outside the Dock span [400, 1000).
private func pushField(calm: Bool) -> SnowField {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 1)
    f.setCalm(calm)
    f.update(windows: [dock(400, 1000)])
    fillBankLevel(f)   // the grown (high) bank
    let g = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in f.surfaces[g].pile.heights.indices where !(200..<500).contains(b) { f.surfaces[g].pile.heights[b] = 20 }
    return f
}
private func ground(_ f: SnowField) -> [Float] { f.pile(id: Tuning.groundID)!.heights }
private func total(_ f: SnowField) -> Float { ground(f).reduce(0, +) }
private func run(_ f: SnowField, _ steps: Int, each: () -> Void = {}) { for _ in 0..<steps { f.step(dt: 1 / 60); each() } }

@Test func growingDockPushesGroundSnowIntoABermAndConservesVolume() {
    let f = pushField(calm: true)   // calm: no debris, so every point of volume must stay in the pile
    let before = total(f)
    f.update(windows: [dock(300, 1100)])
    run(f, 150)
    let g = ground(f)
    #expect(g[145...149].max()! > 24)                           // berm just outside the new left end (x 300 -> column 150)
    #expect(g[551...555].max()! > 24)
    #expect(abs(total(f) - before) < before * 0.03)
    #expect(f.debris.isEmpty)
}

@Test func growingDockKicksUpDebrisWhenNotCalm() {
    let f = pushField(calm: false)
    f.update(windows: [dock(300, 1100)])
    var seen = 0
    run(f, 60) { seen = max(seen, f.debris.count) }
    #expect(seen > 0)
}

@Test func bermMovesMonotonicallyOutwardWhileTheEndMoves() {
    let f = pushField(calm: true)
    f.update(windows: [dock(300, 1000)])
    var last = Int.max
    for _ in 0..<40 {
        f.step(dt: 1 / 60)
        let g = ground(f)
        let edge = (0..<200).last { g[$0] > 24 } ?? Int.max   // outermost raised column left of the Dock span... first from the left
        _ = edge
        let first = (0..<250).first { g[$0] > 24 && $0 > 100 } ?? last
        #expect(first <= last)
        last = first
    }
    #expect(last < 200)
}

@Test func shrinkingDockDropsItsEndSnow() {
    let f = pushField(calm: false)
    let d = f.surfaces.firstIndex { $0.id == 0 }!
    for _ in 0..<12 { for b in f.surfaces[d].pile.heights.indices { f.deposit(surface: d, bin: b, volume: 4) } }
    f.update(windows: [dock(500, 1000)])
    var seen = 0
    run(f, 30) { seen = max(seen, f.debris.count) }
    #expect(seen > 0)
    #expect(f.pile(id: 0)!.heights.count < 300)
    #expect(f.dockCur!.minX > 400)   // the end travels, not teleports
}

@Test func bankOutlineStaysConnectedWhilePushed() {
    let f = pushField(calm: false)
    f.update(windows: [dock(300, 1100)])
    for step in 0..<150 {
        f.step(dt: 1 / 60)
        let s = pileSegs(f).filter { $0.base0 < 1 }.sorted { $0.x0 < $1.x0 }
        for (a, b) in zip(s, s.dropFirst()) where abs(a.x1 - b.x0) < 1e-3 { #expect(abs(a.top1 - b.top0) < 1e-3) }   // no gap
        if step == 149 { for x in s where x.x1 <= 288 || x.x0 >= 1112 { #expect(abs(x.top1 - x.top0) <= 6) } }                                          // no spike once settled
    }
}

// MARK: - Bank growth: the ground beside the Dock fills up to the Dock top

private func youngBank() -> SnowField {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 1)
    f.update(windows: [dock(171, 1269)])   // 171pt gaps: shorter than Tuning.bankShelf, so the finished shelf spans the whole gap
    return f
}
private func rain(_ f: SnowField, rounds: Int) {
    let gi = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for r in 0..<rounds {
        for b in f.surfaces[gi].pile.heights.indices where b < 85 || b > 634 { f.deposit(surface: gi, bin: b, volume: 4) }
        if r % 2 == 0 { f.step(dt: 0.25) }   // lets the ramp level rise once its bar end has filled
    }
}

@Test func bankLimitIsARampFlooredAtGroundAndCappedAtTheDockTop() {
    for lvl: Float in [24, 50, 94, 140] {
        var last: Float = 0
        for d in stride(from: Float(300), through: 0, by: -2) {   // walking toward the bar
            let l = Tuning.bankLimit(dockTop: 94, distance: d, level: lvl)
            #expect(l >= last - 1e-4 && l >= Tuning.groundMaxHeight && l <= 94 + 1e-4)
            last = l
        }
    }
    #expect(Tuning.bankLimit(dockTop: 94, distance: 100, level: Tuning.bankLevelMax(dockTop: 94, gap: 171)) == 94)   // shelf flush with the Dock top
    #expect(Tuning.bankLimit(dockTop: 94, distance: 100, level: Tuning.bankLevelMax(dockTop: 94, gap: 1000)) == 94)  // ... within bankShelf of the bar
    #expect(Tuning.bankLimit(dockTop: 94, distance: 700, level: Tuning.bankLevelMax(dockTop: 94, gap: 1000)) == Tuning.groundMaxHeight)  // far side stays soft
}

@Test func longSnowfallFillsTheGapToTheDockTopFlushAtTheBarEnd() {
    let f = youngBank()
    rain(f, rounds: 500)
    let g = ground(f)
    #expect(f.bankLevel.l > 150 && f.bankLevel.r > 150)
    #expect(g[84] > 94 - 3 && g[84] <= 94.01)                // flush with the Dock top at the bar end
    #expect(g[20] > 94 - 8 && g[20] <= 94.01)                // a level shelf, not a slope, across the gap
    #expect(f.pile(id: Tuning.groundID)!.heights[635] > 94 - 3)
}

@Test func halfFilledBankIsAMonotoneRampTowardTheBar() {
    let f = youngBank()
    rain(f, rounds: 70)
    let g = ground(f)
    #expect(f.bankLevel.l > Tuning.groundMaxHeight && f.bankLevel.l < 150)   // grown, but not finished
    #expect(g[84] > 30)
    for b in 1...84 { #expect(g[b] >= g[b - 1] - 0.9) }       // toward the bar: never lower than the neighbour farther away (within repose noise)
}

@Test func growingBankKeepsAConnectedOutline() {
    let f = youngBank()
    for _ in 0..<5 {
        rain(f, rounds: 30)
        let s = pileSegs(f).filter { $0.base0 < 1 }.sorted { $0.x0 < $1.x0 }
        for (a, b) in zip(s, s.dropFirst()) where abs(a.x1 - b.x0) < 1e-3 && (a.x1 <= 156 || b.x0 >= 1284) { #expect(abs(a.top1 - b.top0) < 1e-3) }
        for x in s where x.x1 <= 156 || x.x0 >= 1284 { #expect(abs(x.top1 - x.top0) <= 12) }   // no spike or notch
    }
}
