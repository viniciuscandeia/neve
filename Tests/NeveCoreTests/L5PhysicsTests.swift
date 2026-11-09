import CoreGraphics
import Testing
@testable import NeveCore

private func wide() -> (SnowField, Int) {
    let f = makeField()
    f.update(windows: [win(1, 100, 300, 1000, 200)])
    return (f, f.surfaces.firstIndex { $0.id == 1 }!)
}

@Test func avalancheFullnessUsesTheWavyLimit() {
    let (f, i) = wide()
    #expect(f.fullSpot(si: i) == nil)
    let n = f.surfaces[i].pile.heights.count
    for b in 0..<n { f.surfaces[i].pile.heights[b] = f.surfaces[i].pile.limit(b) * 0.9 }   // 90% of the real ceiling
    #expect(f.fullSpot(si: i) != nil)
}

@Test func avalancheDriftTriggersAtItsLimit() {
    let (f, i) = wide()
    let n = f.surfaces[i].pile.heights.count
    f.surfaces[i].pile.boost = [Float](repeating: 0, count: n)
    for b in 100..<110 { f.surfaces[i].pile.boost[b] = Tuning.maxDrift; f.surfaces[i].pile.heights[b] = f.surfaces[i].pile.limit(b) }
    #expect(f.fullSpot(si: i, lo: 0, hi: binCenter(f.surfaces[i].c0 + 105) + 4) != nil)
}

@Test func landingSlabLaysItsVolumeAlongItsWidth() {
    let (f, i) = wide()
    let c = f.surfaces[i].pile.heights.count / 2
    let x = binCenter(f.surfaces[i].c0 + c), top = f.surfaces[i].edgeY
    #expect(f.tryLand(x: x, prevY: top + 5, newY: top - 1, volume: 0, fall: 100, vol: 160, span: 32))
    let h = f.surfaces[i].pile.heights
    #expect(h[c - 6] > 0.5 && h[c + 6] > 0.5)
    #expect(h.max()! < 6)   // 160 pt^2 over 32 pt: no 3-column spike
}

@Test func impactKeepsNoCliff() {
    let (f, i) = wide()
    let c = f.surfaces[i].pile.heights.count / 2
    let x = binCenter(f.surfaces[i].c0 + c), top = f.surfaces[i].edgeY
    f.impact(surface: i, bin: c, x: x, top: top, fall: 500, vol: 40)
    let h = f.surfaces[i].pile.heights
    for b in 1..<h.count { #expect(abs(h[b] - h[b - 1]) <= Tuning.slope + Tuning.dustSlope + 0.5) }
}

@Test func slabIsKeptUntilFullyOffTheScreenEdge() {
    let f = makeField()
    f.debris.append(Flake(pos: [-10, 500], vx: -10, fall: 0, phase: 0, amp: 0, freq: 0, size: 40, alpha: 1, kind: .debris, vol: 100, shape: 2))
    f.stepDebris(dt: 1 / 60)
    #expect(f.debris.count == 1)
    f.debris[0].pos.x = -30
    f.stepDebris(dt: 1 / 60)
    #expect(f.debris.isEmpty)
}

@Test func releasedSlabRampsUpInsteadOfLurching() {
    let f = makeField()
    f.debris.append(Flake(pos: [500, 500], vx: 100, fall: 0, phase: 0, amp: 1, freq: 0, size: 40, alpha: 1, kind: .debris, vol: 100, shape: 2, prof: Flake.pack(thickness: 8, left: 1, mid: 1, right: 1)))
    f.stepDebris(dt: 1 / 60)
    #expect(f.debris[0].pos.x - 500 < 100 / 60 * 0.5)
}

@Test func meanShownFollowsTheDrawnSnow() {
    let (f, i) = wide()
    let n = f.surfaces[i].pile.heights.count
    f.surfaces[i].pile.heights = [Float](repeating: 10, count: n)
    f.surfaces[i].pile.shown = [Float](repeating: 4, count: n)
    let col = f.surfaces[i].c0 + n / 2
    #expect(f.meanShown(si: i, col: col, span: 3) == 4 && f.meanHeight(si: i, col: col, span: 3) == 10)
    #expect(abs(f.standY(si: i, x: binCenter(col)) - (f.surfaces[i].edgeY + 4)) < 0.01)
}

@Test func clearResetsAvalancheCursorThrowAndBank() {
    let f = makeField()
    f.chain.fronts.append(AvaFront(win: 1, dir: 1, startX: 0, length: 50, speed: 50)); f.chain.cooldownUntil = 99
    f.cursorThrow.windup = 0.2; f.cursorThrow.thrown = 2
    f.bankLevel = (60, 60)
    f.clear()
    #expect(f.chain.fronts.isEmpty && f.chain.cooldownUntil == 0 && f.cursorThrow.windup < 0 && f.cursorThrow.thrown == 0)
    #expect(f.bankLevel.l == Tuning.groundMaxHeight)
}

private func liveFlakes(_ f: SnowField) -> Int { f.flakes.filter { $0.kind != .dormant }.count }

@Test func snowResumesAfterAnOutroWithoutAnIntro() {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 200, seed: 3)
    f.collapseAll(spread: 0.3)
    advance(f, 2)
    #expect(f.outro && liveFlakes(f) == 0)
    f.endOutro()
    advance(f, 5)
    #expect(!f.outro && liveFlakes(f) > 0)
}

