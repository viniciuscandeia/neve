import CoreGraphics
import Foundation

public enum FigureKind: UInt8, Sendable { case snowman, rabbit, penguin, sleigh, robin }   // future: penguin, robin, sleigh (one `Figures+<Kind>.swift` + a Rig entry + an EventDirector spec)
public enum Phase: UInt8 { case building, idle, walking, fighting, cheering, collapsing, hidden }
/// Where a figure stands: on a surface at x (a window top, the Dock bar, the ground), or in the air.
public enum Attachment: Equatable { case surface(id: Int, x: Float), air }

/// Walking / fighting bookkeeping of one figure (not for rendering).
struct Motion {
    var speed: Float = Tuning.walkSpeed
    var windLean: Float = 0, flutter: Float = 0, phase: Float = 0, gait: Float = 0
    var idle: Float = 0, nextIdle: Float = 6, rest: Float = 0
    var wobble: Float = 0, cheer: Float = 0     // seconds of hit wobble / celebration left
    var squash: Float = 0, headHit: Float = 0   // seconds of hit squash (0.12) / head jitter (0.7) left
    var xfer: Xfer?                              // hop between two surfaces in progress (Walk.swift)
}

/// A hop from one surface to the adjacent one (ground <-> Dock): `from` / `to` are foot positions, t runs 0...1.
struct Xfer { var sid: Int, from: SIMD2<Float>, to: SIMD2<Float>, t: Float = 0 }

/// One actor on a surface. Data-oriented: one struct, `kind` picks the behaviour in a `switch`.
public struct Figure {
    public let id: Int
    public let kind: FigureKind
    public internal(set) var phase = Phase.idle
    public internal(set) var phaseT: Float = 0                  // seconds in the current phase
    public internal(set) var at = Attachment.air
    public internal(set) var foot: SIMD2<Float>                // x, and y of the pile top under it (resolved once per step)
    public internal(set) var facing: Float = 1                  // +-1
    public internal(set) var pose = Pose()
    public internal(set) var radii: SIMD3<Float>               // bottom, middle, head
    public internal(set) var built = Snowman.stageCount         // stages that have appeared (0...7)
    public internal(set) var progress: Float = 0                // 0...1 toward the next stage
    public internal(set) var stageAge: Float = 0                // seconds since the last stage appeared (ease-in, walking gate)
    public internal(set) var fade: Float = 1                    // 1 -> 0 while collapsing
    public let fromBalls: Bool                                  // false: the auto snowman
    public internal(set) var fight: (foe: Int, hits: Int)?
    public internal(set) var headless = false                   // lost its head: stands there, arms drooped
    public internal(set) var headTilt: Float = 0                // radians the head is turned (a re-stacked flying head straightens out)
    public internal(set) var droop: Float = 0                   // 0...1 arms hanging (eases to 1 once headless)
    public internal(set) var carrot = true                      // the snowman still has its nose (a rabbit may steal it)
    var robin = RobinState()                                    // (Figures+Robin.swift)
    var critter = Critter()                                     // visitor / theft bookkeeping (Figures+Rabbit.swift)
    var penguin = PenguinState()                                // Figures+Penguin.swift
    var sleigh = SleighState()                                  // sleigh crossing bookkeeping (Figures+Sleigh.swift)
    var motion = Motion()
    var melt: Float = 1                                         // visitors: 1 -> 0 while the snow melts away (multiplied into the look's fade)
    var scale: Float { radii.x / 11.5 }
    /// Takes part in the world (walks, fights, can be hit).
    var active: Bool { kind == .snowman && phase != .hidden && phase != .collapsing && phase != .building && !headless && stageAge >= 0.3 }
    public var surfaceID: Int? { if case .surface(let id, _) = at { return id }; return nil }

    init(id: Int, kind: FigureKind, foot: SIMD2<Float>, radii: SIMD3<Float>, fromBalls: Bool) {
        self.id = id; self.kind = kind; self.foot = foot; self.radii = radii; self.fromBalls = fromBalls
    }
}

struct Anchors {
    var base: SIMD2<Float>, body: SIMD2<Float>, head: SIMD2<Float>   // ball centres
    var arm: SIMD2<Float>                                             // throwing hand
    var ground: Float                                                 // pile top under the figure
}

