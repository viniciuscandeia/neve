import CoreGraphics
import Foundation

extension Tuning {
    static let penguinWaddle: Float = 18        // pt/s
    static let penguinRock: Float = 8 * .pi / 180   // rad of body rock while waddling, at `penguinRockHz`
    static let penguinRockHz: Float = 2.5
    static let penguinSlide: Float = 90         // pt/s belly-slide start speed
    static let penguinDecelBase: Float = 8      // pt/s^2 on a skim of snow ...
    static let penguinDecelDepth: Float = 1.5   // ... plus this per pt of snow depth ahead of the belly (deep snow brakes harder)
    static let penguinBare: Float = 0.8         // pt: less snow than this ahead of the belly and the slide ends (it stands up)
    static let penguinSink: Float = 0.3         // share of the groove depth the lying body sits below the drawn snow
    static let penguinBermDeep: Float = 6       // piles at least this tall cut deep enough to throw chunks; shallower ones bank nearly all
    static let penguinSlideEnd: Float = 15      // pt/s: stands up below this
    static let penguinFlop: Float = -80 * .pi / 180
    static let penguinStretch: Float = 120      // pt ahead that must carry snow (mean h >= penguinMinH) for a slide
    static let penguinMinH: Float = 3
    static let penguinMinRun: Float = 200       // pt of visible window top the visit needs
    static let penguinGravity: Float = 300
}

/// Penguin bookkeeping (the actor is a `Figure` with `kind == .penguin`).
struct PenguinState {
    enum Stage: UInt8 { case rise, waddle, flop, slide, stand, air, sink }
    var stage = Stage.rise
    var t: Float = 0                // seconds in the stage
    var life: Float = 30            // seconds of visit left
    var dir: Float = 1
    var speed: Float = 0            // slide speed
    var vel = SIMD2<Float>.zero     // while airborne
    var angle: Float = 0            // body rotation (rad); negative = tipped forward onto the belly
    var spin: Float = 0             // rad/s while airborne
    var rockT: Float = 0
    var sinceSlide: Float = 0
    var ref: Float = 0              // pile height the groove is cut from (at slide start)
    var tilt: Float = 0             // extra body rotation (rad) following the local slope of the drawn snow
    var sink: Float = 0             // pt the lying body sits below the drawn snow (the groove)
    var puffD: Float = 0            // belly travel (pt) since the last trail puff
    var spray: Float = 0            // plowed area (pt^2) still owed as debris
    var duck: Float = 0             // seconds of cursor-duck hop left
    var lastBall = 0                // ball it last launched from (no double launch)
    var leaving = false
    var slides = 0, launches = 0, groove: Float = 0   // tests / diagnostics
}

extension SnowField {
    /// Pile top under x, raised by a resting user ball (the ramp): also what the penguin's feet follow.
    func penguinSupport(si: Int, x: Float, span: Int = 3) -> Float {
        var y = penguinSurface(si: si, x: x, span: span)
        let sid = surfaces[si].id
        for b in balls where b.state == .resting && b.parent == nil && !b.melting && b.surfaceID == sid {
            let dx = x - b.pos.x
            if abs(dx) < b.radius { y = max(y, b.pos.y + (b.radius * b.radius - dx * dx).squareRoot()) }
        }
        return y
    }

    /// Mean of the DRAWN snow height at x (columns clamped to the pile), via `meanShown`.
    private func penguinSnow(si: Int, x: Float, span: Int) -> Float {
        let c0 = surfaces[si].c0
        return meanShown(si: si, col: min(max(column(x) - c0, 0), surfaces[si].pile.heights.count - 1) + c0, span: span) ?? 0
    }

    /// y of the drawn snow top at x (what the belly rests on).
    func penguinSurface(si: Int, x: Float, span: Int) -> Float {
        let s = surfaces[si]
        return s.edgeY + s.pile.base[min(max(column(x) - s.c0, 0), s.pile.base.count - 1)] + penguinSnow(si: si, x: x, span: span)
    }

    private func penguinRun(si: Int, x: Float) -> (lo: Float, hi: Float)? {
        standRange(si: si, x: x, height: 22 * snowmanScale).map { (lo: $0.0, hi: $0.1) }
    }

