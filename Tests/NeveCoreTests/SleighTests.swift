// AGENT HEADER - Tests/NeveCoreTests/SleighTests.swift  (Figures+Sleigh.swift + Gifts.swift + CursorThrow.swift)
// Cadence via a director-only clock (`starts(...)`: sleighInterval / sleighChance follow the calendar: Dec 24-25 ~10 min, rest of December 45 min, otherwise 3 h; off with the pref / compact mode / economy / Reduce Motion; cooldown and the one-big-event cap),
//   then 1/60 s integration of the crossing (140 pt/s, top of the screen, bobbing, direction follows the wind), gift drops (<= 3, land sunk 30 % in piles, fade after 90 s; giftTravel must match stepGifts), a cursor sweep pops a gift into confetti,
//   Option-click opens a gift once (glints, flying lid), gifts on a closed window fall or travel, prim budget of the team. "Cursor snowball" section: with Option held and the cursor still, a complete snowman within 300 pt throws 3 balls 2 s apart per hold
//   (0.3 s arm raise, ~70 % aimed hits that leave a 14 pt splat lasting 1.5 s), none over snow, out of range, while the cursor moves, after release, in calm, outside the live strip in compact mode, or for an incomplete snowman.

import CoreGraphics
import Testing
@testable import NeveCore

private func field(day: (Int, Int) = (12, 24), speed: Float = 1, seed: UInt64 = 1, windows: [WindowInfo] = []) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0,
                      config: SimConfig(directorSpeed: speed), seed: seed)
    f.update(windows: windows)
    for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = 12 } }
    f.sleighEnabled = true
    f.calendarDay = (month: day.0, day: day.1)
    return f
}

private func sleighs(_ f: SnowField) -> [Figure] { f.figures.filter { $0.kind == .sleigh } }

/// Director-only clock: ticks `stepDirector` once per simulated second with a hand-advanced `time` (the director's own 1 Hz cadence) and
/// ends each sleigh after a 14 s crossing, so cooldown, caps and the Poisson roll run exactly as in `step` without simulating the world.
/// `onStart` gets the sim time of every start. The real crossing is covered by the 1/60 s integration tests below.
private func starts(_ f: SnowField, hours: Float, onStart: (Double) -> Void = { _ in }) -> Int {
    var seen = 0, endAt = Double.infinity
    for _ in 0..<Int(hours * 3600) {
        f.time += 1
        f.stepDirector(dt: 1)
        #expect(f.figures.filter { $0.kind == .sleigh }.count <= 1)   // a big event never overlaps itself
        if f.director.started != seen { seen = f.director.started; endAt = f.time + 14; onStart(f.time) }
        if f.time >= endAt, let j = f.figures.firstIndex(where: { $0.kind == .sleigh }) { f.removeFigure(j); endAt = .infinity }
    }
    return f.director.started
}

// MARK: Cadence (direct)

@Test func sleighIntervalAndChanceFollowTheCalendar() {
    for (day, total) in [((12, 24), 600), ((12, 25), 600), ((12, 10), 2700), ((7, 15), 10800)] as [((Int, Int), Float)] {
        let f = field(day: day)
        let cd = min(1200, total * 0.2)
        #expect(f.sleighInterval.mean == total - cd && f.sleighInterval.cooldown == cd)
        #expect(f.sleighChance() == 1 / (total - cd) && f.director.sleighCooldown == cd)
    }
    let fast = field(day: (12, 24), speed: 30)
    #expect(fast.sleighChance() == Float(30) / 480)
}

@Test func sleighOnDec24ComesAboutEveryTenMinutes() {
    let n = starts(field(day: (12, 24)), hours: 6)   // 36 expected
    #expect(n >= 25 && n <= 47)
    let m = starts(field(day: (12, 25), seed: 9), hours: 6)
    #expect(m >= 25 && m <= 47)
}

@Test func sleighIsRareOutsideDecember() {
    #expect(starts(field(day: (7, 15), seed: 5), hours: 6) <= 3)
    let dec = starts(field(day: (12, 10)), hours: 6)   // 8 expected
    #expect(dec >= 3 && dec <= 14)
}

