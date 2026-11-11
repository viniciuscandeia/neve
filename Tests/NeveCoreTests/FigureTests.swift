// AGENT HEADER - Tests/NeveCoreTests/FigureTests.swift  (Figures.swift lifecycle and picking)
// promote (a formed, decreasing 3-ball stack -> one Figure; anchors follow c(n+1) = c(n) + r(n) + r(n+1) - 1.5), demote back to balls (falling drops the whole stack, headless -> two balls), shatter -> debris, figure count never exceeds Tuning.maxFigures,
//   a figure under a covering window goes hidden, does not walk or fight and returns when uncovered, travels with its window (slow move) and falls apart when knocked off (fast), closing the window drops it as balls, the auto snowman collapses only when
//   knocked off, a Space switch removes figures on vanished windows but not on the ground, picking a stacked snowman's head demotes it (the body / the auto one are not pickable), standing figures leave balls alone and loose balls bounce off them,
//   `look(of:)` data for the renderer, and `stage(.heavy)` is deterministic per seed.

import CoreGraphics
import Testing
@testable import NeveCore

private func field(_ windows: [WindowInfo] = [], h: Float = 12) -> SnowField {
    let f = makeField()
    f.update(windows: windows)
    let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in 0..<500 { f.surfaces[i].pile.heights[b] = h }
    return f
}

private func windowTop(_ f: SnowField, id: Int, h: Float = 12) {
    let w = f.surfaces.firstIndex { $0.id == id }!
    for b in f.surfaces[w].pile.heights.indices { f.surfaces[w].pile.heights[b] = h }
}

@Test func promoteTurnsAThreeBallStackIntoOneFigure() {
    let f = field()
    let bottom = stackBalls(f, x: 300)
    let id = f.promote(bottomBall: bottom)
    #expect(id != nil && f.balls.isEmpty && f.figures.count == 1)
    let m = f.figures[0]
    #expect(m.fromBalls && m.kind == .snowman && m.built == Snowman.stageCount && m.radii == SIMD3(20, 14, 10))
    #expect(m.foot.x == 300 && abs(m.foot.y - 12) < 0.01 && m.at == .surface(id: Tuning.groundID, x: 300))
    // anchors follow the stacked-ball formula c(n+1) = c(n) + r(n) + r(n+1) - 1.5
    let a = f.anchors(of: m)
    #expect(abs(a.body.y - (a.base.y + 20 + 14 - 1.5)) < 0.01 && abs(a.head.y - (a.body.y + 14 + 10 - 1.5)) < 0.01)
}

@Test func promoteNeedsAFormedStack() {
    let f = field()
    #expect(f.promote(bottomBall: stackBalls(f, x: 300, radii: [20, 14])) == nil)
    #expect(f.promote(bottomBall: stackBalls(f, x: 500, radii: [20, 20, 10])) == nil)   // balls must shrink
    #expect(f.figures.isEmpty && f.balls.count == 5)
}

@Test func demoteTurnsAFigureBackIntoAStackOfBalls() {
    let f = field()
    let id = stand(f, x: 300)
    let ids = f.demote(id)!
    #expect(f.figures.isEmpty && f.balls.count == 3)
    #expect(ball(f, ids.top).parent != nil && ball(f, ids.top).radius == 10 && ball(f, ids.bottom).parent == nil)
    #expect(f.balls.allSatisfy { $0.state == .resting && $0.surfaceID == Tuning.groundID })
    advance(f, 1)
    #expect(f.figures.count == 1 && f.balls.isEmpty)   // the stack is still a snowman: it is promoted again
}

@Test func demoteFallingDropsTheWholeStack() {
    let f = field()
    let id = stand(f, x: 300)
    let ids = f.demote(id, falling: SIMD2(100, 0))!
    #expect(ball(f, ids.bottom).state == .falling && ball(f, ids.bottom).vel.x == 100 && f.balls.count == 3)
}

@Test func shatterBreaksAFigureIntoDebris() {
    let f = field()
    let id = stand(f, x: 300)
    let d0 = f.debris.count
    f.shatter(id, velocity: SIMD2(200, 0))
    #expect(f.figures.isEmpty && f.debris.count - d0 >= 3 * 4 + Int(1.5 * (20 + 14 + 10)))   // per ball: radius * 1.5 + 4 chunks
}

