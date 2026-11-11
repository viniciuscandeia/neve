// AGENT HEADER - Tests/NeveCoreTests/RabbitTests.swift  (Figures+Rabbit.swift + director)
// Rabbit steals the carrot and leaves footprints, an all-miss fight lets the nose regrow after 60 s, a hit drops the carrot and the snowman fetches it, the visit needs a complete snowman with a carrot on a long enough stretch, none in Reduce Motion / with walking off; "Director" section: cadence, gaps, caps, fast mode, off-switches, ground-only modes, follow-ups, storyBias hook and determinism through the EventDirector (`directorRun` from FigureHelpers); "Long-uptime clock": `time` is Double and follow-ups still fire at time 1e6.

import CoreGraphics
import Testing
@testable import NeveCore

private func field(speed: Float = 1, seed: UInt64 = 1, windows: [WindowInfo] = []) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0,
                      config: SimConfig(directorSpeed: speed), seed: seed)
    f.update(windows: windows)
    for si in f.surfaces.indices { for b in f.surfaces[si].pile.heights.indices { f.surfaces[si].pile.heights[b] = 12 } }
    f.visitorsEnabled = true
    return f
}

/// A user-built snowman, standing up (figures only take part in the world after 0.3 s).
@discardableResult
private func home(_ f: SnowField, x: Float, on sid: Int = Tuning.groundID) -> Int {
    let id = stand(f, x: x, on: sid)
    advance(f, 0.5)
    return id
}

private func rabbits(_ f: SnowField) -> [Figure] { f.figures.filter { $0.kind == .rabbit } }

/// Steps until no rabbit is left (or `limit` seconds); calls `each` after every step.
private func playOut(_ f: SnowField, limit: Float = 90, each: () -> Void = {}) {
    for _ in 0..<Int(limit * 60) {
        f.step(dt: 1 / 60)
        each()
        if rabbits(f).isEmpty { break }
    }
}

// MARK: Rabbit

@Test func rabbitStealsTheCarrotAndLeavesFootprints() {
    let f = field()
    f.rabbitHitScale = 0
    let sn = home(f, x: 300)
    #expect(f.startRabbit() && f.canSpawnFigure)   // the rabbit does not count against the snowman cap
    var stolenAt: Double?, landings = 0, hops = 0, bad = 0
    playOut(f) {
        if stolenAt == nil, !fig(f, sn).carrot { stolenAt = f.time }
        guard let r = rabbits(f).first, r.critter.hops != hops else { return }   // (missed snowballs sprinkle crumbs back on the pile while it flees: check the way in)
        defer { hops = r.critter.hops }
        guard r.critter.stage == .hopIn else { return }
        hops = r.critter.hops; landings += 1
        let h = f.surfaces[f.index[Tuning.groundID]!].pile.heights
        for sd: Float in [-3, 3] {
            let c = f.column(r.foot.x + sd)
            if h[min(max(c, 0), h.count - 1)] > 12 - 1 { bad += 1 }
        }
    }
    #expect(stolenAt != nil && !fig(f, sn).carrot)   // all shots missed: the nose is still gone
    #expect(landings >= 8 && bad == 0)
    #expect(rabbits(f).isEmpty)
}

@Test func rabbitAllMissNoseRegrowsAfterSixtySeconds() {
    let f = field()
    f.rabbitHitScale = 0
    let sn = home(f, x: 300)
    _ = f.startRabbit()
    var stolenAt: Double?
    while stolenAt == nil && f.time < 60 { f.step(dt: 1 / 60); if !fig(f, sn).carrot { stolenAt = f.time } }
    let t0 = stolenAt!
    while f.time < t0 + 59 { f.step(dt: 1 / 60) }
    #expect(!fig(f, sn).carrot)
    while f.time < t0 + 61 { f.step(dt: 1 / 60) }
    #expect(fig(f, sn).carrot)
    #expect(f.carrots.isEmpty)
}