extension SnowField {
    static let stackOverlap: Float = 1.5   // stacked balls sink into each other this much
    static let sink: Float = 0.8           // the bottom ball rests this share of its radius above the pile top

    public var canSpawnFigure: Bool { snowmanCount < Tuning.maxFigures }   // visitors (rabbit...) have their own cap in the EventDirector
    var snowmanCount: Int { var n = 0; for f in figures where f.kind == .snowman { n += 1 }; return n }

    func figureIndex(_ id: Int) -> Int? { figures.firstIndex { $0.id == id } }

    /// What the rig needs to draw the figure (foot = bottom of the base ball, before hop).
    public func look(of f: Figure) -> SnowmanLook {
        let t = min(f.stageAge / 0.3, 1)
        return SnowmanLook(foot: SIMD2(f.foot.x, f.foot.y - (1 - SnowField.sink) * f.radii.x), radii: f.radii, facing: f.facing, pose: f.pose,
                           built: f.built, newest: t * (2 - t), fade: f.fade, collapsing: f.phase == .collapsing, headless: f.headless, droop: f.droop, headTilt: f.headTilt, carrot: f.carrot)
    }

    /// One anchor set for every kind of figure, from foot + radii with the stacked-ball formula c(n+1) = c(n) + r(n) + r(n+1) - 1.5.
    func anchors(of f: Figure) -> Anchors {
        switch f.kind {
        case .rabbit, .penguin, .robin:
            let p = SIMD2(f.foot.x, f.foot.y + f.pose.hop)
            return Anchors(base: p, body: p, head: p, arm: p, ground: f.foot.y)
        case .sleigh:
            return Anchors(base: f.foot, body: f.foot, head: f.foot, arm: f.foot, ground: f.foot.y)
        case .snowman:
            let r = f.radii
            let y0 = f.foot.y + f.pose.hop + SnowField.sink * r.x
            let y1 = y0 + r.x + r.y - SnowField.stackOverlap, y2 = y1 + r.y + r.z - SnowField.stackOverlap
            let body = SIMD2(f.foot.x + f.pose.lean * 0.4, y1)
            return Anchors(base: SIMD2(f.foot.x, y0), body: body, head: SIMD2(f.foot.x + f.pose.lean, y2),
                           arm: SIMD2(body.x + f.facing * r.y * 0.8, y1 + r.y * 0.2), ground: f.foot.y)
        }
    }

    /// How many balls stand: all built ones up to three, two when headless.
    func ballCount(_ f: Figure) -> Int { f.headless ? 2 : min(f.built, 3) }

    func circle(_ a: Anchors, _ f: Figure, _ k: Int) -> (SIMD2<Float>, Float) {
        k == 0 ? (a.base, f.radii.x) : k == 1 ? (a.body, f.radii.y) : (a.head, f.radii.z)
    }

    /// Joins the world standing on surface `sid` at x (y from the pile unless given); nil when the cap is reached or the surface is unknown.
    @discardableResult
    func addFigure(fromBalls: Bool, radii: SIMD3<Float>, built: Int, surface sid: Int, x: Float, y: Float? = nil) -> Int? {
        guard canSpawnFigure, let si = index[sid] else { return nil }
        let s = surfaces[si], c = column(x)
        var top = y ?? s.edgeY
        if y == nil, let avg = meanHeight(si: si, col: c, span: 3) { top = s.edgeY + s.pile.base[c - s.c0] + avg }
        var f = Figure(id: nextFigureID, kind: .snowman, foot: SIMD2(x, top), radii: radii, fromBalls: fromBalls)
        nextFigureID += 1
        f.built = built
        f.at = .surface(id: sid, x: x)
        f.facing = Bool.random(using: &rng) ? 1 : -1
        f.motion.speed = Tuning.walkSpeed * Float.random(in: 0.8...1.2, using: &rng)
        f.motion.nextIdle = Float.random(in: 3...10, using: &rng)
        f.motion.phase = Float.random(in: 0..<6, using: &rng)
        f.phase = built < Snowman.stageCount ? .building : .idle
        figures.append(f)
        figuresVersion &+= 1
        return f.id
    }

