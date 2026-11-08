import CoreGraphics
import Testing
@testable import NeveCore

/// Floating Dock bar x 500...900, glass bottom at y=10 (gap 10pt between the bar and the screen bottom).
private func dockField(seed: UInt64 = 5) -> SnowField {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 0, visibleTop: 880, flakeCount: 0, seed: seed)
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 500, y: 10, width: 400, height: 80), radius: 20)])
    return f
}
private let bar: ClosedRange<Float> = 500...900

@Test func groundSnowStaysInsideTheGapUnderTheDockBar() {
    let f = dockField()
    let g = f.index[Tuning.groundID]!
    for b in 0..<f.surfaces[g].pile.heights.count { for _ in 0..<40 { f.deposit(surface: g, bin: b, volume: 4) } }
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 500, y: 10, width: 400, height: 80), radius: 20)])
    let p = f.surfaces[f.index[Tuning.groundID]!].pile
    var under = 0
    for b in p.heights.indices where bar.contains(binCenter(b)) {
        under += 1
        #expect(p.heights[b] <= Tuning.barUnderside(x: binCenter(b), minX: 500, maxX: 900, minY: 10, radius: 20)! - Tuning.barMargin + 0.001)
        if binCenter(b) > 530 && binCenter(b) < 870 { #expect(p.heights[b] <= 9.001) }   // along the flat: strictly inside the gap
    }
    #expect(under > 100)
}

@Test func snowmenNeverStandUnderTheDockBar() {
    for seed in [1, 2, 3] as [UInt64] {
        let f = dockField(seed: seed)
        let g = f.index[Tuning.groundID]!
        for b in 0..<f.surfaces[g].pile.heights.count { for _ in 0..<6 { f.deposit(surface: g, bin: b, volume: 4) } }
        let a = standAuto(f, x: 700), s = stand(f, x: 560)   // both start inside the bar's x-range
        for _ in 0..<(150 * 30) {
            f.step(dt: 1 / 30)
            for id in [a, s] { let q = fig(f, id); if q.phase != .hidden { #expect(!bar.contains(q.foot.x)) } }
        }
        #expect(fig(f, a).phase != .hidden && !bar.contains(fig(f, a).foot.x))
    }
}

@Test func standRangeExcludesLowColumnsForEveryKind() {
    let f = dockField()
    let g = f.index[Tuning.groundID]!
    for h in [14 * f.snowmanScale, 22 * f.snowmanScale, Snowman.height * f.snowmanScale] {
        let r = f.standRange(si: g, x: 700, height: h)!
        #expect(!bar.contains((r.0 + r.1) / 2) && (r.1 <= 500 || r.0 >= 900))
        let r2 = f.standRange(si: g, x: 200, height: h)!
        #expect(r2.1 <= 500 + 1)
    }
}

@Test func ballTooBigForTheGapRollsOutFromUnderTheBar() {
    let f = dockField()
    var b = Snowball(id: 900, pos: SIMD2(700, 15), radius: 12, surfaceID: Tuning.groundID)
    b.state = .resting
    f.nextBallID = 901
    f.balls.append(b)
    advance(f, 6)
    let x = ball(f, 900).pos.x
    #expect(!bar.contains(x))
    var small = Snowball(id: 901, pos: SIMD2(700, 3), radius: 3, surfaceID: Tuning.groundID)   // fits in the 9pt gap: stays
    small.state = .resting
    f.balls.append(small)
    advance(f, 2)
    #expect(ball(f, 901).pos.x == 700)
}

// MARK: - Bank up and over the Dock (1440x900, bar (171,10,1098,84), r 25.2: top 94)

private let rr: Float = 25.2
/// Inside the bar's rounded-rect silhouette, inset by `m` (so the 2pt bin chords do not count).
private func insideBar(_ x: Float, _ y: Float, inset m: Float = 2.1) -> Bool {
    let (x0, x1, y0, y1) = (171 + m, 1269 - m, 10 + m, 94 - m), r = rr - m
    guard x >= x0, x <= x1, y >= y0, y <= y1 else { return false }
    let cx = min(max(x, x0 + r), x1 - r), cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) * (x - cx) + (y - cy) * (y - cy) < r * r
}
private func makeBankedField(grow: Bool) -> SnowField {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 1)
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 171, y: 10, width: 1098, height: 84), radius: CGFloat(rr))])
    fillBankLevel(f)   // fully grown bank (the ramp level rises with snowfall, see DockPushTests)
    if grow {
        for i in f.surfaces.indices where f.surfaces[i].id <= 0 {
            for _ in 0..<400 { for b in f.surfaces[i].pile.heights.indices { f.deposit(surface: i, bin: b, volume: 4) } }
        }
    }
    return f
}
/// The grown piles are deterministic and slow to build (288k deposits in a debug build), so grow them once per process and hand every test a copy.
nonisolated(unsafe) private let grownBankSurfaces = makeBankedField(grow: true).surfaces
private func bankedField() -> SnowField {
    let f = makeBankedField(grow: false)
    f.surfaces = grownBankSurfaces
    f.pilesDirty = true
    return f
}

