import CoreGraphics
import Testing
@testable import NeveCore

/// Runs the scheduler in 1 ms steps; `snapshot(t)` returns (changed, frameMoved) for a read at time t. Returns the read times.
private func run(_ s: inout PollScheduler, from: Double = 0, to: Double, snapshot: (Double) -> (Bool, Bool) = { _ in (false, false) },
                 events: (inout PollScheduler, Double) -> Void = { _, _ in }) -> [Double] {
    var reads: [Double] = []
    var t = from
    while t < to {
        events(&s, t)
        if let r = s.take(now: t), r.contains(.windows) {
            reads.append(t)
            let (c, m) = snapshot(t)
            s.didRead(ok: true, changed: c, frameMoved: m)
        }
        t += 0.001
    }
    return reads
}

@Test func idleSchedulerWantsNothing() {
    var s = PollScheduler()
    #expect(s.nextDue(now: 5) == nil && s.take(now: 5) == nil)
    s.request(.windows)
    #expect(s.take(now: 5) == .windows)
    #expect(s.take(now: 5.001) == nil)
}

@Test func requestsStackIntoOneReadUnderTheRateCap() {
    var s = PollScheduler()
    var n = 0
    var t = 0.0
    while t < 1 {   // AX + mouse + dock + safety all hammering every millisecond
        s.request([.windows, .dock]); s.mouseDragged(); s.transition(now: t)
        if s.take(now: t) != nil { n += 1; s.didRead(ok: true, changed: true, frameMoved: false) }
        t += 0.001
    }
    #expect(n <= 31 && n >= 25)
}

@Test func burstEndsAfterGuardAndTwoIdenticalSnapshots() {
    var s = PollScheduler()
    s.transition(now: 0)
    let reads = run(&s, to: 3)   // nothing ever changes
    #expect(reads.count >= 5 && reads.count <= 9)
    #expect(reads.last! >= 0.2 && reads.last! < 0.5)   // runs to the 250 ms guard (last tick before it), even though 2 identical came at once
    #expect(reads[1] - reads[0] >= 0.045 && reads[1] - reads[0] < 0.07)   // ~20 Hz
}

@Test func burstKeepsGoingWhileChangingButHitsHardCap() {
    var s = PollScheduler()
    s.transition(now: 0)
    let reads = run(&s, to: 4) { _ in (true, false) }
    #expect(reads.last! < 1.55 && reads.last! > 1.4)
}

@Test func burstContinuesUntilAnimationSettles() {
    var s = PollScheduler()
    s.transition(now: 0)
    let reads = run(&s, to: 3) { t in (t < 0.6, false) }   // window slides for 0.6 s
    #expect(reads.last! > 0.6 && reads.last! < 0.85)
}

@Test func ordinaryClickCostsOneOrTwoReads() {
    var s = PollScheduler()
    #expect(run(&s, to: 1).isEmpty)
    s.mouseDown(now: 1, onDesktop: false)
    var n = 0
    for k in 0..<50 { if s.take(now: 1 + Double(k) * 0.001) != nil { n += 1; s.didRead(ok: true, changed: false, frameMoved: false) } }
    s.mouseUp(now: 1.2, onDesktop: false)
    for k in 0..<500 { if s.take(now: 1.2 + Double(k) * 0.001) != nil { n += 1; s.didRead(ok: true, changed: false, frameMoved: false) } }
    #expect(n == 2)
}

@Test func desktopClickStartsBurst() {
    var s = PollScheduler()
    s.mouseDown(now: 0, onDesktop: true)
    #expect(s.burstActive(now: 0.1))
    let reads = run(&s, to: 3)
    #expect(reads.count >= 5)
}

@Test func dragSamplesForeverWhileMovingThenSettles() {
    var s = PollScheduler()
    s.mouseDown(now: 0, onDesktop: false)
    var moving = true
    let reads = run(&s, to: 5, snapshot: { t in (moving, moving) }, events: { s, t in
        if t > 3 && t < 3.001 { moving = false; s.mouseUp(now: t, onDesktop: false) }
        if moving { s.mouseDragged() }
    })
    #expect(reads.filter { $0 < 3 }.count > 60)   // ~25 Hz past the 1.5 s hard cap
    #expect(reads.last! > 3.15 && reads.last! < 3.6)   // settle tail after release, then silence
    #expect(!s.dragging)
}

