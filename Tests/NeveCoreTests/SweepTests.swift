// AGENT HEADER - Tests/NeveCoreTests/SweepTests.swift  (cursor sweep, Surfaces.sweep + pointer swirl)
// Window top y = 500, x 200...500, piles built by direct deposits (`pileField` full, `lightField` 3 rounds). A sweep clears only its path (the snow heaps ahead of the cursor, or to both sides for a vertical pass; nothing sprays at the cursor on a full pile),
//   a sweep above the pile removes nothing, debris flies in the cursor direction from the run end, the dragged window's pile is not swept, falling flakes part around a still pointer and a distant pointer does nothing. "Soft dent": a swipe never pops a
//   column, faster cuts deeper (Tuning.plowFloor leaves a thin layer), volume is conserved between pile, debris and `sweepOwed`, Reduce Motion / pointerPush off leave piles alone, a heap respects the ceiling cap, grows with more pushing and is not trimmed by
//   snowfall. Heap persistence: survives a Space round trip, a `resize`, moving its window; a tall heap is drawn at full height. Slow deliberate strokes (150 pt/s) build a heap >= 8 pt over the pile limit. `plowMicrobench` only prints timing.

import CoreGraphics
import Testing
@testable import NeveCore

/// Window top edge at y=500, x 200...500, with a pile built by direct deposits.
private func pileField() -> SnowField {
    let f = makeField()
    f.update(windows: [win(1, 200, 300, 300, 200)])
    pileUp(f, id: 1)
    return f
}

