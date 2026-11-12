// AGENT HEADER - Sources/NeveCore/Gifts.swift  (gifts dropped by the sleigh + confetti)
// Role: Tuning gift constants (<= 3 gifts, 9 pt box x snowmanScale, sinks 30 % into the pile, rests 90 s then fades over 1 s, lid 0.7 s, <= 28 confetti), `Gift` (falls like a loose ball, rests on a surface standing on the DRAWN snow via standY,
//   `out` 1 -> 0 over 0.4 s on outro / second half of a melt), `Confetti`, `GiftState` (SnowField.giftState) and SnowField code. `dropGift` (called by stepSleigh; no-op while quiet), `stepGifts` (same fall integrator that Figures+Sleigh.giftTravel
//   mirrors - keep both in sync; falls through a vanished pile), `openGift(at:)` (Option-click, from Overlay: pops the lid, 4 glints unless calm / economy / low power), `breakGifts` (a cursor sweep segment pops a gift: confetti + crumbs, called from
//   Surfaces.swift's sweep), `transportGifts` (window moved: x shift, or falls when shed speed > 0.5), `writeGiftPrims` (Rig.gift / confetti quads, honours the drag `shift`).
// Gifts also come from the Christmas tree (Tree.swift: 2-4 around its foot, list may reach maxGifts + 4). Gifts are stashed across Space switches (Stashed.gifts) and removed by clear(). Uses `rng`. Tests: SleighTests (drop / open).

import CoreGraphics
import Foundation

extension Tuning {
    static let maxGifts = 3
    static let giftSize: Float = 9
    static let giftSink: Float = 0.3         // share of the box that rests inside the pile
    static let giftLife: Float = 90          // s resting before it fades (over 1 s)
    static let lidLife: Float = 0.7          // s the popped lid flies
    static let maxConfetti = 28
}

/// A wrapped box dropped by the sleigh. Falls like a loose ball, rests sunk into a pile, fades after 90 s.
public struct Gift {
    public internal(set) var pos: SIMD2<Float>           // centre
    var vel: SIMD2<Float>
    public internal(set) var surface: Int?                // nil while falling
    public internal(set) var rot: Float = 0
    var spin: Float
    public let color: UInt8                               // 0 red, 1 green, 2 gold
    public internal(set) var rest: Float = 0              // seconds resting
    public internal(set) var opened: Float = -1           // < 0 closed; else seconds since the lid popped off
    public internal(set) var land: Float = 1              // seconds since touching down (squash + bounce for the first 0.27 s)
    public var scale: Float = 1                           // snowman scale at drop time
    public var size: Float { Tuning.giftSize * scale }
    var out: Float = 1                                    // 1 -> 0 over 0.4 s when the snow goes (outro, half-way through a melt)
    public var fade: Float { min(max(1 - (rest - Tuning.giftLife), 0), 1) * out }
    public var falling: Bool { surface == nil }
}

/// A paper scrap of a popped gift (drawn as a tiny coloured quad; the white crumbs are ordinary clumps).
struct Confetti {
    var pos: SIMD2<Float>, vel: SIMD2<Float>
    var rot: Float, spin: Float
    let color: UInt8
    var life: Float
}

struct GiftState {
    var gifts: [Gift] = [], confetti: [Confetti] = []
    init() { gifts.reserveCapacity(Tuning.maxGifts + 1); confetti.reserveCapacity(Tuning.maxConfetti) }
}

extension SnowField {
    public var gifts: [Gift] { giftState.gifts }

    func dropGift(at p: SIMD2<Float>, dir: Float) {
        guard giftState.gifts.count < Tuning.maxGifts, !quiet else { return }
        giftState.gifts.append(Gift(pos: p, vel: SIMD2(dir * Tuning.sleighSpeed, 0), surface: nil, rot: 0, spin: Float.random(in: -3...3, using: &rng) , color: UInt8.random(in: 0...2, using: &rng), scale: snowmanScale))
    }

