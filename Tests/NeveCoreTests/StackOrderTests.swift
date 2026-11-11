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