@Test func rabbitHitDropsTheCarrotAndTheSnowmanFetchesIt() {
    let f = field()
    f.rabbitHitScale = 100   // every throw hits
    let sn = home(f, x: 300)
    _ = f.startRabbit()
    var dropT: Double?, backT: Double?, flee: Float = 0
    for _ in 0..<(60 * 60) {
        f.step(dt: 1 / 60)
        if dropT == nil, !f.carrots.isEmpty { dropT = f.time }
        if dropT != nil, backT == nil, fig(f, sn).carrot { backT = f.time }
        if let r = rabbits(f).first, r.critter.speed > flee { flee = r.critter.speed }
        if backT != nil, rabbits(f).isEmpty { break }
    }
    #expect(dropT != nil && backT != nil)
    #expect(backT! - dropT! < 10)
    #expect(flee == Tuning.rabbitFleeHit)   // bolted faster
    #expect(f.carrots.isEmpty && fig(f, sn).carrot)
    #expect(fig(f, sn).critter.fetchX == nil)
}

@Test func rabbitNeedsACompleteSnowmanWithACarrotOnALongEnoughStretch() {
    let f = field()
    #expect(!f.startRabbit())   // nobody home
    standAuto(f, x: 300, built: 4)
    #expect(!f.startRabbit())   // no nose yet
    let g = field(windows: [win(1, 150, 0, 750, 800)])   // 150 pt of ground left of the window: under 160
    home(g, x: 60)
    #expect(!g.startRabbit())
}

@Test func noRabbitInReduceMotionOrWithWalkingOff() {
    let f = field(speed: 30)
    home(f, x: 300)
    f.setCalm(true)
    advance(f, 120, fps: 20)
    #expect(f.director.started == 0 && rabbits(f).isEmpty)
    let g = field(speed: 30)
    home(g, x: 300)
    advance(g, 5, fps: 20)
    g.startRabbit()
    #expect(!rabbits(g).isEmpty)
    g.setCalm(true)   // calm mid-visit: it leaves at once, the nose is whole
    advance(g, 0.5)
    #expect(rabbits(g).isEmpty && g.figures.allSatisfy { $0.carrot })
}

// MARK: Director

private func startTimes(_ f: SnowField, minutes: Float, full: Bool = false) -> (starts: [Double], maxAmbient: Int, rabbitStarts: [Double]) {
    var starts: [Double] = [], last = 0, most = 0
    func tick() {
        most = max(most, f.figures.filter { $0.kind != .snowman }.count)
        if f.director.started != last { last = f.director.started; starts.append(f.time) }
    }
    if full { for _ in 0..<Int(minutes * 60 * 20) { f.step(dt: 1 / 20); tick() } } else { directorRun(f, seconds: Int(minutes * 60), each: tick) }
    return (starts, most, starts)
}

@Test func directorKeepsGapsCooldownsAndCapsOver30Minutes() {
    let f = field(seed: 7)
    home(f, x: 300)
    let r = startTimes(f, minutes: 30)
    #expect(r.starts.count >= 2)
    #expect(zip(r.starts, r.starts.dropFirst()).allSatisfy { $1 - $0 >= 240 })
    #expect(r.maxAmbient <= EventDirector.maxAmbient)
}

@Test func directorFastModeDividesTheIntervals() {
    let slow = field(speed: 1, seed: 3), fast = field(speed: 30, seed: 3)
    home(slow, x: 300); home(fast, x: 300)
    let a = startTimes(slow, minutes: 10), b = startTimes(fast, minutes: 10)
    #expect(b.starts.count > 3 * max(a.starts.count, 1))
    #expect(zip(b.starts, b.starts.dropFirst()).allSatisfy { $1 - $0 >= 45 / 30 && $1 - $0 >= 240 / 30 })
}

