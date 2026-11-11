// AGENT HEADER - Tests/NeveCoreTests/FrostTests.swift  (Frost.swift + Icicles.swift: windows freeze after the threshold only (Nevasca sooner, demo speed ~10 s), stalactite caps, fast move breaks them into debris and thaws, slow move carries them, knocked-off pile / resize thaw, Reduce Motion icicles appear full-grown and fade, frost prims only while frozen, clipped by windows in front.)

import CoreGraphics
import Testing
@testable import NeveCore

private let frame = CGRect(x: 300, y: 400, width: 300, height: 150)   // radius 20 (WindowInfo default)

private func oneWindow(seed: UInt64 = 1, config: SimConfig = .init()) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0, config: config, seed: seed)
    f.update(windows: [win(1, 300, 400, 300, 150)])
    pileUp(f, id: 1)
    return f
}

@Test func windowFreezesAfterThresholdOnly() {
    let f = oneWindow()
    advance(f, 150, fps: 4)
    #expect(f.iceWin.first?.frozen != true)
    #expect(f.icicles.isEmpty)
    advance(f, 40, fps: 4)
    #expect(f.iceWin.first?.frozen == true)
    let st = f.icicles
    #expect(st.count >= 4 && st.count <= 10)
    for c in st {
        let r = Float(Tuning.defaultWindowRadius), d = max(r - (c.x - Float(frame.minX)), (c.x - Float(frame.minX)) - (Float(frame.width) - r), 0)
        let lip = Float(frame.minY) + r - (r * r - d * d).squareRoot()   // the bottom edge, rising along the rounded corners
        #expect(c.y <= lip + 1 && c.y - c.len < lip)
        #expect(c.x > Float(frame.minX) && c.x < Float(frame.maxX))
    }
    advance(f, 130, fps: 4)   // 1-2 minutes of growth
    for c in f.icicles { #expect(c.len == c.maxLen && c.maxLen >= 4 && c.maxLen <= 20) }
    #expect(f.iceWin[0].frost > 0.9)
}

@Test func nevascaFreezesSooner() {
    let f = oneWindow()
    f.intensity = .nevasca
    advance(f, 125, fps: 4)
    #expect(f.iceWin.first?.frozen == true)
}

@Test func demoSpeedFreezesInAboutTenSeconds() {
    let f = oneWindow(config: SimConfig(iceSpeed: 120))
    advance(f, 12, fps: 4)
    #expect(f.iceWin.first?.frozen == true)
}

@Test func stalactiteCapsHold() {
    let f = makeField()
    f.update(windows: (1...5).map { win($0, CGFloat(20 + ($0 - 1) * 190), 400, 180 + CGFloat($0) * 10, 150) })
    for id in 1...5 { pileUp(f, id: id) }
    f.intensity = .nevasca
    advance(f, 130, fps: 4)
    let st = f.icicles
    #expect(st.count <= 40 && !st.isEmpty)
    for id in 1...5 { #expect(st.filter { $0.win == id }.count <= 10) }
}

@Test func fastMoveBreaksStalactitesIntoDebrisAndThaws() {
    let f = oneWindow()
    advance(f, 190, fps: 4)
    let n = f.icicles.count
    #expect(n > 0)
    let d0 = f.debris.count
    f.update(windows: [win(1, 300 + 150, 400, 300, 150)], dt: 0.1)
    f.step(dt: 1.0 / 60)
    #expect(f.icicles.isEmpty)
    #expect(f.debris.count >= d0 + 2 * n)
    #expect(f.iceWin.first?.frozen != true)
}

@Test func slowMoveKeepsStalactitesAttached() {
    let f = oneWindow()
    advance(f, 190, fps: 4)
    let before = f.icicles
    f.update(windows: [win(1, 310, 400, 300, 150)], dt: 1)
    f.step(dt: 1.0 / 60)
    let after = f.icicles
    #expect(after.count == before.count && !after.isEmpty)
    for (a, b) in zip(after, before) { #expect(abs(a.x - b.x - 10) < 0.5 && abs(a.y - b.y) < 0.5) }
}

@Test func knockedOffPileAndResizeThaw() {
    let f = oneWindow()
    advance(f, 190, fps: 4)
    f.surfaces[f.index[1]!].pile.empty()
    advance(f, 2, fps: 4)
    #expect(f.iceWin.first?.frozen != true)
    #expect(f.icicles.isEmpty)
    let g = oneWindow()
    advance(g, 190, fps: 4)
    g.update(windows: [win(1, 300, 400, 340, 150)], dt: 1)
    g.step(dt: 1.0 / 60)
    #expect(g.icicles.isEmpty)
}

@Test func reduceMotionStalactitesAppearFullGrownAndFadeIn() {
    let f = oneWindow()
    f.setCalm(true)
    advance(f, 190, fps: 4)
    let st = f.icicles
    #expect(!st.isEmpty)
    for c in st { #expect(c.len == c.maxLen) }
    let d0 = f.debris.count
    f.surfaces[f.index[1]!].pile.empty()
    f.step(dt: 1.0 / 60)
    #expect(f.debris.count == d0)   // fades, no shatter
}

@Test func frostPrimsAreWrittenOnlyWhileFrozen() {
    let f = oneWindow()
    var buf = [Prim](repeating: Prim(), count: 256)
    func count() -> Int { buf.withUnsafeMutableBufferPointer { var w = PrimWriter($0.baseAddress!, capacity: 256); f.writeIciclePrims(&w, shift: { _ in .zero }); return w.n } }
    advance(f, 6, fps: 4)
    let before = count()
    advance(f, 190, fps: 4)
    #expect(count() > before)
}

@Test func frostAndIciclesAreClippedByFrontWindow() {
    let f = oneWindow()
    advance(f, 200, fps: 4)
    f.intensity = .nevasca
    #expect(f.iceWin.first?.frozen == true)
    // front window (id 2, earlier in the list = in front) covers the middle of the bottom edge
    f.update(windows: [win(2, 380, 350, 140, 120), win(1, 300, 400, 300, 150)])
    let front = CGRect(x: 380, y: 350, width: 140, height: 120)
    var buf = [Prim](repeating: Prim(), count: 512)
    let n = buf.withUnsafeMutableBufferPointer { b -> Int in
        var w = PrimWriter(b.baseAddress!, capacity: 512)
        f.writeIciclePrims(&w, shift: { _ in .zero })
        return w.n
    }
    #expect(n > 0)
    var left = false, right = false
    for q in buf[0..<n] where q.kind != 0 {   // capsule / triangle anchor points: none inside the front window
        for p in [q.a, q.b] {
            #expect(!(CGFloat(p.x) > front.minX && CGFloat(p.x) < front.maxX && CGFloat(p.y) > front.minY && CGFloat(p.y) < front.maxY))
            if p.x < 380 { left = true }
            if p.x > 520 { right = true }
        }
    }
    #expect(left && right)
    // icicles anchored under the front window stop growing
    for c in f.icicles where c.x > 380 && c.x < 520 { #expect(f.covered(f.index[1]!, SIMD2(c.x, c.y))) }
}