    /// Starts a visit on the first window top with a visible run >= 200pt whose mean height is >= 3 (window-only: never the ground / Dock).
    func startPenguin() -> Bool {
        guard !visitorsGroundOnly, !figures.contains(where: { $0.kind == .penguin }) else { return false }
        for si in surfaces.indices where surfaces[si].id > 0 {
            let s = surfaces[si]
            for run in s.runs {
                let lo = max(Float(s.c0 + run.lowerBound) * Tuning.binWidth, s.pile.x0), hi = min(Float(s.c0 + run.upperBound) * Tuning.binWidth, s.pile.x1)
                guard hi - lo >= Tuning.penguinMinRun else { continue }
                var sum: Float = 0
                for b in run { sum += s.pile.heights[b] }
                guard sum / Float(run.count) >= Tuning.penguinMinH else { continue }
                let x = lo + (hi - lo) * Float.random(in: 0.25...0.75, using: &director.rng)
                var f = Figure(id: nextFigureID, kind: .penguin, foot: SIMD2(x, standY(si: si, x: x)), radii: SIMD3(repeating: 11.5 * snowmanScale), fromBalls: true)
                nextFigureID += 1
                f.at = .surface(id: s.id, x: x)
                f.phase = .walking
                f.fade = 0
                f.penguin.dir = hi - x >= x - lo ? 1 : -1
                f.penguin.life = Float.random(in: 20...40, using: &director.rng)
                f.facing = f.penguin.dir
                figures.append(f)
                return true
            }
        }
        return false
    }

    /// Demo hook (NEVE_DEMO_PENGUIN), called at 1 Hz: forces a visit every ~12 s while none is running.
    func stepPenguinDemo() -> Bool {
        guard config.penguinDemo, time.truncatingRemainder(dividingBy: 12) < 1, startPenguin() else { return false }
        director.lastStart = time; director.started += 1
        director.cooldownUntil[Int(FigureKind.penguin.rawValue)] = .infinity
        return true
    }

    /// A cursor segment through a penguin makes it duck (a small hop) instead of destroying it.
    func sweepPenguins(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ r: Float) {
        for i in figures.indices where figures[i].kind == .penguin && figures[i].penguin.stage != .air {
            let c = SIMD2(figures[i].foot.x, figures[i].foot.y + 9 * figures[i].scale), dx = bx - ax, dy = by - ay
            let t = min(max(((c.x - ax) * dx + (c.y - ay) * dy) / max(dx * dx + dy * dy, 1e-6), 0), 1)
            let ex = ax + t * dx - c.x, ey = ay + t * dy - c.y, rad = r + 10 * figures[i].scale
            if ex * ex + ey * ey <= rad * rad, figures[i].penguin.duck <= 0 { figures[i].penguin.duck = 0.3 }
        }
    }

    /// Plows a shallow U trench under the belly (see `Pile.plow`): berms bank behind the dent at the start (both sides) and ahead of the blade while it runs, leaving rims at both ends; the rest of the removed area flies on as chunks
    /// from the front of the belly at snow level (arc ~ speed) with a powder puff each, plus a trail of puffs. Snow is conserved.
    private func plowPath(si: Int, x: Float, dir d: Float, _ p: inout PenguinState, w: Float = 6, depth: Float, moved: Float, ramp: Float = 1, side: Float = 0) {
        let ref = p.ref   // the level when the slide began: the berm and spray piled around must not raise the cut
        guard ref > 0.3 else { return }
        let share = ref >= Tuning.penguinBermDeep ? Tuning.penguinBerm : 0.8   // shallow cuts bank nearly everything: no chunks
        let sprayed = surfaces[si].pile.plow(centerX: x, halfWidth: w, depth: min(depth, 0.35 * ref) * ramp, ref: ref, berm: share, side: side, maxStep: depth > Tuning.penguinGroove ? .infinity : 1)
        if sprayed > 0 { pilesDirty = true; p.spray += sprayed }
        let front = x + d * 7, top = penguinSurface(si: si, x: front, span: 1) + 1
        p.puffD += moved
        if p.puffD >= 6 { p.puffD = 0; addPuff(x: front, y: top + Float.random(in: 0...2, using: &rng)) }
        while p.spray >= Tuning.penguinPuff {
            let size = Tuning.penguinPuff / (Tuning.depositScale * Tuning.binWidth)   // lands as exactly the area it took
            guard addDebris(x: front, y: top, vx: d * (max(p.speed, 0) * 0.7 + Float.random(in: 20...90, using: &rng)), fall: Float.random(in: 0...15, using: &rng), size: size) else { break }
            addPuff(x: front, y: top)
            p.spray -= Tuning.penguinPuff
        }
    }

    /// Mean pile height over the `Tuning.penguinStretch` pt ahead (nil when the run ends sooner).
    private func stretchMean(si: Int, x: Float, dir: Float, run: (lo: Float, hi: Float)) -> Float? {
        guard (dir > 0 ? run.hi - x : x - run.lo) >= Tuning.penguinStretch else { return nil }
        var sum: Float = 0, n: Float = 0, d: Float = 0
        while d < Tuning.penguinStretch { sum += meanHeight(si: si, col: column(x + dir * d), span: 0) ?? 0; n += 1; d += Tuning.binWidth }
        return sum / n
    }