    /// A resting stack of three decreasing balls (bottom ball `id`) becomes one figure; its balls are removed.
    @discardableResult
    public func promote(bottomBall id: Int) -> Int? {
        guard canSpawnFigure, let bi = balls.firstIndex(where: { $0.id == id }), balls[bi].parent == nil, balls[bi].state == .resting, !balls[bi].melting,
              let sid = balls[bi].surfaceID,
              let mi = balls.firstIndex(where: { $0.parent == id }), let hi = balls.firstIndex(where: { $0.parent == balls[mi].id }),
              balls[mi].radius < balls[bi].radius - 0.5, balls[hi].radius < balls[mi].radius - 0.5 else { return nil }
        let b = balls[bi], radii = SIMD3(b.radius, balls[mi].radius, balls[hi].radius)
        let gone = (b.id, balls[mi].id, balls[hi].id)
        guard let fid = addFigure(fromBalls: true, radii: radii, built: Snowman.stageCount, surface: sid, x: b.pos.x) else { return nil }
        balls.removeAll { $0.id == gone.0 || $0.id == gone.1 || $0.id == gone.2 }
        ballsVersion &+= 1
        return fid
    }

    /// The figure turns back into balls where it stands: a stack of three (two when headless). With `falling` the
    /// bottom ball drops with that velocity (the stack falls together). Returns the bottom and top ball ids.
    @discardableResult
    public func demote(_ id: Int, falling v: SIMD2<Float>? = nil) -> (bottom: Int, top: Int)? {
        guard let j = figureIndex(id), figures[j].kind == .snowman, figures[j].built == Snowman.stageCount, figures[j].phase != .collapsing else { return nil }
        let f = figures[j], a = anchors(of: f), sid = f.surfaceID
        var parent: Int?, bottom = 0, top = 0
        for k in 0..<ballCount(f) {
            let (c, r) = circle(a, f, k)
            var b = Snowball(id: nextBallID, pos: c, radius: r, surfaceID: sid)
            nextBallID += 1
            b.state = .resting; b.parent = parent
            if k == 0 {
                bottom = b.id
                if let v { b.state = .falling; b.surfaceID = nil; b.vel = v }
            } else {
                b.surfaceID = balls[balls.count - 1].surfaceID
            }
            parent = b.id; top = b.id
            balls.append(b)
        }
        removeFigure(j)
        ballsVersion &+= 1
        return (bottom, top)
    }

    /// Breaks a figure into debris thrown along `velocity` (a few dozen chunks per ball). The auto snowman fades its
    /// accessories for 0.4 s first (and starts the rebuild cooldown); a user-built one is gone at once.
    public func shatter(_ id: Int, velocity v: SIMD2<Float> = .zero) {
        guard let j = figureIndex(id), figures[j].phase != .collapsing else { return }
        if figures[j].kind != .snowman { removeFigure(j); return }
        let f = figures[j], a = anchors(of: f)
        if !silent {
            for k in 0..<ballCount(f) {
                let (c, r) = circle(a, f, k)
                let n = f.fromBalls ? Int(r * 1.5) + 4 : (k == 0 ? 36 : k == 1 ? 28 : 20)
                for _ in 0..<n {
                    let ang = Float.random(in: 0..<(2 * .pi), using: &rng), d = r * Float.random(in: 0...1, using: &rng).squareRoot()
                    let dx = cos(ang) * d, dy = sin(ang) * d
                    let size = f.fromBalls ? Float.random(in: 4...7, using: &rng) : Float.random(in: 5...8, using: &rng)
                    addDebris(x: c.x + dx, y: c.y + dy, vx: dx * 3 + v.x * 0.3 + Float.random(in: -10...10, using: &rng),
                              fall: Float.random(in: 0...40, using: &rng) - dy * 2 - v.y * 0.3, size: size)
                }
            }
        }
        if f.fromBalls { removeFigure(j); return }
        endFights(of: id)
        figures[j].phase = .collapsing; figures[j].phaseT = 0; figures[j].fade = 1
        figures[j].fight = nil; figures[j].pose = Pose()
        snowmanCooldown = Tuning.snowmanCooldown
        figuresVersion &+= 1
    }

    /// Drops figure `j` from the world; a fight it was in ends (the other one rests).
    func removeFigure(_ j: Int) {
        endFights(of: figures[j].id)
        if figures[j].kind != .snowman { director.ended(figures[j].kind, at: time) }
        figures.remove(at: j)
        figuresVersion &+= 1
    }

