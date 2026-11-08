import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

private func bar(_ x0: CGFloat, _ x1: CGFloat) -> WindowInfo { WindowInfo(number: 0, frame: CGRect(x: x0, y: 10, width: x1 - x0, height: 84), radius: 25.2) }

private func world(_ target: WindowInfo) -> SnowField {
    let f = SnowField(size: CGSize(width: 1920, height: 1080), origin: .zero, groundY: 90, visibleTop: 1060, flakeCount: 0, seed: 3)
    var ws: [WindowInfo] = [bar(700, 1000)]
    for i in 0..<40 { ws.append(win(i + 1, CGFloat(20 + (i % 10) * 180), CGFloat(300 + (i / 10) * 150), 170, 100)) }
    f.update(windows: ws)
    for si in f.surfaces.indices where f.surfaces[si].id > 0 { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = 6 } }
    ws[0] = target
    f.update(windows: ws)
    return f
}

/// Process CPU milliseconds (stable under load from other processes).
private func cpuMs() -> Double { Double(clock()) / Double(CLOCKS_PER_SEC) * 1000 }

/// Dock animation cost: 40 snowy windows, the bar widens by 600pt. With NEVE_BENCH set it prints the mean wall time of one animated step.
/// The assertions pin semantics: the animation ends, and the other windows' piles evolve exactly as with a static bar.
@Test func dockAnimationFinishesAndLeavesOtherWindowsPilesAlone() {
    let f = world(bar(400, 1300)), g = world(bar(700, 1000.4))   // (a rebuild happens in both worlds; only f animates for long)
    var n = 0
    let t0 = cpuMs()
    while f.dockCur != f.dockTarget, n < 600 { f.step(dt: 1 / 60); n += 1 }
    let ms = cpuMs() - t0
    if getenv("NEVE_BENCH") != nil { print("BENCH dock animation: \(n) steps, \(ms / Double(max(n, 1))) ms per step") }
    if getenv("NEVE_BENCH") != nil {   // the rebuild alone: all surfaces vs the Dock + ground only
        let w = f.effective(f.lastWindows)
        for (label, only) in [("full", nil), ("dock+ground", [0, Tuning.groundID])] as [(String, Set<Int>?)] {
            let t = cpuMs()
            for _ in 0..<50 { _ = f.updateSurfaces(windows: w, only: only) }
            print("BENCH rebuild \(label): \((cpuMs() - t) / 50) ms")
        }
    }
    for _ in 0..<n { g.step(dt: 1 / 60) }
    #expect(f.dockCur == f.dockTarget && n < 600)
    #expect(f.surfaces.filter { $0.id > 0 }.map(\.pile.heights) == g.surfaces.filter { $0.id > 0 }.map(\.pile.heights))
    expectMatchesFullRebuild(f)
}

/// After an identical snapshot, a full rebuild must leave every surface's visible / cap / runs / cover exactly as the incremental animation did.
private func expectMatchesFullRebuild(_ f: SnowField, sourceLocation: SourceLocation = #_sourceLocation) {
    f.update(windows: f.lastWindows)
    let have = f.surfaces
    f.updateSurfaces(windows: f.effective(f.lastWindows))
    #expect(f.surfaces.map(\.id) == have.map(\.id), sourceLocation: sourceLocation)
    for (a, b) in zip(have, f.surfaces) {
        #expect(a.pile.visible == b.pile.visible, "visible of \(a.id)", sourceLocation: sourceLocation)
        #expect(a.pile.cap == b.pile.cap, "cap of \(a.id)", sourceLocation: sourceLocation)
        #expect(a.runs == b.runs, "runs of \(a.id)", sourceLocation: sourceLocation)
        #expect(a.cover == b.cover, "cover of \(a.id)", sourceLocation: sourceLocation)
    }
}

private func animate(_ windows: [WindowInfo], from: WindowInfo, to: WindowInfo) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0, seed: 5)
    f.update(windows: [from] + windows)
    f.update(windows: [to] + windows)
    var n = 0
    while f.dockCur != f.dockTarget, n < 2000 { f.step(dt: 0.05); n += 1 }   // 40 pt per step: wider than the bar's rounded corner, so an overlapping step really hides bins
    return f
}

/// The Dock shrinks off a low window (top 92 < Dock top 94): once it leaves the current and target frames, the window must still match a rebuild.
@Test func dockRetractionOverLowWindowMatchesFullRebuild() {
    for (a, b) in [(bar(300, 1000), bar(500, 1000)), (bar(500, 1000), bar(300, 1000)), (bar(300, 1000), bar(700, 1000))] {
        expectMatchesFullRebuild(animate([win(1, 360, 40, 40, 52)], from: a, to: b))
    }
}

/// A tall window whose foot sits behind the Dock: its frost / icicle clip (`cover`) follows the Dock as it widens or shrinks beneath it.
@Test func dockBeneathTallWindowUpdatesCover() {
    let tall = win(1, 350, 90, 300, 200)
    for (a, b) in [(bar(700, 1000), bar(300, 1000)), (bar(300, 1000), bar(700, 1000)), (bar(450, 1000), bar(300, 1000)), (bar(300, 1000), bar(500, 1000))] {
        let f = animate([tall], from: a, to: b)
        expectMatchesFullRebuild(f)
        let si = f.index[1]!
        #expect(f.covered(si, SIMD2(400, 92)) == (b.frame.minX < 400))
        #expect(f.covered(si, SIMD2(640, 92)) == (b.frame.minX < 640))
    }
}
