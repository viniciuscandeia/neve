// AGENT HEADER - Tests/NeveCoreTests/OcclusionTests.swift  (piles are hidden by every window in front of their own: SnowField.occluders + PileSeg.z)
// A wide Finder-like window in front of a narrower, higher one: the back pile's slices carry a z behind the front window's, so the GPU clip (`Occluder.hides`, mirrored by the pile shader) covers its corner arcs
//   inside the front rect; the front pile (z 0) is never clipped; after a command-tab style reorder the z's swap on the next update. Related: Render.swift (Occluder, writePiles z), Surfaces.swift, PileShader.swift.

import CoreGraphics
import Testing
@testable import NeveCore

@Test func backPileSlicesAreOccludedInsideTheFrontWindow() {
    let f = makeField()
    let front = win(2, 100, 250, 500, 150), back = win(1, 200, 200, 250, 215)   // front x 100...600 top 400; back x 200...450 top 415, rounded top corners reach below 400
    f.update(windows: [front, back])
    pileUp(f, id: 1, rounds: 40); pileUp(f, id: 2, rounds: 40)
    #expect(f.occluders.count == 2 && f.occluders[0].id == 2)
    let segs = pileSegs(f)
    #expect(Set(segs.map(\.z)).isSuperset(of: [0, 1]))
    let o = f.occluders[0]
    // Every slice of the back pile (z 1) that dips into the front rect is hidden there; front slices (z 0) have no occluder in front.
    var inside = 0
    for s in segs where s.z == 1 {
        for (x, y) in [(s.x0, s.base0), (s.x1, s.base1), ((s.x0 + s.x1) / 2, (s.base0 + s.base1) / 2 - 1)] where o.hides(x: x, y: y) { inside += 1 }
    }
    #expect(inside > 0, "back slices reach into the front window")
    for s in segs where s.z == 0 { #expect(!f.occluders[0..<Int(s.z)].contains { $0.hides(x: s.x0, y: s.top0) }) }
    #expect(o.hides(x: 300, y: 380) && !o.hides(x: 300, y: 405) && !o.hides(x: 101, y: 399))   // inside / above the top edge / the rounded corner is cut away
}

@Test func reorderingWindowsSwapsTheSliceZ() {
    let f = makeField()
    f.update(windows: [win(2, 100, 250, 500, 150), win(1, 200, 200, 250, 215)])
    pileUp(f, id: 1, rounds: 20)
    #expect(Set(pileSegs(f).map(\.z)).contains(1))
    f.update(windows: [win(1, 200, 200, 250, 215), win(2, 100, 250, 500, 150)])   // command-tab: window 1 comes to the front
    let z = Set(pileSegs(f).map(\.z))
    #expect(f.occluders[0].id == 1 && z.contains(0) && !z.contains(1))
}