@Test func dragDemotesWhenMovementStopsWhileHeld() {
    var s = PollScheduler()
    s.mouseDown(now: 0, onDesktop: false)
    _ = s.take(now: 0.1); s.didRead(ok: true, changed: true, frameMoved: true)
    #expect(s.dragging)
    for _ in 0..<3 { s.didRead(ok: true, changed: false, frameMoved: false) }
    #expect(!s.dragging)
}

@Test func failedReadRetriesBoundedAndEmptyListIsValid() {
    var s = PollScheduler()
    var n = 0
    var t = 0.0
    while t < 2 {
        if s.take(now: t) != nil { n += 1; s.didRead(ok: false, changed: false, frameMoved: false) }
        if t == 0 { s.request(.windows) }
        t += 0.001
    }
    #expect(n == 1 + PollScheduler.maxRetries)
    // a valid (possibly empty) snapshot applies and resets
    s.request(.windows)
    #expect(s.take(now: 5) != nil)
    s.didRead(ok: true, changed: true, frameMoved: false)
    #expect(s.take(now: 6) == nil)
}

@Test func dragTargetNeedsMatchingDeltaConstantSizeAndUniqueness() {
    let a = win(1, 100, 100, 300, 200), b = win(2, 600, 100, 300, 200)
    let mouse = CGVector(dx: 50, dy: -20)
    #expect(dragTarget(prev: [a, b], cur: [win(1, 150, 80, 300, 200), b], mouseDelta: mouse) == 1)
    #expect(dragTarget(prev: [a, b], cur: [win(1, 150, 80, 300, 200), b], mouseDelta: CGVector(dx: 80, dy: 0)) == nil)   // window moved on its own
    #expect(dragTarget(prev: [a, b], cur: [win(1, 150, 80, 320, 200), b], mouseDelta: mouse) == nil)                       // resized
    #expect(dragTarget(prev: [a, b], cur: [win(1, 150, 80, 300, 200), win(2, 652, 78, 300, 200)], mouseDelta: mouse) == nil)   // two compatible
    #expect(dragTarget(prev: [a, b], cur: [a, b], mouseDelta: mouse) == nil)
}

// B1: per-window velocity

private func velocities(bMoves: Bool) -> [Float] {
    let f = makeField()
    var t = 0.0
    var out: [Float] = []
    f.update(windows: [win(1, 100, 300, 300, 200), win(2, 600, 300, 300, 200)], now: t)
    pileUp(f, id: 1)
    for i in 1...20 {
        t += 0.05
        let b = bMoves ? win(2, 600 + CGFloat(i * i % 7) * 9, 300, 300, 200) : win(2, 600, 300, 300, 200)
        f.update(windows: [win(1, 100 + CGFloat(i) * 4, 300, 300, 200), b], now: t)
        out.append(f.surfaces.first { $0.id == 1 }!.vel.x)
    }
    return out
}

@Test func otherWindowsChangesDoNotAlterAVelocity() {
    #expect(velocities(bMoves: true) == velocities(bMoves: false))
}

@Test func eachWindowUsesItsOwnSampleTime() {
    let f = makeField()
    f.update(windows: [win(1, 100, 300, 300, 200), win(2, 600, 300, 300, 200)], now: 0)
    f.update(windows: [win(1, 100, 300, 300, 200), win(2, 600, 300, 300, 200)], now: 10)   // long rest, both sampled
    f.update(windows: [win(1, 120, 300, 300, 200), win(2, 600, 300, 300, 200)], now: 10.05)
    let v = f.surfaces.first { $0.id == 1 }!.vel.x
    #expect(v > 100 && v < 420)   // 20 pt in 50 ms smoothed (400 pt/s raw), not 20 pt over 10 s
}

