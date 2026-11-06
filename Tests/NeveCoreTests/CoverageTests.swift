import CoreGraphics
import Testing
@testable import NeveCore

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let visible = CGRect(x: 0, y: 80, width: 1000, height: 700)   // Dock 80pt at the bottom, 20pt menu bar

@Test func coverageOfFullPartialAndTwoHalves() {
    let full = coverage(of: [visible], in: visible)
    #expect(full.fraction == 1 && full.uncovered == nil)
    let none = coverage(of: [], in: visible)
    #expect(none.fraction == 0 && none.uncovered == visible)
    // Top 70% covered: the live part is the bottom band.
    let part = coverage(of: [CGRect(x: 0, y: 290, width: 1000, height: 490)], in: visible)
    #expect(abs(part.fraction - 0.7) < 0.03)
    #expect(part.uncovered!.minY == 80 && part.uncovered!.maxY < 300 && part.uncovered!.width == 1000)
    // Two side-by-side halves cover everything; two halves with a gap in the middle leave exactly that gap.
    let halves = coverage(of: [CGRect(x: 0, y: 80, width: 500, height: 700), CGRect(x: 500, y: 80, width: 500, height: 700)], in: visible)
    #expect(halves.fraction == 1)
    let gap = coverage(of: [CGRect(x: 0, y: 80, width: 400, height: 700), CGRect(x: 600, y: 80, width: 400, height: 700)], in: visible)
    #expect(gap.fraction > 0.78 && gap.fraction < 0.82 && gap.uncovered!.minX >= 395 && gap.uncovered!.maxX <= 605)
}

@Test func liveRectIsUncoveredPlusDockStrip() {
    let top = coverage(of: [CGRect(x: 0, y: 200, width: 1000, height: 580)], in: visible)
    let r = liveRect(frame: screen, visible: visible, uncovered: top.uncovered)!
    #expect(r.minY == 0 && r.width == 1000 && r.maxY >= 190 && r.maxY < 230)   // never reaches the menu bar
    #expect(liveRect(frame: screen, visible: screen, uncovered: nil) == nil)   // no Dock, fully covered: nothing live
    let strip = liveRect(frame: screen, visible: visible, uncovered: nil)!
    #expect(strip == CGRect(x: 0, y: 0, width: 1000, height: 80))
}

@Test func compactStateHysteresis() {
    var c = CompactState()
    func run(_ fraction: Float, _ secs: Float, mouse: Bool = false, live: CGFloat = 80) {
        for _ in 0..<Int(secs * 60) { c.update(fraction: fraction, liveHeight: live, mouseDown: mouse, dt: 1 / 60) }
    }
    run(0.95, 0.5); #expect(c.state == .normal)          // not long enough
    run(0.5, 0.1); run(0.95, 0.5); #expect(c.state == .normal)   // the dip reset the timer
    run(0.95, 0.2); #expect(c.state == .compact)
    run(0.87, 2); #expect(c.state == .compact)           // between 0.85 and 0.90: stays
    run(0.80, 0.1); #expect(c.state == .compact)         // under 0.85 but < 0.2s
    run(0.95, 0.1); run(0.80, 0.15); #expect(c.state == .compact)   // exit timer was reset
    run(0.80, 0.1); #expect(c.state == .normal)
    // frozen while a button is down
    run(0.99, 2, mouse: true); #expect(c.state == .normal)
    run(0.99, 0.7); #expect(c.state == .compact)
    run(0.1, 2, mouse: true); #expect(c.state == .compact)
    run(0.1, 0.3); #expect(c.state == .normal)
    // a strip under 8pt: covered (paused), and back
    run(1, 0.7, live: 4); #expect(c.state == .covered)
    run(0.5, 0.3); #expect(c.state == .normal)
}

@Test func compactFlakesSpawnAboveTheStripAndFollowTheArea() {
    let f = makeField(flakes: 400, seed: 7)
    f.setLive(CGRect(x: 0, y: 0, width: 1000, height: 100))
    advance(f, 25, fps: 30)
    let live = f.flakes.filter { $0.kind != .dormant }
    #expect(live.allSatisfy { $0.pos.y <= 100 + 40 + 1 })   // nothing in the covered region: they come from just above the strip
    let limit = Float(f.skyLimit + f.bgLimit)
    #expect(abs(Float(live.count) - limit) <= limit * 0.15)
    #expect(limit < 0.2 * Float(f.flakes.count) && limit > 0)
    f.setLive(nil)
    f.wake(fraction: 0.5)
    #expect(f.activeFlakes > live.count * 3)
    #expect(f.flakes.contains { $0.kind != .dormant && $0.pos.y > 400 })
}

@Test func groundPilesAreTheSameInCompactAndNormal() {
    let w = [win(1, 0, 80, 1000, 700)]   // maximized over the usable area
    let a = makeField(seed: 3), b = makeField(seed: 3)
    b.setLive(CGRect(x: 0, y: 0, width: 1000, height: 90))
    for f in [a, b] { f.update(windows: w); pileUp(f, id: Tuning.groundID) }
    #expect(a.pile(id: Tuning.groundID)!.heights == b.pile(id: Tuning.groundID)!.heights)
    #expect(a.pile(id: Tuning.groundID)!.heights.contains { $0 > 1 })
}

@Test func compactExitWakesOnlyFromAboveTheTopEdge() {
    let f = makeField(flakes: 400, seed: 9)
    f.setLive(CGRect(x: 0, y: 0, width: 1000, height: 100))
    advance(f, 5, fps: 30)
    let was = f.flakes.map { $0.kind == .dormant }
    f.setLive(nil)
    f.wake(fraction: 0.5)
    var woken = 0
    for (i, fl) in f.flakes.enumerated() where was[i] && fl.kind != .dormant { woken += 1; #expect(fl.pos.y >= 800) }
    #expect(woken > 50)
}

@Test func raisingIntensityEntersFromAbove() {
    let f = makeField(flakes: 400, seed: 5)
    f.setIntensity(.leve, immediate: true)
    advance(f, 5, fps: 30)
    let was = f.flakes.map { $0.kind == .dormant }
    f.setIntensity(.nevasca)
    f.step(dt: 1 / 30)
    for (i, fl) in f.flakes.enumerated() where was[i] && fl.kind != .dormant { #expect(fl.pos.y >= 800) }
}
