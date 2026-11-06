import CoreGraphics
import Foundation

extension Tuning {
    static let rabbitHop: Float = 0.35          // s per hop
    static let rabbitLen: Float = 22            // pt per hop
    static let rabbitArc: Float = 10            // pt high
    static let rabbitSniff: Float = 1           // s at the snowman
    static let rabbitGap: Float = 14            // pt from the snowman's base edge where the rabbit stops
    static let rabbitFlee: Float = 1.6          // hop speed x
    static let rabbitFleeHit: Float = 2.4       // after being hit
    static let rabbitHitScale: Float = 0.6      // x hitChance(d)
    static let rabbitShotGap: Float = 0.6       // s between the snowman's throws at it
    static let minStretch: Float = 160          // pt of visible surface the visit needs
    static let carrotRegrow: Float = 60         // s of snowfall until a lost nose grows back
    static let carrotGrab: Float = 0.3          // s the snowman takes to put the carrot back
    static let carrotReach: Float = 6           // pt from the carrot where the snowman grabs it
    static let fetchSpeed: Float = 3            // x walk speed while running to the carrot
}

/// Visit bookkeeping: the rabbit's script, and (on a snowman) the way back to a dropped carrot.
struct Critter {
    enum Stage: UInt8 { case hopIn, sniff, snatch, flee }
    var stage = Stage.hopIn
    var target = 0                      // snowman figure id
    var side: Float = -1                // side of the snowman it enters from (and flees back to)
    var stageT: Float = 0
    var hopT: Float = 0, hopFrom: Float = 0, hopTo: Float = 0, hopping = false
    var hops = 0                        // landings so far (tests)
    var speed: Float = 1                // flee speed x
    var carrying = false
    var shots = 0, shotT: Float = 0
    var carrotFrom = SIMD2<Float>.zero  // where the nose was when it was snatched
    var carrot = SIMD3<Float>.zero      // x, y, angle of the carrot flying into the mouth
    var ear: Float = 0
    var fetchX: Float?                  // snowman: where its dropped carrot lies
    var regrow: Float = 0               // snowman: snowfall seconds until the stolen nose is back
}

/// A stolen nose falling or lying on a pile; its `owner` snowman runs to it.
struct Carrot {
    var pos: SIMD2<Float>, vel: SIMD2<Float>
    let surface: Int, owner: Int, size: Float
    var lying = false, grab: Float = -1
    var from = SIMD2<Float>.zero
    var angle: Float = 0.15
}

extension SnowField {
    /// y of the pile top at x on surface index `si` (what a standing figure's foot rests on).
    func standY(si: Int, x: Float) -> Float {
        let s = surfaces[si], c = column(x)
        return s.edgeY + s.pile.base[min(max(c - s.c0, 0), s.pile.base.count - 1)] + (meanHeight(si: si, col: c, span: 3) ?? 0)
    }

    private func mouth(_ f: Figure) -> SIMD2<Float> {
        SIMD2(f.foot.x + f.facing * 8.4 * f.scale, f.foot.y + f.pose.hop + 5.4 * f.scale)
    }

    /// Starts a visit at the first complete snowman that stands on a visible stretch >= 160pt, with the carrot, idle, with room
    /// (>= 30pt) between the rabbit's stop point and its entry end. The rabbit enters from the nearer end.
    func startRabbit() -> Bool {
        for t in figures.indices {
            let w = figures[t]
            guard w.active, w.built == Snowman.stageCount, w.carrot, w.fight == nil, w.motion.rest <= 0, let sid = w.surfaceID,
                  !visitorsGroundOnly || sid <= 0, let si = index[sid], let run = visibleRun(si: si, bin: column(w.foot.x) - surfaces[si].c0) else { continue }
            let s = surfaces[si]
            let lo = max(Float(s.c0 + run.lowerBound) * Tuning.binWidth, s.pile.x0), hi = min(Float(s.c0 + run.upperBound) * Tuning.binWidth, s.pile.x1)
            guard hi - lo >= Tuning.minStretch else { continue }
            var side: Float = 0, best = Float.infinity
            for k in 0..<2 {
                let sd: Float = k == 0 ? -1 : 1, stop = w.foot.x + sd * (w.radii.x + Tuning.rabbitGap), end = sd < 0 ? lo : hi
                let d = abs(end - w.foot.x)
                if (sd < 0 ? stop - lo : hi - stop) >= 30, d < best { side = sd; best = d }
            }
            guard side != 0 else { continue }
            let x = side < 0 ? lo + 1 : hi - 1
            var r = Figure(id: nextFigureID, kind: .rabbit, foot: SIMD2(x, standY(si: si, x: x)), radii: SIMD3(repeating: 11.5 * snowmanScale), fromBalls: true)
            nextFigureID += 1
            r.at = .surface(id: sid, x: x)
            r.phase = .walking
            r.fade = 0
            r.facing = -side
            r.critter.target = w.id; r.critter.side = side
            figures.append(r)
            figuresVersion &+= 1
            return true
        }
        return false
    }

