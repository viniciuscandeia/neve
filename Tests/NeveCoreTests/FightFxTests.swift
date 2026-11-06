import CoreGraphics
import Testing
@testable import NeveCore

private func ground(_ h: Float = 12) -> SnowField {
    let f = makeField()
    f.update(windows: [])
    let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in 0..<500 { f.surfaces[i].pile.heights[b] = h }
    return f
}

@Test func carveShapesAParabolicGrooveWithBerms() {
    var p = Pile(columns: 500, inset: 0)
    for i in p.heights.indices { p.heights[i] = 10 }
    let x = binCenter(150), before = p.heights
    let removed = p.carve(centerX: x, halfWidth: 6, depth: 3, berm: 0.15)
    #expect(abs(p.heights[150] - 7) < 1e-4)
    #expect(p.heights[147] >= 10 && p.heights[153] >= 10 && p.heights[144] == 10)   // +-6 pt: berm; beyond +-8 untouched
    var cut: Float = 0, piled: Float = 0
    for i in p.heights.indices { let d = p.heights[i] - before[i]; if d < 0 { cut -= d * Tuning.binWidth } else { piled += d * Tuning.binWidth } }
    #expect(abs(cut - removed) < 1e-3 && abs(piled - 0.15 * removed) < 1e-3)
}

@Test func draggingABallAcrossSnowLeavesAGrooveWithBerms() {
    let f = ground(8)
    let si = f.surfaces.firstIndex { $0.id == Tuning.groundID }!, edge = f.surfaces[si].edgeY
    let id = f.scoop(at: CGPoint(x: 300, y: CGFloat(edge + 4)))!
    f.drop(id, throwing: false); f.balls[0].state = .held   // (scoop leaves it held already; keep it explicit)
    var x: Float = 300
    while x < 360 { x += 2; f.drag(id, to: CGPoint(x: CGFloat(x), y: CGFloat(edge + 8)), dt: 1 / 60) }
    let h = f.surfaces[si].pile.heights
    let track = h[(Int(305 / 2))..<(Int(355 / 2))], around = h[(Int(250 / 2))..<(Int(400 / 2))]
    #expect(track.min()! <= 6)
    #expect(around.max()! > 8)
}

@Test func aHitCreatesOneSplatOnTheTargetThatFades() {
    let f = ground()
    stand(f, x: 300)
    let b = stand(f, x: 420)
    f.walkEnabled = false
    f.step(dt: 1 / 60)
    var s = Shot(pos: .zero, from: SIMD2(300, 60), to: SIMD2(420, 50), peak: 20, dur: 0.6, hit: true, head: false, target: b, surface: Tuning.groundID)
    f.land(&s)
    #expect(f.splats.count == 1 && f.splats[0].target == b)
    let p0 = f.position(of: f.splats[0])!
    f.figures[f.figureIndex(b)!].foot.x += 10
    #expect(f.position(of: f.splats[0])!.x == p0.x + 10)   // moves with the target
    advance(f, 1.3)
    #expect(f.splats.isEmpty)
}

@Test func splatPoolIsCapped() {
    let f = ground()
    for k in 0..<20 {
        var s = Shot(pos: .zero, from: SIMD2(100, 60), to: SIMD2(200 + Float(k), 20), peak: 20, dur: 0.6, hit: false, head: false, target: 0, surface: Tuning.groundID)
        f.land(&s)
    }
    #expect(f.splats.count == Tuning.maxSplats)
    var buf = [Prim](repeating: Prim(), count: 64)
    let n = buf.withUnsafeMutableBufferPointer { b -> Int in
        var w = PrimWriter(b.baseAddress!, capacity: 64)
        f.writeShotPrims(&w, trails: true, shift: { _ in .zero })
        return w.n
    }
    #expect(n == 2 * Tuning.maxSplats)
}

@Test func shotHoldsSquashedThenIsHidden() {
    let f = ground()
    stand(f, x: 300); stand(f, x: 420)
    advance(f, 1)
    var maxShots = 0
    var sawImpact = false
    for _ in 0..<(10 * 60) {
        f.step(dt: 1 / 60)
        if f.shots.contains(where: \.impacting) { sawImpact = true }
        maxShots = max(maxShots, f.shots.count)
    }
    #expect(sawImpact && maxShots <= 2)
    #expect(f.shots.allSatisfy { !$0.impacting || $0.impactT <= Tuning.impactHold })
}

@Test func thirdHeadHitDroopsTheLoserAndTheHeadSpins() {
    let f = ground()
    stand(f, x: 300)
    let b = stand(f, x: 420)
    advance(f, 1)
    #expect(fig(f, b).droop == 0)
    f.registerHit(b, head: true); f.registerHit(b, head: true); f.registerHit(b, head: true)
    let head = f.balls.first { $0.face != 0 }!
    advance(f, 0.5)
    #expect(abs(ball(f, head.id).rotation) > 3)
    advance(f, 0.1)
    #expect(fig(f, b).droop >= 0.99)
    #expect(fig(f, b).headTilt == 0)
}

@Test func reStackedHeadStraightensAndArmsRise() {
    let f = ground()
    stand(f, x: 300)
    let b = stand(f, x: 420)
    advance(f, 1)
    for _ in 0..<3 { f.registerHit(b, head: true) }
    advance(f, 1)
    f.reattach(f.figureIndex(b)!, radius: 10, tilt: 2)
    #expect(fig(f, b).headTilt == 2)
    advance(f, 0.3)
    #expect(fig(f, b).headTilt == 0 && fig(f, b).droop == 0)
}