@Test func sleighIsOffWithThePrefCompactModeOrEconomy() {
    let off = field(); off.sleighEnabled = false
    #expect(starts(off, hours: 1) == 0 && !off.startSleigh())
    let compact = field(); compact.areaScale = 0.4
    #expect(starts(compact, hours: 1) == 0 && !compact.startSleigh())
    let eco = field(); eco.economy = true
    #expect(starts(eco, hours: 1) == 0)
    let calm = field(); calm.setCalm(true)
    #expect(starts(calm, hours: 1) == 0)
    let on = field()
    #expect(on.startSleigh())
}

@Test func sleighKeepsTheCooldownAndIsABigEvent() {
    let f = field(seed: 4)
    var last: [Double] = []
    _ = starts(f, hours: 3) { last.append($0) }
    #expect(last.count >= 5)
    #expect(zip(last, last.dropFirst()).allSatisfy { $1 - $0 >= 120 })   // Dec 24: cooldown of 2 min inside the 10 min interval
}

// MARK: Crossing and gifts

@Test func sleighCrossesAtTheTopBobbingAt140PointsPerSecond() {
    let f = field(seed: 2)
    f.gustOverride = nil
    #expect(f.startSleigh())
    let s0 = sleighs(f)[0], dir = s0.facing
    var minY = Float.infinity, maxY = -Float.infinity, t = 0 as Float, x0 = s0.foot.x
    while !sleighs(f).isEmpty && t < 40 {
        f.step(dt: 1 / 60); t += 1 / 60
        if let s = sleighs(f).first { minY = min(minY, s.foot.y); maxY = max(maxY, s.foot.y); if t < 0.02 { x0 = s.foot.x } }
    }
    #expect(sleighs(f).isEmpty && t > 5)
    let visible: Float = 780 - 90
    #expect(minY >= 780 - 0.25 * visible - 8.5 && maxY <= 780 - 0.15 * visible + 8.5)
    #expect(maxY - minY > 10)   // swings
    let expected = (1000 + 2 * (Tuning.sleighHalfLength * f.snowmanScale + 12)) / Tuning.sleighSpeed
    #expect(abs(t - expected) < 0.2)
    #expect(dir == 1 || dir == -1)
    _ = x0
}

@Test func sleighFollowsTheWindSign() {
    for sign: Float in [-1, 1] {
        let f = field(seed: 6)
        f.wind = 30 * sign
        _ = f.startSleigh()
        #expect(sleighs(f).first?.facing == sign)
    }
}

@Test func sleighDropsUpToThreeGiftsThatLandOnPilesAndFadeAfter90Seconds() {
    for seed in 1...12 as ClosedRange<UInt64> {
        let f = field(seed: seed, windows: [win(1, 200, 300, 500, 200)])
        for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = 12 } }
        #expect(f.startSleigh())
        var t: Float = 0
        while !sleighs(f).isEmpty && t < 40 { f.step(dt: 1 / 60); t += 1 / 60; #expect(f.gifts.count <= 3) }
        for _ in 0..<120 { f.step(dt: 1 / 60) }
        #expect(f.gifts.count >= 1 && f.gifts.count <= 3)
        for g in f.gifts {
            #expect(!g.falling)
            let si = f.index[g.surface!]!
            let top = f.standY(si: si, x: g.pos.x)
            #expect(abs(g.pos.y - (top + g.size * (0.5 - Tuning.giftSink))) < 0.5)   // sunk 30% into the pile
        }
    }
    let f = field(seed: 3)
    _ = f.startSleigh()
    while !sleighs(f).isEmpty { f.step(dt: 1 / 60) }
    advance(f, 2)
    let n = f.gifts.count
    #expect(n >= 1 && f.gifts.allSatisfy { !$0.falling })
    let t0 = f.time - Double(f.gifts.map(\.rest).max() ?? 0)   // when the first gift landed
    while f.time < t0 + 89 { f.step(dt: 0.25) }
    #expect(f.gifts.count == n && f.gifts.allSatisfy { $0.fade == 1 })
    while f.time < t0 + 91.6 { f.step(dt: 0.25) }
    #expect(f.gifts.isEmpty)
}

