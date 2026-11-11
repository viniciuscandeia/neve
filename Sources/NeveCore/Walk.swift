// AGENT HEADER - Sources/NeveCore/Walk.swift  (snowmen walking: gait, wind, hops between surfaces)
// Role: Tuning.walk/fight constants (fightRange 250, maxFights 2, maxFigures 3, walkSpeed 14 pt/s x scale +-20 %, hop between ground and Dock: stepMax 10 pt high, stepGap 8 pt wide, hopTime 0.45 s, windPush/windLean, headlessLife 25 s, cheerTime 2,
//   headHitsToLose 3), `Flutter` (scarf/arm pose of a walker, transforms only, no path rebuild; part of Pose in Rig) `Flutter.make/rate/arm` (pure pose from gust, gait, direction, phase) and SnowField walking helpers: `walkRange`/`standRange` (where a figure may stand on a surface), `transfer`/`hopStep` (`Xfer` hops between ground and Dock), `walkStep`.
//   Walking is skipped when `walkEnabled` is off or the field is calm (Reduce Motion) (see stepFigures); `gust` (wind -> -1...1 with a 20 pt/s dead zone) is defined here and shared by figures, shots and Fights. The Tuning fight constants (fightRange, maxFights, maxThrows, fightRest, headAim, throwGap, hitChance, shotWind) live here too; the auto snowman never walks onto bare ground. Callers: stepFigure (Figures.swift), Fights. Tests: WalkTests, NaturalMotionTests.

import CoreGraphics
import Foundation

extension Tuning {
    public static let fightRange: Float = 250      // two snowmen on the same surface this close may start a fight
    static let maxFights = 2                       // per screen
    public static let maxFigures = 3               // per screen: the auto snowman, user stacks, later visitors
    static let walkSpeed: Float = 14               // pt/s (x snowman scale, +-20% per walker)
    static let maxThrows = 24                      // a fight nobody wins ends after this many throws in total
    static let fightRest: Float = 12               // s a snowman stays out of fights after one ends
    static let headlessLife: Float = 25            // s the auto snowman stands headless before it collapses (so a new one can be built)
    static let cheerTime: Float = 2                // winner's celebration
    static let headHitsToLose = 3
    static let windPush: Float = 26                // pt/s the wind adds to / takes from a walker at a full gust
    static let windLean: Float = 9.2               // pt of head offset into a full gust (~12 degrees)
    static let shotWind: Float = 45                // pt/s a full gust moves a snowball in flight
    static let headAim: Float = 0.65               // share of throws aimed at the head
    static let stepMax: Float = 10                 // pt: highest step a snowman hops between ground and Dock
    static let stepGap: Float = 8                  // pt: widest horizontal gap between the two stretches
    static let hopTime: Float = 0.45               // s
    static let throwGap: Float = 1.1               // s between throws (plus up to 0.4 random)
    /// Chance that a throw from `d` points away hits: 0.8 up to 80pt, falling linearly to 0.35 at 250pt.
    public static func hitChance(distance d: Float) -> Float { 0.8 - 0.45 * min(max((d - 80) / 170, 0), 1) }
}

/// Scarf and arm pose of a walking snowman, all radians except `up`. Layers apply it as transforms: no path rebuilds.
public struct Flutter: Equatable {
    public var scarf: Float = 0    // upper scarf tail, + = swung toward +x (downwind when the wind blows right)
    public var wave: Float = 0     // extra bend of the lower tail segment, lags the upper one
    public var sway: Float = 0     // both twig arms, + = counter-clockwise: negative = bent toward +x
    public var up: Float = 0       // 0...1 cheer: arms raised into a V
    public init() {}

    /// Pure pose from gust (-1...1), gait (0 still ... 1 walking), walking direction, flutter phase and cheer seconds left.
    /// Amplitude and (via `rate`) frequency grow with wind and walking; a full gust streams the tail ~66 degrees downwind.
    public static func make(gust g: Float, gait: Float, dir: Float, phase: Float, cheer: Float) -> Flutter {
        var f = Flutter()
        let a = 0.07 + 0.16 * abs(g) + 0.05 * gait
        f.scarf = 1.15 * g - 0.12 * dir * gait + a * sin(phase)
        f.wave = 1.8 * a * sin(phase - 1.1)
        f.sway = -0.3 * g + 0.05 * abs(g) * sin(phase * 1.3)
        if cheer > 0 {   // lift in 0.25 s, lower over the last 0.35 s
            let u = min(1, (Tuning.cheerTime - cheer) / 0.25) * min(1, cheer / 0.35)
            f.up = u * u * (3 - 2 * u)
        }
        return f
    }
    /// Phases wrap here: 20 pi is a whole period of every sin(phase * k) used (k = 0.5, 1, 1.3), so a long-lived figure never loses Float precision.
    static let wrap: Float = 20 * .pi
    /// Radians per second the flutter phase advances.
    public static func rate(gust g: Float, gait: Float) -> Float { 2 * .pi * (1.2 + 2.2 * abs(g) + 0.8 * gait) }
    /// Rotation of each arm in the V (about its shoulder; `side` -1 left, +1 right) plus the shared sway.
    public func arm(side: Float) -> Float { sway + side * up * 0.75 }
}

