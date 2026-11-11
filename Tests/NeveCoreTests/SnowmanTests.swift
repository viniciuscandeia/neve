// AGENT HEADER - Tests/NeveCoreTests/SnowmanTests.swift  (Snowman.swift, 1000x800 field without flakes)
// No snowman until the stretch is deep enough, site = centre of the widest visible stretch, stages advance in order and scoop snow, a cursor sweep through it collapses it into debris (next to it leaves it standing), debris capped at maxDebris, clear() removes it, cooldown before a rebuild and never more than one.

import CoreGraphics
import Testing
@testable import NeveCore

/// 1000x800 field, no flakes; ground pile set to `h` over x in `xs` (bins of 2pt).
private func groundField(_ h: Float, _ xs: ClosedRange<Int> = 100...800) -> SnowField {
    let f = makeField()
    f.update(windows: [])
    level(f, h, xs)
    return f
}

private func level(_ f: SnowField, _ h: Float, _ xs: ClosedRange<Int>) {
    let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in xs.lowerBound / 2...xs.upperBound / 2 { f.surfaces[i].pile.heights[b] = h }
}

private func run(_ f: SnowField, _ seconds: Float) { for _ in 0..<Int(seconds * 20) { f.step(dt: 1 / 20) } }   // coarse steps: no flakes, only timers

@Test func noSnowmanUntilTheStretchIsDeepEnough() {
    let shallow = groundField(Tuning.snowmanDepth - 3)
    run(shallow, 5)
    #expect(shallow.figures.isEmpty)
    let narrow = groundField(Tuning.snowmanDepth + 4, 100...120)   // 20pt wide stretch
    run(narrow, 5)
    #expect(narrow.figures.isEmpty)
    let deep = groundField(Tuning.snowmanDepth + 4)
    run(deep, 5)
    #expect(deep.figures.count == 1 && deep.figures[0].built == 0 && !deep.figures[0].fromBalls && deep.figures[0].phase == .building)
}

@Test func siteIsTheCentreOfTheWidestVisibleStretch() {
    let f = makeField()
    f.update(windows: [win(1, 300, 0, 100, 60)])   // hides x 300...400 of the ground: stretches 0...300 and 400...1000
    level(f, Tuning.snowmanDepth + 4, 0...298)
    level(f, Tuning.snowmanDepth + 4, 400...998)
    run(f, 2)
    let x = f.figures[0].foot.x
    #expect(x > 400 && x < 1000 && f.figures[0].at == .surface(id: Tuning.groundID, x: x))
}

@Test func stagesAdvanceInOrderWithTimeAndScoopSnow() {
    let f = groundField(Tuning.snowmanDepth + 4)
    run(f, 1.5)
    let x = f.figures[0].foot.x, before = f.pile(id: Tuning.groundID)!.heights[Int(x / 2)]
    var seen: [Int] = [], last = -1
    for _ in 0..<(80 * 20) {
        f.step(dt: 1 / 20)
        let s = f.figures[0].built
        if s != last { seen.append(s); last = s }
    }
    #expect(seen == [0, 1, 2, 3, 4, 5, 6, 7])
    #expect(f.figures[0].built == Snowman.stageCount && f.figures[0].phase != .hidden)
    #expect(f.pile(id: Tuning.groundID)!.heights[Int(x / 2)] < before)
}

private func built() -> SnowField {
    let f = groundField(Tuning.snowmanDepth + 4)
    run(f, 80)
    return f
}

@Test func sweepThroughTheSnowmanCollapsesItIntoDebris() {
    let f = built()
    let m = f.figures[0], d0 = f.debris.count, y = m.foot.y + 25
    f.sweep(from: CGPoint(x: CGFloat(m.foot.x) - 40, y: CGFloat(y)), to: CGPoint(x: CGFloat(m.foot.x) + 40, y: CGFloat(y)), radius: 10)
    #expect(f.figures[0].phase == .collapsing)
    #expect(f.debris.count - d0 >= 60)   // three balls, a few dozen chunks each (plus swept pile snow)
    run(f, 0.6)
    #expect(f.figures.isEmpty)
}

@Test func sweepNextToTheSnowmanLeavesItStanding() {
    let f = built()
    let m = f.figures[0]
    f.sweep(from: CGPoint(x: CGFloat(m.foot.x) + 60, y: CGFloat(m.foot.y) + 25), to: CGPoint(x: CGFloat(m.foot.x) + 90, y: CGFloat(m.foot.y) + 25), radius: 10)
    f.sweep(from: CGPoint(x: CGFloat(m.foot.x) - 40, y: CGFloat(m.foot.y) + 90), to: CGPoint(x: CGFloat(m.foot.x) + 40, y: CGFloat(m.foot.y) + 90), radius: 10)
    #expect(f.figures.count == 1 && f.figures[0].phase != .collapsing)
}

@Test func debrisIsCappedAtMaxDebris() {
    let f = built()
    for _ in 0..<(Tuning.maxDebris) { f.debris.append(f.debris.first ?? Flake(pos: [0, 700], vx: 0, fall: 0, phase: 0, amp: 0, freq: 0, size: 3, alpha: 1, kind: .debris)) ; if f.debris.count >= Tuning.maxDebris { break } }
    f.collapse()
    #expect(f.debris.count <= Tuning.maxDebris)
}

@Test func clearRemovesTheSnowmanAndClearedPileCollapsesIt() {
    let f = built()
    f.clear()
    #expect(f.figures.isEmpty)
    let g = built()
    level(g, 0, 100...800)   // pile knocked off under it
    g.step(dt: 1 / 60)
    #expect(g.figures[0].phase == .collapsing)
}