    /// Figures a user can grab: stacks they built, and any body that lost its head.
    func pickable(_ f: Figure) -> Bool { f.kind == .snowman && (f.fromBalls || f.headless) && f.built == Snowman.stageCount && f.phase != .collapsing && f.phase != .hidden }

    /// Index of the nearest pickable figure whose topmost ball is within `slack` of `q`, with its squared distance.
    func figureTop(at q: SIMD2<Float>, slack: Float) -> (Int, Float)? {
        var best: (Int, Float)?
        for j in figures.indices where pickable(figures[j]) {
            let f = figures[j], a = anchors(of: f), (c, r) = circle(a, f, ballCount(f) - 1)
            let d = q - c, d2 = d.x * d.x + d.y * d.y
            if d2 <= (r + slack) * (r + slack), d2 < (best?.1 ?? .infinity) { best = (j, d2) }
        }
        return best
    }

    /// Whether `q` is over any ball of a pickable figure.
    func overFigure(_ q: SIMD2<Float>) -> Bool {
        for f in figures where pickable(f) {
            let a = anchors(of: f)
            for k in 0..<ballCount(f) {
                let (c, r) = circle(a, f, k), d = q - c
                if d.x * d.x + d.y * d.y <= (r + 4) * (r + 4) { return true }
            }
        }
        return false
    }

    /// A loose head ball lands on a headless figure: it gets its head back (ease-in again, arms rise).
    func reattach(_ j: Int, radius: Float, tilt: Float = 0) {
        figures[j].headTilt = tilt - 2 * .pi * (tilt / (2 * .pi)).rounded()   // as it lay: eases to upright in 0.25 s
        figures[j].headless = false
        figures[j].radii.z = radius
        figures[j].stageAge = 0
        figures[j].motion.rest = 0
        figuresVersion &+= 1
    }

    // MARK: Simulation

    /// Runs from `step` after the loose balls: resolves where each figure stands, builds / collapses the auto one,
    /// walks, then runs the fights and the snowballs in flight.
    func stepFigures(dt: Float) {
        guard !figures.isEmpty || !fights.isEmpty || !shots.isEmpty else { return }
        let animate = walkEnabled && !calm
        if !animate { clearCritters() }
        if !animate, !fights.isEmpty || !shots.isEmpty { fights.removeAll(keepingCapacity: true); shots.removeAll(keepingCapacity: true) }
        var i = 0
        while i < figures.count {
            let before = figures[i]
            guard stepFigure(i, dt, animate: animate) else { continue }
            let f = figures[i]
            if f.foot != before.foot || f.pose != before.pose || f.facing != before.facing || f.phase != before.phase || f.built != before.built
                || f.kind != .snowman || f.carrot != before.carrot || f.headless != before.headless || f.droop != before.droop || f.headTilt != before.headTilt || f.fade != before.fade || f.stageAge < 0.35 { figuresVersion &+= 1 }
            i += 1
        }
        if animate, !melting {
            startFights()
            stepFights(dt)
            stepShots(dt)
            stepCarrots(dt)
            stepCursorThrow(dt: dt)
        }
    }

