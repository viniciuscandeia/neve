// AGENT HEADER - Tests/NeveCoreTests/WindowBodyTests.swift  (window bodies are obstacles: debris, covered figures, garland)
// Debris flung sideways at a window rectangle never enters it (vx zeroed, it slides down the wall); balls / gifts / tree / snowman fade out of the DRAWING when a window merely brought to front covers them
//   (physics stays on `alive`: nothing falls); the garland skips arcs hidden under an occluder. Related: Debris.swift (blockByWindows), Figures.swift (`hide`), Snowball / Gifts / Tree (`hide`), Lights.swift.

import CoreGraphics
import Testing
@testable import NeveCore

@Test func debrisPushedAgainstAWindowWallDoesNotCrossIt() {
    let f = makeField()
    f.update(windows: [win(1, 300, 200, 200, 150)])   // x 300...500, y 200...350
    for k in 0..<12 { f.addDebris(x: 250 + Float(k) * 3, y: 330 - Float(k) * 8, vx: 400, fall: 0, size: 4) }
    var inside = 0
    for _ in 0..<90 {
        f.step(dt: 1 / 60)
        inside += f.debris.filter { $0.pos.x > 302 && $0.pos.x < 498 && $0.pos.y > 202 && $0.pos.y < 348 }.count
    }
    #expect(inside == 0)
}

/// Max x reached by a single piece launched at (x, y) with vx while it lives (`oz` = origin z: window list index, front = 0).
private func reach(_ f: SnowField, x: Float, y: Float, vx: Float, oz: UInt16) -> Float {
    f.addDebris(x: x, y: y, vx: vx, fall: 0, size: 4, oz: oz)
    var mx = x
    for _ in 0..<40 { f.step(dt: 1 / 60); if let p = f.debris.first { mx = max(mx, p.pos.x) } }
    return mx
}

@Test func debrisLeavingAFrontWindowCrossesABackWindowOutline() {
    let f = makeField()
    f.update(windows: [win(1, 100, 200, 200, 150), win(2, 320, 100, 130, 300)])   // 1 in front (x 100...300), 2 behind and beside it (x 320...450, y 100...400); past it the ground is open
    func beyondWall() -> Float { f.surfaces.reduce(0) { t, s in t + s.pile.heights.indices.reduce(0) { $0 + ((Float(s.c0 + $1) + 0.5) * Tuning.binWidth >= 320 ? s.pile.heights[$1] : 0) } } }
    let g = f.surfaces.firstIndex { $0.id == Tuning.groundID }!   // a bare ground is tunnelled by fast pieces: give it a 12 pt layer past the back window so they land
    for b in f.surfaces[g].pile.heights.indices where (Float(b) + 0.5) * Tuning.binWidth >= 460 { f.surfaces[g].pile.heights[b] = 12 }
    let before = beyondWall()
    #expect(reach(f, x: 302, y: 320, vx: 600, oz: 0) > 340)
    for _ in 0..<200 { f.step(dt: 1 / 60) }
    #expect(f.debris.isEmpty)               // landed, not stuck
    #expect(beyondWall() > before)          // its snow is in a pile past the back window wall, on the ground beyond it (under the window the ground is not open), never above that window top (y 400)
    #expect(f.surfaces.allSatisfy { s in s.pile.heights.indices.allSatisfy { s.edgeY + s.pile.base[$0] + s.pile.heights[$0] <= 400.5 } })
}

@Test func debrisFromABackWindowStillStopsAtAFrontWindowWall() {
    let f = makeField()
    f.update(windows: [win(1, 320, 100, 380, 300), win(2, 100, 200, 200, 150)])   // 1 in front (x 320...700), 2 behind (x 100...300)
    #expect(reach(f, x: 302, y: 320, vx: 300, oz: 1) < 320)
}

@Test func windowBroughtToFrontFadesFiguresButTheyStayPut() {
    let a = win(1, 100, 200, 600, 200), b = win(2, 150, 300, 200, 150)   // b in front covers part of a's top (y 400)
    let f = makeField()
    f.update(windows: [a, b])
    pileUp(f, id: 1, rounds: 60)
    let fid = stand(f, x: 250, on: 1), bid = stackBalls(f, x: 220, on: 1, radii: [10])
    f.giftState.gifts.append(Gift(pos: SIMD2(260, 420), vel: .zero, surface: 1, rot: 0, spin: 0, color: 0, scale: 1))
    advance(f, 1)
    #expect(f.look(of: fig(f, fid)).fade > 0.99 && ball(f, bid).hide > 0.99 && f.gifts[0].hide > 0.99)
    f.update(windows: [b, a]); advance(f, 1)
    #expect(f.look(of: fig(f, fid)).fade < 0.01 && ball(f, bid).hide < 0.01 && f.gifts[0].hide < 0.01)
    #expect(fig(f, fid).surfaceID == 1 && ball(f, bid).surfaceID == 1 && f.gifts[0].surface == 1)   // physics untouched
    f.update(windows: [a, b]); advance(f, 1)
    #expect(f.look(of: fig(f, fid)).fade > 0.99 && ball(f, bid).hide > 0.99)
}

@Test func garlandSkipsArcsUnderAWindow() {
    let f = makeField()
    f.lightsEnabled = true
    var buf = [Prim](repeating: Prim(), count: 4000)
    func count() -> Int { buf.withUnsafeMutableBufferPointer { var w = PrimWriter($0.baseAddress!, capacity: 4000); f.writeLightPrims(&w, shift: { _ in .zero }); return w.n } }
    let all = count()
    f.update(windows: [win(1, 0, 300, 400, 500)])   // reaches above visibleTop over x 0...400
    #expect(count() < all)
}
