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

private func drawPiles(_ f: SnowField) -> [PileSeg] {
    var buf = [PileSeg](repeating: PileSeg(x0: 0, x1: 0, top0: 0, top1: 0, base0: 0, base1: 0, slope: 0, dragged: 0), count: 4096)
    let n = buf.withUnsafeMutableBufferPointer { f.writePiles(to: $0.baseAddress!, capacity: 4096, dt: 10, force: true) } ?? 0
    return Array(buf[0..<n])
}

/// Inside the rounded window rectangle (corner radius 20), shrunk by `m`.
private func inside(_ x: Float, _ y: Float, m: Float = 0) -> Bool {
    let x0 = Float(frame.minX) + m, x1 = Float(frame.maxX) - m, y0 = Float(frame.minY) + m, y1 = Float(frame.maxY) - m, r = 20 - m
    guard x > x0, x < x1, y > y0, y < y1 else { return false }
    let dx = max(x0 + r - x, x - (x1 - r), 0), dy = max(y0 + r - y, y - (y1 - r), 0)
    return dx * dx + dy * dy < r * r
}

private func bodyPoints(_ c: Icicle) -> [(Float, Float)] {
    let hw = c.width / 2 + 0.5
    return [(c.x - hw, c.y), (c.x + hw, c.y), (c.x, c.y), (c.x + c.tilt, c.y - c.len), (c.x + c.tilt / 2, c.y - c.len / 2), (c.x, c.y - 1)]
}

@Test func icicleLipStartsOnTheDrawnPileEndAndBodiesStayOutsideTheWindow() {
    let f = oneWindow()
    advance(f, 6, fps: 4)
    let tops = f.icicles.filter { !$0.bottom }
    #expect(!tops.isEmpty)
    let segs = drawPiles(f).filter { $0.top0 > 300 }
    let left = segs.min { $0.x0 < $1.x0 }!, right = segs.max { $0.x1 < $1.x1 }!
    for right_ in [false, true] {
        guard let c = tops.first(where: { $0.right == right_ }) else { continue }
        var pts: [SIMD2<Float>] = []
        #expect(f.lipChain(id: 1, right: right_) { pts.append($0) })
        let end = right_ ? SIMD2(right.x1, right.top1) : SIMD2(left.x0, left.top0)
        #expect(abs(pts[0].x - end.x) <= 1 && abs(pts[0].y - end.y) <= 1)
        let last = pts.last!   // the knob end: the icicle top touches it
        #expect(abs(last.y - c.y) <= 3 && abs(last.x - c.x) <= 8)
        for p in pts.dropFirst() { #expect(!inside(p.x, p.y)) }   // the lip hugs the corner from outside
    }
    for c in tops { for (x, y) in bodyPoints(c) { #expect(!inside(x, y)) } }
}

@Test func icicleLipFollowsPileShrink() {
    let f = oneWindow()
    advance(f, 6, fps: 4)
    _ = drawPiles(f)
    var a: [SIMD2<Float>] = []
    #expect(f.lipChain(id: 1, right: false) { a.append($0) })
    let si = f.index[1]!
    for b in 0..<8 { f.surfaces[si].pile.heights[b] = 0 }
    _ = drawPiles(f)
    var b: [SIMD2<Float>] = []
    #expect(f.lipChain(id: 1, right: false) { b.append($0) })
    #expect(b[0].x > a[0].x + 1)   // the lip starts at the new, shorter contour end
    let nl = drawPiles(f).filter { $0.top0 > 300 }.min { $0.x0 < $1.x0 }!
    #expect(abs(b[0].x - nl.x0) <= 1 && abs(b[0].y - nl.top0) <= 1)
}

@Test func windowFreezesAfterThresholdOnly() {
    let f = oneWindow()
    advance(f, 150, fps: 4)
    #expect(f.iceWin.first?.frozen != true)
    #expect(!f.icicles.contains { $0.bottom })
    advance(f, 40, fps: 4)
    #expect(f.iceWin.first?.frozen == true)
    let st = f.icicles.filter { $0.bottom }
    #expect(st.count >= 4 && st.count <= 10)
    for c in st {
        #expect(c.y <= Float(frame.minY) + 1 && c.y - c.len < Float(frame.minY))
        #expect(c.x > Float(frame.minX) && c.x < Float(frame.maxX))
        for (x, y) in bodyPoints(c) where y < Float(frame.minY) { #expect(!inside(x, y)) }
    }
    advance(f, 130, fps: 4)   // 1-2 minutes of growth
    for c in f.icicles where c.bottom { #expect(c.len == c.maxLen && c.maxLen >= 4 && c.maxLen <= 20) }
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
    let st = f.icicles.filter { $0.bottom }
    #expect(st.count <= 40 && !st.isEmpty)
    for id in 1...5 { #expect(st.filter { $0.win == id }.count <= 10) }
}

@Test func fastMoveBreaksStalactitesIntoDebrisAndThaws() {
    let f = oneWindow()
    advance(f, 190, fps: 4)
    let n = f.icicles.filter { $0.bottom }.count
    #expect(n > 0)
    let d0 = f.debris.count
    f.update(windows: [win(1, 300 + 150, 400, 300, 150)], dt: 0.1)
    f.step(dt: 1.0 / 60)
    #expect(!f.icicles.contains { $0.bottom })
    #expect(f.debris.count >= d0 + 2 * n)
    #expect(f.iceWin.first?.frozen != true)
}

@Test func slowMoveKeepsStalactitesAttached() {
    let f = oneWindow()
    advance(f, 190, fps: 4)
    let before = f.icicles.filter { $0.bottom }
    f.update(windows: [win(1, 310, 400, 300, 150)], dt: 1)
    f.step(dt: 1.0 / 60)
    let after = f.icicles.filter { $0.bottom }
    #expect(after.count == before.count && !after.isEmpty)
    for (a, b) in zip(after, before) { #expect(abs(a.x - b.x - 10) < 0.5 && abs(a.y - b.y) < 0.5) }
}

@Test func knockedOffPileAndResizeThaw() {
    let f = oneWindow()
    advance(f, 190, fps: 4)
    f.surfaces[f.index[1]!].pile.empty()
    advance(f, 2, fps: 4)
    #expect(f.iceWin.first?.frozen != true)
    #expect(!f.icicles.contains { $0.bottom })
    let g = oneWindow()
    advance(g, 190, fps: 4)
    g.update(windows: [win(1, 300, 400, 340, 150)], dt: 1)
    g.step(dt: 1.0 / 60)
    #expect(!g.icicles.contains { $0.bottom })
}

@Test func reduceMotionStalactitesAppearFullGrownAndFadeIn() {
    let f = oneWindow()
    f.setCalm(true)
    advance(f, 190, fps: 4)
    let st = f.icicles.filter { $0.bottom }
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