@Test func headlessFigureDemotesToTwoBalls() {
    let f = field()
    let a = stand(f, x: 300)
    f.decapitate(a, away: 1, range: nil)
    #expect(fig(f, a).headless && f.balls.count == 1)
    let ids = f.demote(a)!
    #expect(f.balls.count == 3 && ids.top != ids.bottom && ball(f, ids.top).radius == 14)
}

@Test func figureCountNeverExceedsTheCap() {
    let f = field()
    f.walkEnabled = false   // no fights: the ball count stays exact
    for x: Float in [100, 300, 500, 700, 900] { stackBalls(f, x: x) }
    var peak = 0
    for _ in 0..<(30 * 60) { f.step(dt: 1 / 60); peak = max(peak, f.figures.count) }
    #expect(peak == Tuning.maxFigures && !f.canSpawnFigure && f.balls.count == 6)   // the two extra stacks stay plain balls
    let g = field(h: Tuning.snowmanDepth + 4)
    for x: Float in [100, 300, 500] { stand(g, x: x) }
    advance(g, 5, fps: 20)
    #expect(g.figures.count == Tuning.maxFigures && g.figures.allSatisfy { $0.fromBalls })   // no auto snowman squeezed in
    #expect(g.promote(bottomBall: stackBalls(g, x: 700)) == nil)
}

@Test func figureOnAHiddenSpotDoesNotWalkAndReturnsWhenUncovered() {
    let f = field()
    let id = stand(f, x: 300)
    advance(f, 1)
    let x0 = fig(f, id).foot.x
    f.update(windows: [win(1, 250, 0, 100, 60)])   // hides ground x 250...350: the figure is under it
    advance(f, 20)
    #expect(fig(f, id).phase == .hidden && fig(f, id).foot.x == x0 && fig(f, id).motion.gait == 0)
    f.update(windows: [])
    advance(f, 0.2)
    #expect(fig(f, id).phase != .hidden)
}

@Test func hiddenFigureStaysOutOfFights() {
    let f = field()
    stand(f, x: 300); stand(f, x: 420)
    f.update(windows: [win(1, 380, 0, 100, 60)])   // hides the second one
    advance(f, 2)
    #expect(f.fights.isEmpty)
}

@Test func figureTravelsWithItsWindowAndFallsApartWhenKnockedOff() {
    let f = field([win(1, 200, 300, 300, 200)])
    windowTop(f, id: 1)
    let id = stand(f, x: 350, on: 1)
    advance(f, 1)
    f.update(windows: [win(1, 230, 300, 300, 200)], dt: 1)   // slow move: it rides along
    #expect(fig(f, id).at == .surface(id: 1, x: fig(f, id).foot.x) && fig(f, id).phase != .hidden)
    f.update(windows: [win(1, 800, 300, 300, 200)], dt: 0.05)   // fast move: knocked off
    #expect(f.figures.isEmpty && f.balls.count == 3 && f.balls.contains { $0.state == .falling })
    advance(f, 3)   // it lands on the ground as a stack again, which stands up as a figure
    let stack = f.figures.filter(\.fromBalls)
    #expect(stack.count == 1 && stack[0].surfaceID != nil && f.balls.isEmpty)   // it landed (on the moved window, in its way) and stands again
}

@Test func closingTheWindowDropsTheFigureAsBalls() {
    let f = field([win(1, 200, 300, 300, 200)])
    stand(f, x: 350, on: 1)
    f.update(windows: [], dt: 1)
    #expect(f.figures.isEmpty && f.balls.count == 3)
}

@Test func autoSnowmanOnAMovedWindowShattersOnlyWhenKnockedOff() {
    let f = field([win(1, 200, 300, 300, 200)])
    windowTop(f, id: 1, h: 16)
    let id = standAuto(f, x: 350, on: 1)
    f.update(windows: [win(1, 230, 300, 300, 200)], dt: 1)
    #expect(fig(f, id).phase != .collapsing)
    f.update(windows: [win(1, 900, 300, 300, 200)], dt: 0.05)
    #expect(fig(f, id).phase == .collapsing)
}

