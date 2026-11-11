// AGENT HEADER - Tests/NeveCoreTests/SliceZTests.swift  (back-window snow is never drawn over a front window's body)
// A narrower window F and a wider window B with a similar top (steps -6...13 pt), both stackings, young and grown snow. Every drawn slice carries the z of the window whose top edge its snow rests on (junction-merged slices and seam bridges of
//   back snow keep the BACK window's z), so the front window's Occluder clips what lies inside its body: a slice with F's own z never has a point inside F's outline (below its top edge). Regression: phase 2 drew merged back snow with the
//   front window's z (a white comb over the front window's top band). Related: WallBankTests, JunctionTests, Render.junctions.

import CoreGraphics
import Testing
@testable import NeveCore

@Test func backSnowNeverCarriesTheFrontWindowZInsideItsBody() {
    var checked = 0
    for d in [-6, -2, 0, 1, 3, 6, 13] as [CGFloat] {
        for order in [[2, 1], [1, 2]] {
            for rounds in [3, 60] {
                let f = makeField()
                let wins = [2: win(2, 300, 400 + d - 150, 200, 150), 1: win(1, 100, 200, 600, 200)]
                f.update(windows: order.map { wins[$0]! })
                pileUp(f, id: 1, rounds: rounds); pileUp(f, id: 2, rounds: rounds)
                let zF = f.zOf[2]!, o = f.occluders[Int(zF)]
                for g in pileSegs(f) where g.z == zF {
                    for u in stride(from: Float(0), through: 1, by: 0.25) {
                        let x = g.x0 + (g.x1 - g.x0) * u, top = g.top0 + (g.top1 - g.top0) * u, base = g.base0 + (g.base1 - g.base0) * u
                        for y in stride(from: base + 1.2, through: top, by: 1) {
                            checked += 1
                            if [(0, 0), (2, 0), (-2, 0), (0, -2)].allSatisfy({ o.hides(x: x + Float($0.0), y: y + Float($0.1)) }) { Issue.record("d \(d) order \(order) rounds \(rounds): z-front slice inside the window at \(x),\(y)") }   // deep inside the outline (not on the corner arc)
                        }
                    }
                }
            }
        }
    }
    #expect(checked > 0)
}