@Test func giftsNeverExceedThreeEvenAcrossCrossings() {
    let f = field(seed: 8)
    for _ in 0..<4 {
        _ = f.startSleigh()
        while !sleighs(f).isEmpty { f.step(dt: 1 / 30); #expect(f.gifts.count <= 3) }
        f.director.cooldownUntil = [Double](repeating: 0, count: 8)
    }
}

@Test func aCursorSweepPopsAGiftIntoConfetti() {
    let f = field(seed: 5)
    _ = f.startSleigh()
    while !sleighs(f).isEmpty { f.step(dt: 1 / 60) }
    advance(f, 2)
    let g = f.gifts[0], n = f.gifts.count
    f.sweep(from: CGPoint(x: Double(g.pos.x) - 25, y: Double(g.pos.y)), to: CGPoint(x: Double(g.pos.x) + 25, y: Double(g.pos.y)), dt: 1 / 60)
    #expect(f.gifts.count == n - 1 && !f.giftState.confetti.isEmpty)
    var w = PrimWriter(.allocate(capacity: 64), capacity: 64)
    f.writeGiftPrims(&w) { _ in .zero }
    #expect(w.n >= 4)
    advance(f, 1.5)
    #expect(f.giftState.confetti.isEmpty)
}

@Test func optionClickOpensAGiftOnce() {
    let f = field(seed: 5)
    _ = f.startSleigh()
    while !sleighs(f).isEmpty { f.step(dt: 1 / 60) }
    advance(f, 2)
    let g = f.gifts[0], p = CGPoint(x: Double(g.pos.x), y: Double(g.pos.y))
    #expect(f.hitTest(point: p))
    #expect(!f.openGift(at: CGPoint(x: 5, y: 700)))
    f.glints.removeAll()
    #expect(f.openGift(at: p))
    #expect(f.gifts[0].opened >= 0 && f.glints.count >= 3 && f.glints.count <= Tuning.maxGlints)
    #expect(!f.openGift(at: p))   // already open
    advance(f, 0.5)
    var w = PrimWriter(.allocate(capacity: 64), capacity: 64)
    f.writeGiftPrims(&w) { _ in .zero }
    #expect(w.n >= 6)   // box, ribbon cross, dark inside, flying lid
}

@Test func giftsOnADraggedOrClosedWindowFallOrTravel() {
    let f = field(seed: 7, windows: [win(1, 200, 300, 500, 200)])
    for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = 12 } }
    f.dropGift(at: SIMD2(400, 560), dir: 0)
    advance(f, 3)
    #expect(f.gifts.count == 1 && f.gifts[0].surface == 1)
    f.update(windows: [])
    f.update(windows: [], dt: Float(Tuning.goneGrace) + 0.1)   // the read after the grace (production goneGrace here): the gift is released, not discarded
    advance(f, 3)
    #expect(f.gifts.count == 1 && f.gifts[0].surface == Tuning.groundID)
}

@Test func sleighTeamFitsThePrimBudget() {
    for deer in 2...4 {
        let p = UnsafeMutablePointer<Prim>.allocate(capacity: 300)
        var w = PrimWriter(p, capacity: 300)
        Rig.sleigh(SleighLook(pos: SIMD2(100, 700), facing: -1, scale: 1.5, deer: deer, t: 1.3), contrast: false, into: &w)
        #expect(w.n > 40 && w.n <= 110)
    }
}

// MARK: Cursor snowball

private func throwField(seed: UInt64 = 1) -> (SnowField, Int) {
    let f = field(day: (7, 1), seed: seed)
    f.sleighEnabled = false
    let id = stand(f, x: 300)
    advance(f, 0.5)
    return (f, id)
}

private func hold(_ f: SnowField, at p: SIMD2<Float>, seconds: Float, fps: Float = 60) -> [Double] {
    f.setPointer(p, velocity: .zero)
    f.optionHeld = true
    var times: [Double] = [], seen = f.cursorThrow.thrown
    for _ in 0..<Int(seconds * fps) {
        f.step(dt: 1 / fps)
        if f.cursorThrow.thrown != seen { seen = f.cursorThrow.thrown; times.append(f.time) }
    }
    return times
}

@Test func cursorThrowsThreeTwoSecondsApartPerHold() {
    let (f, id) = throwField()
    let t0 = f.time
    let times = hold(f, at: SIMD2(420, 150), seconds: 12)
    #expect(times.count == 3)
    #expect(zip(times, times.dropFirst()).allSatisfy { abs(($1 - $0) - 2) < 0.05 })
    #expect(times[0] - t0 >= 0.8 + 0.3 - 0.05 && times[0] - t0 < 1.3)
    #expect(fig(f, id).facing == 1)
    // release resets: a new hold throws again
    f.optionHeld = false
    f.step(dt: 1 / 60)
    #expect(f.cursorThrow.thrown == 0)
    #expect(hold(f, at: SIMD2(420, 150), seconds: 3).count == 1)
}

