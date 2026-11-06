import CoreGraphics
import Foundation

/// Deterministic showcase scenes for READMEs, screenshots and tests (`NEVE_SCENE=demo|fight`, see main.swift). Driven by simulation time
/// from `SnowField.step`, so the same seed and the same window frames always replay the same story.
public enum SceneKind: String, Sendable { case demo, fight }

/// `NEVE_SCENE=fight`: two user snowmen 150pt apart; head hits at 3.0 / 3.3 / 3.6 s (T = `fightT`), the head is carried back at 7 s, the loop restarts at 14 s.
public enum FightScene { public static let hits: [Float] = [3.0, 3.3, 3.6], fightT: Float = 3.6, restack: Float = 7, loop: Float = 14 }

struct SceneState {
    var kind: SceneKind
    var t: Float = 0
    var fired = Set<Int>()           // events already run in this loop
    var user = 0                     // the user snowman that loses its head
    var carry: Int?, carryFrom = SIMD2<Float>.zero   // the head being put back
    var rabbitPlaced = false
    var carryT0: Float = 0
}

public struct SceneWindow: Equatable, Sendable {
    public let title: String
    public let frame: CGRect
}

/// The three scene windows (front to back: Terminal, Fotos, Notas) for the visible area `vf` at scene time `t`. Notas sits high with its right
/// end over Fotos (avalanche cascade); Terminal overlaps Fotos and is 12pt taller (drift seam); at 25 s Fotos is slid 14% of the width to the left in 0.3 s.
public enum DemoScene {
    public static let loop: Float = 30
    public static let moveAt: Float = 25, moveDur: Float = 0.3
    public static func windows(in vf: CGRect, t: Float) -> [SceneWindow] {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: (vf.minX + vf.width * x).rounded(), y: (vf.minY + vf.height * y).rounded(), width: (vf.width * w).rounded(), height: (vf.height * h + dy).rounded())
        }
        let u = CGFloat(min(max((t - moveAt) / moveDur, 0), 1)), slide = -vf.width * 0.14 * u * u * (3 - 2 * u)
        return [SceneWindow(title: "Terminal", frame: r(0.62, 0.22, 0.28, 0.20, dy: 12)),
                SceneWindow(title: "Fotos", frame: r(0.34, 0.22, 0.34, 0.20).offsetBy(dx: slide, dy: 0)),
                SceneWindow(title: "Notas", frame: r(0.12, 0.52, 0.34, 0.30))]
    }
}

extension SnowField {
    /// Starts (or restarts) a scene on the current surfaces; call after the first `update(windows:)`.
    public func beginScene(_ kind: SceneKind) {
        scene = SceneState(kind: kind)
        resetWorld()
        runSetup()
    }
    /// Seconds into the running scene loop.
    public var sceneTime: Float? { scene?.t }

    private func resetWorld() {
        clear()
        giftState = GiftState(); chain = AvaChain(); icicles.removeAll(keepingCapacity: true); carrots.removeAll(); cursorThrow = CursorThrow()
        shotLand = nil; impactAt = nil
        director.queue.removeAll(); director.story = StoryState(); for i in director.cooldownUntil.indices { director.cooldownUntil[i] = 0 }
        snowmanCooldown = .infinity
    }

    private func runSetup() {
        guard let kind = scene?.kind, let (g, lo, hi, mid) = groundStretch() else { return }
        func place(_ x: Float) -> Float { min(max(x, lo), hi) }
        switch kind {
        case .demo:
            setIntensity(.forte)
            fillPiles(0.6)
            if autoFigure == nil, let id = addFigure(fromBalls: false, radii: Snowman.radii * snowmanScale, built: Snowman.stageCount, surface: g.id, x: place(mid + 200)), let i = figureIndex(id) { figures[i].stageAge = 1 }
        case .fight:
            setIntensity(.media)
            fillPiles(0.5)
            for x in [mid - 75, mid + 75] where figures.count < 2 { scene?.user = addFigure(fromBalls: true, radii: SIMD3(20, 14, 10), built: Snowman.stageCount, surface: g.id, x: x) ?? 0 }
        }
    }

    private func fire(_ id: Int, at t: Float) -> Bool {
        guard let s = scene, s.t >= t, !s.fired.contains(id) else { return false }
        scene?.fired.insert(id)
        return true
    }

    private var topWindow: Int? { surfaces.indices.filter { surfaces[$0].id > 0 }.max { surfaces[$0].edgeY < surfaces[$1].edgeY } }

