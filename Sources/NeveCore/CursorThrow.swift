import CoreGraphics
import Foundation

extension Tuning {
    static let cursorStill: Float = 0.8       // s the cursor must stay (< 20 pt/s) with ⌥ down
    static let cursorStillSpeed: Float = 20   // pt/s
    static let cursorRange: Float = 300       // pt: the snowman must be this close
    static let cursorWindup: Float = 0.3      // s the arm takes to rise
    static let cursorGap: Float = 2           // s between throws while ⌥ stays down
    static let cursorMaxThrows = 3            // per hold
    static let cursorHit: Float = 0.7
}

/// ⌥ held on a still cursor away from snow: a snowman nearby turns, raises its arm and throws a snowball at the cursor.
struct CursorThrow {
    var still: Float = 0        // seconds the cursor has been still
    var windup: Float = -1      // < 0: arm down; else seconds the arm has been rising
    var cool: Float = 0         // seconds until the next windup may start
    var thrown = 0              // throws in this hold (reset when ⌥ is released)
    var who = 0                 // thrower's figure id
    var up: Float = 0           // 0...1 arm raise (windup, then it drops again)
}

extension SnowField {
    static let cursorTarget = -2   // `Shot.target` of a throw at the cursor (no figure is hit)

    /// The thrower: nearest complete, free snowman within range of `p` (body centre).
    private func cursorThrower(_ p: SIMD2<Float>) -> Int? {
        var best: Int?, bestD = Tuning.cursorRange * Tuning.cursorRange
        for j in figures.indices {
            let f = figures[j]
            guard f.active, f.built == Snowman.stageCount, f.fight == nil, f.motion.cheer <= 0, !f.headless else { continue }
            let d = p - SIMD2(f.foot.x, f.foot.y + f.radii.x), d2 = d.x * d.x + d.y * d.y
            if d2 <= bestD { best = j; bestD = d2 }
        }
        return best
    }

    func stepCursorThrow(dt: Float) {
        var c = cursorThrow
        defer { cursorThrow = c }
        var pose = false
        if let p = pointer, optionHeld, !calm {
            let v = pointerVel
            c.still = v.x * v.x + v.y * v.y < Tuning.cursorStillSpeed * Tuning.cursorStillSpeed ? c.still + dt : 0
            c.cool = max(0, c.cool - dt)
            var j: Int?
            if c.still >= Tuning.cursorStill, c.thrown < Tuning.cursorMaxThrows,
               areaScale >= 1 || (p.x >= liveX0 && p.x <= liveX1 && p.y <= liveTop),   // compact: only inside the live strip
               !hitTest(point: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))) { j = cursorThrower(p) }
            if let j {
                if c.windup < 0, c.cool <= 0 { c.windup = 0; c.who = figures[j].id }
                if c.windup >= 0 {
                    c.windup += dt
                    c.who = figures[j].id
                    figures[j].facing = p.x >= figures[j].foot.x ? 1 : -1
                    figures[j].motion.idle = max(figures[j].motion.idle, 0.3); figures[j].motion.rest = max(figures[j].motion.rest, 0.3)
                    c.up = min(1, c.windup / Tuning.cursorWindup)
                    pose = true
                    if c.windup >= Tuning.cursorWindup { throwAtCursor(j, p); c.windup = -1; c.cool = Tuning.cursorGap - Tuning.cursorWindup; c.thrown += 1 }
                }
            } else {
                c.windup = -1
            }
        } else {
            c.still = 0; c.windup = -1; c.cool = 0; c.thrown = 0
        }
        guard c.up > 0 else { return }
        if !pose { c.up = max(0, c.up - dt / 0.35) }   // arm comes down after the throw / when cancelled
        if let k = figureIndex(c.who) {
            figures[k].pose.flutter.up = c.up * c.up * (3 - 2 * c.up)
            figuresVersion &+= 1
        }
    }

    private func throwAtCursor(_ j: Int, _ p: SIMD2<Float>) {
        let a = anchors(of: figures[j]), dir = figures[j].facing
        let hit = Float.random(in: 0..<1, using: &rng) < Tuning.cursorHit
        let d = abs(p.x - a.arm.x)
        let to = hit ? p : SIMD2(p.x + dir * Float.random(in: 28...70, using: &rng), a.ground)   // a miss sails past the cursor
        shots.append(Shot(pos: a.arm, from: a.arm, to: to, peak: 18 + 0.18 * d, dur: 0.6 + 0.4 * min(d / Tuning.fightRange, 1), hit: hit, head: false,
                          target: SnowField.cursorTarget, surface: figures[j].surfaceID ?? Tuning.groundID))
    }
}