@Test func theArmRisesForAThirdOfASecondBeforeEachThrow() {
    let (f, id) = throwField()
    f.setPointer(SIMD2(420, 150), velocity: .zero)
    f.optionHeld = true
    var raised: Float = 0, atThrow: Float = 0
    for _ in 0..<(60 * 3) {
        f.step(dt: 1 / 60)
        raised = max(raised, fig(f, id).pose.flutter.up)
        if !f.shots.isEmpty, atThrow == 0 { atThrow = fig(f, id).pose.flutter.up }
    }
    #expect(raised > 0.95 && atThrow > 0.9)
}

@Test func cursorThrowHitsAbout70PercentAndSplatsAtTheCursor() {
    var hits = 0, n = 0
    for seed in 1...200 as ClosedRange<UInt64> {
        let (f, _) = throwField(seed: seed)
        _ = hold(f, at: SIMD2(420, 150), seconds: 1.5)
        guard let s = f.shots.last else { continue }
        n += 1
        if s.hit { hits += 1 }
        #expect(s.target == SnowField.cursorTarget)
        #expect(s.hit ? s.to == SIMD2<Float>(420, 150) : s.to.x > 420)
    }
    #expect(n == 200 && Float(hits) / Float(n) > 0.6 && Float(hits) / Float(n) < 0.8)
    // a hit leaves a 14 pt blot that lasts 1.5 s
    for seed in 1...20 as ClosedRange<UInt64> {
        let (f, _) = throwField(seed: seed)
        _ = hold(f, at: SIMD2(420, 150), seconds: 1.5)
        guard let s = f.shots.last, s.hit else { continue }
        advance(f, 1.5)
        guard let sp = f.splats.last(where: { $0.rel == SIMD2<Float>(420, 151) }) else { Issue.record("no splat"); return }
        #expect(sp.life == 1.5 && sp.scale > 1.1 && sp.alpha > 0)
        advance(f, 1.0)
        #expect(!f.splats.contains { $0.rel == SIMD2<Float>(420, 151) })
        return
    }
}

@Test func noCursorThrowOverSnowOrWhenCancelledOrOutOfRangeOrCalm() {
    var (f, _) = throwField()
    #expect(hold(f, at: SIMD2(420, 14), seconds: 4).isEmpty && f.shots.isEmpty)   // over the pile: ⌥ scoops instead
    (f, _) = throwField()
    #expect(hold(f, at: SIMD2(900, 150), seconds: 4).isEmpty)                      // > 300 pt from the snowman
    (f, _) = throwField()
    f.setCalm(true)
    #expect(hold(f, at: SIMD2(420, 150), seconds: 4).isEmpty)                      // Reduce Motion
    (f, _) = throwField()
    f.setPointer(SIMD2(420, 150), velocity: SIMD2(100, 0)); f.optionHeld = true
    advance(f, 3)
    #expect(f.cursorThrow.thrown == 0)                                              // the cursor is moving
    (f, _) = throwField()
    f.setPointer(SIMD2(420, 150), velocity: .zero); f.optionHeld = true
    advance(f, 1.0)                                                                // wind-up under way ...
    f.optionHeld = false
    advance(f, 3)
    #expect(f.cursorThrow.thrown == 0 && f.shots.isEmpty)                           // ... released: cancelled
    (f, _) = throwField()
    f.areaScale = 0.4; f.liveTop = 100
    #expect(hold(f, at: SIMD2(420, 150), seconds: 3).isEmpty)                      // compact: above the live strip (live strip top = 100)
    #expect(hold(f, at: SIMD2(420, 90), seconds: 2).count == 1)                   // inside it
}

@Test func cursorThrowNeedsACompleteSnowman() {
    let f = field(day: (7, 1))
    f.sleighEnabled = false
    standAuto(f, x: 300, built: 4)
    advance(f, 0.5)
    #expect(hold(f, at: SIMD2(420, 150), seconds: 4).isEmpty)
}