@Test func cooldownBeforeRebuildingAndNeverMoreThanOne() {
    let f = built()
    f.collapse()
    run(f, 1)
    #expect(f.figures.isEmpty)
    level(f, Tuning.snowmanDepth + 4, 100...800)
    run(f, Tuning.snowmanCooldown - 10)
    #expect(f.figures.isEmpty)
    level(f, Tuning.snowmanDepth + 4, 100...800)
    run(f, 20)
    #expect(f.figures.count == 1 && f.figures[0].built == 0)
    run(f, 60)
    #expect(f.figures.filter { !$0.fromBalls }.count == 1)   // never more than one auto snowman
    f.collapse()   // second snowman only ever replaces the first
    #expect(f.figures[0].phase == .collapsing)
}

@Test func siteKeepsClearOfTheDockEndsAndScreenEdges() {
    let f = makeField()
    f.update(windows: [win(0, 300, 10, 600, 60)])   // floating Dock bar x 300...900
    level(f, Tuning.snowmanDepth + 4, 0...998)
    run(f, 2)
    let x = f.figures[0].foot.x, half = Tuning.snowmanStretch * f.snowmanScale / 2
    for edge in [Float(0), 300, 900, 1000] { #expect(abs(x - edge) >= Tuning.snowmanClearance + half - 3) }
}

@Test func waitsWhenNoStretchHasClearance() {
    let f = makeField()
    f.update(windows: [win(1, 0, 0, 300, 60), win(2, 430, 0, 570, 60)])   // 130pt of ground left: 105pt + 2x20 does not fit
    level(f, Tuning.snowmanDepth + 4, 300...428)
    run(f, 5)
    #expect(f.figures.isEmpty)
}

@Test func disabledSnowmanNeverBuilds() {
    let f = groundField(Tuning.snowmanDepth + 4)
    f.snowmanEnabled = false
    run(f, 5)
    #expect(f.figures.isEmpty)
}

private func live(_ f: SnowField) -> Int { f.flakes.filter { $0.kind != .dormant }.count }

@Test func introRampsTheFlakeCountFromZeroToTheTarget() {
    let f = makeField(flakes: 400)
    let target = live(f)
    f.beginIntro(duration: 2.5)
    #expect(live(f) == 0)
    run(f, 1.25)
    #expect(live(f) > target / 3 && live(f) < target * 2 / 3)
    #expect(f.flakes.filter { $0.kind != .dormant }.allSatisfy { $0.pos.y > 800 - 1.25 * 120 })   // they came in from above
    run(f, 1.35)
    #expect(live(f) == target)
}

@Test func collapseAllEmptiesPilesIntoDebrisAndBreaksBallsAndSnowman() {
    let f = groundField(10)   // 350 bins x 10pt: more snow than the debris cap
    f.update(windows: [win(1, 100, 300, 200, 100)])
    standAuto(f, x: 500)
    stand(f, x: 700)
    f.collapseAll(spread: 0.3)
    #expect(f.figures.count == 1 && f.figures[0].phase == .collapsing && f.balls.isEmpty && f.outro)   // the stack shatters at once, the auto one fades
    var peak = 0
    for _ in 0..<8 { f.step(dt: 1 / 20); peak = max(peak, f.debris.count) }   // 0.4s
    #expect(f.surfaces.allSatisfy { $0.pile.heights.allSatisfy { $0 == 0 } })
    #expect(peak > 60 && peak <= Tuning.maxDebris)   // slabs: ~one per 16pt of pile
    run(f, 3)
    #expect(f.debris.isEmpty && f.pile(id: Tuning.groundID)!.heights.allSatisfy { $0 == 0 })   // nothing lands back
}

@Test func collapseAllWithoutSpreadActsAtOnceAndIntroEndsTheOutro() {
    let f = groundField(10)
    f.collapseAll(spread: 0)
    #expect(f.pile(id: Tuning.groundID)!.heights.allSatisfy { $0 == 0 } && !f.debris.isEmpty)
    f.beginIntro(duration: 1)
    #expect(!f.outro)
}

// Nevasca (3x flakes, gusty wind up to 100pt/s): the real-screen ground pile builds, the auto snowman completes
// and nothing collapses it over 5 simulated minutes (reported once as "the pile keeps clearing").
@Test func nevascaBuildsGroundPileAndSnowmanWithoutCollapsing() {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 0, visibleTop: 880, flakeCount: 400, config: SimConfig(snowmanSpeed: 1), seed: 3)
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 171, y: 10, width: 1098, height: 84))])
    f.setIntensity(.nevasca, immediate: true)
    var collapses = 0, was = false
    for i in 0..<(5 * 60 * 30) {   // coarse 1/30 s steps: the same 5 simulated minutes in half the work
        f.step(dt: 1 / 30)
        if i % 3 == 0 { f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 171, y: 10, width: 1098, height: 84))], dt: 0.1) }
        let c = f.figures.first?.phase == .collapsing
        if c && !was { collapses += 1 }
        was = c
    }
    #expect(f.pile(id: Tuning.groundID)!.heights.reduce(0, +) > 2000)
    #expect(f.figures.first?.built == Snowman.stageCount)
    #expect(collapses == 0)
}

@Test func meltFreezesBuildAndStartsNoNewSnowman() {
    let f = groundField(Tuning.snowmanDepth + 4)
    for _ in 0..<2000 where f.figures.first?.built ?? 0 < 1 { f.step(dt: 1 / 20) }
    let built = f.figures[0].built
    #expect(built >= 1 && built < Snowman.stageCount)
    f.beginMelt(duration: 20)
    for _ in 0..<80 { f.step(dt: 1 / 20); #expect(f.figures.count <= 1 && (f.figures.first?.built ?? 0) <= built) }
}