    /// False when the figure was removed (the next one now has its index).
    private func stepFigure(_ i: Int, _ dt: Float, animate: Bool) -> Bool {
        if figures[i].kind == .rabbit { return stepRabbit(i, dt) }
        if figures[i].kind == .robin { return stepRobin(i, dt) }
        if figures[i].kind == .penguin { return stepPenguin(i, dt) }
        if figures[i].kind == .sleigh { return stepSleigh(i, dt) }
        var f = figures[i]
        f.phaseT += dt
        if f.phase == .collapsing {
            f.fade -= dt / 0.4
            if f.fade <= 0 { removeFigure(i); return false }
            figures[i] = f
            return true
        }
        guard var sid = f.surfaceID, let si = index[sid], let avg = meanHeight(si: si, col: column(f.motion.xfer?.from.x ?? f.foot.x), span: 3) else {
            return lose(i)   // its surface is gone
        }
        let s = surfaces[si], c = column(f.motion.xfer?.from.x ?? f.foot.x) - s.c0
        let visible = s.pile.visible[c]
        if visible {
            if !f.fromBalls, avg < 1, !melting { collapse(); return true }   // pile cleared / knocked off under the auto snowman
            f.foot.y = s.edgeY + s.pile.base[c] + avg
        }
        f.stageAge += dt
        let dd = (f.headless ? 1 : 0) - f.droop
        f.droop += dd > 0 ? min(dd, dt / 0.6) : max(dd, -dt / 0.3)   // arms fall over 0.6 s, rise over 0.3 s
        if f.headTilt != 0 { f.headTilt *= exp(-16 * dt); if abs(f.headTilt) < 0.03 { f.headTilt = 0 } }
        if !f.fromBalls { advanceBuild(&f, si: si, dt: dt) }
        stepCarrot(&f, dt)
        var moving = false, landed = false
        if animate, visible, f.built == Snowman.stageCount, f.stageAge >= 0.3, !f.headless {
            if f.motion.xfer != nil { moving = true; if let to = hopStep(&f, dt) { sid = to; landed = true } }
            else { moving = f.critter.fetchX != nil ? fetchStep(&f, dt) : walkStep(&f, sid: sid, dt: dt) }
        } else if f.motion.gait != 0 || f.motion.cheer > 0 || f.pose != Pose() {
            if let x = f.motion.xfer { f.foot = x.from }   // interrupted mid-hop: back where it took off
            f.motion = Motion(speed: f.motion.speed, nextIdle: f.motion.nextIdle, rest: f.motion.rest)   // standing still: rest pose
            f.pose = Pose()
        }
        f.at = .surface(id: sid, x: f.foot.x)
        let c2 = column(f.foot.x) - s.c0, fits = landed || f.motion.xfer != nil || !visible || c2 < 0 || c2 >= s.pile.cap.count || s.pile.cap[c2] - s.pile.heights[c2] >= Snowman.height * f.scale   // after walking: still under the Dock bar / a low window
        let phase: Phase = !visible || !fits ? .hidden : f.built < Snowman.stageCount ? .building : f.motion.cheer > 0 ? .cheering
            : f.fight != nil ? .fighting : moving ? .walking : .idle
        if phase != f.phase { f.phase = phase; f.phaseT = 0 }
        figures[i] = f
        return true
    }

    /// The figure lost its surface (window closed): the auto one shatters, a stack falls apart. False when removed.
    private func lose(_ i: Int) -> Bool {
        if figures[i].fromBalls { demote(figures[i].id, falling: .zero); return false }
        collapse()
        return true
    }

    /// Windows moved / closed: figures on them travel along (x shift) or are knocked off, same rules as piles and balls.
    func transportFigures(before: [Surface]) {
        var i = figures.count - 1
        while i >= 0 {
            defer { i -= 1 }
            guard i < figures.count, figures[i].phase != .collapsing, let sid = figures[i].surfaceID, sid != Tuning.groundID, sid != 0 else { continue }
            guard let ni = index[sid], let o = before.first(where: { $0.id == sid }) else { knockOff(i, .zero); continue }
            let n = surfaces[ni]
            if SnowField.shedFraction(v: n.vel, prev: o.vel) > 0.5 { knockOff(i, n.vel * 0.5); continue }
            let dx = Float(n.frame.minX - o.frame.minX)
            if dx != 0 { figures[i].foot.x += dx; figures[i].at = .surface(id: sid, x: figures[i].foot.x); figuresVersion &+= 1 }
        }
    }

    private func knockOff(_ i: Int, _ v: SIMD2<Float>) {
        if figures[i].kind != .snowman { removeFigure(i) } else if figures[i].fromBalls { demote(figures[i].id, falling: v) } else { shatter(figures[i].id, velocity: v) }
    }

    /// The snowman switch went off: the auto snowman vanishes (no debris).
    func dropAutoFigure() {
        var i = figures.count - 1
        while i >= 0 {
            if !figures[i].fromBalls { removeFigure(i) }
            i -= 1
        }
    }

    /// Figures on windows go with them (Space switch).
    func dropWindowFigures() {
        var i = figures.count - 1
        while i >= 0 {
            if let sid = figures[i].surfaceID, sid != Tuning.groundID { removeFigure(i) }
            i -= 1
        }
    }
}
