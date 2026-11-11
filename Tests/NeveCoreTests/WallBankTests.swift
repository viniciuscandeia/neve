// AGENT HEADER - Tests/NeveCoreTests/WallBankTests.swift  (back window snow meets a narrower, HIGHER front window inside its span: no vertical cut)
// Back window 1 x 100...700 top 400; front window 2 x 300...500 centred, top 400 + step (6, 13, 20, 40, 100). Checks the back pile (Pile.addWalls banks it up the wall to the front top for step <= maxDrift, small capped ramp beyond),
//   the drawn back crest (Pile.fillet + Render.drawHeights through writePiles) has slope <= ~2pt per bin approaching each wall and into the front's corner cut-out (grown and young snow), and Occluder.hides covers every back slice
//   point inside the front outline. Related: DriftTests, JunctionTests, Render.writePiles, Occluder.

import CoreGraphics
import Testing
@testable import NeveCore

private func scene(step: CGFloat, rounds: Int = 60) -> SnowField {
    let f = makeField()
    f.update(windows: [win(2, 300, 400 + step - 150, 200, 150), win(1, 100, 200, 600, 200)])
    pileUp(f, id: 1, rounds: rounds)
    pileUp(f, id: 2, rounds: rounds)
    return f
}
/// Highest drawn top of the BACK window's slices (z 1; the front window is z 0) over x.
private func backTop(_ s: [PileSeg], _ x: Float) -> Float? {
    s.filter { $0.z == 1 && $0.x0 <= x && x <= $0.x1 }.map { $0.top0 + ($0.top1 - $0.top0) * (x - $0.x0) / max($0.x1 - $0.x0, 1e-3) }.max()
}
private let walls: [(wall: Float, dir: Float)] = [(300, -1), (500, 1)]   // x of each wall, and the side the back crest approaches it from (-1: from the left)

@Test func backSnowBanksUpToTheFrontTopAgainstBothWalls() {
    for step in [6, 13, 20] as [CGFloat] {   // <= maxDrift: the crest reaches the front top
        let p = scene(step: step).pile(id: 1)!
        let l = p.visible.firstIndex { !$0 }! - 1, r = p.visible.lastIndex { !$0 }! + 1
        #expect(p.heights[l] >= Float(step) - 0.6 && p.heights[r] >= Float(step) - 0.6, "step \(step): \(p.heights[l]) \(p.heights[r])")
    }
    for (step, want) in [(40, Tuning.maxDrift), (100, Tuning.maxPileHeight + Tuning.driftFarRamp)] as [(CGFloat, Float)] {   // beyond: capped
        let p = scene(step: step).pile(id: 1)!
        let l = p.visible.firstIndex { !$0 }! - 1, r = p.visible.lastIndex { !$0 }! + 1
        #expect(p.heights[l] <= want + 2 && p.heights[r] <= want + 2 && p.heights[l] >= want - 3, "step \(step): \(p.heights[l]) \(p.heights[r])")
    }
}

@Test func drawnBackCrestNeverCutsVerticallyAtTheWalls() {
    for step in [6, 13, 20, 40, 100] as [CGFloat] {
        for rounds in [60, 3] {   // grown and young snow
            let f = scene(step: step, rounds: rounds)
            let rad = f.occluders[0].radius, s = pileSegs(f)
            for (wall, dir) in walls {
                var prev: Float?
                for d in stride(from: Float(40), through: -(rad - 2), by: -2) {   // from 40 pt out to the wall, then into the corner cut-out
                    guard let t = backTop(s, wall + dir * d) else { if d > 0 { Issue.record("step \(step) rounds \(rounds): gap at \(wall + dir * d)") }; break }
                    if let q = prev { #expect(abs(t - q) <= 2.2, "step \(step) rounds \(rounds) wall \(wall): crest step \(t - q) at d=\(d)") }
                    prev = t
                }
            }
        }
    }
}

@Test func nothingOfTheBackPileShowsInsideTheFrontOutline() {
    var checked = 0
    for step in [6, 13, 20, 40, 100] as [CGFloat] {
        let f = scene(step: step, rounds: 3)
        let o = f.occluders[0], rad = o.radius
        for g in pileSegs(f) where g.z == 1 {
            for u in stride(from: Float(0), through: 1, by: 0.5) {
                let x = g.x0 + (g.x1 - g.x0) * u, top = g.top0 + (g.top1 - g.top0) * u, base = g.base0 + (g.base1 - g.base0) * u
                guard x > o.rect.x + 0.5, x < o.rect.z - 0.5 else { continue }   // between the front's sides: inside the outline below the corner arcs' start
                for y in stride(from: base, through: min(top, o.rect.w - rad - 0.5), by: 1) { #expect(o.hides(x: x, y: y), "step \(step): back snow visible at \(x),\(y)"); checked += 1 }
            }
        }
    }
    #expect(checked > 0)
}
