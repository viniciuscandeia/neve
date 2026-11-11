// AGENT HEADER - Tests/NeveCoreTests/ActorFixesTests.swift  (regression tests from the actor review; Swift Testing, `@testable import NeveCore`, seeded, no I/O)
// Covers: ending fights leaves no frozen fighters, covered snowmen fade out/in, headless auto snowman collapses so a new one builds, rabbit / robin hops ride a moving window, visitors fade instead of vanishing, Space stash keeps user snowmen / balls / gifts,
// fights do not cross hidden gaps, carrot fetch stays on its stretch, promoted stacks ease details in, shots follow moved targets and splats outlive their figure, facing turns over a few frames. Helpers: FigureHelpers.swift (stand / standAuto / advance) and makeField / win / pileUp in SurfaceMapTests.swift. Run: Tests/run.sh [-r] ActorFixes.

import CoreGraphics
import Testing
@testable import NeveCore

// Actor review fixes: fights, hiding, headless auto snowman, window moves, visitor fades, Space stash, shots / splats.

private func field(_ windows: [WindowInfo] = [], h: Float = 12) -> SnowField {
    let f = makeField()
    f.update(windows: windows)
    for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = h } }
    return f
}

private func rabbit(_ f: SnowField) -> Figure? { f.figures.first { $0.kind == .rabbit } }

@Test func endingFightsLeavesNoFrozenFighters() {
    let f = field()
    stand(f, x: 300); stand(f, x: 420)
    advance(f, 1)
    #expect(f.fights.count == 1)
    f.walkEnabled = false   // walking off wipes the fights ...
    f.step(dt: 1 / 60)
    #expect(f.fights.isEmpty && f.figures.allSatisfy { $0.fight == nil && $0.phase != .fighting })
    let g = field()
    stand(g, x: 300); stand(g, x: 420)
    advance(g, 1)
    g.beginMelt(duration: 20)   // ... and so does the melt
    #expect(g.fights.isEmpty && g.figures.allSatisfy { $0.fight == nil })
}

@Test func snowmanCoveredByAWindowEdgeFadesOutAndBackIn() {
    let f = field([win(1, 330, 0, 200, 300)])   // hides the ground from x = 330
    for b in 0..<500 { f.surfaces[f.index[Tuning.groundID]!].pile.heights[b] = 12 }
    let id = stand(f, x: 320)   // centre column visible, the right half of the body is not
    advance(f, 0.1)
    #expect(f.look(of: fig(f, id)).fade < 1)
    advance(f, 0.5)
    #expect(fig(f, id).phase == .hidden)
    f.update(windows: [])
    advance(f, 0.05)
    #expect(fig(f, id).phase != .hidden && f.look(of: fig(f, id)).fade < 1)   // eases in
    advance(f, 0.5)
    #expect(f.look(of: fig(f, id)).fade == 1)
}

@Test func beheadedAutoSnowmanCollapsesSoANewOneCanBeBuilt() {
    let f = field()
    let id = standAuto(f, x: 300)
    f.decapitate(id, away: 1, range: nil)
    advance(f, 20)
    #expect(f.figures.contains { $0.id == id })
    advance(f, 8)
    #expect(!f.figures.contains { $0.id == id })
}

@Test func rabbitHopsRideTheirMovingWindow() {
    let f = field([win(1, 200, 300, 500, 200)])
    f.visitorsEnabled = true
    stand(f, x: 450, on: 1)
    advance(f, 0.5)
    #expect(f.startRabbit())
    for _ in 0..<600 { f.step(dt: 1 / 60); if rabbit(f)?.critter.hopping == true { break } }
    let x0 = rabbit(f)!.foot.x
    f.update(windows: [win(1, 230, 300, 500, 200)], dt: 1)
    f.step(dt: 1 / 60)
    #expect(abs(rabbit(f)!.foot.x - (x0 + 30)) < 6)
}

@Test func robinFlightAndHopsRideTheirMovingWindow() {
    let g = field([win(1, 200, 300, 500, 200)])
    #expect(g.startRobin())
    g.step(dt: 1 / 60)
    let to0 = g.figures.first { $0.kind == .robin }!.robin.to.x
    g.update(windows: [win(1, 210, 300, 500, 200)], dt: 1)
    #expect(abs(g.figures.first { $0.kind == .robin }!.robin.to.x - (to0 + 10)) < 0.01)   // the flight target moves with the window
    for _ in 0..<2400 { g.step(dt: 1 / 60); if let r = g.figures.first(where: { $0.kind == .robin }), r.robin.stage == .hop, r.robin.hopping { break } }
    let r0 = g.figures.first { $0.kind == .robin }!.foot.x
    g.update(windows: [win(1, 220, 300, 500, 200)], dt: 1)
    g.step(dt: 1 / 60)
    #expect(abs(g.figures.first { $0.kind == .robin }!.foot.x - (r0 + 10)) < 3)
}

