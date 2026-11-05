import CoreGraphics
import Foundation

extension Tuning {
    public static let fightRange: Float = 250      // two snowmen on the same surface this close may start a fight
    static let maxFights = 2                       // per screen
    public static let maxFigures = 3               // per screen: the auto snowman, user stacks, later visitors
    static let walkSpeed: Float = 14               // pt/s (x snowman scale, +-20% per walker)
    static let maxThrows = 24                      // a fight nobody wins ends after this many throws in total
    static let fightRest: Float = 12               // s a snowman stays out of fights after one ends
    static let cheerTime: Float = 2                // winner's celebration
    static let headHitsToLose = 3
    static let windPush: Float = 26                // pt/s the wind adds to / takes from a walker at a full gust
    static let windLean: Float = 9.2               // pt of head offset into a full gust (~12 degrees)
    static let shotWind: Float = 45                // pt/s a full gust moves a snowball in flight
    static let headAim: Float = 0.65               // share of throws aimed at the head
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
    /// Radians per second the flutter phase advances.
    public static func rate(gust g: Float, gait: Float) -> Float { 2 * .pi * (1.2 + 2.2 * abs(g) + 0.8 * gait) }
    /// Rotation of each arm in the V (about its shoulder; `side` -1 left, +1 right) plus the shared sway.
    public func arm(side: Float) -> Float { sway + side * up * 0.75 }
}

extension SnowField {
    /// Where a figure may stand: the visible stretch of its surface around x, kept clear of ends, corners and covered columns.
    func walkRange(surface sid: Int, x: Float, half: Float) -> (Float, Float)? {
        guard let si = index[sid], let run = visibleRun(si: si, bin: column(x) - surfaces[si].c0) else { return nil }
        let s = surfaces[si]
        let lo = max(Float(s.c0 + run.lowerBound) * Tuning.binWidth, s.pile.x0), hi = min(Float(s.c0 + run.upperBound) * Tuning.binWidth, s.pile.x1)
        return (lo + half + 8, hi - half - 8)
    }

    /// Whether there is snow (mean height over +-3 columns >= 1.5) under x on the surface.
    private func snowUnder(_ sid: Int, _ x: Float) -> Bool {
        guard let si = index[sid], let m = meanHeight(si: si, col: column(x), span: 3) else { return false }
        return m >= 1.5
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
        var moving = false, jump: Float = 0
        let range = walkRange(surface: sid, x: f.foot.x, half: half)
        // Steps x by `dx`, never past the stretch ends (and the auto snowman never onto bare ground).
        func shift(_ dx: Float) {
            guard let (lo, hi) = range, hi > lo + 4 else { return }
            var nx = f.foot.x + dx
            if f.foot.x <= hi && f.foot.x >= lo { nx = min(max(nx, lo), hi) }
            if auto && !snowUnder(sid, nx) { return }
            f.foot.x = nx
        }
        if m.cheer > 0 {
            m.cheer = max(0, m.cheer - dt)
            jump = abs(sin(m.cheer * 2 * .pi * 1.5)) * 7 * scale * min(1, m.cheer)
        } else if f.fight == nil, m.idle <= 0, let (lo, hi) = range, hi > lo + 4 {
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
                if blocked || (auto && !snowUnder(sid, nx)) { f.facing = -f.facing } else {
                    shift(v * dt)
                    if f.foot.x >= hi && f.facing > 0 { f.foot.x = hi; f.facing = -1 } else if f.foot.x <= lo && f.facing < 0 { f.foot.x = lo; f.facing = 1 }
                }
            }
        } else {
            if f.fight == nil { m.idle = max(0, m.idle - dt) }
            if abs(g) > 0.5 { shift(g * Tuning.windPush * 0.3 * scale * dt) }   // a strong gust slides a standing (idle or fighting) figure
        }
        m.windLean += (-g * Tuning.windLean * scale - m.windLean) * min(1, dt * 3)   // leans into the wind
        m.gait += ((moving ? 1 : 0) - m.gait) * min(1, dt * 6)
        m.phase += dt * 2 * .pi * 1.4 * m.gait
        let wob = sin(m.wobble * 28) * min(m.wobble, 0.7)
        f.pose.hop = abs(sin(m.phase)) * 2.2 * scale * m.gait + jump
        f.pose.lean = m.windLean + sin(m.phase * 0.5) * 1.4 * scale * m.gait + wob * 7 * scale
        f.pose.shake = wob
        m.flutter += dt * Flutter.rate(gust: g, gait: m.gait)
        f.pose.flutter = .make(gust: g, gait: m.gait, dir: f.facing, phase: m.flutter, cheer: m.cheer)
        f.motion = m
        return moving
    }
}
