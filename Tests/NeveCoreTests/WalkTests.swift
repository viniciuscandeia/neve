import CoreGraphics
import Testing
@testable import NeveCore

private func field(_ windows: [WindowInfo] = []) -> SnowField {
    let f = makeField()
    f.update(windows: windows)
    let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in 0..<500 { f.surfaces[i].pile.heights[b] = 12 }
    return f
}

private func run(_ f: SnowField, _ s: Float) { for _ in 0..<Int(s * 60) { f.step(dt: 1 / 60) } }

private func ready(_ f: SnowField) { run(f, 0.6) }

@Test func figureStaysInsideItsStretchAndTurnsAround() {
    let f = field([win(1, 450, 0, 600, 60)])   // hides the ground from x = 450 on
    let id = stand(f, x: 300)
    ready(f)
    var lo = Float.infinity, hi = -Float.infinity, turns = 0, dir = fig(f, id).facing
    for _ in 0..<(90 * 60) {
        f.step(dt: 1 / 60)
        let w = fig(f, id)
        lo = min(lo, w.foot.x); hi = max(hi, w.foot.x)
        if w.facing != dir { turns += 1; dir = w.facing }
    }
    #expect(lo >= 20 + 8 - 0.5 && hi <= 450 - 20 - 8 + 0.5)   // half width + margin from the screen edge / covering window
    #expect(hi - lo > 100 && turns >= 1)
    #expect(fig(f, id).phase != .hidden && fig(f, id).at == .surface(id: Tuning.groundID, x: fig(f, id).foot.x))   // never walked off
}

@Test func standingStackBecomesWalkingAfterThreeTenths() {
    let f = field()
    let id = stand(f, x: 300)
    f.figures[0].motion.nextIdle = 100   // no pauses
    #expect(fig(f, id).phase == .idle && fig(f, id).fromBalls)
    run(f, 0.25)
    #expect(fig(f, id).foot.x == 300 && fig(f, id).phase == .idle)
    run(f, 0.3)
    #expect(fig(f, id).foot.x != 300 && fig(f, id).phase == .walking)
}

@Test func figuresMoveWithTheirWindow() {
    let f = field([win(1, 200, 300, 400, 200)])
    let id = stand(f, x: 400, on: 1)
    ready(f)
    let x0 = fig(f, id).foot.x
    f.update(windows: [win(1, 250, 300, 400, 200)], dt: 1)
    #expect(abs(fig(f, id).foot.x - (x0 + 50)) < 1)
    run(f, 1)
    #expect(fig(f, id).at == .surface(id: 1, x: fig(f, id).foot.x) && fig(f, id).phase != .hidden)
}

@Test func noWalkingWithReduceMotionOrWhenSwitchedOff() {
    for calm in [true, false] {
        let f = field()
        let id = stand(f, x: 300)
        let auto = standAuto(f, x: 700)
        if calm { f.setCalm(true) } else { f.walkEnabled = false }
        run(f, 20)
        for k in [id, auto] {   // static pose, only idle / building phases
            #expect(fig(f, k).foot.x == (k == id ? 300 : 700) && fig(f, k).phase == .idle && fig(f, k).pose == Pose())
        }
        #expect(f.fights.isEmpty && f.shots.isEmpty)
    }
}

@Test func autoSnowmanWalks() {
    let f = field()
    let id = standAuto(f, x: 300)
    run(f, 20)
    #expect(fig(f, id).foot.x != 300 && fig(f, id).foot.x > 19 && fig(f, id).foot.x < 981)
}

// MARK: Wind

@Test func walkingAgainstTheWindIsSlowerThanWithIt() {
    func walked(_ g: Float) -> Float {   // distance walked along its heading in 2 s; gust sign relative to the heading
        let f = field()
        let id = stand(f, x: 500)
        ready(f)
        f.figures[0].motion.nextIdle = 100   // no pauses
        let dir = fig(f, id).facing, x0 = fig(f, id).foot.x
        f.gustOverride = g * dir
        run(f, 2)
        return (fig(f, id).foot.x - x0) * dir
    }
    let against = walked(-1), calm = walked(0), with = walked(1)
    #expect(against < calm * 0.2 && with > calm && with <= calm * 1.5 + 0.5)
}

