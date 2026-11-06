import Foundation
import Testing
@testable import NeveCore

private func bare() -> Pile { Pile(columns: 200, inset: Tuning.cornerInset, c0: 0, x0: 0, x1: 400) }

/// First landings on a bare window stay local: a speck, not an instant wide film.
@Test func firstLandingsOnBareWindowStayLocalAndConserveVolume() {
    var p = bare()
    for _ in 0..<5 { p.deposit(bin: 100, volume: 5) }
    #expect(p.heights.indices.filter { p.heights[$0] > 0 }.allSatisfy { abs($0 - 100) <= 10 })
    #expect(abs(p.heights.reduce(0, +) - 25) < 1e-3)
    var q = bare()
    q.deposit(bin: 100, volume: 5)
    #expect(q.heights.filter { $0 > 0 }.count <= 5)   // 7 bins before the dust step
}

/// Once the snow is deep enough the profile is the usual repose pile.
@Test func manyLandingsConvergeToTheSmoothPile() {
    var p = bare()
    var s: UInt64 = 7
    for _ in 0..<400 {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        p.deposit(bin: 20 + Int(Float(s >> 40) / Float(1 << 24) * 160), volume: 4)
    }
    #expect(p.heights.max()! <= 18 + 1e-4)
    for b in 21..<179 where p.heights[b] > Tuning.dustDepth && p.heights[b + 1] > Tuning.dustDepth {
        #expect(abs(p.heights[b] - p.heights[b + 1]) <= Tuning.slope + 0.2)
    }
    #expect(p.heights[20..<180].reduce(0, +) / 160 > 9)   // mean height as before (~11)
}

/// One speck on a bare window: a handful of segments around it, not a line across the window.
@Test func bareWindowWithOneSpeckEmitsFewSegments() {
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    f.deposit(surface: i, bin: 100, volume: 5)
    var buf = [PileSeg](repeating: PileSeg(x0: 0, x1: 0, top0: 0, top1: 0, base0: 0, base1: 0, slope: 0, dragged: 0), count: 4096)
    let n = buf.withUnsafeMutableBufferPointer { f.writePiles(to: $0.baseAddress!, capacity: 4096, dt: 10, force: true) } ?? 0
    #expect(n > 0 && n < 12)
}