@Test func visitorsFadeOutInsteadOfVanishing() {
    let f = field([win(1, 200, 300, 500, 200)])
    f.visitorsEnabled = true
    stand(f, x: 450, on: 1)
    advance(f, 0.5)
    #expect(f.startRabbit())
    advance(f, 0.5)
    f.update(windows: [], dt: 1)   // the window closes
    f.step(dt: 1 / 60)
    #expect(rabbit(f) != nil && f.rabbitLook(of: rabbit(f)!).fade < 1)
    advance(f, 0.5)
    #expect(rabbit(f) == nil)

    let g = field()
    g.visitorsEnabled = true
    stand(g, x: 450)
    advance(g, 0.5)
    #expect(g.startRabbit())
    advance(g, 0.5)
    g.walkEnabled = false
    g.step(dt: 1 / 60)
    #expect(rabbit(g) != nil)
    advance(g, 0.5)
    #expect(rabbit(g) == nil)
}

@Test func spaceSwitchKeepsUserSnowmenBallsAndGiftsOfAStashedWindow() {
    let f = makeField()
    f.update(windows: [back])
    pileUp(f, id: 1)
    let g = stand(f, x: 150, on: 1)
    stackBalls(f, x: 300, on: 1)
    f.giftState.gifts.append(Gift(pos: SIMD2(200, 420), vel: .zero, surface: 1, rot: 0, spin: 0, color: 0, scale: 1))
    f.dropPiles(); f.markStale()
    f.update(windows: [], now: 1)
    #expect(f.figures.isEmpty && f.balls.isEmpty && f.gifts.isEmpty)
    f.update(windows: [win(1, 500, 200, 300, 200)], now: 2)   // back, 400pt to the right
    #expect(f.figures.map(\.id) == [g] && abs(fig(f, g).foot.x - 550) < 0.01)
    #expect(f.balls.count == 3 && abs(f.balls[0].pos.x - 700) < 0.01 && f.gifts.count == 1)
}

@Test func fightsDoNotReachAcrossAHiddenGap() {
    let f = field([win(1, 340, 0, 40, 100)])   // a window hides the ground between them
    for b in 0..<500 { f.surfaces[f.index[Tuning.groundID]!].pile.heights[b] = 12 }
    stand(f, x: 300); stand(f, x: 420)
    advance(f, 1)
    #expect(f.fights.isEmpty)
}

@Test func carrotFetchStaysOnTheStretchAndIsForgottenWhenCarrotsAreCleared() {
    let f = field([win(1, 340, 0, 200, 100)])   // hides the ground from x = 340
    for b in 0..<500 { f.surfaces[f.index[Tuning.groundID]!].pile.heights[b] = 12 }
    let id = stand(f, x: 300)
    let i = f.figureIndex(id)!
    f.figures[i].carrot = false; f.figures[i].critter.regrow = 60; f.figures[i].critter.fetchX = 450
    advance(f, 4)
    #expect(fig(f, id).foot.x <= 313)   // runs to the end of its stretch, not under the window
    f.beginMelt(duration: 20)
    #expect(fig(f, id).critter.fetchX == nil)

    let g = field([win(1, 200, 300, 500, 200)])
    let h = stand(g, x: 300, on: 1)
    g.figures[g.figureIndex(h)!].carrot = false
    g.carrots.append(Carrot(pos: SIMD2(600, 330), vel: .zero, surface: 1, owner: h, size: 1))
    g.update(windows: [win(1, 230, 300, 500, 200)], dt: 1)
    #expect(abs(g.carrots[0].pos.x - 630) < 0.01)
}

@Test func promotedStackEasesItsDetailsIn() {
    let f = field()
    let id = stand(f, x: 300)
    #expect(f.look(of: fig(f, id)).built < Snowman.stageCount)
    advance(f, 0.4)
    #expect(f.look(of: fig(f, id)).built == Snowman.stageCount)
}

@Test func shotsFollowAMovedTargetAndSplatsOutliveTheirFigure() {
    let f = field()
    let a = stand(f, x: 300), b = stand(f, x: 420)
    var target = -1
    for _ in 0..<(40 * 60) {
        f.step(dt: 1 / 60)
        if let s = f.shots.first(where: { $0.hit && !$0.impacting && $0.target >= 0 }) { target = s.target; break }
    }
    #expect(target == a || target == b)
    let t0 = f.shotLand?.t
    f.figures[f.figureIndex(target)!].foot.x += 40
    for _ in 0..<120 { f.step(dt: 1 / 60); if f.shotLand?.t != t0 { break } }
    #expect(f.shotLand?.t != t0 && abs(f.shotLand!.p.x - fig(f, target).foot.x) < 15)
    let splat = f.splats.first { $0.target == target }
    #expect(splat != nil)
    f.removeFigure(f.figureIndex(target)!)
    #expect(f.position(of: splat!) != nil)
}

@Test func facingTurnsOverAFewFramesInsteadOfFlipping() {
    let f = field()
    let id = stand(f, x: 500)
    let i = f.figureIndex(id)!
    f.figures[i].facing = 1
    advance(f, 0.2)   // settled facing right (still standing: it walks from 0.3 s)
    f.figures[i].facing = -1
    f.step(dt: 1 / 60)
    let mid = f.look(of: fig(f, id)).facing
    #expect(mid > -1 && mid < 1)
    advance(f, 0.2)
    #expect(f.look(of: fig(f, id)).facing == fig(f, id).facing)
}