    /// The rabbit leaves at once, carrots and held noses are restored: Reduce Motion / walking off.
    func clearCritters() {
        clearPenguins()
        var i = figures.count - 1
        while i >= 0 {
            if figures[i].kind == .rabbit { removeFigure(i) } else if !figures[i].carrot { figures[i].carrot = true; figures[i].critter = Critter(); figuresVersion &+= 1 }
            i -= 1
        }
        carrots.removeAll(keepingCapacity: true)
    }

    /// One step of a rabbit visit: hop in, sniff, snatch the carrot, flee; the snowman throws at it meanwhile. False when removed.
    func stepRabbit(_ i: Int, _ dt: Float) -> Bool {
        var f = figures[i]
        var c = f.critter
        f.phaseT += dt
        c.stageT += dt
        guard let sid = f.surfaceID, let si = index[sid], let run = visibleRun(si: si, bin: column(f.foot.x) - surfaces[si].c0) else { removeFigure(i); return false }
        let s = surfaces[si]
        let lo = max(Float(s.c0 + run.lowerBound) * Tuning.binWidth, s.pile.x0), hi = min(Float(s.c0 + run.upperBound) * Tuning.binWidth, s.pile.x1)
        var t = figureIndex(c.target)
        if let k = t, figures[k].kind != .snowman || figures[k].phase == .collapsing || figures[k].surfaceID != sid { t = nil }
        if c.stage == .hopIn || c.stage == .sniff, t == nil || !figures[t!].carrot || figures[t!].headless {   // nothing left to steal
            c.stage = .flee; c.hopping = false; c.speed = Tuning.rabbitFlee
        }
        if let k = t, c.stage != .flee || c.shots > 0 {   // the snowman stands still, watching, and is kept out of fights
            figures[k].motion.rest = max(figures[k].motion.rest, 2)
            figures[k].motion.idle = max(figures[k].motion.idle, 1)
        }
        f.pose.squash = 0; f.pose.hop = 0; f.pose.shake = 0
        var vx: Float = 0
        switch c.stage {
        case .hopIn, .flee:
            if !c.hopping {   // plan the next hop (landing exactly at the stop point / the exit)
                var d: Float, len = Tuning.rabbitLen
                if c.stage == .hopIn, let k = t {
                    let goal = figures[k].foot.x + c.side * (figures[k].radii.x + Tuning.rabbitGap)
                    d = goal - f.foot.x
                    if d * -c.side <= 0.5 { c.stage = .sniff; c.stageT = 0; f.phase = .idle; break }   // arrived (or the snowman came closer)
                } else {
                    d = (c.side < 0 ? lo : hi) - f.foot.x
                    len *= c.speed
                    if abs(d) <= 2 { removeFigure(i); return false }
                }
                let dir: Float = d > 0 ? 1 : -1
                c.hopFrom = f.foot.x; c.hopTo = f.foot.x + dir * min(len, abs(d)); c.hopT = 0; c.hopping = true
                f.facing = dir
            }
            c.hopT += dt
            let u = min(c.hopT / Tuning.rabbitHop, 1)
            f.foot.x = c.hopFrom + (c.hopTo - c.hopFrom) * u
            f.pose.hop = 4 * Tuning.rabbitArc * u * (1 - u)
            let landed: Float = c.hopT < 0.1 && c.hops > 0 ? 0.55 * (1 - c.hopT / 0.1) : 0
            f.pose.squash = landed - 0.3 * sin(.pi * u)
            vx = c.stage == .flee ? f.facing * Tuning.rabbitLen * c.speed / Tuning.rabbitHop : 0
            if u >= 1 {
                c.hopping = false; c.hops += 1
                for k in 0..<2 {   // a footprint pair, snapped to the column grid so each print is a full-depth dent
                    let sd: Float = k == 0 ? -1 : 1
                    if surfaces[si].pile.carve(centerX: binCenter(column(f.foot.x + sd * 3)), halfWidth: 1.5, depth: 1.2, berm: 0.15) > 0 { pilesDirty = true }
                }
            }
            c.ear = c.stage == .flee ? -1 : 0
        case .sniff:
            c.ear = max(0, sin(c.stageT * 13)) * 0.5
            f.pose.shake = sin(c.stageT * 22) * 0.6   // nose bob
            if c.stageT >= Tuning.rabbitSniff, let k = t {
                c.stage = .snatch; c.stageT = 0
                figures[k].carrot = false
                figures[k].critter.regrow = Tuning.carrotRegrow
                figures[k].facing = f.foot.x >= figures[k].foot.x ? 1 : -1   // turns on the thief
                let a = anchors(of: figures[k])
                c.carrotFrom = SIMD2(a.head.x + figures[k].facing * figures[k].radii.z * 1.1, a.head.y)
                c.shots = Int.random(in: 2...3, using: &director.rng); c.shotT = 0.45
                figuresVersion &+= 1
            }
        case .snatch:
            let u = min(c.stageT / 0.4, 1), e = u * u * (3 - 2 * u)
            f.pose.hop = 4 * 16 * u * (1 - u)
            f.pose.squash = -0.3 * sin(.pi * u)
            let m = mouth(f)
            c.carrot = SIMD3(c.carrotFrom.x + (m.x - c.carrotFrom.x) * e, c.carrotFrom.y + (m.y - c.carrotFrom.y) * e + 8 * sin(.pi * u), 0.6 * u)
            if u >= 1 { c.stage = .flee; c.stageT = 0; c.carrying = true; c.speed = Tuning.rabbitFlee; c.hopping = false; f.phase = .walking }
        }
        if let k = t, c.shots > 0, c.stage == .snatch || c.stage == .flee {
            c.shotT -= dt
            if c.shotT <= 0 { c.shots -= 1; c.shotT = Tuning.rabbitShotGap; throwAtRabbit(from: k, rabbit: f, vx: vx) }
        }
        f.foot.y = standY(si: si, x: f.foot.x)
        f.at = .surface(id: sid, x: f.foot.x)
        f.fade = min(1, max(0, min(f.foot.x - lo, hi - f.foot.x) / 14))
        f.critter = c
        figures[i] = f
        return true
    }