extension SnowField {
    /// Where a figure may stand: the visible stretch of its surface around x, kept clear of ends, corners and covered columns.
    func walkRange(surface sid: Int, x: Float, half: Float, height: Float = 0) -> (Float, Float)? {
        guard let si = index[sid], let (lo, hi) = standRange(si: si, x: x, height: height) else { return nil }
        return (lo + half + 8, hi - half - 8)
    }

    /// The visible stretch around x (or the nearest one when x is not in it) whose columns leave `height` points free
    /// above the snow: nothing under the Dock bar or a floating window that is too low. nil when there is none.
    func standRange(si: Int, x: Float, height: Float) -> (Float, Float)? {
        let s = surfaces[si], p = s.pile, c = column(x) - s.c0
        guard let run = visibleRun(si: si, bin: c) else { return nil }
        var best: Range<Int>?, bestD = Int.max, b = run.lowerBound
        while b < run.upperBound {
            guard p.cap[b] - p.heights[b] >= height else { b += 1; continue }
            var e = b
            while e < run.upperBound, p.cap[e] - p.heights[e] >= height { e += 1 }
            let d = c < b ? b - c : c >= e ? c - e + 1 : 0
            if d < bestD { best = b..<e; bestD = d }
            b = e
        }
        guard let r = best else { return nil }
        return (max(Float(s.c0 + r.lowerBound) * Tuning.binWidth, p.x0), min(Float(s.c0 + r.upperBound) * Tuning.binWidth, p.x1))
    }

    /// Whether there is snow (mean height over +-3 columns >= 1.5) under x on the surface.
    private func snowUnder(_ sid: Int, _ x: Float) -> Bool {
        guard let si = index[sid], let m = meanHeight(si: si, col: column(x), span: 3) else { return false }
        return m >= 1.5
    }

    /// A hop onto the neighbouring surface past the end of `f`'s stretch in direction `dir`, when the two stretches nearly
    /// touch and the snow tops differ by at most `stepMax`. Only ground <-> Dock. The auto snowman needs snow where it lands.
    func transfer(_ f: Figure, sid: Int, dir: Float, auto: Bool) -> Xfer? {
        let to = sid == Tuning.groundID ? 0 : sid == 0 ? Tuning.groundID : nil
        guard let to, let si = index[sid], let ti = index[to] else { return nil }
        let h = Snowman.height * f.scale, half = f.radii.x
        guard let cur = standRange(si: si, x: f.foot.x, height: h) else { return nil }
        let probe = dir > 0 ? cur.1 + 4 : cur.0 - 4
        guard let tgt = standRange(si: ti, x: probe, height: h), let (lo, hi) = walkRange(surface: to, x: probe, half: half, height: h), hi > lo + 4 else { return nil }
        let gap = dir > 0 ? tgt.0 - cur.1 : cur.0 - tgt.1
        let x = dir > 0 ? lo : hi
        guard abs(gap) <= Tuning.stepGap, !auto || snowUnder(to, x), let m = meanHeight(si: ti, col: column(x), span: 3) else { return nil }
        let t = surfaces[ti], c = column(x) - t.c0
        guard t.pile.visible[c] else { return nil }
        let y = t.edgeY + t.pile.base[c] + m
        guard abs(y - f.foot.y) <= Tuning.stepMax else { return nil }
        for o in figures where o.id != f.id && o.surfaceID == to && abs(o.foot.x - x) < half + o.radii.x + 6 { return nil }
        return Xfer(sid: to, from: f.foot, to: SIMD2(x, y))
    }

    /// Advances a hop: a flat arc, squash on landing. Returns the new surface id once it has landed.
    func hopStep(_ f: inout Figure, _ dt: Float) -> Int? {
        guard var x = f.motion.xfer else { return nil }
        x.t = min(1, x.t + dt / Tuning.hopTime)
        let u = x.t, e = u * u * (3 - 2 * u)
        f.foot = x.from + (x.to - x.from) * e
        f.pose.hop = 4 * u * (1 - u) * (6 + max(x.to.y - x.from.y, 0)) * f.scale
        if u < 1 { f.motion.xfer = x; return nil }
        f.motion.xfer = nil
        f.motion.squash = Tuning.squashTime
        guard index[x.sid] != nil else { f.foot = x.from; return nil }
        f.foot = x.to
        f.at = .surface(id: x.sid, x: x.to.x)
        return x.sid
    }

    /// -1...1: how hard the wind blows sideways. Zero below a dead zone, so only Nevasca gusts count (Leve / Media peak at 8).
    var gust: Float { if let o = gustOverride { return o }; return (wind < 0 ? -1 : 1) * min(1, max(0, abs(wind) - 20) / 80) }