    /// Resting y of the box centre over a pile top.
    private func giftRest(_ g: Gift) -> Float { g.size * (0.5 - Tuning.giftSink) }

    func stepGifts(dt: Float) {
        let leaving = outro || (melting && meltT >= meltDur * 0.5)   // gifts fade; confetti is short-lived and fades by itself
        var i = giftState.confetti.count - 1
        while i >= 0 {
            var c = giftState.confetti[i]
            c.life -= dt
            if c.life <= 0 { giftState.confetti.swapAt(i, giftState.confetti.count - 1); giftState.confetti.removeLast(); i -= 1; continue }
            c.vel.y -= 500 * dt; c.vel.x -= c.vel.x * 2 * dt; c.pos += c.vel * dt; c.rot += c.spin * dt
            giftState.confetti[i] = c
            i -= 1
        }
        i = giftState.gifts.count - 1
        while i >= 0 {
            defer { i -= 1 }
            var g = giftState.gifts[i]
            if g.opened >= 0 { g.opened += dt }
            if leaving { g.out -= dt * fadeK / 0.4; if g.out <= 0 { giftState.gifts.remove(at: i); continue } }
            if let sid = g.surface {
                guard let si = index[sid], column(g.pos.x) - surfaces[si].c0 >= 0, column(g.pos.x) - surfaces[si].c0 < surfaces[si].pile.heights.count,
                      surfaces[si].pile.alive(column(g.pos.x) - surfaces[si].c0) else { g.surface = nil; g.vel = .zero; g.spin = 0; giftState.gifts[i] = g; continue }   // the pile is gone: it falls on
                g.rest += dt; g.land += dt
                if g.rest >= Tuning.giftLife + 1 { giftState.gifts.remove(at: i); continue }
                g.pos.y = standY(si: si, x: g.pos.x) + giftRest(g)
            } else {
                let prev = g.pos
                g.vel.y = max(g.vel.y - Tuning.debrisGravity * 0.8 * dt, -1300)
                g.vel.x -= g.vel.x * 1.5 * dt
                g.pos += g.vel * dt
                g.rot += g.spin * dt
                g.pos.x = min(max(g.pos.x, 5), size.x - 5)
                if let (si, _, top) = supportTop(x: g.pos.x, fromY: prev.y), g.pos.y <= top + giftRest(g) {
                    g.pos.y = standY(si: si, x: g.pos.x) + giftRest(g); g.land = 0
                    g.surface = surfaces[si].id; g.vel = .zero; g.spin = 0
                    g.rot = Float.random(in: -0.25...0.25, using: &rng)
                    if !calm, !silent { addPuff(x: g.pos.x, y: top + 2) }
                }
                if g.pos.y < -20 { giftState.gifts.remove(at: i); continue }
            }
            giftState.gifts[i] = g
        }
    }

    /// Index of the resting, closed gift under `q` (within a few points of the box).
    func giftUnder(_ q: SIMD2<Float>) -> Int? {
        for i in giftState.gifts.indices where !giftState.gifts[i].falling && openAt(surface: giftState.gifts[i].surface, x: giftState.gifts[i].pos.x) {
            let d = q - giftState.gifts[i].pos
            if d.x * d.x + d.y * d.y <= (giftState.gifts[i].size / 2 + 4) * (giftState.gifts[i].size / 2 + 4) { return i }
        }
        return nil
    }