@Test func sweepThroughAPileClearsOnlyThePathAndThrowsDebris() {
    let f = pileField()
    let before = f.pile(id: 1)!.heights, d0 = f.debris.count
    f.sweep(from: CGPoint(x: 340, y: 502), to: CGPoint(x: 360, y: 502), radius: 10)
    let after = f.pile(id: 1)!.heights
    #expect(f.debris.count == d0)   // the pile is full, yet nothing sprays at the cursor: the snow heaps ahead of it
    // bin i covers x = 200 + 2i; path x 340...360 (+10) = bins 65...85
    #expect(after[75] < before[75])
    for i in [10, 40, 55] { #expect(after[i] == before[i]) }
}

@Test func sweepAboveThePileRemovesNothing() {
    let f = pileField()
    let before = f.pile(id: 1)!.heights, d0 = f.debris.count
    f.sweep(from: CGPoint(x: 250, y: 560), to: CGPoint(x: 450, y: 560), radius: 10)
    #expect(f.pile(id: 1)!.heights == before)
    #expect(f.debris.count == d0)
}

@Test func debrisFliesInTheCursorDirectionFromTheRunEnd() {
    for dir: CGFloat in [1, -1] {
        let f = pileField()
        let d0 = f.debris.count
        let x0: CGFloat = dir > 0 ? 440 : 260
        for _ in 0..<60 { f.sweep(from: CGPoint(x: x0, y: 505), to: CGPoint(x: x0 + 40 * dir, y: 505), radius: 10, dt: 1 / 30) }
        let vs = f.debris[d0...].map(\.vx)
        #expect(!vs.isEmpty)
        #expect(vs.allSatisfy { $0 * Float(dir) > 0 })
    }
}

@Test func draggedWindowsPileIsNotSwept() {
    let f = pileField()
    f.setDragTarget(1)
    f.update(windows: [win(1, 230, 300, 300, 200)])   // same size, moved: being dragged
    #expect(f.draggingID == 1)
    let before = f.pile(id: 1)!.heights
    f.sweep(from: CGPoint(x: 340, y: 502), to: CGPoint(x: 400, y: 502), radius: 10)
    #expect(f.pile(id: 1)!.heights == before)
}

@Test func fallingSnowPartsAroundAStillPointer() {
    let f = makeField(flakes: 400)
    let ptr = SIMD2<Float>(500, 400)
    f.setPointer(ptr, velocity: .zero)
    var close: Float = .infinity, displaced = 0
    for n in 0..<900 {
        f.step(dt: 1 / 60)
        guard n > 60 else { continue }
        for fl in f.flakes where fl.kind != .dormant {
            let d = fl.pos - ptr
            close = min(close, (d.x * d.x + d.y * d.y).squareRoot())
            if abs(d.y) < 70, abs(d.x) > 20, abs(d.x) < 60 { displaced += 1 }
        }
    }
    #expect(close > 8)
    #expect(displaced > 0)
}

@Test func pointerFarAwayDoesNotMoveFlakes() {
    let a = makeField(flakes: 400), b = makeField(flakes: 400)
    b.setPointer([500, 400], velocity: [300, 0])
    for _ in 0..<10 { a.step(dt: 1 / 60); b.step(dt: 1 / 60) }
    for (x, y) in zip(a.flakes, b.flakes) where abs(x.pos.x - 500) > 100 || abs(x.pos.y - 400) > 100 { #expect(x.pos == y.pos) }
}

// MARK: soft dent

/// Drives the cursor across the pile (x 230...470 at height y) at `speed` pt/s, 60 fps; returns per-frame heights.
private func swipe(_ f: SnowField, speed: Float, y: CGFloat = 505, settle: Int = 0) -> [[Float]] {
    var frames: [[Float]] = [], x: CGFloat = 230
    let step = CGFloat(speed / 60)
    while x + step <= 470 {
        f.sweep(from: CGPoint(x: x, y: y), to: CGPoint(x: x + step, y: y), radius: 10, dt: 1 / 60)
        x += step
        frames.append(f.pile(id: 1)!.heights)
        f.stepDebris(dt: 1 / 60)
    }
    for _ in 0..<settle { f.stepDebris(dt: 1 / 60) }
    return frames
}

@Test func swipeNeverPopsAColumnAndTheDentIsSmooth() {
    let f = pileField()
    var prev = f.pile(id: 1)!.heights
    let top = prev.max()!
    for h in swipe(f, speed: 900) {
        for i in h.indices { #expect(prev[i] - h[i] <= 6.01) }
        prev = h
    }
    let h = prev, mid = h.count / 2
    var worst: Float = 0
    for i in 2..<(h.count - 2) { worst = max(worst, abs(h[i - 1] - 2 * h[i] + h[i + 1])) }
    #expect(worst < 2.5)
    #expect(h[mid - 20...mid + 20].min()! < top - 3)   // a trench, not a pop-in-place
}

@Test func fasterSwipeCutsDeeperAndSlowHoverOnlySifts() {
    let slow = pileField(), fast = pileField()
    let before = slow.pile(id: 1)!.heights.reduce(0, +)
    _ = swipe(slow, speed: 20);  // below Tuning.plowSlowSpeed: a hover
    _ = swipe(fast, speed: 1200)
    let rs = before - slow.pile(id: 1)!.heights.reduce(0, +), rf = before - fast.pile(id: 1)!.heights.reduce(0, +)
    #expect(rs > 0)
    #expect(rf > 1.3 * rs)   // the hover is slow, so it spends more frames at the same 0.6 pt depth: only the ratio shrank
}

@Test func swipeConservesVolumeBetweenPileAndDebris() {
    let f = pileField()
    let before = f.pile(id: 1)!.heights.reduce(0, +) * Tuning.binWidth
    _ = swipe(f, speed: 1000)
    let inFlight = f.debris.reduce(0) { $0 + $1.vol } + f.sweepOwed
    let p = f.pile(id: 1)!, now = (p.heights.reduce(0, +) + p.spillL + p.spillR) * Tuning.binWidth
    #expect(abs(before - now - inFlight) < 0.02 * before)
}

@Test func reduceMotionSweepFliesNothing() {
    let f = pileField()
    f.setCalm(true)
    let d0 = f.debris.count
    _ = swipe(f, speed: 1000)
    #expect(f.debris.count == d0)
}

// MARK: plow

/// A pile well under its limit, so the plow has room to bank snow.
private func lightField() -> SnowField {
    let f = makeField()
    f.update(windows: [win(1, 200, 300, 300, 200)])
    pileUp(f, id: 1, rounds: 3)
    return f
}

private func volume(_ f: SnowField) -> Float {
    let p = f.pile(id: 1)!
    return (p.heights.reduce(0, +) + p.spillL + p.spillR) * Tuning.binWidth
}
private func carried(_ f: SnowField) -> Float { f.debris.reduce(0) { $0 + $1.vol } + f.sweepOwed }

@Test func sweepPlowsASnowBermAheadOfTheCursor() {
    for dir: CGFloat in [1, -1] {
        let f = lightField()
        let before = f.pile(id: 1)!.heights
        let x0: CGFloat = dir > 0 ? 300 : 400
        f.sweep(from: CGPoint(x: x0, y: 502), to: CGPoint(x: x0 + 20 * dir, y: 502), radius: 10, dt: 1 / 20)
        let after = f.pile(id: 1)!.heights
        let mid = Int((x0 + 10 * dir - 200) / 2), ahead = mid + Int(dir) * 14, behind = mid - Int(dir) * 14
        #expect(after[mid] < before[mid])
        #expect((ahead - 4...ahead + 4).reduce(0) { $0 + after[$1] - before[$1] } > 0.5)
        #expect((behind - 4...behind + 4).reduce(0) { $0 + abs(after[$1] - before[$1]) } < 0.1)
    }
}

@Test func verticalSweepPartsTheSnowToBothSides() {
    let f = lightField()
    let before = f.pile(id: 1)!.heights
    f.sweep(from: CGPoint(x: 350, y: 540), to: CGPoint(x: 350, y: 500), radius: 10, dt: 1 / 20)
    let after = f.pile(id: 1)!.heights, mid = 75
    #expect(after[mid] < before[mid])
    #expect((mid - 12...mid - 6).reduce(0) { $0 + after[$1] - before[$1] } > 0.2)
    #expect((mid + 6...mid + 12).reduce(0) { $0 + after[$1] - before[$1] } > 0.2)
}

@Test func plowConservesVolumeAndStaysSmooth() {
    for speed: Float in [60, 400, 1200] {
        let f = lightField()
        let v0 = volume(f)
        _ = swipe(f, speed: speed)
        for _ in 0..<5 { f.sweep(from: CGPoint(x: 460, y: 505), to: CGPoint(x: 470, y: 505), radius: 10, dt: 1 / 60) }   // the end of the window
        #expect(abs(v0 - volume(f) - carried(f)) < 0.01 * v0)
        let h = f.pile(id: 1)!.heights
        #expect(h.allSatisfy { $0.isFinite && $0 >= 0 })
        var slope: Float = 0
        for i in 1..<h.count { slope = max(slope, abs(h[i] - h[i - 1])) }
        #expect(slope < 6)
    }
}

@Test func plowedSnowPastTheWindowEndFallsAsDebris() {
    let f = lightField()
    let d0 = f.debris.count, v0 = volume(f)
    for _ in 0..<80 { f.sweep(from: CGPoint(x: 440, y: 505), to: CGPoint(x: 480, y: 505), radius: 10, dt: 1 / 30) }
    #expect(f.debris.count > d0 || f.sweepOwed > 0)
    #expect(abs(v0 - volume(f) - carried(f)) < 0.01 * v0)
}

@Test func pointerPushOffLeavesPilesAlone() {
    let f = lightField()
    f.pointerPush = false
    let before = f.pile(id: 1)!.heights
    f.sweep(from: CGPoint(x: 300, y: 502), to: CGPoint(x: 400, y: 502), radius: 10)
    #expect(f.pile(id: 1)!.heights == before)
    #expect(!f.snowNear(from: CGPoint(x: 300, y: 530), to: CGPoint(x: 400, y: 530), radius: 20))   // pile bins in the path no longer count
}

@Test func plowOnAPileAtItsLimitHeapsAheadAndNeverSpraysAtTheCursor() {
    let f = pileField()   // full: every bin at or above its limit
    let v0 = volume(f), before = f.pile(id: 1)!.heights, d0 = f.debris.count
    for k in 0..<30 { f.sweep(from: CGPoint(x: 260 + CGFloat(k) * 4, y: 505), to: CGPoint(x: 280 + CGFloat(k) * 4, y: 505), radius: 10, dt: 1 / 30) }
    let p = f.pile(id: 1)!
    #expect(abs(v0 - volume(f) - carried(f)) < 0.01 * v0)
    #expect((p.heights.max() ?? 0) > (before.max() ?? 0) + 2)   // the pushed snow heaps above the usual pile: no height limit
    #expect(f.debris[d0...].allSatisfy { $0.pos.x > 430 })   // anything that flies off does so at the run end, not at the cursor
}

@Test func plowHeapRespectsTheCeilingCap() {
    let f = lightField()
    for i in 90..<130 { f.surfaces[0].pile.cap[i] = 3 }
    let before = f.pile(id: 1)!.heights
    for _ in 0..<20 { f.sweep(from: CGPoint(x: 300, y: 505), to: CGPoint(x: 330, y: 505), radius: 10, dt: 1 / 20) }
    let after = f.pile(id: 1)!.heights
    for i in 90..<130 { #expect(after[i] <= max(before[i], 3) + 0.01) }
}

/// Timing only (prints µs per call); the pile is restored every call so each pass cuts a fresh pile, as the first frames of a real swipe do.
@Test func plowMicrobench() {
    let f = lightField()
    let saved = f.surfaces[0].pile.heights
    var total = Duration.zero
    for i in 0..<20000 {
        let x = CGFloat(230 + (i % 40) * 6)
        let s: CGFloat = i % 3 == 0 ? 14 : 6   // 840 and 360 pt/s
        f.surfaces[0].pile.heights = saved
        let t0 = ContinuousClock.now
        f.sweep(from: CGPoint(x: x, y: 505), to: CGPoint(x: x + s, y: 505), radius: 10, dt: 1 / 60)
        total += ContinuousClock.now - t0
        if i % 50 == 0 { f.stepDebris(dt: 1 / 60) }
    }
    print("SWEEP µs/call:", total / 20000)
}

@Test func plowLeavesAThinLayerOnTheWindow() {
    let f = pileField()
    let before = f.pile(id: 1)!.heights
    for _ in 0..<40 { f.sweep(from: CGPoint(x: 300, y: 501), to: CGPoint(x: 400, y: 501), radius: 10, dt: 1 / 30) }
    let after = f.pile(id: 1)!.heights
    for i in 55...95 { #expect(after[i] >= min(before[i], Tuning.plowFloor) - 0.01) }   // never scraped bare: a bare edge between lumps reads as dark dashes
}

@Test func pushingMoreGrowsTheHeapAndSnowfallDoesNotTrimIt() {
    let f = pileField()
    func push(_ n: Int) { for k in 0..<n { f.sweep(from: CGPoint(x: 230 + CGFloat(k % 40) * 3, y: 505), to: CGPoint(x: 250 + CGFloat(k % 40) * 3, y: 505), radius: 10, dt: 1 / 30) } }
    push(20); let h1 = f.pile(id: 1)!.heights.max() ?? 0
    push(60); let h2 = f.pile(id: 1)!.heights.max() ?? 0
    #expect(h2 > h1 + 1)   // more pushing, bigger heap
    let v = f.pile(id: 1)!.heights.reduce(0, +)
    let peak = f.pile(id: 1)!.heights.firstIndex(of: h2)!
    for _ in 0..<20 { f.deposit(surface: f.index[1]!, bin: peak, volume: 1) }   // snow landing on and around the heap
    #expect((f.pile(id: 1)!.heights.max() ?? 0) >= h2 - 0.5)
    #expect(f.pile(id: 1)!.heights.reduce(0, +) >= v - 1)
    let p = f.pile(id: 1)!
    for i in 1..<p.heights.count where p.visible[i] && p.visible[i - 1] && abs(p.base[i] - p.base[i - 1]) < 0.5 {   // rounded corners drop the base: not the heap's slope
        #expect(abs(p.base[i] + p.heights[i] - p.base[i - 1] - p.heights[i - 1]) <= Tuning.slope * 2 + Tuning.dustSlope + 1) }   // a mound, not a spike (surface step within the snow's angle of repose)
}

// MARK: heap persistence (Space round trip, resize, ordinary rebuilds) and drawing

private func heapField() -> SnowField {
    let f = pileField()
    for k in 0..<80 { f.sweep(from: CGPoint(x: 230 + CGFloat(k % 40) * 3, y: 505), to: CGPoint(x: 250 + CGFloat(k % 40) * 3, y: 505), radius: 10, dt: 1 / 30) }
    return f
}
private func heapPeak(_ f: SnowField) -> Float { f.pile(id: 1)!.heights.max() ?? 0 }

@Test func heapSurvivesASpaceRoundTrip() {
    let f = heapField(); let h = heapPeak(f)
    #expect(h > Tuning.maxPileHeight + 2)
    f.dropPiles(); f.markStale()
    f.update(windows: [], now: 1)
    f.update(windows: [win(1, 200, 300, 300, 200)], now: 2)
    #expect(heapPeak(f) >= h - 0.5)
}

@Test func heapSurvivesAResize() {
    let f = heapField(); let h = heapPeak(f)
    f.resize(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780)
    f.update(windows: [win(1, 200, 300, 300, 200)], now: 1)
    #expect(heapPeak(f) >= h - 0.5)
}

@Test func heapSurvivesMovingItsWindowAndAnotherAppearing() {
    let f = heapField(); let h = heapPeak(f)
    f.update(windows: [win(1, 200, 300, 300, 200), win(2, 700, 200, 200, 100)], now: 1)
    #expect(heapPeak(f) >= h - 0.5)
    f.update(windows: [win(1, 230, 310, 300, 200), win(2, 700, 200, 200, 100)], now: 2)
    #expect(heapPeak(f) >= h - 0.5)
}

@Test func aTallHeapIsDrawnAtItsFullHeight() {
    let f = pileField()
    let si = f.index[1]!, b = f.surfaces[si].pile.heights.count / 2
    f.surfaces[si].pile.mound = [Float](repeating: 0, count: f.surfaces[si].pile.heights.count)
    for k in (b - 6)...(b + 6) { f.surfaces[si].pile.heights[k] = 150; f.surfaces[si].pile.mound[k] = 150 }
    f.pilesDirty = true
    let top = pileSegs(f).filter { $0.x0 > 200 && $0.x1 < 500 }.map { max($0.top0, $0.top1) }.max() ?? 0
    #expect(top - f.surfaces[si].edgeY > 140)
}

@Test func slowDeliberatePushesBuildAVisibleHeap() {
    let f = pileField()
    let d0 = f.debris.count
    let v0 = volume(f) + carried(f)
    for _ in 0..<10 {   // 150 pt/s strokes, 60 Hz, back over the same stretch
        for i in 0..<60 { let x = 240 + CGFloat(i) * 2.5; f.sweep(from: CGPoint(x: x, y: 505), to: CGPoint(x: x + 2.5, y: 505), radius: 10, dt: 1 / 60) }
    }
    let p = f.pile(id: 1)!
    let over = p.heights.indices.map { p.heights[$0] - p.rawLimit($0) }.max() ?? 0
    #expect(over >= 8)
    #expect(abs(volume(f) + carried(f) - v0) < 1)
    #expect(f.debris.count == d0)   // nothing sprays at the cursor
}
