import Foundation
import Testing
@testable import NeveCore

private func bare() -> Pile { Pile(columns: 200, inset: Tuning.cornerInset, c0: 0, x0: 0, x1: 400) }

/// First landings on a bare window stay local: a speck, not an instant wide film.
@Test func firstLandingsOnBareWindowStayLocalAndConserveVolume() {
    var p = bare()
    for _ in 0..<5 { p.deposit(bin: 100, volume: 5, powder: true) }
    #expect(p.heights.indices.filter { p.heights[$0] > 0 }.allSatisfy { abs($0 - 100) <= 10 })
    #expect(p.heights.reduce(0, +) < 25 && p.heights.reduce(0, +) > 5)   // bare powder only partly sticks (speckStick), nothing lost after that
    var q = bare()
    q.deposit(bin: 100, volume: 5, powder: true)
    #expect(q.heights.filter { $0 > 0 }.count == 1)   // a one-bin speck
}

/// Once the snow is deep enough the profile is the usual repose pile.
@Test func manyLandingsConvergeToTheSmoothPile() {
    var p = bare()
    var s: UInt64 = 7
    for _ in 0..<800 {   // 800: bare powder only partly sticks (speckStick), so the pile needs more landings than before
        s = s &* 6364136223846793005 &+ 1442695040888963407
        p.deposit(bin: 20 + Int(Float(s >> 40) / Float(1 << 24) * 160), volume: 4)
    }
    #expect(p.heights.max()! <= 18 + 1e-4)
    for b in 21..<179 where p.heights[b] > Tuning.dustDepth && p.heights[b + 1] > Tuning.dustDepth {
        #expect(abs(p.heights[b] - p.heights[b + 1]) <= Tuning.slope + 0.45)   // +0.45 (was 0.2): bins below speckFloor no longer relax, so the pile's foot is a little steeper
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

/// Slabs / clumps (debris with real volume) keep all their snow on a bare surface: only powder flakes partly melt on contact.
@Test func debrisOnBareSurfaceKeepsItsVolume() {
    var p = bare()
    p.deposit(bin: 100, volume: 5)
    #expect(abs(p.heights.reduce(0, +) - 5) < 1e-3)
}