@Test func spaceSwitchRemovesFiguresOnVanishedWindowsButNotOnTheGround() {
    let f = field([win(1, 200, 300, 300, 200)])
    stand(f, x: 350, on: 1)
    let g = stand(f, x: 700)
    f.dropPiles(); f.markStale()
    #expect(f.figures.count == 2)   // not before the next snapshot
    f.update(windows: [])
    #expect(f.figures.map(\.id) == [g])
}

@Test func pickingAStackedSnowmansHeadDemotesItThenHoldsTheHead() {
    let f = field()
    let id = stand(f, x: 300)
    let head = f.anchors(of: fig(f, id)).head
    let held = f.pickSnowball(at: CGPoint(x: CGFloat(head.x), y: CGFloat(head.y)))
    #expect(held != nil && f.figures.isEmpty && f.balls.count == 3)
    #expect(ball(f, held!).state == .held && ball(f, held!).radius == 10 && ball(f, held!).parent == nil)
    // put it back: it stacks again and the snowman returns
    let mid = f.balls.first { $0.parent != nil }!
    f.drag(held!, to: CGPoint(x: CGFloat(mid.pos.x), y: CGFloat(mid.pos.y) + 100), dt: 1 / 60)
    f.drop(held!, throwing: false)
    advance(f, 2)
    #expect(f.figures.count == 1 && f.balls.isEmpty)
}

@Test func theBodyOfAFigureIsNotPickedAndTheAutoOneNeverIs() {
    let f = field()
    let id = stand(f, x: 300)
    let body = f.anchors(of: fig(f, id)).base
    #expect(f.pickSnowball(at: CGPoint(x: CGFloat(body.x), y: CGFloat(body.y))) == nil && f.figures.count == 1)
    let g = field()
    let auto = standAuto(g, x: 300)
    let head = g.anchors(of: fig(g, auto)).head
    #expect(g.pickSnowball(at: CGPoint(x: CGFloat(head.x), y: CGFloat(head.y))) == nil && g.figures.count == 1)
}

@Test func standingFiguresLeaveTheBallsAlone() {
    let f = field()
    stand(f, x: 300); stand(f, x: 700)
    advance(f, 1)
    let before = f.balls
    advance(f, 20)
    #expect(f.balls == before)
}

@Test func looseBallsBounceOffAStandingFigure() {
    let f = field()
    let id = stand(f, x: 300)
    let top = f.anchors(of: fig(f, id)).head
    let b = f.scoop(at: CGPoint(x: 600, y: 8))!
    f.balls[f.balls.firstIndex { $0.id == b }!].radius = 6
    f.drag(b, to: CGPoint(x: CGFloat(top.x), y: CGFloat(top.y) + 80), dt: 1 / 60)
    f.drop(b, throwing: false)
    advance(f, 3)
    #expect(ball(f, b).parent == nil && f.figures.count == 1)
}

@Test func lookDataExposesWhatARendererNeeds() {
    let f = field()
    let id = stand(f, x: 300)
    advance(f, 0.27)   // a promoted stack eases its details in first
    let l = f.look(of: fig(f, id))
    #expect(abs(l.foot.y - (fig(f, id).foot.y - 0.2 * 20)) < 0.001 && l.foot.x == 300 && l.radii == SIMD3(20, 14, 10) && l.built == 7 && l.newest >= 0 && l.newest <= 1)
    #expect(!l.collapsing && !l.headless && l.fade == 1 && l.droop == 0)
    advance(f, 1)
    #expect(f.look(of: fig(f, id)).newest == 1)
}

@Test func heavyFiguresAreDeterministic() {
    func world() -> SnowField {
        let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 11)
        f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 171, y: 10, width: 1098, height: 84), radius: 25)])
        f.stage(.heavy)
        advance(f, 30, fps: 30)
        return f
    }
    let a = world(), b = world()
    #expect(a.figures.map(\.foot) == b.figures.map(\.foot) && a.figures.map(\.phase) == b.figures.map(\.phase))
    #expect(a.balls.map(\.pos) == b.balls.map(\.pos) && a.figures.count == 3)
}
