// AGENT HEADER - Tests/NeveCoreTests/GroundSideTests.swift  (the ground pile: wavy, and banked against a window's side)
// Covers buildGround (Surfaces.swift): the ground ceiling is wavy downward only (0.85...1 x groundMaxHeight, stable per column, none beside walls or within the Dock bank's reach), and a window that stands on the ground columns
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

@Test func groundLimitIsWavyDownwardOnlyAwayFromWallsAndTheDock() {
    let f = makeField()
    f.update(windows: [win(1, 400, 0, 300, 200)])   // a wall at 400 and 700, no Dock
    let g = f.pile(id: Tuning.groundID)!
    let cols = g.heights.indices.filter { g.boost[$0] == 0 && g.visible[$0] }
    let ls = cols.map { g.limit($0) }
    #expect(ls.max()! <= Tuning.groundMaxHeight + 1e-4, "never above groundMaxHeight")
    #expect(ls.min()! >= 0.85 * Tuning.groundMaxHeight - 1e-4 && ls.min()! < 0.95 * Tuning.groundMaxHeight, "varies down to ~85 %: \(ls.min()!)")
    f.update(windows: [win(1, 400, 0, 300, 200)])
    #expect(f.pile(id: Tuning.groundID)!.limit(cols[3]) == ls[3], "stable per column")
}
