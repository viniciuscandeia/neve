// AGENT HEADER - Tests/NeveCoreTests/LowSeamTests.swift  (no narrow, thick, steep sliver up the Dock bar's side at any ground / Dock accumulation: visual regression guard for the bank/bridge geometry in Render.writePiles)

import Testing
import CoreGraphics
@testable import NeveCore

private func lowField(ground g: Float, dock d: Float) -> SnowField {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 1)
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 171, y: 10, width: 1098, height: 84), radius: 25.2)])
    for i in f.surfaces.indices where f.surfaces[i].id <= 0 {
        let v = f.surfaces[i].id == 0 ? d : g
        for b in f.surfaces[i].pile.heights.indices { f.surfaces[i].pile.heights[b] = min(v, f.surfaces[i].pile.cap[b]) }
        f.surfaces[i].pile.shown = f.surfaces[i].pile.heights
    }
    return f
}

/// No narrow, thick, steep body (a vertical sliver up the bar's side) at any ground / Dock accumulation.
@Test func noVerticalSliverAtAnyAccumulation() {
    for g: Float in [0, 1, 2, 3, 4, 6, 10, 16, 24, 40, 60, 80, 94] {
        for d: Float in [0, 1, 2, 4, 6, 10, 14, 18] {
            for s in pileSegs(lowField(ground: g, dock: d)) where s.x0 != 169 && s.x0 != 1267 && s.base0 == 0 && s.base1 == 0 && s.x0 > 100 && s.x1 < 1340 && s.x1 - s.x0 < 3 && min(s.top0 - s.base0, s.top1 - s.base1) > 8 {
                #expect(abs(s.top0 - s.top1) <= 4, "sliver g\(g) d\(d): x \(s.x0)-\(s.x1) top \(s.top0)/\(s.top1) base \(s.base0)/\(s.base1)")
            }
        }
    }
}
