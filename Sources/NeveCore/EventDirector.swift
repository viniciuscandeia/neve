// AGENT HEADER - Sources/NeveCore/EventDirector.swift  (when visitors appear)
// Role: `EventDirector` (one per SnowField, ticked at 1 Hz of SIMULATION time from step; seeded, clock-free: same seed + inputs => same visits). Rules: <= 3 ambient actors per screen (snowmen excluded), <= 1 big event (sleigh), `minGap` 45 s between ambient starts,
//   per-kind cooldown counted from the END of the last visit, Poisson starts p = dt / mean, speed divisor from NEVE_DIRECTOR_FAST (SimConfig.directorSpeed), intervals x2 and 1 ambient at a time in Economy / Low Power, off for Reduce Motion / still / outro / walking off /
//   Visitantes off; compact (maximized window) and behind-windows modes start only ground-capable kinds, only there. `spec(_:)` = per-kind interval/cooldown table, `kinds` = what the Poisson roll considers (rabbit, penguin, sleigh, robin),
//   `request(kind, after:)` queues story follow-ups (skip minGap, never the caps), `ended(kind, at:)` must be called when a visit ends (SnowField.clear does it) or the cooldown stays infinite.
// Plugging in a critter: see Figures.swift (`startVisitor` is private here). Tests exercising it: FigureHelpers, RabbitTests, PenguinTests, RobinTests, SleighTests, MeltTests.

import Foundation

/// Schedules visitors (ambient critters) and, later, big events. One per `SnowField`, ticked at 1 Hz of simulation time from `step`,
/// seeded and clock-free: the same seed and inputs give the same visits.
///
/// Rules: <= 3 ambient actors per screen (snowmen do not count: they have `Tuning.maxFigures`), <= 1 big event, `minGap` s between
/// ambient starts, a cooldown per kind (counted from the end of the last visit), Poisson starts (p = dt / mean). Off for Reduce Motion /
/// still / outro, with walking off, and when the Visitantes option is off. Economy / Low Power: intervals x2 and 1 ambient at a time.
/// Compact (maximized window) and behind-windows mode only start kinds that can stand on the ground, and only there.
///
/// Plugging in a critter: add a `FigureKind` case, a row in `spec(_:)`, a `case` in `SnowField.startVisitor`, a `Figures+<Kind>.swift`
/// with its `step` (called from `stepFigure`) and a `Rig` entry. Follow-ups (`request`) skip `minGap` but never the caps.
public struct EventDirector {
    static let maxAmbient = 3, maxBig = 1
    static let minGap: Float = 45

    struct Spec {
        let mean: Float          // seconds between visits (Poisson)
        let cooldown: Float      // seconds after a visit ends
        var windowOnly = false   // cannot live on the ground / Dock (robin, penguin): skipped in compact / behind-windows mode
        var big = false          // counts against `maxBig` instead of `maxAmbient`
    }
    static func spec(_ k: FigureKind) -> Spec? {
        switch k {
        case .snowman: return nil
        case .rabbit: return Spec(mean: 360, cooldown: 240)
        case .penguin: return Spec(mean: 480, cooldown: 300, windowOnly: true)
        case .sleigh: return Spec(mean: 10800, cooldown: 1200, big: true)   // mean / cooldown really come from `SnowField.sleighInterval`
        case .robin: return Spec(mean: 300, cooldown: 180, windowOnly: true)
        }
    }
    static let kinds: [FigureKind] = [.rabbit, .penguin, .sleigh, .robin]   // the kinds the Poisson roll considers

    struct Request { var kind: FigureKind, at: Double }

    var rng: SplitMix64
    let speed: Float                       // NEVE_DIRECTOR_FAST: divides every interval
    var acc: Float = 0
    var lastStart = -Double.infinity
    var cooldownUntil = [Double](repeating: 0, count: 8)   // by `FigureKind.rawValue`; infinity while a visit runs
    var queue: [Request] = []
    var sleighCooldown: Float = 1200
    public internal(set) var started = 0    // visits started so far (tests / diagnostics)

