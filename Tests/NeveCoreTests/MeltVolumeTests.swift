// AGENT HEADER - Tests/NeveCoreTests/MeltVolumeTests.swift  (melt / cornice / end spill / wind dust: volume conservation and the per-surface rules)
// Covers: the cornice (`Pile.eaveL/R`) sinks during a melt with the pile under it instead of hanging until it vanishes in one frame; each surface melts on its own schedule (a tall Dock bank / heap does not
//   make window piles vanish early); `spill` (Surfaces.swift) carries the spilled volume in the debris `vol` and keeps what addDebris refused; wind dust never moves snow into / out of a bin that is not `open`.

import CoreGraphics
import Testing
@testable import NeveCore

private func field() -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 200, seed: 7)
    f.update(windows: [win(1, 300, 400, 300, 150)])
    return f
}

private func vol(_ f: SnowField, id: Int) -> Float {
    let p = f.pile(id: id)!
    return p.heights.reduce(0, +) * Tuning.binWidth + p.eaveL + p.eaveR
}

@Test func corniceSinksDuringTheMeltInsteadOfHangingUntilTheEnd() {
    let f = field()
    pileUp(f, id: 1)
    let si = f.surfaces.firstIndex { $0.id == 1 }!
    f.surfaces[si].pile.eaveL = 10; f.surfaces[si].pile.eaveR = 10
    f.beginMelt(duration: 10)
    var last: Float = 20
    for k in 0..<300 {   // 5 s = half the run
        f.step(dt: 1 / 60)
        let e = f.surfaces[si].pile.eaveL
        #expect(e <= last + 1e-4); last = e
        _ = k
    }
    #expect(last < 10 && last > 0)
    advance(f, 5.2)
    #expect(f.pileVolume == 0)
}

@Test func windowPileMeltsOnItsOwnScheduleDespiteATallBank() {
    let f = field()
    pileUp(f, id: 1)
    let gi = f.surfaces.firstIndex { $0.id != 1 }!
    for b in 0..<min(30, f.surfaces[gi].pile.heights.count) { f.surfaces[gi].pile.heights[b] = 90 }
    let w0 = vol(f, id: 1)
    f.beginMelt(duration: 10)
    var last = w0
    for _ in 0..<300 { f.step(dt: 1 / 60); let v = vol(f, id: 1); #expect(v <= last + 1e-3); last = v }
    #expect(last > 0.3 * w0)   // halfway through: a global rate would have emptied it by ~10 %
    advance(f, 5.2)
    #expect(f.pileVolume == 0)
}

@Test func spillCarriesItsVolumeAndKeepsWhatWasRefused() {
    let f = field()
    let si = f.surfaces.firstIndex { $0.id == 1 }!
    f.surfaces[si].pile.spillL = 5; f.surfaces[si].pile.spillR = 3
    f.spill(si)
    #expect(f.surfaces[si].pile.spillL == 0 && f.surfaces[si].pile.spillR == 0)
    let carried = f.debris.reduce(0) { $0 + $1.vol }
    #expect(abs(carried - 8 * Tuning.binWidth) < 1e-3)
    f.debris.removeAll()
    for _ in 0..<Tuning.maxDebris { f.addDebris(x: 0, y: 0, vx: 0, fall: 0) }
    f.surfaces[si].pile.spillL = 5
    f.spill(si)
    #expect(f.surfaces[si].pile.spillL == 5)   // refused: stays owed
}

@Test func windDustLeavesBinsUnderAnotherWindowAlone() {
    let f = field()
    f.wind = 120
    let si = f.surfaces.firstIndex { $0.id == 1 }!
    let n = f.surfaces[si].pile.heights.count
    for b in 0..<n { f.surfaces[si].pile.heights[b] = 8 + Float(b % 5) }
    f.surfaces[si].pile.hideTop = [Float](repeating: 500, count: n)   // every bin visible but under a window body: not open
    let before = f.surfaces[si].pile.heights
    for _ in 0..<4000 { f.stepWindDust(dt: 1 / 30) }
    #expect(f.surfaces[si].pile.heights == before)
}