    /// One step of a visit. False when removed.
    func stepPenguin(_ i: Int, _ dt: Float) -> Bool {
        var f = figures[i]
        var p = f.penguin
        p.t += dt; p.life -= dt; p.rockT += dt; p.duck = max(0, p.duck - dt); p.sinceSlide += dt
        f.pose.hop = 0
        defer { if i < figures.count, figures[i].id == f.id { f.penguin = p; figures[i] = f } }
        if p.stage == .air { return flyPenguin(i, &f, &p, dt) }
        guard let sid = f.surfaceID, let si = index[sid], let run = penguinRun(si: si, x: f.foot.x) else { f.dying = true; return true }
        let prevX = f.foot.x, d = p.dir
        f.facing = d
        switch p.stage {
        case .rise:
            let u = min(p.t / 0.4, 1), e = u * (2 - u)
            f.fade = e; f.pose.hop = -(1 - e) * 18 * f.scale
            if p.t >= 0.4 { p.stage = .waddle; p.t = 0 }
        case .waddle, .stand:
            if p.stage == .stand {
                let u = min(p.t / 0.3, 1)
                p.angle = Tuning.penguinFlop * (1 - u * (2 - u))
                p.tilt *= max(0, 1 - 10 * dt); p.sink *= max(0, 1 - 10 * dt)
                if u >= 1 { p.stage = .waddle; p.t = 0; p.angle = 0; p.tilt = 0; p.sink = 0 }
            }
            f.foot.x += d * Tuning.penguinWaddle * dt
            if p.life <= 0, !p.leaving {
                p.leaving = true
                if sid <= 0 { p.stage = .sink; p.t = 0; break }
                p.dir = f.foot.x - run.lo < run.hi - f.foot.x ? -1 : 1   // heads for the nearer end
                f.facing = p.dir
            }
            if !p.leaving, p.stage == .waddle, p.sinceSlide > 4, let m = stretchMean(si: si, x: f.foot.x, dir: d, run: run), m >= Tuning.penguinMinH {
                p.stage = .flop; p.t = 0
            }
        case .flop:
            let u = min(p.t / 0.2, 1)
            p.angle = Tuning.penguinFlop * u * (2 - u)
            if u >= 1 {
                p.stage = .slide; p.t = 0; p.speed = Tuning.penguinSlide; p.slides += 1; p.ref = meanHeight(si: si, col: column(f.foot.x), span: 1) ?? 0; p.puffD = 0
                plowPath(si: si, x: f.foot.x, dir: d, &p, w: 7, depth: 1.5 * Tuning.penguinGroove, moved: 0)   // the belly lands: a deeper dent ...
                for k in 0..<2 { addPuff(x: f.foot.x + Float(k * 2 - 1) * 6, y: penguinSurface(si: si, x: f.foot.x, span: 1) + 1) }   // ... and a puff
            }
        case .slide:
            let ahead = penguinSnow(si: si, x: f.foot.x + d * 8, span: 1)
            p.speed -= (Tuning.penguinDecelBase + Tuning.penguinDecelDepth * ahead) * dt
            f.foot.x += d * max(p.speed, 0) * dt
            let moved = abs(f.foot.x - prevX), ramp = min(p.t / 0.2, 1)
            plowPath(si: si, x: f.foot.x, dir: d, &p, depth: Tuning.penguinGroove, moved: moved, ramp: ramp, side: d)
            p.groove += moved
            let s0 = penguinSurface(si: si, x: f.foot.x - 4 * d, span: 1), s1 = penguinSurface(si: si, x: f.foot.x + 4 * d, span: 1), sm = penguinSurface(si: si, x: f.foot.x, span: 1)
            let target = min(max(atan2(s1 - s0, 8), -0.4), 0.4)
            p.tilt += (target - p.tilt) * min(1, 12 * dt)
            p.sink = min(Tuning.penguinSink * max(p.ref - penguinSnow(si: si, x: f.foot.x, span: 1), 0), 1) * ramp
            let rough = abs(penguinSurface(si: si, x: f.foot.x + 3, span: 0) + penguinSurface(si: si, x: f.foot.x - 3, span: 0) - 2 * sm)
            f.pose.hop += min(rough, 1) * 0.4 * sinf(30 * p.t)
            if p.speed <= Tuning.penguinSlideEnd || ahead < Tuning.penguinBare { p.stage = .stand; p.t = 0; p.sinceSlide = 0 }
        case .sink:
            let u = min(p.t / 0.45, 1)
            f.foot.x += d * 8 * dt
            f.fade = 1 - u; f.pose.hop = -u * u * 18 * f.scale
            if u >= 1 { removeFigure(i); return false }
        default: break
        }
        if p.stage == .waddle || p.stage == .slide {
            for b in balls where b.state == .resting && b.parent == nil && !b.melting && b.surfaceID == sid && b.id != p.lastBall {
                guard (prevX - b.pos.x) * d < 0, (f.foot.x - b.pos.x) * d >= 0 else { continue }
                let v = max(p.stage == .slide ? p.speed : 0, 60)
                launch(&f, &p, from: SIMD2(b.pos.x, b.pos.y + b.radius), v: v, vy: 0.8 * v, spin: true)
                p.lastBall = b.id
                return true
            }
            if d > 0 ? f.foot.x >= run.hi - 3 : f.foot.x <= run.lo + 3 {   // window end: fly off, or hop down behind the edge
                if Bool.random(using: &director.rng) {
                    let v = max(p.stage == .slide ? p.speed : 0, 40)
                    launch(&f, &p, from: f.foot, v: v, vy: 0.8 * v, spin: false)
                } else { p.stage = .sink; p.t = 0; p.angle = 0 }
                return true
            }
        }
        let target = penguinSupport(si: si, x: f.foot.x, span: p.stage == .slide || p.stage == .flop || p.stage == .stand ? 1 : 3)
        f.foot.y = target > f.foot.y && p.stage != .slide ? f.foot.y + (target - f.foot.y) * min(1, 18 * dt) : target   // `shown` is already eased: the slide follows it exactly
        if p.duck > 0, p.stage != .rise { f.pose.hop += 5 * f.scale * sin(.pi * (1 - p.duck / 0.3)) }
        f.at = .surface(id: sid, x: f.foot.x)
        if p.stage != .rise, p.stage != .sink { f.fade = 1 }
        return true
    }

