// AGENT HEADER - Tests/NeveCoreTests/StackOrderTests.swift  (Cmd-Tab: same windows, other stacking order)
// Two overlapping windows (front higher / lower, narrower / wider) with grown snow, a bank against the higher front window and a cursor heap. update(windows:) with reversed arrays 10 times: every pile's heights / mound arrays stay
//   identical (+-1e-4), no debris spawns, no peel is pending, and after toggling back the drawn piles (writePiles) equal the start. Snowfall in the other order must not grow snow past the old limits. Related: Surfaces.updateSurfaces `orderOnly`, Pile.hold.

import CoreGraphics
import Testing
@testable import NeveCore

private func snap(_ f: SnowField) -> [Int: ([Float], [Float])] { Dictionary(uniqueKeysWithValues: f.surfaces.map { ($0.id, ($0.pile.heights, $0.pile.mound)) }) }

@Test(arguments: [(450.0, 700.0), (330.0, 700.0), (450.0, 200.0), (330.0, 200.0)] as [(Double, Double)])
func togglingTheStackingOrderNeverChangesTheSnow(top: Double, frontW: Double) {
    let a = win(1, 100, 200, 600, 200)                                  // wide, top 400
    let b = win(2, 300, CGFloat(top) - 150, CGFloat(frontW), 150)   // overlapping, top `top` (higher or lower than 400)
    let f = makeField()
    f.update(windows: [b, a])
    pileUp(f, id: 1, rounds: 60); pileUp(f, id: 2, rounds: 60)
    f.sweep(from: CGPoint(x: 150, y: 402), to: CGPoint(x: 250, y: 402), dt: 1.0 / 60)   // a cursor heap on the back window's top
    f.sweep(from: CGPoint(x: 250, y: 402), to: CGPoint(x: 150, y: 402), dt: 1.0 / 60)
    let start = snap(f), startSegs = pileSegs(f), d0 = f.debris.count
    for i in 1...10 {
        f.update(windows: i % 2 == 1 ? [a, b] : [b, a])
        let now = snap(f)
        for (id, s) in start {
            let n = now[id]!
            #expect(zip(s.0, n.0).allSatisfy { abs($0 - $1) < 1e-4 }, "heights \(id) toggle \(i)")
            #expect(s.1.count == n.1.count && zip(s.1, n.1).allSatisfy { abs($0 - $1) < 1e-4 }, "mound \(id) toggle \(i)")
        }
        #expect(f.debris.count == d0 && f.surfaces.allSatisfy { !$0.pile.peeling }, "toggle \(i)")
    }
    let end = pileSegs(f)
    #expect(end.count == startSegs.count)
    #expect(zip(end, startSegs).allSatisfy { abs($0.top0 - $1.top0) < 1e-4 && abs($0.top1 - $1.top1) < 1e-4 && $0.z == $1.z && abs($0.x0 - $1.x0) < 1e-4 })
}

@Test func snowfallInTheOtherOrderKeepsOldSnowButDoesNotGrowPastLimits() {
    let f = makeField()
    f.update(windows: [win(2, 300, 300, 200, 150), win(1, 100, 200, 600, 200)])
    pileUp(f, id: 1, rounds: 60)
    let h0 = f.pile(id: 1)!.heights
    f.update(windows: [win(1, 100, 200, 600, 200), win(2, 300, 300, 200, 150)])
    let p = f.pile(id: 1)!
    for b in p.heights.indices where p.visible[b] { #expect(p.heights[b] >= h0[b] - 1e-4) }
    pileUp(f, id: 1, rounds: 20)
    let q = f.pile(id: 1)!
    for b in q.heights.indices where q.visible[b] { #expect(q.heights[b] <= max(h0[b], q.rawLimit(b)) + 0.5) }
}

private func volume(_ f: SnowField) -> Float { f.surfaces.reduce(0) { $0 + $1.pile.heights.reduce(0, +) + ($1.pile.eaveL + $1.pile.eaveR) / Tuning.binWidth } }   // heights + cornices (snow that crept off the end bins over the ~10 s of the test)

@Test func manyOrderSwapsLeaveSnowBallsGiftsSnowmanAndFrostUntouched() {
    let a = win(1, 100, 200, 600, 200), b = win(2, 150, 300, 200, 150)   // b (top 450) covers part of a's top (400) when in front
    let f = makeField()
    f.update(windows: [a, b])
    pileUp(f, id: 1, rounds: 60); pileUp(f, id: 2, rounds: 60)
    let fid = stand(f, x: 250, on: 1)
    let bid = stackBalls(f, x: 220, on: 1, radii: [10])
    f.giftState.gifts.append(Gift(pos: SIMD2(260, 420), vel: .zero, surface: 1, rot: 0, spin: 0, color: 0, scale: 1))
    advance(f, 1)
    let v0 = volume(f), fill = f.fillRatio(si: f.index[1]!), nb = f.balls.count, d0 = f.debris.count
    for i in 0..<100 {
        f.update(windows: i % 2 == 0 ? [b, a] : [a, b])
        advance(f, 0.1)
        #expect(f.surfaces.allSatisfy { !$0.pile.peeling })
    }
    f.update(windows: [b, a]); advance(f, 0.1)   // ends with b in front: a's top under b is covered
    #expect(abs(volume(f) - v0) < 1e-2 && f.debris.count == d0)
    #expect(fig(f, fid).surfaceID == 1 && fig(f, fid).foot.x > 100 && fig(f, fid).foot.x < 700)
    #expect(f.balls.count == nb && ball(f, bid).surfaceID == 1)
    #expect(f.gifts.count == 1 && f.gifts[0].surface == 1)
    #expect(abs(f.fillRatio(si: f.index[1]!) - fill) < 2e-3)   // order swaps change nothing; only the cornice feed (0.5 s steps, time-driven) moves < 0.1 % of the fill off the end bins
}

@Test func aWindowMissingForOnePollKeepsItsPile() {
    let a = win(1, 100, 200, 600, 200), b = win(2, 150, 500, 200, 100)
    let f = makeField()
    f.goneGrace = Tuning.goneGrace
    f.update(windows: [a, b]); pileUp(f, id: 1, rounds: 60)
    let h0 = f.pile(id: 1)!.heights, d0 = f.debris.count
    f.update(windows: [b], dt: 0.1)
    #expect(f.debris.count == d0)
    f.update(windows: [a, b], dt: 0.1)
    #expect(f.pile(id: 1)!.heights == h0 && f.debris.count == d0)
    f.update(windows: [b], dt: 0.1)   // really gone: knocked off after the grace
    _ = f.update(windows: [b, win(3, 800, 100, 50, 50)], dt: Float(Tuning.goneGrace) + 0.1)
    #expect(f.pile(id: 1) == nil && f.debris.count > d0)
}
