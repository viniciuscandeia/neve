// AGENT HEADER - Tests/NeveCoreTests/PileDepositGoldenTests.swift
// Pins Pile.deposit's output (heights + spill) for a seeded sequence of deposits (powder and flakes, one pushed heap): the relax loop stops early on a pass that moves nothing, which must not change any result.
// Hash re-pinned when Tuning.speckStick went 0.04 -> 0.2 (first snow sooner): bare-bin powder now sticks 5x more, so heights differ; deposit rules otherwise unchanged.
// Related: Pile.swift (deposit, relax).

import Foundation
import Testing
@testable import NeveCore

@Test func depositGoldenSeeded() {
    var p = Pile(columns: 200, inset: Tuning.cornerInset, c0: 0, x0: 0, x1: 400)
    p.trackMound(0)
    var s: UInt64 = 12345
    func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
    for k in 0..<20000 {
        let bin = Int(next() % 200), v = Float(next() % 100) / 25
        if k == 3000 { p.heights[100] += 30; p.trackMound(100) }
        _ = p.deposit(bin: bin, volume: v, powder: next() % 3 == 0)
    }
    var h: UInt64 = 1469598103934665603
    for x in p.heights + [p.spillL, p.spillR] { h = (h ^ UInt64(x.bitPattern)) &* 1099511628211 }
    #expect(h == 1534246845177366256)
}
