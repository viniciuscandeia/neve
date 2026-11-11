// AGENT HEADER - Tests/NeveCoreTests/SnowballTests.swift  (Snowball.swift; ground pile at height h over x 100...800)
// scoop takes volume from the pile (no snow = no ball), rolling grows the ball (<= ballMax) and lowers the pile, carrying through the air does not grow, a dropped ball falls and rests, a smaller ball stacks on a bigger one (off-centre rolls off, bigger on
//   smaller does not stack), three decreasing balls promote to a user figure (two do not; a fourth cannot join), balls ride a slowly moving window / fall when it closes or moves fast, a cursor sweep breaks balls and a stacked snowman whole, `clear()`
//   removes balls and the oldest melts beyond Tuning.maxBalls, hitTest / pickSnowball, a ball landing while the drawn pile is still easing does not snap.

import CoreGraphics
import Testing
@testable import NeveCore

/// Ground piled to `h` over x 100...800.
private func snowy(_ h: Float = 12) -> SnowField {
    let f = makeField()
    f.update(windows: [])
    let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in 50...400 { f.surfaces[i].pile.heights[b] = h }
    return f
}

private func volume(_ f: SnowField, _ id: Int = Tuning.groundID) -> Float { f.pile(id: id)!.heights.reduce(0, +) }
private func run(_ f: SnowField, _ s: Float) { for _ in 0..<Int(s * 60) { f.step(dt: 1 / 60) } }

/// Scoops at the pile (x, y), sets the radius, lifts it to `at` and drops it.
@discardableResult
private func dropBall(_ f: SnowField, scoop p: CGPoint, r: Float, at: CGPoint) -> Int {
    let id = f.scoop(at: p)!
    f.balls[f.balls.firstIndex { $0.id == id }!].radius = r
    f.drag(id, to: at, dt: 1 / 60)
    f.balls[f.balls.firstIndex { $0.id == id }!].vel = .zero   // the teleport above is not a throw
    f.drop(id)
    return id
}

@Test func scoopTakesVolumeFromThePile() {
    let f = snowy(), v = volume(f)
    let id = f.scoop(at: CGPoint(x: 300, y: 8))
    #expect(id != nil && ball(f, id!).radius == Tuning.ballStart && ball(f, id!).state == .held)
    #expect(volume(f) < v - 15)
    #expect(snowy(0).scoop(at: CGPoint(x: 300, y: 2)) == nil)   // no snow, no ball
}

@Test func rollingAlongThePileGrowsTheBallAndLowersThePile() {
    let f = snowy(), v = volume(f)
    let id = f.scoop(at: CGPoint(x: 200, y: 8))!
    for k in 0..<40 { f.drag(id, to: CGPoint(x: 200 + 2 * CGFloat(k), y: 8), dt: 1 / 60) }
    let b = ball(f, id)
    #expect(b.radius > Tuning.ballStart + 3 && b.radius <= Tuning.ballMax)
    #expect(b.rotation < -3)
    #expect(volume(f) < v - 150)
    for k in 0..<400 { f.drag(id, to: CGPoint(x: 200 + 2 * CGFloat(k % 300), y: 8), dt: 1 / 60) }
    #expect(ball(f, id).radius <= Tuning.ballMax)
}

@Test func carryingThroughTheAirDoesNotGrow() {
    let f = snowy()
    let id = f.scoop(at: CGPoint(x: 200, y: 8))!
    for k in 0..<40 { f.drag(id, to: CGPoint(x: 200 + 2 * CGFloat(k), y: 200), dt: 1 / 60) }
    #expect(ball(f, id).radius == Tuning.ballStart)
}

@Test func droppedBallFallsAndRestsOnTheGround() {
    let f = snowy()
    let id = dropBall(f, scoop: CGPoint(x: 300, y: 8), r: 10, at: CGPoint(x: 300, y: 300))
    run(f, 2)
    let b = ball(f, id)
    #expect(b.state == .resting && b.surfaceID == Tuning.groundID && b.parent == nil && b.pos.y < 40)
}