    private func launch(_ f: inout Figure, _ p: inout PenguinState, from pos: SIMD2<Float>, v: Float, vy: Float, spin: Bool) {
        f.foot = pos; f.at = .air
        p.stage = .air; p.t = 0; p.launches += 1
        p.vel = SIMD2(p.dir * v, vy)
        p.spin = spin ? -p.dir * 2 * .pi / (2 * vy / Tuning.penguinGravity) : 0   // one full turn in the air
        if !spin { p.angle = 0 }
    }

    /// Ballistic flight: lands on the highest pile / ball top it falls onto (a lower window or the ground too), else leaves the screen.
    private func flyPenguin(_ i: Int, _ f: inout Figure, _ p: inout PenguinState, _ dt: Float) -> Bool {
        let prev = f.foot
        p.vel.y -= Tuning.penguinGravity * dt
        f.foot += p.vel * dt
        p.angle += p.spin * dt
        if f.foot.x < -30 || f.foot.x > size.x + 30 || f.foot.y < -30 { removeFigure(i); return false }
        guard p.vel.y < 0 else { return true }
        var land: (sid: Int, y: Float)?
        if let (si, _, top) = supportTop(x: f.foot.x, fromY: prev.y), f.foot.y <= top { land = (surfaces[si].id, top) }
        for b in balls where b.state == .resting && b.parent == nil && !b.melting {
            guard let sid = b.surfaceID, abs(f.foot.x - b.pos.x) < b.radius else { continue }
            let dx = f.foot.x - b.pos.x, top = b.pos.y + (b.radius * b.radius - dx * dx).squareRoot()
            if f.foot.y <= top, prev.y >= top - 1, top > (land?.y ?? -.infinity) { land = (sid, top) }
        }
        guard let l = land else { return true }
        p.stage = .waddle; p.t = 0; p.angle = 0; p.spin = 0; p.vel = .zero
        f.foot.y = l.y; f.at = .surface(id: l.sid, x: f.foot.x)
        if p.life < 6 { p.life = 6 }
        return true
    }

    public func penguinLook(of f: Figure) -> PenguinLook {
        let p = f.penguin
        let rock = p.stage == .waddle ? Tuning.penguinRock * sin(2 * .pi * Tuning.penguinRockHz * p.rockT) : 0
        let flap: Float = p.stage == .waddle ? sin(2 * .pi * Tuning.penguinRockHz * p.rockT)
            : p.stage == .slide ? -0.8 + 0.2 * sin(2 * .pi * 7 * p.rockT)   // tucked back with a light flutter
            : p.stage == .flop ? -1 : p.stage == .stand ? sin(.pi * min(p.t / 0.3, 1)) : p.stage == .air ? 1 : 0   // stand: a flipper push
        let lie: Float = p.stage == .flop || p.stage == .slide || p.stage == .stand ? min(max(p.angle / Tuning.penguinFlop, 0), 1) : 0
        return PenguinLook(foot: f.foot, facing: f.facing, scale: f.scale, hop: f.pose.hop, angle: p.angle + p.tilt + rock, flap: flap, fade: f.fade * f.melt, lie: lie, sink: p.sink)
    }
}
