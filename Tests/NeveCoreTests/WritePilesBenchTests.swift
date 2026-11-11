// AGENT HEADER - Tests/NeveCoreTests/WritePilesBenchTests.swift  (microbench of Render.writePiles; runs only with NEVE_BENCH=1)
// `NEVE_BENCH=1 Tests/run.sh -r writePilesBench` prints ns/call of the shipped writePiles on a 3000 pt screen with a Dock and six wide snowy windows (stacked: no seams), and on a "groups" scene (windows side by side and higher windows over lower ones: walls and seams).
//   Replaces the old reference-vs-shipped comparison (WritePilesCompareTests / writePilesRef mirrored the stitched drawing that Contour.swift replaced). Related: Render.writePiles, Contour.swift.

import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

private func dockWin(_ x0: CGFloat, _ x1: CGFloat) -> WindowInfo { WindowInfo(number: 0, frame: CGRect(x: x0, y: 10, width: x1 - x0, height: 84), radius: 25.2) }

private func bench(_ label: String, _ f: SnowField) {
    let cap = f.pileSegDemand
    let p = UnsafeMutablePointer<PileSeg>.allocate(capacity: cap)
    defer { p.deallocate() }
    for _ in 0..<50 { _ = f.writePiles(to: p, capacity: cap, dt: 10, force: true) }
    var best = Double.infinity, n = 0
    for _ in 0..<7 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<300 { n = f.writePiles(to: p, capacity: cap, dt: 10, force: true) ?? 0 }
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 300)
    }
    print("BENCH writePiles \(label): \(Int(best)) ns/call (\(n) slices)")
}

@Test func writePilesBench() {
    guard getenv("NEVE_BENCH") != nil else { return }
    let f = SnowField(size: CGSize(width: 3000, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 1)
    let ws = [dockWin(900, 2100)] + (0..<6).map { win($0 + 1, CGFloat($0) * 20, 120 + CGFloat($0) * 110, 2900 - CGFloat($0) * 40, 90) }
    f.update(windows: ws)
    for w in ws { pileUp(f, id: w.number, rounds: 6) }
    pileUp(f, id: Tuning.groundID, rounds: 6)
    bench("stacked", f)
    let g = SnowField(size: CGSize(width: 3000, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 1)
    let gs = [dockWin(900, 2100), win(1, 0, 300, 700, 300), win(2, 700, 300, 700, 300), win(3, 1400, 306, 600, 300), win(4, 300, 312, 400, 300), win(5, 2100, 400, 800, 200), win(6, 2300, 410, 300, 200)]
    g.update(windows: gs)
    for w in gs { pileUp(g, id: w.number, rounds: 12) }
    pileUp(g, id: Tuning.groundID, rounds: 6)
    bench("groups ", g)
}