    /// One step of a standing / walking figure `f` on surface `sid`: idle pauses, wind, walking (turning at the ends,
    /// at other figures, and never onto bare ground for the auto one), then the pose. True when it moved by walking.
    func walkStep(_ f: inout Figure, sid: Int, dt: Float) -> Bool {
        var m = f.motion
        let g = gust, scale = f.scale, half = f.radii.x, auto = !f.fromBalls
        m.rest = max(0, m.rest - dt)
        m.wobble = max(0, m.wobble - dt)
        m.squash = max(0, m.squash - dt)
        m.headHit = max(0, m.headHit - dt)
        var moving = false, jump: Float = 0, cheerSquash: Float = 0
        let range = walkRange(surface: sid, x: f.foot.x, half: half, height: Snowman.height * scale)
        let outside = range.map { f.foot.x < $0.0 || f.foot.x > $0.1 } ?? false   // in a column too low for it: walks out, bare ground allowed
        // Steps x by `dx`, never past the stretch ends (and the auto snowman never onto bare ground).
        func shift(_ dx: Float) {
            guard let (lo, hi) = range, hi > lo + 4 else { return }
            var nx = f.foot.x + dx
            if f.foot.x <= hi && f.foot.x >= lo { nx = min(max(nx, lo), hi) }
            if auto && !outside && !snowUnder(sid, nx) { return }
            f.foot.x = nx
        }
        if m.cheer > 0 {
            m.cheer = max(0, m.cheer - dt)
            jump = abs(sin(m.cheer * 2 * .pi * 1.5)) * 7 * scale * min(1, m.cheer)
            cheerSquash = 0.15 * max(0, 1 - jump / scale / 0.8)   // squashes at ground contact, like the rabbit
        } else if f.fight == nil, m.idle <= 0 || outside, let (lo, hi) = range, hi > lo + 4 {
            m.nextIdle -= dt
            if m.nextIdle <= 0 {
                m.idle = Float.random(in: 1.5...4, using: &rng); m.nextIdle = Float.random(in: 8...18, using: &rng)
            } else {
                moving = true
                if f.foot.x > hi { f.facing = -1 } else if f.foot.x < lo { f.facing = 1 }
                let base = m.speed * scale
                // Against the wind they barely advance, with it they speed up (capped at 1.5x).
                let v = min(max(f.facing * base + g * Tuning.windPush * scale, -1.5 * base), 1.5 * base)
                let nx = f.foot.x + v * dt
                // Figures do not walk through each other (or onto bare ground, for the auto one): turn back.
                var blocked = false
                for o in figures where o.id != f.id && o.surfaceID == sid && o.active {
                    if abs(nx - o.foot.x) < half + o.radii.x + 6 && abs(nx - o.foot.x) < abs(f.foot.x - o.foot.x) { blocked = true; break }
                }
                if blocked || (auto && !outside && !snowUnder(sid, nx)) { f.facing = -f.facing } else {
                    shift(v * dt)
                    if f.foot.x >= hi && f.facing > 0 {
                        f.foot.x = hi
                        if let x = transfer(f, sid: sid, dir: 1, auto: auto) { m.xfer = x } else { f.facing = -1 }
                    } else if f.foot.x <= lo && f.facing < 0 {
                        f.foot.x = lo
                        if let x = transfer(f, sid: sid, dir: -1, auto: auto) { m.xfer = x } else { f.facing = 1 }
                    }
                }
            }
        } else {
            if f.fight == nil { m.idle = max(0, m.idle - dt) }
            if abs(g) > 0.5 { shift(g * Tuning.windPush * 0.3 * scale * dt) }   // a strong gust slides a standing (idle or fighting) figure
        }
        m.windLean += (-g * Tuning.windLean * scale - m.windLean) * min(1, dt * 3)   // leans into the wind
        m.gait += ((moving ? 1 : 0) - m.gait) * min(1, dt * 6)
        m.phase += dt * 2 * .pi * 1.4 * m.gait; if m.phase > Flutter.wrap { m.phase -= Flutter.wrap }
        let wob = sin(m.wobble * 28) * min(m.wobble, 0.7)
        f.pose.hop = abs(sin(m.phase)) * 2.2 * scale * m.gait + jump
        f.pose.lean = m.windLean + sin(m.phase * 0.5) * 1.4 * scale * m.gait + wob * 7 * scale
        f.pose.squash = max(cheerSquash, 0.12 * sin(.pi * (1 - m.squash / Tuning.squashTime)) * (m.squash > 0 ? 1 : 0))   // 1.06 x 0.95 at the peak
        f.pose.shake = wob + sin(m.headHit * 45) * (m.headHit / 0.7) * 1.5 * scale
        m.flutter += dt * Flutter.rate(gust: g, gait: m.gait); if m.flutter > Flutter.wrap { m.flutter -= Flutter.wrap }
        f.pose.flutter = .make(gust: g, gait: m.gait, dir: f.facing, phase: m.flutter, cheer: m.cheer)
        f.motion = m
        return moving
    }
}
