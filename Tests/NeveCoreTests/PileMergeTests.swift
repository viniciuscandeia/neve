import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

private func dock() -> WindowInfo { WindowInfo(number: 0, frame: CGRect(x: 300, y: 10, width: 400, height: 84), radius: 25.2) }

private func field(_ g: Int, _ d: Int, _ w: Int) -> SnowField {
    let f = makeField()
    f.update(windows: [dock(), win(1, 100, 300, 250, 120), win(2, 330, 380, 200, 120), win(3, 800, 250, 150, 100), win(4, 553, 380, 150, 90)])
    pileUp(f, id: Tuning.groundID, rounds: g); pileUp(f, id: 0, rounds: d)
    for id in 1...4 { pileUp(f, id: id, rounds: w) }
    return f
}

private func merged(_ f: SnowField) -> (before: [PileSeg], after: [PileSeg]) {
    let cap = 1 << 14
    let p = UnsafeMutablePointer<PileSeg>.allocate(capacity: cap)
    defer { p.deallocate() }
    let n = f.writePiles(to: p, capacity: cap, dt: 10, force: true)!
    let before = Array(UnsafeBufferPointer(start: p, count: n))
    let m = mergePileSegs(p, count: n)
    return (before, Array(UnsafeBufferPointer(start: p, count: m)))
}

/// Some slice of `s` covers `x` at the same top and base (within 0.16): surfaces overlap in x, so any covering slice may match.
private func covered(_ s: [PileSeg], x: Float, top: Float, base: Float) -> Bool {
    s.contains { g in
        guard x >= g.x0 - 1e-4, x <= g.x1 + 1e-4 else { return false }
        let u = (x - g.x0) / max(g.x1 - g.x0, 1e-3)
        return abs(g.top0 + (g.top1 - g.top0) * u - top) <= 0.16 && abs(g.base0 + (g.base1 - g.base0) * u - base) <= 0.16
    }
}

@Test func mergeCutsSegmentsAndKeepsTheDrawnContour() {
    for (g, d, w) in [(12, 12, 12), (2, 1, 1), (12, 3, 0), (0, 0, 6)] {
        let (a, b) = merged(field(g, d, w))
        FileHandle.standardError.write(Data("merge counts g\(g) d\(d) w\(w): \(a.count) -> \(b.count)\n".utf8))
        #expect(b.count <= a.count)
        for s in a {   // every original slice end and midpoint: contour within the tolerance
            for x in [s.x0 + 0.01, (s.x0 + s.x1) / 2, s.x1 - 0.01] where s.x1 - s.x0 > 0.05 {
                let u = (x - s.x0) / (s.x1 - s.x0)
                #expect(covered(b, x: x, top: s.top0 + (s.top1 - s.top0) * u, base: s.base0 + (s.base1 - s.base0) * u))
            }
        }
    }
    let (a, b) = merged(field(12, 12, 12))
    #expect(b.count < a.count)
}

@Test func mergeDropsOverlapOnlyBetweenCollinearNeighbours() {
    let flat = (0..<10).map { PileSeg(x0: Float($0) * 2, x1: Float($0) * 2 + 2, top0: 50, top1: 50, base0: 40, base1: 40, slope: 0, dragged: 0, n0: 0, n1: 0) }
    var buf = flat
    #expect(buf.withUnsafeMutableBufferPointer { mergePileSegs($0.baseAddress!, count: 10) } == 1)
    // A rise then a flat: the join keeps its overlap and stays two segments.
    var kink = [PileSeg(x0: 0, x1: 2, top0: 50, top1: 52, base0: 40, base1: 40, slope: 1, dragged: 0, n0: 1, n1: 1),
                PileSeg(x0: 2, x1: 4, top0: 52, top1: 52, base0: 40, base1: 40, slope: 0, dragged: 0, n0: 0, n1: 0)]
    let n = kink.withUnsafeMutableBufferPointer { mergePileSegs($0.baseAddress!, count: 2) }
    #expect(n == 2 && kink[0].dragged & 8 == 0 && kink[1].dragged & 4 == 0)
    // Same slope but split by a dragged flag: not merged.
    var drag = [flat[0], { var s = flat[1]; s.dragged = 1; return s }()]
    #expect(drag.withUnsafeMutableBufferPointer { mergePileSegs($0.baseAddress!, count: 2) } == 2)
}
