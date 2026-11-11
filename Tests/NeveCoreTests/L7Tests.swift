// AGENT HEADER - Tests/NeveCoreTests/L7Tests.swift  (robustness, review round L7)
// Side Dock clears the frame at once (unlike a failed read), column() survives NaN/Inf/huge x, secondary screens (field origin != 0: right, above, below the primary) use only their own windows and the Dock is local to that screen, writeInstances never exceeds capacity with every pool full in Nevasca, step survives zero and huge dt.

import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

private let bar = CGRect(x: 500, y: 10, width: 400, height: 80)

@Test func sideDockClearsTheFrameAtOnceUnlikeAFailedRead() {
    var d = DockDebounce()
    _ = d.feed(bar)
    var failed = d
    #expect(failed.feed(nil) == (false, true))            // failed read: keeps the frame, asks for a retry
    #expect(failed.frame != nil)
    let r = d.feedSide()                                  // Dock on a side: no bar, no grace
    #expect(r.changed && !r.retry)
    #expect(d.frame == nil)
    #expect(d.feedSide() == (false, false))               // nothing to clear the second time
    #expect(d.feed(bar).changed)                          // and a bottom Dock afterwards is adopted normally
}

@Test func columnSurvivesNaNInfAndHugeX() {
    let f = makeField()
    #expect(f.column(.nan) == 0)
    #expect(f.column(.infinity) == f.numCols - 1)
    #expect(f.column(-.infinity) == 0)
    #expect(f.column(1e30) == f.numCols - 1)
    #expect(f.column(-1e30) == 0)
    #expect(f.column(500) == min(max(Int(500 * f.invBin), 0), f.numCols - 1))
}

// MARK: secondary screens (field origin != 0)

private func screenField(origin: CGPoint) -> SnowField {
    SnowField(size: CGSize(width: 1000, height: 800), origin: origin, groundY: 90, visibleTop: 780, flakeCount: 0, seed: 1)
}

@Test func screenToTheRightUsesItsOwnWindowsOnly() {
    let f = screenField(origin: CGPoint(x: 1000, y: 0))
    f.update(windows: [win(1, 1100, 200, 300, 200), win(2, 100, 200, 300, 200), win(3, 2100, 200, 300, 200)])
    #expect(f.pile(id: 1) != nil)
    #expect(f.pile(id: 2) == nil)   // on the primary screen
    #expect(f.pile(id: 3) == nil)   // on a screen further right
    #expect(f.surfaces[f.index[1]!].frame.minX == 100)   // local coordinates
}

@Test func screenAbovePrimaryUsesItsOwnWindowsOnly() {
    let f = screenField(origin: CGPoint(x: 0, y: 800))
    f.update(windows: [win(1, 100, 1000, 300, 200), win(2, 100, 200, 300, 200)])
    #expect(f.pile(id: 1) != nil)
    #expect(f.pile(id: 2) == nil)
    #expect(f.surfaces[f.index[1]!].edgeY == 400)
}

@Test func screenBelowPrimaryUsesItsOwnWindowsOnly() {
    let f = screenField(origin: CGPoint(x: -300, y: -800))
    f.update(windows: [win(1, -200, -600, 300, 200), win(2, 100, 200, 300, 200)])
    #expect(f.pile(id: 1) != nil)
    #expect(f.pile(id: 2) == nil)
    #expect(f.surfaces[f.index[1]!].frame.minX == 100)
}

@Test func dockOnASecondaryScreenIsLocalToThatScreen() {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: CGPoint(x: 1440, y: 0), groundY: 0, visibleTop: 880, flakeCount: 0, seed: 5)
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 1940, y: 10, width: 400, height: 80), radius: 20)])
    let s = f.surfaces[f.index[0]!]
    #expect(s.frame.minX == 500 && s.frame.maxX == 900)
    f.update(windows: [WindowInfo(number: 0, frame: bar, radius: 20)])   // the primary screen's Dock is not this screen's
    #expect(f.index[0] == nil)
}

// MARK: buffers and robustness

@Test func writeInstancesNeverExceedsCapacityWithEveryPoolFullInNevasca() {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 4000, seed: 3)
    f.setIntensity(.nevasca, immediate: true)
    let fl = f.flakes[0]
    f.debris = Array(repeating: fl, count: Tuning.maxDebris)
    f.glints = Array(repeating: fl, count: Tuning.maxGlints)
    f.puffs = Array(repeating: fl, count: Tuning.maxPuffs)
    f.drops = Array(repeating: Drop(pos: .zero, size: 3, src: 1), count: Tuning.maxDrops)
    for i in f.flakes.indices { f.flakes[i].kind = .sky }
    let cap = f.capacity
    let p = UnsafeMutablePointer<Instance>.allocate(capacity: cap + 64)
    defer { p.deallocate() }
    #expect(f.writeInstances(to: p) <= cap)
}

@Test func stepSurvivesZeroAndHugeDt() {
    let f = makeField(flakes: 400)
    f.update(windows: [win(1, 100, 200, 300, 200)])
    f.step(dt: 0)
    for dt: Float in [0, 1e-9, 5, 600, 3600] { f.step(dt: dt) }
    for fl in f.flakes { #expect(fl.pos.x.isFinite && fl.pos.y.isFinite) }
    for s in f.surfaces { for h in s.pile.heights { #expect(h.isFinite && h >= 0) } }
}

@Test func windShapeStaysBoundedAtHugeTimes() {
    let f = makeField()
    for t in [0.0, 1e5, 1e7, 3.6e9] {
        f.time = t
        let w = f.windShape()
        #expect(w.isFinite && abs(w) <= 1.1)
    }
}
