// AGENT HEADER - Tests/NeveCoreTests/DockCeilingTests.swift  (a near-fullscreen window roofs the floating Dock bar)
// Setup: 1440x900, bar (171,10,1098,84) top 94, a full-width window whose bottom is 2 pt above the bar top (less than Tuning.minRoom: the Dock pile cannot exist). Snow piles up; the upper envelope
// of the emitted contour must have no vertical step > 2 pt (the bank used to stay a shelf flush with the Dock top and ended in a cliff at the bar's corner). See DockPush.bankTop.

import CoreGraphics
import Testing
@testable import NeveCore

@Test func roofedDockBarLeavesNoCliffInTheBankContour() {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 1)
    let ws = [WindowInfo(number: 7, frame: CGRect(x: 0, y: 96, width: 1440, height: 760), radius: 10),
              WindowInfo(number: 0, frame: CGRect(x: 171, y: 10, width: 1098, height: 84), radius: 25.2)]
    f.update(windows: ws)
    fillBankLevel(f)
    for i in f.surfaces.indices where f.surfaces[i].id <= 0 { for _ in 0..<150 { for b in f.surfaces[i].pile.heights.indices { f.deposit(surface: i, bin: b, volume: 4) } } }
    f.update(windows: ws)
    let segs = pileSegs(f)
    func env(_ x: Float) -> Float? { var m: Float?; for g in segs where x >= g.x0 && x <= g.x1 { let y = g.top0 + (g.top1 - g.top0) * (x - g.x0) / max(g.x1 - g.x0, 1e-3); m = max(m ?? y, y) }; return m }
    var prev: Float?, peak: Float = 0
    for x in stride(from: Float(20), through: 1420, by: 1) {
        guard let y = env(x) else { prev = nil; continue }
        peak = max(peak, y)
        if let p = prev { #expect(abs(y - p) <= 2, "step \(p) -> \(y) at x \(x)") }
        prev = y
    }
    #expect(peak < 40, "no flush shelf at the Dock top under a roof: peak \(peak)")
}
