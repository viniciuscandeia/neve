// AGENT HEADER - Tests/NeveCoreTests/FixedStepTests.swift
// Lot 6 timing: `substeps` (fixed 1/60 s, at most 2 a frame; stepSeams and the Dock bank relax use it) and stepSlump dropping a flat mound back to [].
// Related: Seams.swift, DockPush.swift, Surfaces.swift (stepSlump).

import CoreGraphics
import Testing
@testable import NeveCore

@Test func substepsAreByTimeAndCapped() {
    let f = SnowField(size: CGSize(width: 800, height: 600), origin: .zero, groundY: 50, visibleTop: 580, flakeCount: 0, seed: 1)
    var c: Float = 0
    #expect(f.substeps(&c, dt: 1.0 / 60) == 1)
    #expect(f.substeps(&c, dt: 1.0 / 30) == 2)
    #expect(f.substeps(&c, dt: 1.0 / 120) == 0)   // half a substep owed
    #expect(f.substeps(&c, dt: 1.0 / 120) == 1)
    #expect(f.substeps(&c, dt: 1) == 2)           // a long frame never owes more than 2
}

@Test func flatMoundIsDropped() {
    let f = SnowField(size: CGSize(width: 800, height: 600), origin: .zero, groundY: 50, visibleTop: 580, flakeCount: 0, seed: 1)
    let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    let n = f.surfaces[i].pile.heights.count
    f.surfaces[i].pile.mound = [Float](repeating: 0.3, count: n)
    f.time = 10; f.sweptAt = 0
    f.stepSlump(dt: 1.0 / 60)
    #expect(f.surfaces[i].pile.mound.isEmpty)
}