@Test func identicalSnapshotDecaysVelocityInsteadOfZeroing() {
    let f = makeField()
    f.update(windows: [win(1, 100, 300, 300, 200)], now: 0)
    for i in 1...6 { f.update(windows: [win(1, 100 + CGFloat(i) * 10, 300, 300, 200)], now: Double(i) * 0.05) }
    let v0 = f.surfaces.first { $0.id == 1 }!.vel.x
    f.update(windows: [win(1, 160, 300, 300, 200)], now: 0.35)
    let v1 = f.surfaces.first { $0.id == 1 }!.vel.x
    #expect(v0 > 0 && v1 > 0 && v1 < v0)
}

// B3: Space switch

@Test func staleWindowsTakeNoSnowUntilNextSnapshot() {
    let f = makeField()
    f.update(windows: [win(1, 100, 300, 300, 200)], now: 0)
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    f.markStale()
    f.deposit(surface: i, bin: 5, volume: 50)
    #expect(f.surfaces[i].pile.heights[5] == 0)
    let g = f.surfaces.firstIndex { $0.id == Tuning.groundID }
    if let g { f.deposit(surface: g, bin: 5, volume: 5); #expect(f.surfaces[g].pile.heights[5] > 0) }   // ground pile keeps working
    f.update(windows: [win(1, 100, 300, 300, 200)], now: 0.1)
    f.deposit(surface: i, bin: 5, volume: 50)
    #expect(f.surfaces[i].pile.heights[5] > 0)
}

@Test func safetyPollStretchesAfterTenQuietSecondsWithAccessibility() {
    var s = PollScheduler()
    #expect(s.safetyInterval(now: 100, ax: true) == 2)    // first call starts the quiet clock
    #expect(s.safetyInterval(now: 109.9, ax: true) == 2)
    #expect(s.safetyInterval(now: 110, ax: true) == 5)
    #expect(s.safetyInterval(now: 500, ax: false) == 2)   // no Accessibility: never stretched
    s.transition(now: 500)                                // any event brings it back to 2 s
    #expect(s.safetyInterval(now: 500.1, ax: true) == 2)
    #expect(s.safetyInterval(now: 509.9, ax: true) == 2)
    #expect(s.safetyInterval(now: 510, ax: true) == 5)
}

@Test func frameRateSteps() {
    #expect(FrameRate.range(lowPower: false, economy: true, shrunk: false, calm: true).preferred == 20)
    #expect(FrameRate.range(lowPower: true, economy: true, shrunk: true, calm: true).preferred == 20)
    #expect(FrameRate.range(lowPower: false, economy: false, shrunk: false, calm: true).preferred == 30)
    #expect(FrameRate.range(lowPower: false, economy: true, shrunk: false, calm: false).preferred == 60)   // busy: back to 60 at once
    #expect(FrameRate.range(lowPower: true, economy: false, shrunk: false, calm: false).preferred == 30)
    #expect(FrameRate.range(lowPower: false, economy: false, shrunk: true, calm: false).preferred == 30)
}

@Test func fastCursorOnlyConcernsNearbyScreens() {
    let a = CGRect(x: 0, y: 0, width: 1000, height: 800), b = CGRect(x: 1000, y: 0, width: 1000, height: 800)
    func near(_ f: CGRect, _ p: (CGFloat, CGFloat), _ c: (CGFloat, CGFloat)) -> Bool {
        FrameRate.cursorNear(frame: f, from: CGPoint(x: p.0, y: p.1), to: CGPoint(x: c.0, y: c.1))
    }
    #expect(near(a, (500, 400), (520, 400)))            // inside
    #expect(!near(b, (500, 400), (520, 400)))           // other screen
    #expect(near(b, (900, 400), (1100, 400)))           // crossing in
    #expect(near(a, (900, 400), (1100, 400)))           // crossing out
    #expect(near(b, (500, 400), (2500, 400)))           // segment passes through with both ends outside
    #expect(!near(b, (500, 1000), (2500, 1000)))        // passes above
    #expect(near(b, (950, 400), (960, 400)))            // within margin (60)
    #expect(!near(b, (900, 400), (920, 400)))           // beyond margin
}