@Test func bankReachesTheBarTopBesideItsEndAsAFlushShelf() {
    let f = bankedField()
    let g = f.pile(id: Tuning.groundID)!
    #expect(g.heights[84] >= 92 && g.heights[635] >= 92)   // columns adjacent to the bar ends
    for b in 1..<84 { #expect(abs(g.heights[b] - g.heights[b - 1]) <= Tuning.slope * Tuning.binWidth + 0.01) }
    #expect(g.heights[84 - 60] >= 90)                      // the grown bank is a level shelf flush with the Dock top across the 171pt gap
}

@Test func noContourPointInsideTheBarSilhouetteAndOneChainOverTheTop() {
    let f = bankedField()
    let segs = pileSegs(f).sorted { $0.x0 < $1.x0 }
    var tops: [(x: Float, y: Float)] = []
    for g in segs where g.x1 > 100 && g.x0 < 1340 && g.base0 < 100 {
        for k in 0...8 { let t = Float(k) / 8; tops.append((g.x0 + (g.x1 - g.x0) * t, g.top0 + (g.top1 - g.top0) * t)) }
    }
    for p in tops { #expect(!insideBar(p.x, p.y), "contour (\(p.x), \(p.y)) inside the bar") }
    // The upper envelope of every segment (max top at each x) is continuous from the bank to the Dock top and back down.
    func env(_ x: Float) -> Float? {
        var m: Float?
        for g in segs where x >= g.x0 && x <= g.x1 { let y = g.top0 + (g.top1 - g.top0) * (x - g.x0) / max(g.x1 - g.x0, 1e-3); m = max(m ?? y, y) }
        return m
    }
    var prev: Float?
    for x in stride(from: Float(120), through: 1320, by: 1) {
        guard let y = env(x) else { prev = nil; continue }
        if let p = prev { #expect(abs(y - p) <= 2.5, "jump \(p) -> \(y) at x \(x)") }
        prev = y
    }
    #expect(env(171)! >= 92 && env(700)! >= 92)   // up at the Dock top at the end and over the bar
}

@Test func bankMeetsTheDockPileAtEachBarEndWithoutStepOrSpike() {
    let f = bankedField()
    let segs = pileSegs(f)
    func env(_ x: Float) -> Float? {
        var m: Float?
        for g in segs where x >= g.x0 && x <= g.x1 { let y = g.top0 + (g.top1 - g.top0) * (x - g.x0) / max(g.x1 - g.x0, 1e-3); m = max(m ?? y, y) }
        return m
    }
    var prev: Float?
    for x in stride(from: Float(120), through: 1320, by: 0.5) {   // the cliff down to the gap hides under the envelope; no step above 1.5pt, hence no spike either
        guard let y = env(x) else { prev = nil; continue }
        if let p = prev { #expect(abs(y - p) <= 1.5, "jump \(p) -> \(y) at x \(x)") }
        prev = y
    }
    // The bank column beside each bar end and the Dock pile's filled corner share the same contour point, and the bridge between them is always emitted.
    for (bankX, dockX) in [(Float(169), Float(171)), (1271, 1269)] {
        let bank = segs.filter { $0.x0 == bankX || $0.x1 == bankX }.map { $0.x0 == bankX ? $0.top0 : $0.top1 }
        #expect(bank.count >= 2 && (bank.max()! - bank.min()!) < 0.01 && bank[0] >= 92, "bank/Dock top mismatch at \(bankX): \(bank)")
        #expect(segs.contains { min($0.x0, $0.x1) == min(bankX, dockX) && max($0.x0, $0.x1) == max(bankX, dockX) && $0.base0 + $0.base1 < 200 && $0.top0 >= 92 })
    }
}

@Test func groundIsOneChainThroughEachDockEndAndTheBridgeIsABodyNotAnEdge() {
    let f = bankedField()
    let segs = pileSegs(f).sorted { $0.x0 < $1.x0 }
    let ground = segs.filter { $0.base0 == 0 && $0.base1 == 0 && $0.dragged & 2 == 0 }   // ground chain: base on the screen bottom, not the bank-flagged bridges
    let bridges = segs.filter { $0.dragged & 2 != 0 && ($0.base0 == 0 || $0.base1 == 0) }   // bank-flagged bodies standing in for the ground slice at each bar end
    for (a, b) in zip(ground, ground.dropFirst()) where a.x1 > 100 && b.x0 < 1340 {
        if a.x1 != b.x0 { #expect(bridges.contains { $0.x0 <= a.x1 && $0.x1 >= b.x0 }, "hole in the ground chain at \(a.x1)...\(b.x0)"); continue }   // the only holes are exactly covered by a bridge
        #expect(a.x1 == b.x0, "ground chain overlaps or leaves a gap at \(a.x1) / \(b.x0)")   // no duplicated columns, no hairline gap
        #expect(abs(b.top0 - a.top1) <= 2, "top jumps \(a.top1) -> \(b.top0) at \(a.x1)")
        // Within a column the top moves at most 2pt, except the one cliff column at each bar end, whose low side is the bar underside arc.
        if abs(a.top1 - a.top0) > 6 { #expect(a.x0 == 169 || a.x0 == 1267, "unexpected cliff at \(a.x0)"); #expect(min(a.top0, a.top1) <= 25.2 + 10) }   // (the bank itself climbs at the 0.7 repose step: < 6pt per bin pair)
    }
    // Bridges (bank-flagged, ground-based) are bodies with no slanted base edge: a steep one cast a dark skirt across the bank.
    #expect(bridges.count == 2 && bridges.allSatisfy { $0.base0 == 0 && $0.base1 == 0 })
}

// The snow over each rounded bar corner is a smooth shoulder: no flat block with a right angle where bank meets Dock pile.
@Test func outlineOverEachBarCornerIsASmoothShoulder() {
    let segs = pileSegs(bankedField())
    func env(_ x: Float) -> Float? {
        var m: Float?
        for g in segs where x >= g.x0 && x <= g.x1 { let y = g.top0 + (g.top1 - g.top0) * (x - g.x0) / max(g.x1 - g.x0, 1e-3); m = max(m ?? y, y) }
        return m
    }
    for (name, xs) in [("left", Array(stride(from: Float(150), through: 215, by: 2))), ("right", Array(stride(from: Float(1290), through: 1225, by: -2)))] {
        let ys = xs.compactMap(env)
        #expect(ys.count == xs.count, "\(name): hole in the outline")
        for k in 1..<(ys.count - 1) { #expect(abs(ys[k + 1] - 2 * ys[k] + ys[k - 1]) <= 2, "\(name): kink at \(xs[k]): \(ys[k - 1]) \(ys[k]) \(ys[k + 1])") }
        // Never a flat-topped block across the corner: the top keeps climbing from the bank to the Dock snow.
        #expect(ys[ys.count - 1] - ys[xs.firstIndex { abs($0 - (name == "left" ? 172 : 1268)) < 1 }!] >= 8, "\(name): flat block over the corner")
    }
}

@Test func dockSurfaceFollowsAWidenedFrame() {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 0, visibleTop: 880, flakeCount: 0, seed: 5)
    func put(_ x: CGFloat, _ w: CGFloat) { f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: x, y: 10, width: w, height: 80), radius: 20)]) }
    put(500, 400)
    let d = f.index[0]!
    for b in f.surfaces[d].pile.heights.indices { f.deposit(surface: d, bin: b, volume: 3) }
    put(450, 500)   // an item was added: the bar grew on both sides (the sim moves the ends at Tuning.dockSpeed; let it arrive)
    for _ in 0..<30 { f.step(dt: 1 / 60) }
    let s = f.surfaces[f.index[0]!]
    #expect(s.frame.minX == 450 && s.frame.maxX == 950)
    #expect(s.pile.x0 == 450 && s.pile.x1 == 950)
    for b in s.pile.heights.indices { #expect(binCenter(s.c0 + b) >= 450 && binCenter(s.c0 + b) <= 950) }
    #expect(s.c0 * Int(Tuning.binWidth) <= 452 && (s.c0 + s.pile.heights.count) * Int(Tuning.binWidth) >= 948)   // columns cover the new ends
    let old = s.pile.heights.indices.filter { binCenter(s.c0 + $0) >= 510 && binCenter(s.c0 + $0) <= 890 }
    #expect(old.allSatisfy { s.pile.heights[$0] > 0 })   // the pile over the old span is carried
}
