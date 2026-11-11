// AGENT HEADER - Tests/NeveCoreTests/ClimbTests.swift  (snowmen hopping between the ground bank and the Dock top)
// Scene: floating Dock bar x 500...900, top y = 90; hand-built ground banks beside the bar ends (flat 40 pt then 0.3 slope) and a Dock-top pile. Covers: climb up a full bank and walk the Dock, hop arc with squash and facing, a low bank turns back, step back down, the AUTO snowman never lands on a bare Dock.
// Related code: Walk.swift (transfer/hopStep, Tuning.stepMax/stepGap), DockPush.swift (bank).

import CoreGraphics
import Testing
@testable import NeveCore

/// Floating Dock bar x 500...900, top at y=90. Ground banks (by hand) up to `bank` at both bar ends, flat for 40pt, then sloping away at 0.3; Dock top carries `dockSnow`.
private func climbField(bank: Float, dockSnow: Float = 3, seed: UInt64 = 5) -> SnowField {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 0, visibleTop: 880, flakeCount: 0, seed: seed)
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 500, y: 10, width: 400, height: 80), radius: 20)])
    let g = f.index[Tuning.groundID]!, d = f.index[0]!
    for b in f.surfaces[g].pile.heights.indices {
        let x = (Float(b) + 0.5) * Tuning.binWidth, dist = max(500 - x, x - 900, 0)
        f.surfaces[g].pile.heights[b] = max(12, bank - 0.3 * max(dist - 40, 0))
    }
    for b in f.surfaces[d].pile.heights.indices { f.surfaces[d].pile.heights[b] = dockSnow }
    return f
}

private func prep(_ f: SnowField, _ id: Int, facing: Float) {
    let i = f.figureIndex(id)!
    f.figures[i].facing = facing; f.figures[i].motion.nextIdle = 1e6; f.figures[i].motion.speed = Tuning.walkSpeed
}

/// Steps for `s` seconds; returns whether the figure was ever on surface `sid`, and the x range seen there.
private func watch(_ f: SnowField, _ id: Int, seconds: Float, on sid: Int) -> (seen: Bool, lo: Float, hi: Float) {
    var seen = false, lo = Float.infinity, hi = -Float.infinity
    for _ in 0..<Int(seconds * 60) {
        f.step(dt: 1 / 60)
        let q = fig(f, id)
        #expect(q.phase != .hidden)
        if q.surfaceID == sid, q.motion.xfer == nil { seen = true; lo = min(lo, q.foot.x); hi = max(hi, q.foot.x) }
    }
    return (seen, lo, hi)
}

@Test func snowmanClimbsFromAFullBankOntoTheDockAndWalksThere() {
    for auto in [false, true] {
        let f = climbField(bank: 88)
        let id = auto ? standAuto(f, x: 440) : stand(f, x: 440)
        prep(f, id, facing: 1)
        let r = watch(f, id, seconds: 30, on: 0)
        #expect(r.seen && r.hi - r.lo > 100 && r.lo >= 500 && r.hi <= 900)
    }
}

@Test func hopArcsWithSquashAndKeepsFacing() {
    let f = climbField(bank: 88)
    let id = stand(f, x: 440)
    prep(f, id, facing: 1)
    var maxHop: Float = 0, squashed = false, wasHopping = false
    for _ in 0..<(30 * 60) {
        f.step(dt: 1 / 60)
        let q = fig(f, id)
        if q.motion.xfer != nil { wasHopping = true; #expect(q.facing == 1); maxHop = max(maxHop, q.pose.hop) }
        if wasHopping, q.surfaceID == 0, q.pose.squash > 0.01 { squashed = true; break }
    }
    #expect(maxHop > 3 && squashed)
}

@Test func lowBankTurnsBack() {
    let f = climbField(bank: 40)
    let id = stand(f, x: 440)
    prep(f, id, facing: 1)
    let r = watch(f, id, seconds: 40, on: 0)
    #expect(!r.seen && fig(f, id).foot.x < 500)
}

@Test func snowmanStepsBackDownToTheGround() {
    let f = climbField(bank: 88)
    let id = stand(f, x: 700, on: 0)
    prep(f, id, facing: 1)
    var down = false
    for _ in 0..<(40 * 60) {
        f.step(dt: 1 / 60)
        let q = fig(f, id)
        if q.surfaceID == Tuning.groundID { down = true; #expect(q.foot.x >= 900) ; break }
    }
    #expect(down)
}

@Test func autoSnowmanNeverLandsOnBareDock() {
    let f = climbField(bank: 88, dockSnow: 0)
    let id = standAuto(f, x: 440)
    prep(f, id, facing: 1)
    let r = watch(f, id, seconds: 40, on: 0)
    #expect(!r.seen)
}
