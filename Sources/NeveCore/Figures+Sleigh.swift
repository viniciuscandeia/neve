import CoreGraphics
import Foundation

extension Tuning {
    static let sleighSpeed: Float = 140         // pt/s
    static let sleighBob: Float = 8             // pt of vertical swing ...
    static let sleighBobPeriod: Float = 3       // ... per this many seconds
    static let sleighHalfLength: Float = 60     // pt at scale 1 (the whole team is ~120 pt long)
    static let sleighRelease: Float = 33        // pt behind the team's centre where gifts leave the sleigh
}

/// One crossing: where it flies, how many reindeer, and the x (of the release point) where each gift is dropped, in flight order.
struct SleighState {
    var dir: Float = 1, endX: Float = 0, y0: Float = 0, scale: Float = 1, t: Float = 0
    var deer = 2
    var drops = SIMD3<Float>(repeating: 0), count = 0, next = 0
    var trail: Float = 0
}

extension SnowField {
    /// Start-to-start mean interval and the cooldown inside it: Dec 24-25 every 10 min, the rest of December 45 min, otherwise 3 h;
    /// the cooldown is 20 min at most (a fifth of the interval when that is shorter), so the Poisson part is `mean - cooldown`.
    var sleighInterval: (mean: Float, cooldown: Float) {
        if config.sleighDemo { return (1, 25) }
        let total: Float = calendarDay.month == 12 ? (calendarDay.day == 24 || calendarDay.day == 25 ? 600 : 2700) : 10800
        let cooldown = min(1200, total * 0.2)
        return (total - cooldown, cooldown)
    }

    /// The option is on, the screen is not compact (maximized window), and the economy modes (one ambient, no sleigh) are off.
    var sleighAllowed: Bool { sleighEnabled && areaScale >= 1 && !economy && !lowPower }

    /// Per-second chance of a start (called once a second by the director); also fixes the cooldown the next end will use.
    func sleighChance() -> Float {
        let i = sleighInterval
        director.sleighCooldown = i.cooldown
        return config.sleighDemo ? 1 : director.speed / i.mean
    }

    /// Seconds-free forward simulation of a gift falling `height` pt from the sleigh: horizontal distance it drifts (same integrator as `stepGifts`).
    private func giftTravel(height: Float, dir: Float) -> Float {
        var x: Float = 0, y = height, vx = dir * Tuning.sleighSpeed, vy: Float = 0
        let dt: Float = 1 / 120
        while y > 0 {
            vy = max(vy - Tuning.debrisGravity * 0.8 * dt, -1300); vx -= vx * 1.5 * dt
            x += vx * dt; y += vy * dt
        }
        return abs(x)
    }

    /// Starts a crossing if there is at least one visible pile (mean >= 4pt over +-5 columns) for a gift. Gifts alive + new <= 3.
    func startSleigh() -> Bool {
        guard sleighAllowed, !figures.contains(where: { $0.kind == .sleigh }), !surfaces.isEmpty else { return false }
        let room = Tuning.maxGifts - giftState.gifts.count
        guard room > 0 else { return false }
        var s = SleighState()
        s.dir = abs(wind) > 2 ? (wind < 0 ? -1 : 1) : (Bool.random(using: &rng) ? 1 : -1)
        s.scale = snowmanScale
        s.deer = Int.random(in: 2...4, using: &rng)
        let top = visibleTop - Float.random(in: 0.15...0.25, using: &rng) * (visibleTop - groundY)
        s.y0 = top
        let want = min(Int.random(in: 1...3, using: &rng), room)
        var xs: [Float] = []
        for _ in 0..<60 where xs.count < want {
            let si = Int.random(in: 0..<surfaces.count, using: &rng)
            let n = surfaces[si].pile.heights.count
            guard n > 12, surfaces[si].id != draggingID else { continue }
            let b = Int.random(in: 5..<(n - 5), using: &rng)
            var sum: Float = 0, low = Float.infinity, seen = true
            for k in (b - 5)...(b + 5) { sum += surfaces[si].pile.heights[k]; low = min(low, surfaces[si].pile.heights[k]); seen = seen && surfaces[si].pile.visible[k] }
            guard seen, low >= 3, sum / 11 >= 4 else { continue }
            let x = binCenter(surfaces[si].c0 + b), ground = surfaces[si].edgeY + surfaces[si].pile.base[b] + sum / 11
            guard supportTop(x: x, fromY: top)?.0 == si, top - 8 * s.scale - ground > 20,
                  !xs.contains(where: { abs($0 - x) < 40 }), !giftState.gifts.contains(where: { abs($0.pos.x - x) < 24 }) else { continue }
            let rel = x - s.dir * giftTravel(height: top - 8 * s.scale - ground, dir: s.dir)
            guard rel > 20, rel < size.x - 20 else { continue }
            xs.append(rel)
        }
        guard !xs.isEmpty else { return false }
        let d = s.dir
        xs.sort { d > 0 ? $0 < $1 : $0 > $1 }
        for (k, x) in xs.enumerated() { s.drops[k] = x }
        s.count = xs.count
        let edge = Tuning.sleighHalfLength * s.scale + 12
        let startX = d > 0 ? -edge : size.x + edge
        s.endX = d > 0 ? size.x + edge : -edge
        var f = Figure(id: nextFigureID, kind: .sleigh, foot: SIMD2(startX, top), radii: .zero, fromBalls: true)
        nextFigureID += 1
        f.built = 0; f.facing = d; f.phase = .walking
        f.sleigh = s
        figures.append(f)
        figuresVersion &+= 1
        return true
    }

    /// Flies across, bobbing; drops its gifts as it passes their release points; throws 3 glints a second from the tail. False when removed.
    func stepSleigh(_ i: Int, _ dt: Float) -> Bool {
        guard sleighEnabled, walkEnabled, !calm, !outro else { removeFigure(i); return false }
        var f = figures[i]
        var s = f.sleigh
        f.phaseT += dt
        s.t += dt
        let d = s.dir
        f.foot.x += d * Tuning.sleighSpeed * dt
        f.foot.y = s.y0 + Tuning.sleighBob * sin(2 * .pi * s.t / Tuning.sleighBobPeriod)
        let release = f.foot.x - d * Tuning.sleighRelease * s.scale
        while s.next < s.count, (release - s.drops[s.next]) * d >= 0 {
            dropGift(at: SIMD2(release, f.foot.y - 8 * s.scale), dir: d)
            s.next += 1
        }
        s.trail += dt
        if s.trail >= 1 / 3 {
            s.trail -= 1 / 3
            if glints.count < Tuning.maxGlints, !economy, !lowPower {
                let p = SIMD2(f.foot.x - d * (Tuning.sleighHalfLength + 4) * s.scale, f.foot.y + Float.random(in: -8...8, using: &rng))
                glints.append(Flake(pos: p, vx: 0, fall: 0, phase: 0, amp: 0, freq: 0, size: Float.random(in: 4...6, using: &rng), alpha: 1, kind: .debris,
                                    seed: Float.random(in: 0..<1, using: &rng), fade: 1, delay: Tuning.glintLife, shape: 4))
            }
        }
        if (f.foot.x - s.endX) * d >= 0 { removeFigure(i); return false }
        f.sleigh = s
        figures[i] = f
        return true
    }

    public func sleighLook(of f: Figure) -> SleighLook {
        SleighLook(pos: f.foot, facing: f.facing, scale: f.sleigh.scale, deer: f.sleigh.deer, t: f.sleigh.t)
    }
}