@Test func windNeverPushesAWalkerPastTheEnds() {
    for g: Float in [1, -1] {
        let f = field([win(1, 450, 0, 600, 60)])
        let id = stand(f, x: 300)
        f.gustOverride = g
        var lo = Float.infinity, hi = -Float.infinity
        for _ in 0..<(120 * 30) { f.step(dt: 1 / 30); let x = fig(f, id).foot.x; lo = min(lo, x); hi = max(hi, x) }
        #expect(lo >= 27.5 && hi <= 450 - 28 + 0.5 && fig(f, id).phase != .hidden)
    }
}

@Test func lightBreezesDoNotMoveSnowmenButNevascaGustsDo() {
    for level in [Intensity.leve, .media] {
        let f = field()
        f.setIntensity(level, immediate: true)
        var peak: Float = 0
        for _ in 0..<(40 * 10) { f.step(dt: 1 / 10); peak = max(peak, abs(f.gust)) }
        #expect(peak == 0)
    }
    let f = field()
    f.setIntensity(.nevasca, immediate: true)
    var peak: Float = 0
    for _ in 0..<(90 * 10) { f.step(dt: 1 / 10); peak = max(peak, abs(f.gust)) }
    #expect(peak > 0.3)
}

@Test func snowmenDoNotWalkThroughEachOther() {
    let f = field()
    let a = stand(f, x: 300), b = stand(f, x: 360)
    ready(f)
    f.fights.removeAll()
    for i in f.figures.indices { f.figures[i].fight = nil; f.figures[i].motion.rest = 1e6; f.figures[i].motion.nextIdle = 1e6 }
    var closest = Float.infinity
    for _ in 0..<(60 * 30) { f.step(dt: 1 / 30); closest = min(closest, abs(fig(f, a).foot.x - fig(f, b).foot.x)) }
    #expect(closest >= 20 + 20 - 1)   // never closer than the two base balls touching
}

@Test func scarfFlutterGrowsWithWindAndStreamsDownwind() {
    func peak(_ g: Float) -> Float {   // largest wave of the lower tail over a flutter cycle
        (0..<64).map { abs(Flutter.make(gust: g, gait: 0, dir: 1, phase: Float($0) * 0.1, cheer: 0).wave) }.max()!
    }
    #expect(peak(1) > peak(0) * 2 && peak(0) > 0)   // calm air still flutters a little
    #expect(Flutter.rate(gust: 1, gait: 0) > Flutter.rate(gust: 0, gait: 0) && Flutter.rate(gust: 0, gait: 1) > Flutter.rate(gust: 0, gait: 0))
    for g: Float in [1, -1] {
        let p = Flutter.make(gust: g, gait: 0, dir: 1, phase: 0, cheer: 0)
        #expect(p.scarf * g > 1 && p.sway * g < 0)   // tail streams downwind (> 57 degrees), arms bend with it
    }
}

@Test func armsRaiseDuringTheCheerAndRestAfterwards() {
    func up(_ cheer: Float) -> Float { Flutter.make(gust: 0, gait: 0, dir: 1, phase: 0, cheer: cheer).up }
    #expect(up(0) == 0 && up(Tuning.cheerTime) == 0)
    #expect(up(1) == 1 && up(0.1) < 1)   // full V mid-cheer, lowering at the end
    let f = field()
    let a = stand(f, x: 300), b = stand(f, x: 420)
    run(f, 1)
    for _ in 0..<3 { f.registerHit(b, head: true) }
    run(f, 1)
    #expect(fig(f, a).pose.flutter.up > 0.9 && fig(f, a).phase == .cheering && fig(f, b).pose.flutter.up == 0)
    run(f, 3)
    #expect(fig(f, a).pose.flutter.up == 0 && fig(f, a).phase != .cheering)
}