@Test func smallerBallDroppedOnABiggerOneStacks() {
    let f = snowy()
    let a = dropBall(f, scoop: CGPoint(x: 300, y: 8), r: 14, at: CGPoint(x: 300, y: 300))
    run(f, 2)
    let b = dropBall(f, scoop: CGPoint(x: 400, y: 8), r: 9, at: CGPoint(x: 303, y: 300))
    run(f, 2)
    #expect(ball(f, b).parent == a && ball(f, b).pos.y > ball(f, a).pos.y + 14)
}

@Test func offCenterBallRollsOffToTheGround() {
    let f = snowy()
    let a = dropBall(f, scoop: CGPoint(x: 300, y: 8), r: 14, at: CGPoint(x: 300, y: 300))
    run(f, 2)
    let b = dropBall(f, scoop: CGPoint(x: 500, y: 8), r: 9, at: CGPoint(x: 311, y: 300))   // 0.8 radius off
    run(f, 3)
    #expect(ball(f, b).parent == nil && ball(f, b).state == .resting && ball(f, b).surfaceID == Tuning.groundID)
    #expect(abs(ball(f, b).pos.x - ball(f, a).pos.x) > 14)
}

@Test func biggerBallDoesNotStackOnASmallerOne() {
    let f = snowy()
    dropBall(f, scoop: CGPoint(x: 300, y: 8), r: 9, at: CGPoint(x: 300, y: 300))
    run(f, 2)
    let b = dropBall(f, scoop: CGPoint(x: 500, y: 8), r: 14, at: CGPoint(x: 300, y: 300))
    run(f, 3)
    #expect(ball(f, b).parent == nil)
}

private func stack(_ f: SnowField, _ radii: [Float]) -> [Int] {
    var ids: [Int] = []
    for (k, r) in radii.enumerated() {
        ids.append(dropBall(f, scoop: CGPoint(x: 400 + 40 * CGFloat(k), y: 8), r: r, at: CGPoint(x: 300, y: 300)))
        run(f, 2)
    }
    return ids
}

@Test func threeDecreasingBallsFormAFigureAndTwoDoNot() {
    let f = snowy()
    _ = stack(f, [16, 11])
    #expect(f.figures.isEmpty && f.balls.count == 2)
    let g = snowy()
    let j = stack(g, [16, 11, 7])
    #expect(g.balls.isEmpty && g.figures.count == 1)   // the stack was promoted: its three balls became one figure
    let m = g.figures[0]
    #expect(m.fromBalls && m.radii == SIMD3(16, 11, 7) && m.at == .surface(id: Tuning.groundID, x: m.foot.x) && j.count == 3)
}

@Test func fourthBallCannotJoinTheStack() {
    let f = snowy()
    _ = stack(f, [16, 11, 7])
    let d = dropBall(f, scoop: CGPoint(x: 600, y: 8), r: 5, at: CGPoint(x: 300, y: 300))
    run(f, 3)
    #expect(ball(f, d).parent == nil && f.figures.count == 1 && f.balls.count == 1)
}

@Test func windowCloseKnocksBallsOffAndMovingTransportsThem() {
    let f = makeField()
    f.update(windows: [win(1, 200, 300, 300, 200)])
    let w = f.surfaces.firstIndex { $0.id == 1 }!
    for b in f.surfaces[w].pile.heights.indices { f.surfaces[w].pile.heights[b] = 12 }
    let id = dropBall(f, scoop: CGPoint(x: 350, y: 505), r: 8, at: CGPoint(x: 350, y: 700))
    run(f, 2)
    #expect(ball(f, id).surfaceID == 1 && ball(f, id).state == .resting)
    f.update(windows: [win(1, 230, 300, 300, 200)], dt: 1)   // slow move: it rides along
    #expect(abs(ball(f, id).pos.x - 380) < 0.01 && ball(f, id).surfaceID == 1)
    f.update(windows: [], dt: 1)
    #expect(ball(f, id).state == .falling)
    run(f, 3)
    #expect(ball(f, id).surfaceID == Tuning.groundID)
}