    /// ⌥-click on a gift: the lid pops off and a few glints burst. False when there is no closed gift there.
    public func openGift(at p: CGPoint) -> Bool {
        guard let i = giftUnder(SIMD2(Float(p.x), Float(p.y))), giftState.gifts[i].opened < 0 else { return false }
        giftState.gifts[i].opened = 0
        let c = giftState.gifts[i].pos
        guard !calm, !economy, !lowPower else { return true }   // glints are off in these modes (stepGlints would drop them the same frame)
        // Make room (at most maxGlints alive): the oldest sparkles fade quickly instead of being wiped.
        var live = glints.filter { $0.fade >= 1 }.count
        for k in glints.indices where live > Tuning.maxGlints - 4 && glints[k].fade >= 1 { glints[k].fade = 0.99; live -= 1 }   // < 1 = dying (stepGlints)
        for _ in 0..<4 where live < Tuning.maxGlints {
            live += 1
            glints.append(Flake(pos: c + SIMD2(Float.random(in: -9...9, using: &rng), Float.random(in: 0...12, using: &rng)), vx: 0, fall: 0, phase: 0, amp: 0, freq: 0,
                                size: Float.random(in: 4...7, using: &rng), alpha: 1, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1, delay: Tuning.glintLife, shape: 4))
        }
        return true
    }

    /// Cursor segment a->b through a gift pops it: coloured confetti plus white crumbs.
    func breakGifts(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ r: Float, _ v: SIMD2<Float>) {
        guard !giftState.gifts.isEmpty else { return }
        let dx = bx - ax, dy = by - ay, len2 = max(dx * dx + dy * dy, 1e-6)
        var i = giftState.gifts.count - 1
        while i >= 0 {
            defer { i -= 1 }
            let g = giftState.gifts[i]
            let t = min(max(((g.pos.x - ax) * dx + (g.pos.y - ay) * dy) / len2, 0), 1)
            let ex = ax + t * dx - g.pos.x, ey = ay + t * dy - g.pos.y, reach = r + g.size / 2
            guard ex * ex + ey * ey <= reach * reach else { continue }
            giftState.gifts.remove(at: i)
            for _ in 0..<14 where giftState.confetti.count < Tuning.maxConfetti {
                let a = Float.random(in: 0..<(2 * .pi), using: &rng), sp = Float.random(in: 50...170, using: &rng)
                giftState.confetti.append(Confetti(pos: g.pos, vel: SIMD2(cos(a) * sp, sin(a) * sp + 60) + v * 0.3, rot: a, spin: Float.random(in: -9...9, using: &rng),
                                                   color: UInt8.random(in: 0...2, using: &rng), life: Float.random(in: 0.6...1.0, using: &rng)))
            }
            if !silent {
                for _ in 0..<5 {
                    let a = Float.random(in: 0..<(2 * .pi), using: &rng), sp = Float.random(in: 40...110, using: &rng)
                    _ = put(Flake(pos: g.pos, vx: cos(a) * sp + v.x * 0.2, fall: -sin(a) * sp, phase: 0, amp: 0, freq: 0, size: Float.random(in: 2.5...3.5, using: &rng),
                                  alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1, spin: Float.random(in: -2...2, using: &rng), shape: 1))
                }
            }
        }
    }

    /// Windows moved / closed: gifts resting on them travel along (x shift) or fall, same rules as balls.
    func transportGifts(before: [Surface]) {
        guard !giftState.gifts.isEmpty else { return }
        for i in giftState.gifts.indices {
            guard let sid = giftState.gifts[i].surface, sid != Tuning.groundID, sid != 0 else { continue }
            guard let ni = index[sid], let o = before.first(where: { $0.id == sid }) else { giftState.gifts[i].surface = nil; continue }
            let n = surfaces[ni]
            if SnowField.shedFraction(v: n.vel, prev: o.vel) > 0.5 { giftState.gifts[i].surface = nil; giftState.gifts[i].vel = n.vel * 0.5; continue }
            giftState.gifts[i].pos.x += Float(n.frame.minX - o.frame.minX)
        }
    }

    /// Gifts and confetti as prims; `shift` gives the drag offset of a surface id.
    public func writeGiftPrims(_ w: inout PrimWriter, contrast: Bool = false, shift: (Int?) -> SIMD2<Float>) {
        for g in giftState.gifts { Rig.gift(g, offset: shift(g.surface), contrast: contrast, into: &w) }
        for c in giftState.confetti { Rig.confetti(center: c.pos, rot: c.rot, color: c.color, alpha: min(1, c.life * 3), into: &w) }
    }
}