@Test func directorIsOffForReduceMotionVisitorsOffAndOutro() {
    for mode in 0..<4 {
        let f = field(speed: 30)
        home(f, x: 300)
        switch mode {
        case 0: f.setCalm(true)
        case 1: f.visitorsEnabled = false
        case 2: f.walkEnabled = false
        default: f.collapseAll(spread: 0)
        }
        let r = startTimes(f, minutes: 10)
        #expect(r.starts.isEmpty && rabbits(f).isEmpty)
    }
}

@Test func compactAndBehindWindowsOnlyStartGroundVisitors() {
    func surfaces(ground: Bool, compact: Bool) -> Set<Int> {
        let f = field(speed: 30, seed: 5, windows: [win(1, 200, 300, 500, 200)])
        home(f, x: 400, on: 1); home(f, x: 800)
        if compact { f.areaScale = 0.4 } else if ground { f.groundOnlyActors = true }
        var seen = Set<Int>()
        directorRun(f, seconds: 20 * 60) { for r in rabbits(f) { if let s = r.surfaceID { seen.insert(s) } } }
        return seen
    }
    #expect(surfaces(ground: false, compact: false).contains(1))   // normally the window top gets visits too
    for (g, c) in [(true, false), (false, true)] {
        let s = surfaces(ground: g, compact: c)
        #expect(!s.isEmpty && s.allSatisfy { $0 <= 0 })
    }
}

@Test func followUpsSkipTheGapButNotTheCaps() {
    let f = field()
    home(f, x: 300)
    f.director.lastStart = f.time   // a visit just started: minGap blocks the Poisson roll
    f.request(.rabbit, after: 0)
    advance(f, 3, fps: 20)
    #expect(rabbits(f).count == 1 && f.director.started == 1)   // the follow-up went through
    // caps: economy allows one at a time, so a second request waits (and expires)
    let g = field()
    home(g, x: 300)
    g.economy = true
    g.startRabbit()
    g.request(.rabbit, after: 0)
    advance(g, 3, fps: 20)
    #expect(g.director.started == 0 && rabbits(g).count == 1)
    // the full cap of three
    let h = field()
    home(h, x: 300)
    for _ in 0..<3 { h.startRabbit() }
    h.request(.rabbit, after: 0)
    advance(h, 3, fps: 20)
    #expect(h.director.started == 0 && rabbits(h).count == 3)
}

@Test func storyBiasHookRunsWhenAVisitStarts() {
    let f = field()
    home(f, x: 300)
    var told: FigureKind?
    f.director.storyBias = { kind, _ in told = kind }
    f.request(.rabbit, after: 0)
    advance(f, 3, fps: 20)
    #expect(told == .rabbit)
}

@Test func visitsAreDeterministic() {
    func run() -> (Int, Int, Float, Int) {
        let f = field(speed: 30, seed: 11)
        home(f, x: 300)
        _ = startTimes(f, minutes: 2, full: true)   // full world steps: determinism of the whole visit, not just the roll
        return (f.director.started, f.figures.count, f.figures.reduce(0) { $0 + $1.foot.x }, f.carrots.count)
    }
    let a = run(), b = run()
    #expect(a == b && a.0 > 0)
}

// MARK: Long-uptime clock

@Test func clockStillAdvancesAfterDaysOfUptime() {
    let f = field()
    f.time = 1e6   // ~11.6 days: a Float clock would have stopped
    f.step(dt: 1 / 60)
    let w0 = f.windShape(), t0 = f.time
    f.step(dt: 1 / 60)
    #expect(abs(f.time - t0 - 1.0 / 60) < 1e-9)
    #expect(f.windShape() != w0)
}

@Test func followUpFiresAfterItsDelayAtHighUptime() {
    let f = field()
    home(f, x: 300)
    f.time = 1e6
    f.request(.rabbit, after: 5)
    advance(f, 4.5, fps: 20)
    #expect(f.director.started == 0)
    advance(f, 1.5, fps: 20)
    #expect(f.director.started == 1)
}
