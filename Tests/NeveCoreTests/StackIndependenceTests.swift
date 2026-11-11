// AGENT HEADER - Tests/NeveCoreTests/StackIndependenceTests.swift  (snow is ONE mass: the drawing never depends on the window stacking order)
// Four geometries (narrow higher window over a wide lower one at step 6 / 13 / 20, and a Finder-like partial overlap), grown snow, both stackings (higher in front / lower in front, switched through update = Cmd-Tab): writePiles output is
//   identical except the per-slice z (walls, banks, seams, the group contour derive from frames only); the drawn crest within 40 pt of a wall is bounded in slope (<= 2.2 pt per 2 pt); no drawn slice floats without snow
//   under / beside it (stored heights over its x-range +- the corner radius). Related: StackOrderTests (physics), WallBankTests, JunctionTests, Pile.addWalls, SurfaceMap.computeSeams, Contour.swift.

import CoreGraphics
import Testing
@testable import NeveCore

private let wide = win(1, 100, 200, 600, 200)   // top 400
private func geometries() -> [(name: String, high: WindowInfo, low: WindowInfo)] {
    [6, 13, 20].map { ("narrow +\($0)", win(2, 300, 400 + CGFloat($0) - 150, 200, 150), wide) }
        + [("partial +13", win(2, 600, 400 + 13 - 150, 300, 150), wide)]   // sticks out of the wide window's right end
}

private func grown(_ s: [WindowInfo]) -> SnowField {
    let f = makeField()
    f.update(windows: s)
    pileUp(f, id: 1, rounds: 60); pileUp(f, id: 2, rounds: 60)
    return f
}
private func same(_ a: PileSeg, _ b: PileSeg) -> Bool {
    [a.x0 - b.x0, a.x1 - b.x1, a.top0 - b.top0, a.top1 - b.top1, a.base0 - b.base0, a.base1 - b.base1, a.slope - b.slope, a.n0 - b.n0, a.n1 - b.n1, a.inset - b.inset, a.tint0 - b.tint0, a.tint1 - b.tint1].allSatisfy { abs($0) < 1e-4 } && a.dragged == b.dragged
}
/// Buffer order follows the window list; the picture does not: compare in x order.
private func sorted(_ s: [PileSeg]) -> [PileSeg] { s.sorted { ($0.x0, $0.x1, $0.top0, $0.base0, $0.z) < ($1.x0, $1.x1, $1.top0, $1.base0, $1.z) } }
private func crest(_ s: [PileSeg], _ x: Float) -> Float? {
    s.filter { $0.x0 <= x && x <= $0.x1 }.map { $0.top0 + ($0.top1 - $0.top0) * (x - $0.x0) / max($0.x1 - $0.x0, 1e-3) }.max()
}

@Test func drawingIsIdenticalForEveryStackingOrder() {
    for g in geometries() {
        let f = grown([g.high, g.low])
        let a = sorted(pileSegs(f))
        f.update(windows: [g.low, g.high])
        let b = sorted(pileSegs(f))
        #expect(a.count == b.count && a.count > 0, "\(g.name): \(a.count) vs \(b.count)")
        for (p, q) in zip(a, b) { #expect(same(p, q), "\(g.name): \(p) vs \(q)") }
        // The same physics-free picture when the snow is grown in the other order and switched the other way.
        let h = grown([g.low, g.high])
        let c = sorted(pileSegs(h))
        h.update(windows: [g.high, g.low])
        let d = sorted(pileSegs(h))
        #expect(c.count == d.count && zip(c, d).allSatisfy { same($0, $1) }, "\(g.name): reverse")
        // The seams are frames only.
        #expect(Set(f.seams.map { [$0.left, $0.right, $0.front] }) == Set(grown([g.high, g.low]).seams.map { [$0.left, $0.right, $0.front] }), "\(g.name): seams")
    }
}

@Test func crestBesideAWallNeverCutsVertically() {
    for g in geometries() {
        for order in [[g.high, g.low], [g.low, g.high]] {
            let f = grown(order), s = pileSegs(f)
            let h = g.high.frame
            for wall in [Float(h.minX), Float(h.maxX)] where wall > 100 && wall < 700 {
                var prev: Float?
                for x in stride(from: wall - 40, through: wall + 40, by: 2) {
                    guard let t = crest(s, x) else { continue }
                    if let q = prev { #expect(abs(t - q) <= 2.2, "\(g.name) wall \(wall): crest step \(t - q) at \(x)") }
                    prev = t
                }
            }
        }
    }
}

@Test func noDrawnSliceFloatsWithoutSnow() {
    for g in geometries() {
        for order in [[g.high, g.low], [g.low, g.high]] {
            let f = grown(order)
            for rounds in [60, 2] {
                if rounds == 2 { f.update(windows: order.map { $0.number == 1 ? win(1, 100, 200, 600, 200) : $0 }) ; for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices where b % 7 != 0 { f.surfaces[si].pile.heights[b] = 0; f.surfaces[si].pile.shown[b] = 0 } } }
                for s in pileSegs(f) {
                    let id = f.occluders[Int(s.z)].id, p = f.pile(id: id)!, c0 = p.c0, reach: Float = 40
                    var lo = max(0, Int((s.x0 - reach) / Tuning.binWidth) - c0), hi = min(p.heights.count - 1, Int((s.x1 + reach) / Tuning.binWidth) - c0)
                    while lo > 0, !p.hideTop.isEmpty, p.hideTop[lo] > 0 { lo -= 1 }; while hi < p.heights.count - 1, !p.hideTop.isEmpty, p.hideTop[hi] > 0 { hi += 1 }   // back snow merged over a window's span continues the snow beside it
                    if s.top1 - s.base1 < 0.3 && s.top0 - s.base0 < 0.3 { continue }
                    #expect(lo <= hi && p.heights[lo...hi].contains { $0 > 0.15 }, "\(g.name) rounds \(rounds): floating slice \(s)")
                }
            }
        }
    }
}
