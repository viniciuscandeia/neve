// AGENT HEADER - Tests/NeveCoreTests/SnowAgeTests.swift  (lot 8: snow age / compaction, Pile.age + Pile.reposeStep)
// An old pile holds a steeper face than a fresh one (the repose step rises with age, mound still wins when larger); fresh snowfall on old snow lowers the age locally; age rises with time (capped) and only on snow;
//   it is carried by a Space switch, a moving window and reset by clear().
// Related: Pile.transfer / reposeStep / mixAge / ageStep, Surfaces.buildSurface carry, SnowField.stashAway.

import CoreGraphics
import Testing
@testable import NeveCore

@Test func reposeStepRisesWithAgeAndMoundStillWinsWhenLarger() {
    #expect(Pile.reposeStep(age: 0) == Tuning.slope)
    #expect(Pile.reposeStep(age: Tuning.ageFull * 10) == Tuning.ageSlope)
    #expect(Pile.reposeStep(age: Tuning.ageFull / 2) > Tuning.slope)
    #expect(Pile.reposeStep(age: Tuning.ageFull, heap: true) == Tuning.slope + Tuning.moundSlope)
}

@Test func anOldPileHoldsASteeperFaceThanAFreshOne() {
    func face(age: Float) -> Float {
        var p = Pile(columns: 60, inset: 0, c0: 0, x0: -1e4, x1: 1e4)
        for b in 0..<60 { p.heights[b] = b >= 20 && b < 40 ? 28 : 8; p.age[b] = age }   // a plateau on a bed deeper than dustDepth
        for _ in 0..<300 { for i in 0..<60 { _ = p.relax(i, i - 1); _ = p.relax(i, i + 1) } }
        return (1..<60).map { abs(p.heights[$0] - p.heights[$0 - 1]) }.max()!   // the steepest step the face settled to
    }
    let fresh = face(age: 0), old = face(age: Tuning.ageFull)
    #expect(old > fresh * 1.25, "old \(old) fresh \(fresh)")
}

@Test func freshSnowfallOnOldSnowLowersTheAgeLocally() {
    var p = Pile(columns: 60, inset: 0, c0: 0, x0: -1e4, x1: 1e4)
    p.maxHeight = 60
    for b in 0..<60 { p.heights[b] = 10; p.age[b] = Tuning.ageFull }
    p.deposit(bin: 30, volume: 4)
    #expect(p.age[30] < Tuning.ageFull * 0.9)
    #expect(p.age[5] == Tuning.ageFull)   // far away untouched
}

@Test func ageRisesOnSnowOnlyAndIsCapped() {
    var p = Pile(columns: 4, inset: 0)
    p.heights[1] = 5
    p.ageStep(100); #expect(p.age[1] == 100 && p.age[0] == 0)
    p.ageStep(Tuning.ageFull); #expect(p.age[1] == Tuning.ageFull)
    p.heights[1] = 0; p.ageStep(1); #expect(p.age[1] == 0)
}

@Test func ageTravelsWithTheSnow() {
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    var i = f.surfaces.firstIndex { $0.id == 1 }!
    for b in 40..<60 { f.surfaces[i].pile.heights[b] = 3; f.surfaces[i].pile.age[b] = 321 }
    let a = f.surfaces[i].pile.age
    f.dropPiles(); f.markStale()   // Space switch
    f.update(windows: [], now: 1)
    f.update(windows: [win(1, 300, 300, 400, 200)], now: 2)
    i = f.surfaces.firstIndex { $0.id == 1 }!
    #expect(f.surfaces[i].pile.age == a)
    f.update(windows: [win(1, 320, 300, 400, 200)], dt: 1)   // moved 10 columns
    i = f.surfaces.firstIndex { $0.id == 1 }!
    #expect(f.surfaces[i].pile.age[50] == 321)
    f.clear()
    #expect(f.surfaces.allSatisfy { $0.pile.age.allSatisfy { $0 == 0 } })
}
