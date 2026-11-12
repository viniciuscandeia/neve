// AGENT HEADER - Tests/NeveCoreTests/OverflowTests.swift  (a full window overflows through its ends; a snowman burst keeps its volume)
// A landing a full pile cannot keep (softness, `limit`, a ceiling) is owed (`Pile.owedL/R`) to the nearest unsupported end and drips off as lumps (SnowField.stepOverflow, every 0.5 s: drops, not rain), conserved;
// a burst's carried volume (sum of ball discs x Tuning.burstVolume) is all accounted for (landed + still owed + airborne) on a FULL window, where it used to vanish in the middle bins.
// Related: Pile.swift (deposit / owe), Surfaces.swift (stepOverflow), Figures.swift (shatter), Flakes.swift (tryLand).

import CoreGraphics
import Testing
@testable import NeveCore

private func fullWindowField() -> (SnowField, Int) {
    let f = makeField()
    f.update(windows: [win(1, 200, 400, 700, 150)])
    let i = f.index[1]!
    for b in f.surfaces[i].pile.heights.indices { f.surfaces[i].pile.heights[b] = f.surfaces[i].pile.limit(b) }
    f.surfaces[i].pile.peel = []
    return (f, i)
}

private func totalArea(_ f: SnowField) -> Float {   // pt^2 on every surface, plus what is owed / spilled / hanging as cornice
    f.surfaces.reduce(0) { $0 + ($1.pile.heights.reduce(0, +) + $1.pile.spillL + $1.pile.spillR + $1.pile.owedL + $1.pile.owedR) * Tuning.binWidth + $1.pile.eaveL + $1.pile.eaveR }
}

/// The middle of a full pile used to swallow what it could not keep; now it is owed to the nearest end, to the last bit.
@Test func fullPileOwesWhatItCannotKeepToTheNearestEnd() {
    let (f, i) = fullWindowField()
    let h0 = f.surfaces[i].pile.heights.reduce(0, +)
    f.deposit(surface: i, bin: 40, volume: 50)
    let p = f.surfaces[i].pile
    #expect(abs(p.heights.reduce(0, +) - h0) < 1e-3)
    #expect(abs(p.owedL - 50) < 1e-3 && p.owedR == 0)
    f.deposit(surface: i, bin: 300, volume: 20)
    #expect(abs(f.surfaces[i].pile.owedR - 20) < 1e-3)
}

/// Owed snow leaves as lumps (>= 6 units, each carrying its volume), never as a stream, and none of it is lost.
@Test func owedSnowDripsOffTheEndAsConservedLumps() {
    let (f, i) = fullWindowField()
    f.deposit(surface: i, bin: 40, volume: 100)
    f.stepOverflow(); f.stepOverflow()
    #expect(f.debris.isEmpty)   // one drip per 1.5 s, not per tick
    f.stepOverflow()
    #expect(f.debris.count == 1)
    #expect(abs(f.debris[0].vol / Tuning.binWidth + f.surfaces[i].pile.owedL - 100) < 1e-3)
    for _ in 0..<200 { f.stepOverflow() }
    #expect(f.surfaces[i].pile.owedL < SnowField.overflowMin)
    #expect(abs(f.debris.reduce(0) { $0 + $1.vol } / Tuning.binWidth + f.surfaces[i].pile.owedL - 100) < 1e-2)
}

/// A snowman burst on a full window: its carried volume (sum pi r^2 x 1.25) is landed + owed + airborne + what the ground heap ceiling refused (`bankRefused`) within 2 % (it was ~4 % of it: the middle bins threw it away).
@Test func burstOnAFullWindowKeepsItsVolume() {
    let (f, i) = fullWindowField()
    _ = i
    let id = standAuto(f, x: 500, on: 1)
    let a0 = totalArea(f)
    f.shatter(id, velocity: .zero, burst: true)
    let carried = f.debris.reduce(0) { $0 + $1.vol }
    #expect(carried > 2000)
    advance(f, 25, fps: 60)
    let accounted = totalArea(f) - a0 + f.bankRefused + f.debris.reduce(0) { $0 + $1.vol }
    #expect(accounted >= carried * 0.98)   // a lower bound: impact crumbs (vol 0) add a little snow of their own
}

/// The same burst on the ground keeps its volume too (nothing is lost on the way down either).
@Test func burstOnTheGroundKeepsItsVolume() {
    let f = makeField()
    f.update(windows: [])
    let id = standAuto(f, x: 500)
    let a0 = totalArea(f)
    f.shatter(id, velocity: .zero, burst: true)
    let carried = f.debris.reduce(0) { $0 + $1.vol }
    advance(f, 10, fps: 60)
    #expect(totalArea(f) - a0 + f.bankRefused + f.debris.reduce(0) { $0 + $1.vol } >= carried * 0.98)
}