    /// The snowman turns on the rabbit and throws; the shot flies to where it will be (hit) or lands short / long of it.
    private func throwAtRabbit(from k: Int, rabbit f: Figure, vx: Float) {
        figures[k].facing = f.foot.x >= figures[k].foot.x ? 1 : -1
        let from = anchors(of: figures[k]).arm, d = abs(f.foot.x - from.x)
        let dur = 0.35 + 0.4 * min(d / Tuning.fightRange, 1)
        let hit = Float.random(in: 0..<1, using: &director.rng) < min(1, Tuning.hitChance(distance: d) * rabbitHitScale)
        var to = SIMD2(f.foot.x + vx * dur, f.foot.y + 5 * f.scale)
        if !hit { to = SIMD2(to.x + (Bool.random(using: &director.rng) ? 1 : -1) * Float.random(in: 22...45, using: &director.rng), f.foot.y) }
        shots.append(Shot(pos: from, from: from, to: to, peak: 12 + 0.12 * d, dur: dur, hit: hit, head: false, target: f.id, surface: f.surfaceID ?? Tuning.groundID))
        figuresVersion &+= 1
    }

    /// A snowball hit the rabbit: it drops the carrot (if it holds it) and bolts.
    func rabbitHit(_ j: Int) {
        guard figures[j].critter.carrying, let k = figureIndex(figures[j].critter.target), let sid = figures[j].surfaceID else { return }
        let m = mouth(figures[j]), owner = figures[k]
        figures[j].critter.carrying = false
        figures[j].critter.speed = Tuning.rabbitFleeHit
        figures[j].critter.shots = 0
        figures[j].critter.hopping = false
        carrots.append(Carrot(pos: m, vel: SIMD2(-figures[j].facing * 25, 110), surface: sid, owner: owner.id, size: owner.scale))
        figures[k].critter.fetchX = m.x
        figuresVersion &+= 1
    }