@Test func fastWindowMoveKnocksBallsOff() {
    let f = makeField()
    f.update(windows: [win(1, 200, 300, 300, 200)])
    let w = f.surfaces.firstIndex { $0.id == 1 }!
    for b in f.surfaces[w].pile.heights.indices { f.surfaces[w].pile.heights[b] = 12 }
    let id = dropBall(f, scoop: CGPoint(x: 350, y: 505), r: 8, at: CGPoint(x: 350, y: 700))
    run(f, 2)
    f.update(windows: [win(1, 800, 300, 300, 200)], dt: 0.05)
    #expect(ball(f, id).state == .falling)
}

@Test func sweepBreaksBallsAndASnowmanBreaksWhole() {
    let f = snowy()
    let id = dropBall(f, scoop: CGPoint(x: 300, y: 8), r: 10, at: CGPoint(x: 300, y: 300))
    run(f, 2)
    let d0 = f.debris.count, y = CGFloat(ball(f, id).pos.y)
    f.sweep(from: CGPoint(x: 250, y: y), to: CGPoint(x: 350, y: y), radius: 10)
    #expect(f.balls.isEmpty && f.debris.count - d0 >= 10)
    let g = snowy()
    _ = stack(g, [16, 11, 7])
    let hy = CGFloat(g.anchors(of: g.figures[0]).head.y), d1 = g.debris.count
    g.sweep(from: CGPoint(x: 250, y: hy), to: CGPoint(x: 350, y: hy), radius: 10)
    #expect(g.balls.isEmpty && g.figures.isEmpty && g.debris.count - d1 >= 30)   // the figure breaks whole, a few chunks per ball
}

@Test func clearRemovesBallsAndOldestMeltsBeyondTheCap() {
    let f = snowy()
    for k in 0..<(Tuning.maxBalls + 2) {
        let id = f.scoop(at: CGPoint(x: 150 + 90 * CGFloat(k), y: 8))!
        f.drop(id)
    }
    run(f, 2)
    #expect(f.balls.count == Tuning.maxBalls)
    f.clear()
    #expect(f.balls.isEmpty)
}

@Test func hitTestFindsSnowAndBallsOnly() {
    let f = snowy()
    #expect(f.hitTest(point: CGPoint(x: 300, y: 10)))
    #expect(!f.hitTest(point: CGPoint(x: 300, y: 200)))
    #expect(!f.hitTest(point: CGPoint(x: 900, y: 5)))
    let id = dropBall(f, scoop: CGPoint(x: 300, y: 8), r: 10, at: CGPoint(x: 300, y: 300))
    run(f, 2)
    let b = ball(f, id)
    #expect(f.hitTest(point: CGPoint(x: Double(b.pos.x), y: Double(b.pos.y) + 12)))
    #expect(f.pickSnowball(at: CGPoint(x: Double(b.pos.x), y: Double(b.pos.y))) == id)
    let g = snowy()
    stand(g, x: 300)
    let a = g.anchors(of: g.figures[0])
    #expect(g.hitTest(point: CGPoint(x: CGFloat(a.head.x), y: CGFloat(a.head.y) + 12)))   // a stacked snowman is interactive too
}

@Test func ballLandingWhileThePileEasesDoesNotSnapDown() {
    let f = snowy(12)
    let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    f.surfaces[i].pile.shown = f.surfaces[i].pile.heights.map { $0 * 0.1 }   // drawn snow still low: heights just jumped
    let id = dropBall(f, scoop: CGPoint(x: 300, y: 8), r: 8, at: CGPoint(x: 600, y: 60))
    let k = f.balls.firstIndex { $0.id == id }!
    f.balls[k].pos = [700, 12 + 8 * SnowField.sink + 0.01]   // just above the real pile top, away from the groove
    let y0 = ball(f, id).pos.y
    f.step(dt: 1 / 60)
    #expect(ball(f, id).pos.y > y0 - 1)   // it keeps falling toward the drawn surface instead of teleporting onto it
    run(f, 1)
    let b = ball(f, id)
    let want: Float = f.standY(si: i, x: b.pos.x) + b.radius * SnowField.sink
    #expect(abs(b.pos.y - want) < 0.01)
}
