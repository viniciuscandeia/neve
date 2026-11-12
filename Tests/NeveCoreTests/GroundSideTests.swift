// AGENT HEADER - Tests/NeveCoreTests/GroundSideTests.swift  (the ground pile: wavy, and banked against a window's side)
// Covers buildGround (Surfaces.swift) and Resize: a window that stands on the ground columns
//   (bottom at the screen edge) acts as a wall for the neighbouring visible columns (`Pile.addWalls`: `walls`, `hideTop`, `boost`), as a window surface does. Related: DockCeilingTests (keep the bank ordering), Pile.addWalls.

import CoreGraphics
import Testing
@testable import NeveCore

private func ground(_ f: SnowField) -> Pile { f.pile(id: Tuning.groundID)! }

@Test func groundBanksAgainstAWindowSide() {
    let f = makeField()
    f.update(windows: [win(1, 400, 0, 300, 200)])   // stands on the screen bottom: hides ground columns 400...700, top 200
    let g = ground(f)
    #expect(g.hideTop.contains(200), "hideTop = the window's top over the hidden columns")
    #expect(g.walls.count == 2 && g.walls.contains(400) && g.walls.contains(700), "walls at both sides: \(g.walls)")
    let b = Int(380 / Tuning.binWidth)
    #expect(g.boost.count == g.heights.count && g.boost[b] > 0, "the limit rises toward the wall")
}