    /// Nose regrowth of a snowman `f` that lost its carrot (snowfall time).
    func stepCarrot(_ f: inout Figure, _ dt: Float) {
        guard !f.carrot else { return }
        f.critter.regrow -= dt * config.snowmanSpeed
        guard f.critter.regrow <= 0 else { return }
        f.carrot = true; f.critter.fetchX = nil
        carrots.removeAll { $0.owner == f.id }
    }

    /// Running to the dropped carrot (3x walking speed). True while moving.
    func fetchStep(_ f: inout Figure, _ dt: Float) -> Bool {
        guard let x = f.critter.fetchX else { return false }
        var m = f.motion
        m.rest = max(0, m.rest - dt); m.wobble = max(0, m.wobble - dt); m.squash = max(0, m.squash - dt); m.headHit = max(0, m.headHit - dt)
        let d = x - f.foot.x, moving = abs(d) > Tuning.carrotReach - 1
        if moving {
            f.facing = d > 0 ? 1 : -1
            f.foot.x += f.facing * min(abs(d), m.speed * f.scale * Tuning.fetchSpeed * dt)
        }
        m.gait += ((moving ? 1 : 0) - m.gait) * min(1, dt * 6)
        m.phase += dt * 2 * .pi * 2.2 * m.gait
        f.pose.hop = abs(sin(m.phase)) * 2.2 * f.scale * m.gait
        f.pose.lean = sin(m.phase * 0.5) * 1.4 * f.scale * m.gait
        f.pose.squash = 0; f.pose.shake = 0
        m.flutter += dt * Flutter.rate(gust: gust, gait: m.gait)
        f.pose.flutter = .make(gust: gust, gait: m.gait, dir: f.facing, phase: m.flutter, cheer: 0)
        f.motion = m
        return moving
    }

    /// Carrots fall, lie, and are taken back by their owner (0.3 s ease up to the nose).
    func stepCarrots(_ dt: Float) {
        var k = carrots.count - 1
        while k >= 0 {
            defer { k -= 1 }
            var c = carrots[k]
            guard let o = figureIndex(c.owner), let si = index[c.surface], !figures[o].carrot else { carrots.remove(at: k); continue }
            let top = standY(si: si, x: c.pos.x) + 1
            figures[o].critter.fetchX = c.pos.x
            if c.grab >= 0 {
                c.grab += dt
                let a = anchors(of: figures[o]), nose = SIMD2(a.head.x + figures[o].facing * figures[o].radii.z * 1.1, a.head.y)
                let u = min(c.grab / Tuning.carrotGrab, 1)
                c.pos = c.from + (nose - c.from) * (u * u * (3 - 2 * u))
                if u >= 1 {
                    figures[o].carrot = true; figures[o].critter.fetchX = nil; figures[o].critter.regrow = 0
                    figuresVersion &+= 1
                    carrots.remove(at: k)
                    continue
                }
            } else if !c.lying {
                c.vel.y -= 900 * dt
                c.pos += c.vel * dt
                if c.pos.y <= top, c.vel.y < 0 { c.pos.y = top; c.lying = true; c.angle = -c.vel.x * 0.01 + 0.15; c.vel = .zero }
            } else {
                c.pos.y = top
                if abs(figures[o].foot.x - c.pos.x) <= Tuning.carrotReach { c.grab = 0; c.from = c.pos }
            }
            carrots[k] = c
        }
    }

    // MARK: Drawing

    public func rabbitLook(of f: Figure) -> RabbitLook {
        let c = f.critter
        var l = RabbitLook(foot: f.foot, facing: f.facing, scale: f.scale, hop: f.pose.hop, squash: f.pose.squash, ear: c.ear, bob: f.pose.shake, fade: f.fade)
        l.carry = c.carrying
        if c.stage == .snatch { l.flight = c.carrot }
        return l
    }

    /// Lying / falling / returning carrots as prims; `shift` gives the drag offset of a surface id.
    public func writeCarrotPrims(_ w: inout PrimWriter, shift: (Int?) -> SIMD2<Float>) {
        for c in carrots { Rig.carrotPiece(at: c.pos + shift(c.surface), angle: c.angle, length: 6.5 * c.size, alpha: 1, into: &w) }
    }
}
