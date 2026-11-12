// AGENT HEADER - Tests/NeveCoreTests/TreeTests.swift  (Tree.swift + Rig+Tree.swift)
// Role: the Christmas tree: the burst warns ~2 s then it falls at that x; it lands on the ground, a window and the Dock bar sunk in the drawn snow with 2-4 gifts; never on a covered bin; follows a moved window (a fast move only sheds
//   branch snow); falls again when its window vanishes; only one exists (dropTree refuses while a burst / tree / stashed tree exists); the burst leaves the simulation `rng` untouched (DeterminismTests relies on it); pick-up / drag / release and
//   the hand-over to another field; the prim budget (<= 120) and snow on the branches growing with the counter; quiet fades it out; clear() removes it.

import CoreGraphics
import Testing
@testable import NeveCore

private func field(seed: UInt64 = 1, windows: [WindowInfo] = [], flakes: Int = 0) -> SnowField {
    let f = makeField(flakes: flakes, seed: seed)
    f.update(windows: windows)
    f.treeEnabled = true
    return f
}

/// Drops the tree at a chosen x (the burst the menu would draw randomly) and steps until it rests.
private func land(_ f: SnowField, x: Float) {
    f.burst = Burst(x: x, t: 0)
    var n = 0
    while f.tree?.state != .resting, n < 60 * 12 { f.step(dt: 1 / 60); n += 1 }
}

@Test func theBurstWarnsTwoSecondsThenTheTreeFallsAtThatX() {
    let f = field()
    #expect(f.dropTree() && f.burst != nil && f.tree == nil)
    let x = f.burst!.x
    #expect(x >= 120 && x <= 880)   // away from the edges
    advance(f, 1.9)
    #expect(f.burst != nil && f.tree == nil && f.busyReasons.contains(.tree))
    advance(f, 0.3)
    #expect(f.burst == nil && f.tree != nil && abs(f.tree!.pos.x - x) < 25)
    advance(f, 4)
    #expect(f.tree?.state == .resting && f.tree?.surface == Tuning.groundID && !f.busyReasons.contains(.tree))
    #expect(f.gifts.count >= 2 && f.gifts.count <= 4)
}

@Test func burstFlakesAppearAroundTheTreeX() {
    let f = field(flakes: 400)
    f.burst = Burst(x: 500, t: 0)
    for i in f.flakes.indices { f.flakes[i].kind = .dormant }
    var near = 0, all = 0
    for _ in 0..<200 { let s = f.spawn(.sky, anywhere: false); all += 1; if abs(s.pos.x - 500) <= Tuning.burstHalfWidth { near += 1 } }
    #expect(Float(near) / Float(all) > 0.7)
    f.burst = nil
    near = 0
    for _ in 0..<200 { if abs(f.spawn(.sky, anywhere: false).pos.x - 500) <= Tuning.burstHalfWidth { near += 1 } }
    #expect(near < 40)
}

@Test func theBurstDoesNotTouchTheSimulationRng() {
    func run(burst: Bool) -> UInt64 {
        let f = makeField(flakes: 300, seed: 42)
        f.update(windows: [])
        f.treeEnabled = true
        if burst { #expect(f.dropTree()) }
        for _ in 0..<90 { f.step(dt: 1 / 60) }   // 1.5 s: still inside the burst
        var r = f.rng
        return r.next()
    }
    #expect(run(burst: true) == run(burst: false))
}

@Test func landsOnAWindowTheDockAndTheGroundSunkInTheDrawnSnow() {
    let f = field(windows: [win(1, 200, 300, 400, 200)])
    for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = 8 } }
    land(f, x: 400)
    advance(f, 0.2)
    var t = f.tree!
    #expect(t.surface == 1)
    var si = f.index[1]!
    #expect(abs(t.pos.y - (f.standY(si: si, x: t.pos.x) - Tuning.treeSink * t.scale)) < 0.01)
    f.clear(); f.treeEnabled = true
    land(f, x: 800)   // no window there
    advance(f, 0.2)
    t = f.tree!
    si = f.index[Tuning.groundID]!
    #expect(t.surface == Tuning.groundID && abs(t.pos.y - (f.standY(si: si, x: t.pos.x) - Tuning.treeSink * t.scale)) < 0.01)

    let d = field(windows: [WindowInfo(number: 0, frame: CGRect(x: 300, y: 10, width: 400, height: 80), radius: 20)])
    land(d, x: 500)
    #expect(d.tree?.surface == 0)
}

