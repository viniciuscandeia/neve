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

private func run(_ f: SnowField, _ seconds: Float) { for _ in 0..<Int(seconds * 60) { f.step(dt: 1 / 60) } }

@Test func noSnowmanUntilTheStretchIsDeepEnough() {
    let shallow = groundField(Tuning.snowmanDepth - 3)
    run(shallow, 5)
    #expect(shallow.snowman == nil)
    let narrow = groundField(Tuning.snowmanDepth + 4, 100...120)   // 20pt wide stretch
    run(narrow, 5)
    #expect(narrow.snowman == nil)
    let deep = groundField(Tuning.snowmanDepth + 4)
    run(deep, 5)
    #expect(deep.snowman != nil && deep.snowman!.stage == 0)
}

@Test func siteIsTheCentreOfTheWidestVisibleStretch() {
    let f = makeField()
    f.update(windows: [win(1, 300, 0, 100, 60)])   // hides x 300...400 of the ground: stretches 0...300 and 400...1000
    level(f, Tuning.snowmanDepth + 4, 0...298)
    level(f, Tuning.snowmanDepth + 4, 400...998)
    run(f, 2)
    let x = f.snowman!.x
    #expect(x > 400 && x < 1000 && f.snowman!.surfaceID == Tuning.groundID)
}

@Test func stagesAdvanceInOrderWithTimeAndScoopSnow() {
    let f = groundField(Tuning.snowmanDepth + 4)
    run(f, 1.5)
    let x = f.snowman!.x, before = f.pile(id: Tuning.groundID)!.heights[Int(x / 2)]
    var seen: [Int] = [], last = -1
    for _ in 0..<(80 * 60) {
        f.step(dt: 1 / 60)
        let s = f.snowman!.stage
        if s != last { seen.append(s); last = s }
    }
    #expect(seen == [0, 1, 2, 3, 4, 5, 6, 7])
    #expect(f.snowman!.complete)
    #expect(f.pile(id: Tuning.groundID)!.heights[Int(x / 2)] < before)
    #expect(f.snowmanPlacement() != nil)
}

private func built() -> SnowField {
    let f = groundField(Tuning.snowmanDepth + 4)
    run(f, 80)
    return f
}

@Test func sweepThroughTheSnowmanCollapsesItIntoDebris() {
    let f = built()
    let m = f.snowman!, d0 = f.debris.count, y = m.y + 25
    f.sweep(from: CGPoint(x: CGFloat(m.x) - 40, y: CGFloat(y)), to: CGPoint(x: CGFloat(m.x) + 40, y: CGFloat(y)), radius: 10)
    #expect(f.snowman!.collapsing)
    #expect(f.debris.count - d0 >= 60)   // three balls, a few dozen chunks each (plus swept pile snow)
    run(f, 0.6)
    #expect(f.snowman == nil)
}

@Test func sweepNextToTheSnowmanLeavesItStanding() {
    let f = built()
    let m = f.snowman!
    f.sweep(from: CGPoint(x: CGFloat(m.x) + 60, y: CGFloat(m.y) + 25), to: CGPoint(x: CGFloat(m.x) + 90, y: CGFloat(m.y) + 25), radius: 10)
    f.sweep(from: CGPoint(x: CGFloat(m.x) - 40, y: CGFloat(m.y) + 90), to: CGPoint(x: CGFloat(m.x) + 40, y: CGFloat(m.y) + 90), radius: 10)
    #expect(f.snowman?.collapsing == false)
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
    #expect(f.snowman == nil)
    let g = built()
    level(g, 0, 100...800)   // pile knocked off under it
    g.step(dt: 1 / 60)
    #expect(g.snowman!.collapsing)
}

@Test func cooldownBeforeRebuildingAndNeverMoreThanOne() {
    let f = built()
    f.collapse()
    run(f, 1)
    #expect(f.snowman == nil)
    level(f, Tuning.snowmanDepth + 4, 100...800)
    run(f, Tuning.snowmanCooldown - 10)
    #expect(f.snowman == nil)
    level(f, Tuning.snowmanDepth + 4, 100...800)
    run(f, 20)
    #expect(f.snowman != nil && f.snowman!.stage == 0)
    f.collapse()   // second snowman only ever replaces the first
    #expect(f.snowman!.collapsing)
}

@Test func disabledSnowmanNeverBuilds() {
    let f = groundField(Tuning.snowmanDepth + 4)
    f.snowmanEnabled = false
    run(f, 5)
    #expect(f.snowman == nil)
}