    func stepScene(dt: Float) {
        guard scene != nil else { return }
        scene!.t += dt
        let kind = scene!.kind, t = scene!.t
        if t >= (kind == .demo ? DemoScene.loop : FightScene.loop) { scene = SceneState(kind: kind); resetWorld(); if kind == .fight { runSetup() }; return }
        if kind == .fight {
            for (k, at) in FightScene.hits.enumerated() where fire(20 + k, at: at) { headHit(final: k == FightScene.hits.count - 1) }
            if fire(23, at: FightScene.restack) { startCarry() }
            if let c = scene!.carry { carryHead(c, t: t) }
            return
        }
        if fire(0, at: 0.4) { runSetup() }
        if fire(1, at: 6), let (g, lo, hi, _) = groundStretch(), let a = autoFigure {
            let ax = figures[a].foot.x
            let x = ax - 110 >= lo ? ax - 110 : min(ax + 110, hi)
            scene!.user = addFigure(fromBalls: true, radii: SIMD3(20, 14, 10), built: Snowman.stageCount, surface: g.id, x: x) ?? 0
        }
        if fire(2, at: 6.5), let si = topWindow {   // lands on Notas, near its right end, ~17.5 s
            director.story.surface = surfaces[si].id; director.story.x = Float(surfaces[si].frame.maxX) - 90
            request(.robin, after: 0)
        }
        for (k, at) in [12.4, 12.7, 13.0].enumerated() where fire(3 + k, at: Float(at)) { headHit(final: k == 2) }
        if fire(6, at: 14) {
            for i in figures.indices where figures[i].kind == .snowman { figures[i].motion.rest = 0 }
            request(.rabbit, after: 0)
        }
        if !scene!.rabbitPlaced, let r = figures.firstIndex(where: { $0.kind == .rabbit }), let w = figureIndex(figures[r].critter.target) {
            scene!.rabbitPlaced = true   // starts 140pt from its stop point instead of walking in from the screen edge
            let side = figures[r].critter.side
            figures[r].critter.hopping = false
            figures[r].foot.x = figures[w].foot.x + side * (figures[w].radii.x + Tuning.rabbitGap + 140)
        }
        if fire(7, at: 16) { startCarry() }
        if let c = scene!.carry { carryHead(c, t: t) }
        if fire(8, at: 17.9) { fillAroundRobin() }
        if fire(9, at: 19.8), let r = figures.first(where: { $0.kind == .robin && !$0.robin.flying }) { shotLand = (r.foot + SIMD2(0, 4), time) }   // a miss lands next to it
        if fire(10, at: 22) { request(.sleigh, after: 0) }
    }

    /// Two body hits (wobble), then the head hit that pops it: forced to be the third, so the pop time never depends on the throws before it.
    private func headHit(final: Bool) {
        guard let j = figureIndex(scene!.user) else { return }
        if !final { registerHit(scene!.user, head: false); return }
        if let fo = figures[j].fight?.foe { figures[j].fight = (fo, Tuning.headHitsToLose - 1); registerHit(scene!.user, head: true); return }
        if let w = figures.firstIndex(where: { $0.kind == .snowman && $0.id != scene!.user }) { figures[w].motion.cheer = Tuning.cheerTime }   // no fight running: same ending
        decapitate(scene!.user, away: 1, range: nil)
    }

    private func startCarry() {
        guard let h = balls.first(where: { $0.parent == nil && $0.face != 0 }), let id = pickSnowball(at: CGPoint(x: CGFloat(h.pos.x), y: CGFloat(h.pos.y))) else { return }
        scene!.carry = id; scene!.carryFrom = h.pos; scene!.carryT0 = scene!.t
    }

    /// The head is carried over the body in 0.6 s, then let go: the body re-stacks it by itself.
    private func carryHead(_ id: Int, t: Float) {
        guard let j = figureIndex(scene!.user) else { scene!.carry = nil; return }
        let to = anchors(of: figures[j]).body + SIMD2(0, figures[j].radii.y + figures[j].radii.z + 30)
        let u = min((t - scene!.carryT0) / 0.6, 1), p = scene!.carryFrom + (to - scene!.carryFrom) * (u * u * (3 - 2 * u))
        drag(id, to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), dt: 1 / 60)
        if u >= 1 { drop(id, throwing: false); scene!.carry = nil }
    }

    /// Makes sure the pile under the robin is full, so its takeoff starts an avalanche.
    private func fillAroundRobin() {
        guard let r = figures.first(where: { $0.kind == .robin }), let si = index[r.robin.sid] else { return }
        let c0 = surfaces[si].c0, n = surfaces[si].pile.heights.count
        let b0 = max(0, column(r.foot.x - 90) - c0), b1 = min(n - 1, column(r.foot.x + 90) - c0)
        for b in b0...b1 where surfaces[si].pile.visible[b] { surfaces[si].pile.heights[b] = max(surfaces[si].pile.heights[b], surfaces[si].pile.limit(b)) }
        pilesDirty = true
    }
}
