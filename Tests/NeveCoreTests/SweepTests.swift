// AGENT HEADER - Tests/NeveCoreTests/SweepTests.swift  (cursor sweep, Surfaces.sweep + pointer swirl)
// Window top y = 500, x 200...500, piles built by direct deposits (`pileField` full, `lightField` 3 rounds). A sweep clears only its path (the snow heaps ahead of the cursor, or to both sides for a vertical pass; nothing sprays at the cursor on a full pile),
//   a sweep above the pile removes nothing, debris flies in the cursor direction from the run end, the dragged window's pile is not swept, falling flakes part around a still pointer and a distant pointer does nothing. "Soft dent": a swipe never pops a
//   column, a push scoops to Tuning.plowFloor while a hover only sifts, volume is conserved between pile, debris and `sweepOwed`, Reduce Motion / pointerPush off leave piles alone, a heap respects the ceiling cap, grows with more pushing and is not trimmed by
//   snowfall. Heap persistence: survives a Space round trip, a `resize`, moving its window; a tall heap is drawn at full height. Slow deliberate strokes (150 pt/s) build a heap >= 20 pt over the pile limit. A push (>= 40 pt/s) scoops to plowFloor with radius Tuning.plowRadius; one 100 pt/s stroke leaves the floor and builds a heap, same at 30 and 120 fps. `plowMicrobench` only prints timing.

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
    f.sweep(from: CGPoint(x: 340, y: 502), to: CGPoint(x: 360, y: 502))
    let after = f.pile(id: 1)!.heights
    #expect(f.debris.count == d0)   // the pile is full, yet nothing sprays at the cursor: the snow heaps ahead of it
    // bin i covers x = 200 + 2i; path x 340...360 (+10) = bins 65...85
    #expect(after[75] < before[75])
    for i in [30, 45] { #expect(after[i] == before[i]) }   // (a tall heap settles over a wide reach, so only far ends of the pile may relax)
}

@Test func sweepAboveThePileRemovesNothing() {
    let f = pileField()
    let before = f.pile(id: 1)!.heights, d0 = f.debris.count
    f.sweep(from: CGPoint(x: 250, y: 560), to: CGPoint(x: 450, y: 560))
    #expect(f.pile(id: 1)!.heights == before)
    #expect(f.debris.count == d0)
}