    /// Story extension point: called (outside the director's mutation) right after an ambient visit of `kind` starts. A later slice sets
    /// it to stage the chained story, e.g. `request(.robin, after: 0)` before a rabbit steals, or to bias where shots go.
    public var storyBias: ((_ started: FigureKind, _ field: SnowField) -> Void)? = { k, f in f.storyStarted(k) }
    var story = StoryState()

    init(seed: UInt64, speed: Float) {
        rng = SplitMix64(seed: seed); self.speed = max(speed, 1)
        queue.reserveCapacity(4)
    }

    /// Asks for a visit of `kind` `after` seconds from `now` (plus up to 30 s of patience). Ignored when the queue is full.
    public mutating func request(_ kind: FigureKind, after: Float, now: Double) {
        guard queue.count < 4 else { return }
        queue.append(Request(kind: kind, at: now + Double(after)))
    }

    mutating func ended(_ kind: FigureKind, at t: Double) {
        guard let s = Self.spec(kind) else { return }
        if kind == .rabbit { story.active = false; story.pending = false }
        cooldownUntil[Int(kind.rawValue)] = t + Double((kind == .sleigh ? sleighCooldown : s.cooldown) / speed)
    }
}

extension SnowField {
    /// Queues a follow-up visit (see `EventDirector.request`).
    public func request(_ kind: FigureKind, after: Float) { director.request(kind, after: after, now: time) }

    var visitorsGroundOnly: Bool { groundOnlyActors || areaScale < 1 }

    func stepDirector(dt: Float) {
        director.acc += dt
        guard director.acc >= 1 else { return }
        director.acc -= 1
        guard visitorsEnabled || sleighEnabled, walkEnabled, !calm, !quiet, !melting else { director.queue.removeAll(keepingCapacity: true); return }
        let eco = economy || lowPower
        if config.penguinDemo, !visitorsGroundOnly, stepPenguinDemo() { return }
        let limit = eco ? 1 : EventDirector.maxAmbient
        var ambient = 0, big = 0
        for f in figures where f.kind != .snowman { if EventDirector.spec(f.kind)?.big == true { big += 1 } else { ambient += 1 } }
        // Follow-ups: no minGap, no Poisson, but caps and cooldowns hold.
        var q = director.queue.count - 1
        while q >= 0 {
            let r = director.queue[q]
            q -= 1
            guard time >= r.at else { continue }
            if time > r.at + 30 { director.queue.remove(at: q + 1); continue }
            if canStart(r.kind, ambient: ambient, big: big, limit: limit), startVisitor(r.kind) {
                director.queue.remove(at: q + 1)
                visitStarted(r.kind)
                return
            }
        }
        guard scene == nil, ambient < limit, time - director.lastStart >= Double(EventDirector.minGap / director.speed) else { return }
        for kind in EventDirector.kinds {
            guard let spec = EventDirector.spec(kind), canStart(kind, ambient: ambient, big: big, limit: limit) else { continue }
            let p = kind == .sleigh ? sleighChance() : director.speed / (spec.mean * (eco ? 2 : 1))   // dt = 1 s
            guard Float.random(in: 0..<1, using: &director.rng) < p, startVisitor(kind) else { continue }
            visitStarted(kind)
            return
        }
    }

    private func canStart(_ kind: FigureKind, ambient: Int, big: Int, limit: Int) -> Bool {
        guard let spec = EventDirector.spec(kind), time >= director.cooldownUntil[Int(kind.rawValue)] else { return false }
        if visitorsGroundOnly && spec.windowOnly { return false }
        if kind == .sleigh { if !sleighAllowed { return false } } else if !visitorsEnabled { return false }
        return spec.big ? big < EventDirector.maxBig : ambient < limit
    }

    private func startVisitor(_ kind: FigureKind) -> Bool {
        switch kind {
        case .rabbit: return startRabbit()
        case .robin: return startRobin()
        case .penguin: return startPenguin()
        case .sleigh: return startSleigh()
        case .snowman: return false
        }
    }

    private func visitStarted(_ kind: FigureKind) {
        director.lastStart = time
        director.started += 1
        director.cooldownUntil[Int(kind.rawValue)] = .infinity   // until the visit ends
        if let hook = director.storyBias { hook(kind, self) }
    }
}
