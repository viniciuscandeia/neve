// AGENT HEADER - Tests/NeveCoreTests/DockSpillTests.swift  (DockSpill.swift: a full Dock-top pile near a bar end trickles to the ground bank; a low pile spills nothing)

import CoreGraphics
import Testing
@testable import NeveCore

private func field(seed: UInt64 = 5) -> SnowField {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 0, visibleTop: 880, flakeCount: 0, seed: seed)
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 500, y: 10, width: 400, height: 84), radius: 25)])
    return f
}
private func volume(_ f: SnowField) -> Float {
    var v: Float = 0
    for s in f.surfaces { for h in s.pile.heights { v += h } }
    for d in f.debris { v += d.size * Tuning.depositScale }
    return v + f.dockTrickle.vol.0 + f.dockTrickle.vol.1
}
private func bankNearLeftEnd(_ f: SnowField) -> Float {
    let p = f.surfaces[f.index[Tuning.groundID]!].pile
    var s: Float = 0
    for b in 0..<p.heights.count where binCenter(b) > 470 && binCenter(b) < 500 { s += p.heights[b] }
    return s
}

@Test func fullDockPileNearEndTricklesToBank() {
    for calm in [false, true] {
        let f = field(); f.setCalm(calm)
        let d = f.index[0]!
        for _ in 0..<60 { for b in 0..<10 { f.deposit(dock: d, bin: b, volume: 4) } }   // fill the left end until it rejects snow
        let bank0 = bankNearLeftEnd(f), vol0 = volume(f)
        for _ in 0..<60 { for b in 0..<10 { f.deposit(dock: d, bin: b, volume: 4) } }
        let vol1 = volume(f)
        advance(f, 40)
        #expect(bankNearLeftEnd(f) > bank0 + 5)
        #expect(volume(f) <= vol1 + 0.01)   // nothing is created (the bank clamps what it cannot hold, as for any landing)
        #expect(vol1 >= vol0 - 0.01)
    }
}

@Test func lowDockPileSpillsNothing() {
    let f = field()
    let d = f.index[0]!
    f.deposit(dock: d, bin: 100, volume: 4); f.deposit(dock: d, bin: 5, volume: 0.2)
    let bank0 = bankNearLeftEnd(f)
    advance(f, 10)
    #expect(bankNearLeftEnd(f) == bank0 && f.dockTrickle.vol.0 == 0 && f.dockTrickle.vol.1 == 0)
}
