import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

/// Field with a snowy pile on window 1 (x 300...700, top edge y=500) built by direct deposits; no flakes.
private func piledField(extra: [WindowInfo] = []) -> SnowField {
    let f = makeField()
    f.update(windows: extra + [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for _ in 0..<40 { for b in stride(from: 5, to: f.surfaces[i].pile.heights.count - 5, by: 2) { f.deposit(surface: i, bin: b, volume: 4) } }
    return f
}

/// Moves window 1 from x=300 to x=300+total in `n` equal steps (slow: 1 s per update, so nothing sheds).
private func slide(_ n: Int, total: CGFloat) -> (c0: Int, heights: [Float]) {
    let f = piledField()
    for k in 1...n { f.update(windows: [win(1, 300 + total * CGFloat(k) / CGFloat(n), 300, 400, 200)], dt: 1) }
    let p = f.pile(id: 1)!
    return (p.c0, Array(p.heights.dropFirst(5).dropLast(5)))   // ends are clipped by the corner taper, which depends on the exact x
}

// 1. Pile travels exactly as far as the window, however the move is split.
@Test func manySmallMovesEqualOneBigMove() {
    let one = slide(1, total: 20)
    for n in [2, 7, 20, 50] {
        let r = slide(n, total: 20)
        #expect(r.c0 == one.c0 && r.heights == one.heights)
    }
    let frac = slide(25, total: 10)          // 0.4 pt steps
    #expect(frac.c0 == slide(1, total: 10).c0 && frac.heights == slide(1, total: 10).heights)
}

@Test func pileCenterFollowsWindowWithinOneColumn() {
    let f = piledField()
    func center() -> Float { let p = f.pile(id: 1)!; var m: Float = 0, w: Float = 0
        for (b, h) in p.heights.enumerated() { m += h * (Float(p.c0 + b) + 0.5) * 2; w += h }; return m / w }
    let before = center()
    for k in 1...20 { f.update(windows: [win(1, 300 + CGFloat(k), 300, 400, 200)], dt: 1) }
    #expect(abs((center() - before) - 20) <= 2)
}

// 2 + 3. Drawn contour stays under a front window's underside.
/// Contour points (segment ends, tops and bases) of everything `writePiles` emits, fully eased.
func pilePoints(_ f: SnowField) -> [CGPoint] {
    pileSegs(f).flatMap { [CGPoint(x: Double($0.x0), y: Double($0.top0)), CGPoint(x: Double($0.x1), y: Double($0.top1)),
                           CGPoint(x: Double($0.x0), y: Double($0.base0)), CGPoint(x: Double($0.x1), y: Double($0.base1))] }
}

func pileSegs(_ f: SnowField) -> [PileSeg] {
    let cap = 8192
    let p = UnsafeMutablePointer<PileSeg>.allocate(capacity: cap)
    defer { p.deallocate() }
    let n = f.writePiles(to: p, capacity: cap, dt: 10, force: true)!
    return Array(UnsafeBufferPointer(start: p, count: n))
}

/// Tops only (what the old path's top edge was).
private func flatten(_ f: SnowField) -> [CGPoint] {
    pileSegs(f).flatMap { [CGPoint(x: Double($0.x0), y: Double($0.top0)), CGPoint(x: Double($0.x1), y: Double($0.top1))] }
}

@Test func drawnContourNeverEntersFrontWindow() {
    // Back top edge y=400 (x 100...400); front window underside at y=410, x 200...500: ceiling = 10pt of snow.
    let f = makeField()
    let front410 = win(2, 200, 410, 300, 200)
    f.update(windows: [front410, back])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for _ in 0..<40 { for b in 0..<f.surfaces[i].pile.heights.count { f.deposit(surface: i, bin: b, volume: 4) } }
    let pts = flatten(f).filter { $0.x >= 220 && $0.x <= 400 }   // past the front window's rounded corner (radius 20), where the ceiling rises along the arc
    #expect(pts.count > 20)
    #expect(pts.map(\.y).max()! <= 410 + 1e-9)
    #expect(flatten(f).filter { $0.x < 190 }.map(\.y).max()! > 410)   // snow left of the front window is still tall
}

@Test func contourIrregularityIsStableAndTravelsWithThePile() {
    let f = piledField()
    let a = flatten(f).filter { $0.x > 330 && $0.x < 670 }   // ends: corner taper clips on the next move
    #expect(flatten(f).filter { $0.x > 330 && $0.x < 670 } == a)   // no frame-to-frame shimmer
    let tops = a.filter { $0.y > 500 + 5 && $0.x > 400 && $0.x < 600 }.map(\.y)
    #expect(Set(tops.map { ($0 * 100).rounded() }).count > 5)   // not a smooth band
    #expect(a.map(\.y).max()! <= 500 + Double(Tuning.maxPileHeight) * 1.15 + 1.5 + 0.3 + 1e-9)
    f.update(windows: [win(1, 340, 300, 400, 200)], dt: 1)      // 40 pt = 20 whole columns
    let b = flatten(f).filter { $0.x > 370 && $0.x < 710 }
    #expect(a.count > 100 && a.count == b.count && zip(a, b).allSatisfy { abs($1.x - $0.x - 40) < 1e-9 && abs($1.y - $0.y) < 1e-9 })
}

// 4. Corner radius by OS.
@Test func windowRadiusDependsOnMacOSVersion() {
    #expect(Tuning.windowRadius(for: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) == 22)
    #expect(Tuning.windowRadius(for: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)) == 22)
    #expect(Tuning.windowRadius(for: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)) == 10)
    #expect(Tuning.windowRadius(for: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)) == 10)
}

// 5. Reduce Motion.
private func maxSway(calm: Bool) -> Float {
    let f = makeField(flakes: 600, seed: 7)
    f.setCalm(calm)
    var m: Float = 0
    for _ in 0..<600 {
        let before = f.flakes
        f.step(dt: 1 / 60)
        for (a, b) in zip(before, f.flakes) where a.kind != .dormant && b.pos.y < a.pos.y && abs(b.pos.x - a.pos.x) < 5 { m = max(m, abs(b.pos.x - a.pos.x) * 60) }
    }
    return m
}

@Test func calmModeReducesSwayToAQuarter() {
    // |vx| <= 6 * 1.3 = 7.8 pt/s (calm: no wind) plus sway amplitude <= 25 * 1.3 (per-flake drift) * 0.25 = 8.125.
    #expect(maxSway(calm: true) <= 7.8 + 8.125 + 0.01)
    #expect(maxSway(calm: false) > 20)
}

@Test func calmModeDebrisFallsWithoutClumpsOrJitter() {
    let f = makeField(flakes: 0)
    f.setCalm(true)
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for _ in 0..<40 { for b in stride(from: 5, to: 190, by: 2) { f.deposit(surface: i, bin: b, volume: 4) } }
    let spilled = f.debris.count   // edge spill-off is not knock-off
    f.update(windows: [])
    #expect(f.debris.count - spilled >= 3)   // a few intact blocks
    #expect(f.debris.dropFirst(spilled).allSatisfy { $0.vx == 0 && $0.fall == Tuning.calmDebrisFall })
    f.step(dt: 0.05)
    #expect(f.debris.dropFirst(spilled).allSatisfy { $0.fall > Tuning.calmDebrisFall })   // still falls (and accelerates)
}

// The screen-bottom pile (id -1) must be in the normal path (it was dropped: -1 doubled as the "no dragged window" sentinel)
// and sit on the visible bottom edge: base y = 0, top within groundMaxHeight.
@Test func groundPileIsDrawnOnScreen() {
    let f = makeField()
    f.update(windows: [])
    let g = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for _ in 0..<40 { for b in stride(from: 5, to: f.surfaces[g].pile.heights.count - 5, by: 2) { f.deposit(surface: g, bin: b, volume: 4) } }
    let ys = pilePoints(f).map(\.y)
    #expect(ys.count > 20)
    #expect(ys.min()! >= 0)
    #expect(ys.max()! > 10 && ys.max()! <= Double(Tuning.groundMaxHeight) + 2)
}

// Smooth growth: `shown` rises with tau 0.25 s, snaps down, and writePiles rewrites only when something changed.
@Test func shownEasesUpAndDown() {
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    let buf = UnsafeMutablePointer<PileSeg>.allocate(capacity: 4096)
    defer { buf.deallocate() }
    _ = f.writePiles(to: buf, capacity: 4096, dt: 1 / 60)
    for _ in 0..<8 { f.deposit(surface: i, bin: 100, volume: 4) }   // 8: the first landings on bare snow only partly stick (speckStick)
    let target = f.surfaces[i].pile.heights[100]
    #expect(target > 3)
    _ = f.writePiles(to: buf, capacity: 4096, dt: 1 / 60)
    #expect(f.surfaces[i].pile.shown[100] < 1.5)
    for _ in 0..<90 { _ = f.writePiles(to: buf, capacity: 4096, dt: 1 / 60) }
    #expect(f.surfaces[i].pile.shown[100] >= target * 0.95)
    for _ in 0..<200 { _ = f.writePiles(to: buf, capacity: 4096, dt: 1 / 60) }
    #expect(f.writePiles(to: buf, capacity: 4096, dt: 1 / 60) == nil)   // settled: reuse the last slot
    f.surfaces[i].pile.heights[100] = 0
    f.pilesDirty = true
    _ = f.writePiles(to: buf, capacity: 4096, dt: 1 / 60)
    #expect(f.surfaces[i].pile.shown[100] > 0 && f.surfaces[i].pile.shown[100] < target)   // eases down, no 1-frame snap
    for _ in 0..<18 { _ = f.writePiles(to: buf, capacity: 4096, dt: 1 / 60) }
    #expect(f.surfaces[i].pile.shown[100] == 0)   // within 0.3 s
}

@Test func pileVersionBumpsOnlyWhenHeightsChange() {
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    let v = f.pileVersion
    f.deposit(surface: i, bin: 100, volume: 1)
    #expect(f.pileVersion > v)
    let v2 = f.pileVersion
    f.step(dt: 0.0)                                  // nothing falls: no change
    f.update(windows: [win(1, 300, 300, 400, 200)])  // identical poll
    #expect(f.pileVersion == v2)
}

@Test func pilesSettledOnlyAfterTheLastWriteAndBusyIsFalseForQuietSnow() {
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    let buf = UnsafeMutablePointer<PileSeg>.allocate(capacity: 4096)
    defer { buf.deallocate() }
    _ = f.writePiles(to: buf, capacity: 4096, dt: 1 / 60, force: true)
    #expect(f.pilesSettled)
    f.deposit(surface: i, bin: 100, volume: 4)
    #expect(!f.pilesSettled)                         // changed: a frame is owed
    for _ in 0..<600 { _ = f.writePiles(to: buf, capacity: 4096, dt: 1 / 60) }
    #expect(f.pilesSettled)                          // eased to the end: the link may sleep
    #expect(!f.isBusy)
}

@Test func gentleSheddingAndGustsAloneAreNotBusyButBurstsAndSlabsAre() {
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    f.gustOverride = 0.8
    for i in 0..<16 { f.addDebris(x: 100 + Float(i), y: 500, vx: 10, fall: 20) }
    #expect(!f.isBusy)                               // a dozen small chunks and a gust with no figure: calm
    for i in 0..<12 { f.addDebris(x: 200 + Float(i), y: 500, vx: 10, fall: 20) }
    #expect(f.busyReasons == .debris)                // a burst
    f.debris.removeAll()
    f.debris.append(Flake(pos: [100, 500], vx: 0, fall: 0, phase: 0, amp: 1, freq: 0, size: 30, alpha: 1, kind: .debris, seed: 0, fade: 1))
    #expect(f.isBusy)                                // one intact slab (avalanche)
}

// Smoothed end slopes: stride matches the Metal struct (11 x 4 bytes, inset last); neighbours share n; run ends keep their own slope.
@Test func pileSegNormalsAreContinuous() {
    #expect(MemoryLayout<PileSeg>.stride == 44)
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for _ in 0..<40 { for b in 100..<140 { f.deposit(surface: i, bin: b, volume: 3 + Float(b % 7)) } }
    let s = pileSegs(f).filter { $0.dragged == 0 && $0.top0 > 300 && $0.x0 > 300 && $0.x1 < 700 }
    #expect(s.count > 10)
    var joined = 0
    for k in 0..<(s.count - 1) where abs(s[k].x1 - s[k + 1].x0) < 1e-3 {
        #expect(s[k].n1 == s[k + 1].n0)
        #expect(abs(s[k].n1 - (s[k].slope + s[k + 1].slope) / 2) < 1e-4)
        joined += 1
    }
    #expect(joined > 5)
}

@Test func pileSegRunEndsKeepOwnSlope() {
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for _ in 0..<40 { for b in 100..<140 { f.deposit(surface: i, bin: b, volume: 3) } }
    let s = pileSegs(f).filter { $0.x0 > 300 && $0.x1 < 700 && $0.top0 > 300 }
    #expect(!s.isEmpty)
    #expect(s.first!.n0 == s.first!.slope)
    #expect(s.last!.n1 == s.last!.slope)
}

// Ceiling modulation and soft approach.
private func wideField(id: Int = 1) -> SnowField {
    let f = makeField()
    f.update(windows: [win(id, 100, 300, 1000, 200)])
    return f
}

@Test func ceilingVariesAlongWindowAndIsStableForSameNumber() {
    let a = wideField().pile(id: 1)!, b = wideField().pile(id: 1)!
    let mid = (5..<(a.heights.count - 5)).map { a.limit($0) }
    #expect(mid.max()! - mid.min()! > 0.15 * a.maxHeight)
    #expect(mid.max()! <= a.maxHeight * 1.151)
    #expect((0..<a.heights.count).allSatisfy { a.limit($0) == b.limit($0) })
    #expect(wideField(id: 2).pile(id: 2)!.wobble != a.wobble)
}

@Test func depositSlowsNearTheCeiling() {
    var p = Pile(columns: 20, inset: 0)
    let l = p.limit(10)
    p.deposit(bin: 10, volume: 1)
    let first = p.heights[10]
    p.heights = [Float](repeating: l * 0.95, count: 20)
    p.deposit(bin: 10, volume: 1)
    #expect(p.heights[10] - l * 0.95 < first * 0.5)
}

@Test func longSnowfallStillFillsToCeilingAndAvalancheTriggers() {
    let f = wideField()
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for _ in 0..<400 { for b in 5..<(f.surfaces[i].pile.heights.count - 5) { f.deposit(surface: i, bin: b, volume: 4) } }
    let p = f.pile(id: 1)!
    let fill = (60..<(p.heights.count - 60)).map { p.heights[$0] / p.limit($0) }
    #expect(fill.min()! > 0.9)
    #expect(f.fullSpot(si: i) != nil)
}

/// Two specks far apart on a clean window are drawn as two specks: no segment spans the bare stretch between them (it used to show as a 1pt film).
@Test func farApartSpecksDrawNoFilmBetweenThem() {
    let f = makeField()
    f.update(windows: [win(1, 100, 300, 600, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    let c0 = f.surfaces[i].c0, n = f.surfaces[i].pile.heights.count
    f.surfaces[i].pile.heights[20] = 1; f.surfaces[i].pile.heights[n - 20] = 1
    let segs = pileSegs(f).filter { $0.base0 > 400 }   // the window's own pile (top edge at y=500)
    let left = (Float(c0 + 20) + 0.5) * Tuning.binWidth, right = (Float(c0 + n - 20) + 0.5) * Tuning.binWidth
    #expect(!segs.isEmpty)
    #expect(!segs.contains { $0.x0 > left + 4 && $0.x1 < right - 4 }, "a segment lies on the bare stretch between the specks")
}
