import CoreGraphics
import Testing
@testable import NeveCore

// Back window 1: x 100...400, top 400. A taller front window leaning on it: the back snow banks against its side.
private let back1 = win(1, 100, 200, 300, 200)
private func scene(front: WindowInfo?, rounds: Int = 40) -> SnowField {
    let f = makeField()
    f.update(windows: front.map { [$0, back1] } ?? [back1])
    pileUp(f, id: 1, rounds: rounds)
    if let front { pileUp(f, id: front.number, rounds: rounds) }
    return f
}
private func chain(_ f: SnowField) -> [PileSeg] {
    var buf = [PileSeg](repeating: PileSeg(x0: 0, x1: 0, top0: 0, top1: 0, base0: 0, base1: 0, slope: 0, dragged: 0), count: 4000)
    let n = buf.withUnsafeMutableBufferPointer { f.writePiles(to: $0.baseAddress!, capacity: 4000, dt: 10, force: true) } ?? 0
    return Array(buf[0..<n]).sorted { $0.x0 < $1.x0 }
}
/// x reached by segments joined end to start (no gap), beginning at the first one at or after `x`.
private func reach(_ s: [PileSeg], from x: Float) -> Float {
    guard var cur = s.first(where: { $0.x0 >= x - 0.01 }) else { return x }
    for q in s where q.x0 >= cur.x1 - 0.01 && q.x0 <= cur.x1 + 0.01 { cur = q }
    return cur.x1
}
private func wall(_ p: Pile) -> Int { p.visible.firstIndex { !$0 }! - 1 }   // last visible bin before the front window

@Test func driftReachesTheFrontTopAsOneContour() {
    let f = scene(front: win(2, 200, 300, 300, 110))   // step 10
    let p = f.pile(id: 1)!, w = wall(p)
    #expect(p.heights[w] >= 9.5)
    #expect(p.heights[w - 40] <= Tuning.maxPileHeight + 0.01)
    let s = chain(f)
    #expect(reach(s, from: s.map { $0.x0 }.min()!) > 480)   // back run, bridge, front run: unbroken to the front's right end
}

@Test func tallStepsCapTheDrift() {
    for (front, want) in [(win(2, 200, 300, 300, 160), Float(24)), (win(2, 200, 300, 300, 400), Tuning.maxPileHeight + 4)] {
        let f = scene(front: front)
        let p = f.pile(id: 1)!, w = wall(p)
        #expect(abs(p.heights[w] - want) < 0.6, "wall \(p.heights[w]) want \(want)")
        for b in (w - 20)...w { #expect(p.heights[b] - p.heights[b - 1] < 0.8) }   // smooth slope
        #expect(p.heights[w - 40] <= Tuning.maxPileHeight + 0.01)
    }
}

@Test func nothingIsLostAtTheWall() {
    let f = scene(front: win(2, 200, 300, 300, 160), rounds: 2)
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    let p0 = f.pile(id: 1)!, w = wall(p0)
    let before = p0.heights.reduce(0, +)
    for _ in 0..<30 { f.deposit(surface: i, bin: w, volume: 1) }
    let p1 = f.pile(id: 1)!
    #expect(p1.heights.reduce(0, +) > before)
    #expect(Array(p1.heights[(w + 1)...]) == Array(p0.heights[(w + 1)...]))   // hidden bins stay frozen
    #expect(p1.heights[w] >= p0.heights[w])
}

@Test func driftCollapsesWhenTheFrontWindowLeaves() {
    let f = scene(front: win(2, 200, 300, 300, 160))
    let p0 = f.pile(id: 1)!
    func ceil(_ b: Int) -> Float { Tuning.maxPileHeight * p0.wobble[b] }   // the wavy ceiling the drift sits on
    let excess = p0.heights.indices.map { max(p0.heights[$0] - ceil($0), 0) }.reduce(0, +)
    #expect(excess > 3)
    f.update(windows: [back1], dt: 0.5)
    f.debris.removeAll()
    for _ in 0..<60 { f.step(dt: 1.0 / 60) }   // 1 s: the ramp peels from the wall at 180pt/s
    #expect(f.pile(id: 1)!.heights.indices.allSatisfy { f.pile(id: 1)!.heights[$0] <= ceil($0) + 0.01 })
    #expect(f.peeledVolume > excess * 0.5 && f.peeledVolume <= excess * 1.05, "peeled \(f.peeledVolume) excess \(excess)")
}

@Test func sideBySideWindowsJoin() {
    let f = makeField()
    f.update(windows: [back1, win(2, 403, 200, 300, 202)])
    pileUp(f, id: 1, rounds: 40); pileUp(f, id: 2, rounds: 40)
    let p = f.pile(id: 1)!, q = f.pile(id: 2)!
    #expect(p.heights.last! > 10 && q.heights.first! > 10)   // no taper at the facing ends
    #expect(p.spillR == 0 && q.spillL == 0)
    let s = chain(f)
    #expect(reach(s, from: s.map { $0.x0 }.min()!) > 680)
}

@Test func windowsWithoutALinkStillTaper() {
    let f = makeField()
    f.update(windows: [back1, win(2, 450, 200, 300, 200)])   // 50pt apart
    pileUp(f, id: 1, rounds: 40)
    #expect(f.pile(id: 1)!.heights.last! < 3)
}

// The bank beside the Dock and the strip under it meet at the Dock bar ends: no gap in the ground contour there.
@Test func groundContourHasNoGapAtDockBarEnds() {
    let f = makeField()
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 400, y: 10, width: 200, height: 70), radius: 18)])
    pileUp(f, id: Tuning.groundID)
    let s = chain(f).filter { $0.base0 < 1 }
    for edge: Float in [400, 600] {
        let left = s.filter { $0.x1 <= edge + 2 }.map { $0.x1 }.max()!, right = s.filter { $0.x0 >= edge - 2 }.map { $0.x0 }.min()!
        #expect(right - left < 0.01, "gap \(left)...\(right) at \(edge)")
    }
}

// A drift meeting a front window whose own pile is taller bridges to its top with a gentle ramp, not a cliff.
@Test func driftRisesToTheFrontPileWithoutACliff() {
    let f = scene(front: win(2, 200, 300, 300, 110))
    f.surfaces[f.surfaces.firstIndex { $0.id == 2 }!].pile.heights.indices.forEach { f.surfaces[f.surfaces.firstIndex { $0.id == 2 }!].pile.heights[$0] = 14 }
    f.pileVersion += 1
    let s = chain(f).filter { $0.x0 > 150 && $0.x1 < 260 }   // around the seam at x = 200
    #expect(!s.isEmpty && s.allSatisfy { abs($0.slope) < 1.0 }, "steepest \(s.map { abs($0.slope) }.max()!)")
}
