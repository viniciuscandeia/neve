import CoreGraphics
import Foundation

extension Tuning {
    static let penguinWaddle: Float = 18        // pt/s
    static let penguinRock: Float = 8 * .pi / 180   // rad of body rock while waddling, at `penguinRockHz`
    static let penguinRockHz: Float = 2.5
    static let penguinSlide: Float = 90         // pt/s belly-slide start speed
    static let penguinDecel: Float = 25         // pt/s^2
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
    var spray: Float = 0            // plowed area (pt^2) still owed as debris
    var duck: Float = 0             // seconds of cursor-duck hop left
    var lastBall = 0                // ball it last launched from (no double launch)
    var leaving = false
    var slides = 0, launches = 0, groove: Float = 0   // tests / diagnostics
}

extension SnowField {
    /// Pile top under x, raised by a resting user ball (the ramp): also what the penguin's feet follow.
    func penguinSupport(si: Int, x: Float) -> Float {
        var y = standY(si: si, x: x)
        let sid = surfaces[si].id
        for b in balls where b.state == .resting && b.parent == nil && !b.melting && b.surfaceID == sid {
            let dx = x - b.pos.x
            if abs(dx) < b.radius { y = max(y, b.pos.y + (b.radius * b.radius - dx * dx).squareRoot()) }
        }
        return y
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
                figuresVersion &+= 1
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
            if ex * ex + ey * ey <= rad * rad, figures[i].penguin.duck <= 0 { figures[i].penguin.duck = 0.3; figuresVersion &+= 1 }
        }
    }

    /// Plows a shallow trench under the belly (see `Pile.plow`); the area not banked in berms comes back as a forward spray of debris.
    private func plowPath(si: Int, x: Float, dir d: Float, _ p: inout PenguinState, y: Float) {
        let w: Float = 6, ref = p.ref   // the level when the slide began: the berm and spray piled ahead must not raise the cut
        guard ref > 0.3 else { return }
        let sprayed = surfaces[si].pile.plow(centerX: x, halfWidth: w, depth: min(Tuning.penguinGroove, 0.35 * ref) * min(p.t / 0.2, 1), ref: ref, berm: Tuning.penguinBerm, side: d, maxStep: 1)
        if sprayed > 0 { pilesDirty = true; p.spray += sprayed }
        while p.spray >= Tuning.penguinPuff {
            let size = Tuning.penguinPuff / (Tuning.depositScale * Tuning.binWidth)   // lands as exactly the area it took
            guard addDebris(x: x + d * 4, y: y + 14, vx: d * (max(p.speed, 0) + Float.random(in: 30...150, using: &rng)), fall: Float.random(in: 0...30, using: &rng), size: size) else { break }
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
        guard let sid = f.surfaceID, let si = index[sid], let run = penguinRun(si: si, x: f.foot.x) else { removeFigure(i); return false }
        let prevX = f.foot.x, d = p.dir
        f.facing = d
        switch p.stage {
        case .rise:
            let u = min(p.t / 0.4, 1), e = u * (2 - u)
            f.fade = e; f.pose.hop = -(1 - e) * 18 * f.scale
            if p.t >= 0.4 { p.stage = .waddle; p.t = 0 }
        case .waddle, .stand:
            if p.stage == .stand {
                let u = min(p.t / 0.2, 1)
                p.angle = Tuning.penguinFlop * (1 - u * (2 - u))
                if u >= 1 { p.stage = .waddle; p.t = 0; p.angle = 0 }
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
            if u >= 1 { p.stage = .slide; p.t = 0; p.speed = Tuning.penguinSlide; p.slides += 1; p.ref = meanHeight(si: si, col: column(f.foot.x), span: 1) ?? 0 }
        case .slide:
            p.speed -= Tuning.penguinDecel * dt
            f.foot.x += d * max(p.speed, 0) * dt
            plowPath(si: si, x: f.foot.x, dir: d, &p, y: f.foot.y)
            p.groove += abs(f.foot.x - prevX)
            if p.speed <= Tuning.penguinSlideEnd { p.stage = .stand; p.t = 0; p.sinceSlide = 0 }
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
        let target = penguinSupport(si: si, x: f.foot.x)
        f.foot.y = target > f.foot.y ? f.foot.y + (target - f.foot.y) * min(1, 18 * dt) : target
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
        let flap: Float = p.stage == .waddle ? sin(2 * .pi * Tuning.penguinRockHz * p.rockT) : p.stage == .slide || p.stage == .flop ? -1 : p.stage == .air ? 1 : 0
        return PenguinLook(foot: f.foot, facing: f.facing, scale: f.scale, hop: f.pose.hop, angle: p.angle + rock, flap: flap, fade: f.fade * f.melt)
    }
}