@Test func debrisFliesInTheCursorDirectionFromTheRunEnd() {
    for dir: CGFloat in [1, -1] {
        let f = pileField()
        let d0 = f.debris.count
        let x0: CGFloat = dir > 0 ? 440 : 260
        for _ in 0..<60 { f.sweep(from: CGPoint(x: x0, y: 505), to: CGPoint(x: x0 + 40 * dir, y: 505), dt: 1 / 30) }
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
    f.sweep(from: CGPoint(x: 340, y: 502), to: CGPoint(x: 400, y: 502))
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
        f.sweep(from: CGPoint(x: x, y: y), to: CGPoint(x: x + step, y: y), dt: 1 / 60)
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
        for i in 20..<(h.count - 20) { #expect(h[i] >= min(prev[i], Tuning.plowFloor) - 0.8) }   // (slumping heaps nibble the floor) a blade scoops to the floor, never below
        prev = h
    }
    let h = prev, mid = h.count / 2
    var worst: Float = 0
    for i in 2..<(h.count - 2) { worst = max(worst, abs(h[i - 1] - 2 * h[i] + h[i + 1])) }
    #expect(worst < 4.2)   // pushed heaps are compacted (steeper by Tuning.moundSlope), so a crest kink is a bit sharper than at the plain slope
    #expect(h[mid - 20...mid + 20].min()! < top - 3)   // a trench, not a pop-in-place
}

@Test func pushScoopsToTheFloorAndHoverOnlySifts() {
    let slow = pileField(), push = pileField()
    let before = slow.pile(id: 1)!.heights.reduce(0, +)
    _ = swipe(slow, speed: 20)   // below Tuning.plowSlowSpeed: a hover
    _ = swipe(push, speed: 100)  // a deliberate push
    let rs = before - slow.pile(id: 1)!.heights.reduce(0, +), rp = before - push.pile(id: 1)!.heights.reduce(0, +)
    #expect(rs > 0)
    #expect(rp > 20 * rs)   // the hover barely marks, the push takes the whole path
    let h = push.pile(id: 1)!.heights
    for i in 40...90 { #expect(h[i] < 3 + 0.5) }   // path y=505 (5 pt above the window) with radius 14: everything above plowFloor goes (heap sits only at the ends)
}

/// One stroke at `speed` over a full pile, `fps` frames per second; returns (heap peak, removed volume under the path).
private func stroke(fps: Float, speed: Float = 100) -> (peak: Float, removed: Float, path: [Float]) {
    let f = pileField()
    let before = f.pile(id: 1)!.heights
    let step = CGFloat(speed / fps)
    var x: CGFloat = 250
    while x + step <= 350 { f.sweep(from: CGPoint(x: x, y: 505), to: CGPoint(x: x + step, y: 505), dt: 1 / fps); x += step }
    let p = f.pile(id: 1)!
    let removed = (0..<p.heights.count).reduce(Float(0)) { $0 + max(before[$1] - p.heights[$1], 0) } * Tuning.binWidth
    return (p.heights.max() ?? 0, removed, Array(p.heights[35...65]))
}

@Test func slowStrokeThroughAFullPileLeavesOnlyTheFloorAndBuildsAHeap() {
    let f = pileField()
    let before = f.pile(id: 1)!.heights, v0 = volume(f), d0 = f.debris.count
    var x: CGFloat = 250
    while x < 350 { f.sweep(from: CGPoint(x: x, y: 505), to: CGPoint(x: x + 1.67, y: 505), dt: 1 / 60); x += 1.67 }   // 100 pt/s
    let p = f.pile(id: 1)!
    for i in 35...60 { #expect(p.heights[i] <= Tuning.plowFloor + 0.5) }   // (the heap slumps a little back) bins x 270...320: only plowFloor under the path
    let removed = (0..<p.heights.count).reduce(Float(0)) { $0 + max(before[$1] - p.heights[$1], 0) } * Tuning.binWidth
    let over = p.heights.indices.map { p.heights[$0] - before[$0] }.max() ?? 0
    #expect(removed > 5 * 28 * 10)   // ~ 100 pt x ~10 pt of snow
    #expect(over >= removed / 60)   // the heap (slope-relaxed to a ~60 pt wide mound) stands at least removed volume / 60 high
    #expect(abs(volume(f) + carried(f) - v0) < 0.01 * v0)
    #expect(f.debris.count == d0)
    print("PLOW stroke: removed", removed, "heap growth", over)
}

@Test func plowResultIsTheSameAtAnyFrameRate() {
    let a = stroke(fps: 30), b = stroke(fps: 120)
    #expect(abs(a.removed - b.removed) <= 0.05 * b.removed)
    #expect(abs(a.peak - b.peak) <= 0.15 * b.peak)   // the heap is relaxed once per frame, so its crest differs a little more than the removed volume
    for (x, y) in zip(a.path, b.path) { #expect(abs(x - y) <= 1.0) }
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
        f.sweep(from: CGPoint(x: x0, y: 502), to: CGPoint(x: x0 + 20 * dir, y: 502), dt: 1 / 20)
        let after = f.pile(id: 1)!.heights
        let mid = Int((x0 + 10 * dir - 200) / 2), ahead = mid + Int(dir) * 14, behind = mid - Int(dir) * 24
        #expect(after[mid] < before[mid])
        #expect((ahead - 4...ahead + 4).reduce(0) { $0 + after[$1] - before[$1] } > 0.5)
        #expect((behind - 4...behind + 4).reduce(0) { $0 + abs(after[$1] - before[$1]) } < 0.1)
    }
}

@Test func verticalSweepPartsTheSnowToBothSides() {
    let f = lightField()
    let before = f.pile(id: 1)!.heights
    f.sweep(from: CGPoint(x: 350, y: 540), to: CGPoint(x: 350, y: 500), dt: 1 / 20)
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
        for _ in 0..<5 { f.sweep(from: CGPoint(x: 460, y: 505), to: CGPoint(x: 470, y: 505), dt: 1 / 60) }   // the end of the window
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
    for _ in 0..<80 { f.sweep(from: CGPoint(x: 440, y: 505), to: CGPoint(x: 480, y: 505), dt: 1 / 30) }
    #expect(f.debris.count > d0 || f.sweepOwed > 0)
    #expect(abs(v0 - volume(f) - carried(f)) < 0.01 * v0)
}

@Test func pointerPushOffLeavesPilesAlone() {
    let f = lightField()
    f.pointerPush = false
    let before = f.pile(id: 1)!.heights
    f.sweep(from: CGPoint(x: 300, y: 502), to: CGPoint(x: 400, y: 502))
    #expect(f.pile(id: 1)!.heights == before)
    #expect(!f.snowNear(from: CGPoint(x: 300, y: 530), to: CGPoint(x: 400, y: 530), radius: 20))   // pile bins in the path no longer count
}

@Test func plowOnAPileAtItsLimitHeapsAheadAndNeverSpraysAtTheCursor() {
    let f = pileField()   // full: every bin at or above its limit
    let v0 = volume(f), before = f.pile(id: 1)!.heights, d0 = f.debris.count
    for k in 0..<30 { f.sweep(from: CGPoint(x: 260 + CGFloat(k) * 4, y: 505), to: CGPoint(x: 280 + CGFloat(k) * 4, y: 505), dt: 1 / 30) }
    let p = f.pile(id: 1)!
    #expect(abs(v0 - volume(f) - carried(f)) < 0.01 * v0)
    #expect((p.heights.max() ?? 0) > (before.max() ?? 0) + 2)   // the pushed snow heaps above the usual pile: no height limit
    #expect(f.debris[d0...].allSatisfy { $0.pos.x > 430 })   // anything that flies off does so at the run end, not at the cursor
}

@Test func plowHeapRespectsTheCeilingCap() {
    let f = lightField()
    for i in 90..<130 { f.surfaces[0].pile.cap[i] = 3 }
    let before = f.pile(id: 1)!.heights
    for _ in 0..<20 { f.sweep(from: CGPoint(x: 300, y: 505), to: CGPoint(x: 330, y: 505), dt: 1 / 20) }
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
        f.sweep(from: CGPoint(x: x, y: 505), to: CGPoint(x: x + s, y: 505), dt: 1 / 60)
        total += ContinuousClock.now - t0
        if i % 50 == 0 { f.stepDebris(dt: 1 / 60) }
    }
    print("SWEEP µs/call:", total / 20000)
}

@Test func plowLeavesAThinLayerOnTheWindow() {
    let f = pileField()
    let before = f.pile(id: 1)!.heights
    for _ in 0..<40 { f.sweep(from: CGPoint(x: 300, y: 501), to: CGPoint(x: 400, y: 501), dt: 1 / 30) }
    let after = f.pile(id: 1)!.heights
    for i in 55...95 { #expect(after[i] >= min(before[i], Tuning.plowFloor) - 0.01) }   // never scraped bare: a bare edge between lumps reads as dark dashes
}

@Test func pushingMoreGrowsTheHeapAndSnowfallDoesNotTrimIt() {
    let f = pileField()
    func push(_ n: Int) { for k in 0..<n { f.sweep(from: CGPoint(x: 230 + CGFloat(k % 40) * 3, y: 505), to: CGPoint(x: 250 + CGFloat(k % 40) * 3, y: 505), dt: 1 / 30) } }
    push(20); let h1 = f.pile(id: 1)!.heights.max() ?? 0
    push(60); let h2 = f.pile(id: 1)!.heights.max() ?? 0
    #expect(h2 > h1 + 1)   // more pushing, bigger heap
    let v = f.pile(id: 1)!.heights.reduce(0, +)
    let peak = f.pile(id: 1)!.heights.firstIndex(of: h2)!
    for _ in 0..<6 { f.deposit(surface: f.index[1]!, bin: peak, volume: 1) }   // snow landing on and around the heap
    #expect((f.pile(id: 1)!.heights.max() ?? 0) >= h2 - 1.5)
    #expect(f.pile(id: 1)!.heights.reduce(0, +) >= v - 1)
    let p = f.pile(id: 1)!
    for i in 1..<p.heights.count where p.visible[i] && p.visible[i - 1] && abs(p.base[i] - p.base[i - 1]) < 0.5 {   // rounded corners drop the base: not the heap's slope
        #expect(abs(p.base[i] + p.heights[i] - p.base[i - 1] - p.heights[i - 1]) <= Tuning.slope * 2 + Tuning.moundSlope + Tuning.dustSlope + 1) }   // (heap flanks may stand at slope + moundSlope per bin: compacted snow) a mound, not a spike (surface step within the snow's angle of repose)
}

// MARK: heap persistence (Space round trip, resize, ordinary rebuilds) and drawing

private func heapField() -> SnowField {
    let f = pileField()
    for k in 0..<80 { f.sweep(from: CGPoint(x: 230 + CGFloat(k % 40) * 3, y: 505), to: CGPoint(x: 250 + CGFloat(k % 40) * 3, y: 505), dt: 1 / 30) }
    return f
}
private func heapPeak(_ f: SnowField) -> Float { f.pile(id: 1)!.heights.max() ?? 0 }

@Test func pushedHeapStaysCompactWhenTheCursorStops() {
    let f = heapField(); let h0 = heapPeak(f)
    for _ in 0..<300 { f.step(dt: 1 / 60) }   // 5 s without the cursor
    #expect(heapPeak(f) >= 0.85 * h0)   // pushed snow is compacted (~45 degrees): it settles little and slowly
    let h = f.pile(id: 1)!.heights
    for i in 1..<h.count - 1 { #expect(h[i] - max(h[i - 1], h[i + 1]) <= 3) }   // no isolated 1-bin spike
}

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
    for _ in 0..<3 {   // 150 pt/s strokes, 60 Hz, back over the same stretch
        for i in 0..<60 { let x = 240 + CGFloat(i) * 2.5; f.sweep(from: CGPoint(x: x, y: 505), to: CGPoint(x: x + 2.5, y: 505), dt: 1 / 60) }
    }
    let p = f.pile(id: 1)!
    let over = p.heights.indices.map { p.heights[$0] - p.rawLimit($0) }.max() ?? 0
    #expect(over >= 20)   // full scoops: a tall heap after a few strokes
    #expect(abs(volume(f) + carried(f) - v0) < 1)
    #expect(f.debris.count == d0)   // nothing sprays at the cursor
}