@Test func neverRestsOnACoveredBin() {
    // B stands in front of A and covers its top between x 460 and 700: a tree over that stretch must find open snow elsewhere.
    let f = field(windows: [win(2, 460, 350, 240, 300), win(1, 200, 300, 500, 200)])
    for x in stride(from: Float(220), through: 680, by: 20) {
        f.clear(); f.treeEnabled = true
        land(f, x: x)
        guard let t = f.tree, t.state == .resting, let sid = t.surface, let si = f.index[sid] else { Issue.record("no resting tree at \(x)"); continue }
        let b = f.column(t.pos.x) - f.surfaces[si].c0
        #expect(f.surfaces[si].pile.open(b), "x=\(x) rests on a covered bin of surface \(sid)")
        for j in [-1, 1] { #expect(f.surfaces[si].pile.open(f.column(t.pos.x + Float(j) * t.halfFoot) - f.surfaces[si].c0)) }
    }
}

@Test func followsAMovedWindowAndOnlyShedsSnowWhenItMovesFast() {
    let f = field(windows: [win(1, 200, 300, 400, 200)])
    land(f, x: 400)
    advance(f, 1)
    #expect(f.tree?.surface == 1)
    let x0 = f.tree!.pos.x
    f.update(windows: [win(1, 260, 300, 400, 200)], dt: 0.1)
    #expect(abs(f.tree!.pos.x - (x0 + 60)) < 0.01 && f.tree!.state == .resting)
    f.tree!.snow = SIMD4(repeating: 1)
    f.update(windows: [win(1, 760, 300, 400, 200)], dt: 0.016)   // yanked across the screen
    advance(f, 0.2)
    #expect(f.tree!.state == .resting && f.tree!.surface == 1)
    #expect(f.tree!.snow.sum() < 4)
}

@Test func fallsAgainWhenItsWindowDisappears() {
    let f = field(windows: [win(1, 200, 300, 400, 200)])
    land(f, x: 400)
    #expect(f.tree?.surface == 1)
    f.update(windows: [])
    #expect(f.tree?.state == .falling && f.busyReasons.contains(.tree))
    advance(f, 4)
    #expect(f.tree?.state == .resting && f.tree?.surface == Tuning.groundID)
}

@Test func thereIsOnlyOneTree() {
    let f = field()
    #expect(f.dropTree() && !f.dropTree())   // a burst is under way
    advance(f, 6)
    #expect(f.tree != nil && !f.dropTree())
    f.treeEnabled = false
    #expect(f.tree == nil && !f.hasTree && !f.dropTree())
    f.treeEnabled = true
    #expect(f.dropTree())
    f.clear()
    #expect(!f.hasTree)
}

@Test func optionClickPicksItUpAndTheReleaseDropsItOnTheFirstSurfaceBelow() {
    let f = field(windows: [win(1, 200, 300, 400, 200)])
    land(f, x: 800)
    let t = f.tree!, p = CGPoint(x: Double(t.pos.x), y: Double(t.pos.y) + 25)
    #expect(f.hitTest(point: p) && !f.hitTest(point: CGPoint(x: 500, y: 700)))
    #expect(!f.pickTree(at: CGPoint(x: 100, y: 600)) && f.pickTree(at: p) && f.treeHeld)
    f.dragTree(to: CGPoint(x: 400, y: 700), dt: 1 / 60)
    advance(f, 0.5)
    #expect(f.treeHeld && abs(f.tree!.pos.x - 400) < 1 && f.tree!.pos.y > 600)
    f.releaseTree()
    advance(f, 4)
    #expect(f.tree?.state == .resting && f.tree?.surface == 1)   // lands on the window it was released over
}

@Test func aDragCanHandTheTreeToAnotherField() {
    let a = field(), b = field(seed: 2)
    land(a, x: 500)
    let t = a.tree!
    #expect(a.pickTree(at: CGPoint(x: Double(t.pos.x), y: Double(t.pos.y) + 20)))
    let moved = a.takeTree()!
    #expect(a.tree == nil && !a.hasTree)
    b.adoptTree(moved, at: CGPoint(x: 100, y: 300))
    #expect(b.treeHeld && b.hasTree)
    b.dragTree(to: CGPoint(x: 120, y: 310), dt: 1 / 60)
    b.releaseTree()
    advance(b, 4)
    #expect(b.tree?.state == .resting && !b.dropTree())
}

@Test func theTreeFitsThePrimBudgetAndItsSnowGrows() {
    func count(_ snow: Float) -> Int {
        let p = UnsafeMutablePointer<Prim>.allocate(capacity: 400)
        defer { p.deallocate() }
        var w = PrimWriter(p, capacity: 400)
        Rig.tree(TreeLook(foot: SIMD2(100, 100), scale: 1.5, tilt: 0.1, snow: SIMD4(repeating: snow)), contrast: true, into: &w)
        #expect(w.dropped == 0)
        return w.n
    }
    #expect(count(1) <= 120 && count(0) < count(0.5) && count(0.5) < count(1))
    let f = field()
    land(f, x: 400)
    f.tree!.snow = .zero
    advance(f, 20)
    #expect(f.tree!.snow.x > 0.1)
    var w = PrimWriter(.allocate(capacity: 200), capacity: 200)
    f.writeTreePrims(&w) { _ in .zero }
    #expect(w.n > 20)
}

@Test func theSnowLeavingFadesTheTreeAndClearRemovesIt() {
    let f = field()
    land(f, x: 400)
    f.collapseAll(spread: 0)
    advance(f, 1)
    #expect(f.tree == nil && f.burst == nil)
}
