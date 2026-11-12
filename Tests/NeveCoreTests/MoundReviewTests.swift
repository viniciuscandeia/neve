// AGENT HEADER - Tests/NeveCoreTests/MoundReviewTests.swift  (tall heap rounded / lumpy / volume kept; scooped gap walls slump + fast push throws powder, calm none; Pile.mound stays self-correcting when snow leaves a heap without trackMound; clear() resets dockMoundCarry)
import CoreGraphics
import Testing
@testable import NeveCore

private func heapPile() -> Pile {
    var p = Pile(columns: 100, inset: 0, c0: 0, x0: 0, x1: 200)
    p.mound = [Float](repeating: 0, count: 100)
    for k in 40..<60 { p.heights[k] = 120; p.trackMound(k) }
    return p
}
private func flood(_ p: inout Pile) { for _ in 0..<400 { for b in stride(from: 0, to: 100, by: 3) { p.deposit(bin: b, volume: 4) } } }

// Melt / releasePiles / takeSnow lower heights directly; snowfall must then fill only to the normal ceiling, not regrow the old heap.
@Test func lowerHeapDoesNotRegrowFromSnowfall() {
    for lower in [{ (p: inout Pile) in for k in 40..<60 { p.heights[k] = 0 } },          // release
                  { (p: inout Pile) in for k in 40..<60 { p.heights[k] = max(0, p.heights[k] - 119) } },   // melt
                  { (p: inout Pile) in for k in 40..<60 { p.heights[k] *= 0.5 } }] {   // takeSnow-like
        var p = heapPile()
        lower(&p)
        let ceiling = max(p.heights.max()!, p.heights.indices.map { p.rawLimit($0) }.max()!) + 0.01   // what is left, or the normal ceiling
        flood(&p)
        #expect(p.heights.max()! <= ceiling, "regrown heap \(p.heights.max()!)")
    }
}

@Test func clearResetsDockMoundCarry() {
    let f = makeField()
    f.dockCarry = [1]; f.dockMoundCarry = [1]
    f.clear()
    #expect(f.dockCarry.isEmpty && f.dockMoundCarry.isEmpty)
}

// A tall pushed heap (as the plow builds: a triangle at the repose slope) rounds into a lumpy mound: no knife apex, not one straight line, texture grows with height, volume kept.
@Test func tallHeapIsRoundedLumpyAndKeepsItsVolume() {
    var p = Pile(columns: 200, inset: 0, c0: 0, x0: -1e4, x1: 1e4)
    p.mound = [Float](repeating: 0, count: 200)
    for k in 0..<200 { p.heights[k] = 6 + max(0, 60 - 2 * Float(abs(k - 100))); p.trackMound(k) }   // base layer + 60 pt triangle at slope 2 per bin
    let v0 = p.heights.reduce(0, +)
    for _ in 0..<600 { p.settle(60, 140) }
    #expect(abs(p.heights.reduce(0, +) - v0) < 0.01 * v0)
    let top = p.heights.max()!, at = p.heights.firstIndex(of: top)!
    #expect(top > 30)
    // rounded crest: the apex is not a spike over its neighbours 2 bins away (a triangle would be 4 pt above them per bin of slope 2)
    #expect(top - max(p.heights[at - 2], p.heights[at + 2]) < 2.5, "apex \(top) vs \(p.heights[at - 2]) / \(p.heights[at + 2])")
    // slope is not a straight line: second difference along the face varies
    let hs = p.heights
    var d2s: [Float] = []
    for i in (at - 30)..<(at - 6) { let a: Float = hs[i - 1] + hs[i + 1]; d2s.append(a - 2 * hs[i]) }
    #expect(d2s.map { abs($0) }.max()! > 0.1, "straight face")
    // drawn texture amplitude grows with height
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let s = f.surfaces.first { $0.id == 1 }!
    func amp(_ sm: Float) -> Float { (0..<300).map { abs(SnowField.jitter(s, $0, sm)) }.max()! }
    #expect(amp(60) > 1.8 * amp(15), "amp \(amp(60)) vs \(amp(15))")
}

@Test func scoopedGapWallsSlumpToReposeAndAFastPushThrowsPowder() {
    func scene(_ economy: Bool = false, calm: Bool = false) -> SnowField {
        let f = makeField(); f.update(windows: [win(1, 100, 300, 600, 300)])
        if calm { f.setCalm(true) }
        f.economy = economy
        let i = f.surfaces.firstIndex { $0.id == 1 }!
        for b in f.surfaces[i].pile.heights.indices { f.surfaces[i].pile.heights[b] = 12 }
        return f
    }
    func total(_ f: SnowField) -> Float { f.surfaces.reduce(0) { $0 + $1.pile.heights.reduce(0, +) } * Tuning.binWidth + f.debris.reduce(0) { $0 + $1.vol } + f.sweepOwed + f.surfaces.reduce(0) { $0 + ($1.pile.spillL + $1.pile.spillR) * Tuning.binWidth } }
    let f = scene(); let v0 = total(f)
    let top = Float(300 + 300)
    for k in 0..<10 { f.sweep(from: CGPoint(x: 300 + CGFloat(k) * 20, y: CGFloat(top + 5)), to: CGPoint(x: 320 + CGFloat(k) * 20, y: CGFloat(top + 5)), dt: 1 / 60) }
    let si0 = f.surfaces.firstIndex { $0.id == 1 }!
    #expect(!f.debris.isEmpty || !f.puffs.isEmpty, "fast push throws powder")
    #expect(abs(total(f) - v0) < 0.02 * v0)
    for _ in 0..<60 { f.step(dt: 1 / 60) }   // 1 s: the walls slump
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    let h = f.surfaces[i].pile.heights
    var steep: Float = 0
    let mo = f.surfaces[i].pile.mound
    for b in 1..<h.count where min(h[b], h[b - 1]) >= Tuning.dustDepth && (mo.isEmpty || (mo[b] < 0.5 && mo[b - 1] < 0.5)) { steep = max(steep, abs(h[b] - h[b - 1])) }
    #expect(steep <= Tuning.ageSlope + 0.2, "wall step \(steep)")
    let c = scene(calm: true)
    c.sweep(from: CGPoint(x: 300, y: CGFloat(top + 5)), to: CGPoint(x: 400, y: CGFloat(top + 5)), dt: 1 / 60)
    #expect(c.debris.isEmpty && c.puffs.isEmpty)
}