@Test func introAfterOutroKeepsFlakesStillFadingOut() {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 200, seed: 3)
    advance(f, 1)
    f.collapseAll(spread: 0.3)
    advance(f, 0.2)
    let live = liveFlakes(f)
    #expect(live > 0)
    f.beginIntro(duration: 2.5)
    #expect(liveFlakes(f) >= live)
}

@Test func giftFadesInTheOutro() {
    let f = makeField()
    f.dropGift(at: [500, 300], dir: 1)
    f.collapseAll(spread: 0.3)
    f.step(dt: 1 / 60)
    #expect(f.gifts.count == 1 && f.gifts[0].fade < 1 && f.gifts[0].fade > 0)
    advance(f, 0.6)
    #expect(f.gifts.isEmpty)
}

@Test func glintsFadeWhenTheirModeTurnsOff() {
    let (f, _) = wide()
    f.glints.append(Flake(pos: [500, 400], vx: 0, fall: 0, phase: 0, amp: 0, freq: 0, size: 4, alpha: 1, kind: .debris, fade: 1, delay: 0.6, shape: 4))
    f.economy = true
    f.stepGlints(dt: 1 / 60)
    #expect(f.glints.count == 1 && f.glints[0].fade < 1)
    for _ in 0..<20 { f.stepGlints(dt: 1 / 60) }
    #expect(f.glints.isEmpty)
}

@Test func glintRidesTheDrawnCrest() {
    let (f, i) = wide()
    let n = f.surfaces[i].pile.heights.count
    f.surfaces[i].pile.heights = [Float](repeating: 10, count: n); f.surfaces[i].pile.shown = [Float](repeating: 3, count: n)
    f.glints.append(Flake(pos: [500, 0], vx: 0, fall: 0, phase: Float(f.surfaces[i].c0 + n / 2), amp: 1, freq: 0, size: 4, alpha: 1, kind: .debris, fade: 1, delay: 0.6, shape: 4, prof: 1))
    f.stepGlints(dt: 1 / 60)
    #expect(abs(f.glints[0].pos.y - (f.surfaces[i].edgeY + 3)) < 0.01)
}

@Test func throwVelocityDoesNotDependOnTheEventRate() {
    func throwSpeed(events: Int) -> Float {
        let f = makeField()
        f.balls.append(Snowball(id: 1, pos: [500, 500], radius: 8, surfaceID: nil)); f.nextBallID = 2
        let dt = 0.01 / Float(events)
        for k in 1...events { f.drag(1, to: CGPoint(x: 500 + Double(k) * Double(dt) * 600, y: 500), dt: dt) }
        return f.balls[0].vel.x
    }
    #expect(abs(throwSpeed(events: 1) - throwSpeed(events: 10)) < 0.2 * throwSpeed(events: 10))
}

@Test func tiedGlintSurvivesShrinkAndFollowsItsColumn() {
    let f = makeField(seed: 3)
    f.update(windows: [win(1, 300, 300, 600, 200)])
    var i = f.surfaces.firstIndex { $0.id == 1 }!
    let col = f.surfaces[i].c0 + f.surfaces[i].pile.heights.count - 5
    f.glints.append(Flake(pos: [0, 0], vx: 0, fall: 0, phase: Float(col), amp: 1, freq: 0, size: 4, alpha: 1, kind: .debris, fade: 1, delay: 0.6, shape: 4,
                          prof: UInt32(bitPattern: Int32(1))))
    f.update(windows: [win(1, 300, 300, 100, 200)])   // far fewer bins: the column is gone
    i = f.surfaces.firstIndex { $0.id == 1 }!
    #expect(col - f.surfaces[i].c0 >= f.surfaces[i].pile.heights.count)
    f.stepGlints(dt: 1 / 60)
    #expect(f.glints.count == 1 && f.glints[0].fade < 1)
    for _ in 0..<20 { f.stepGlints(dt: 1 / 60) }
    #expect(f.glints.isEmpty)
}
