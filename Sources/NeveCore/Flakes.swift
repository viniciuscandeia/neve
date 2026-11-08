import CoreGraphics
import Foundation

public enum FlakeKind: UInt8 { case sky, background, debris, dormant }

/// Plain-old-data flake (no references).
public struct Flake {
    public var pos: SIMD2<Float>
    public var vx: Float
    public var fall: Float
    var phase: Float
    var amp: Float
    var freq: Float
    var size: Float
    var alpha: Float
    public var kind: FlakeKind
    var seed: Float = 0     // per-flake shape variant / rotation (0..1)
    var fade: Float = 1     // 0..1 fade-in after a spawn; multiplied into alpha
    // Effects (Effects.swift): shape 0 dot, 1 clump, 2 slab, 3 puff, 4 glint (= Instance.kind)
    var rot: Float = 0      // radians
    var spin: Float = 0     // rad/s
    var vol: Float = 0      // carried snow (area, pt^2): deposited where it lands; 0 = legacy size-based deposit
    var delay: Float = 0    // slab: seconds aloft; puff / glint: seconds of life left
    var shape: UInt8 = 0
    var prof: UInt32 = 0    // falling chunk: packed top profile (Effects.swift `Flake.pack`)
    var wv: Float = 0       // sky/background: lateral speed from the wind field, relaxing toward it (inertia grows with size)
}

extension SnowField {
    func spawn(_ kind: FlakeKind, anywhere: Bool) -> Flake {
        // Compact mode: new snow appears just above the live strip (behind the window); `anywhere` spans the whole screen.
        let x = anywhere ? Float.random(in: 0...size.x, using: &rng) : Float.random(in: liveX0...max(liveX0, liveX1), using: &rng)
        let y = anywhere ? Float.random(in: 0...size.y, using: &rng) : liveTop + Float.random(in: 0...40, using: &rng)
        let phase = Float.random(in: 0...(2 * .pi), using: &rng)
        switch kind {
        case .background:
            let s = Float.random(in: 1.5...3.5, using: &rng)
            return Flake(pos: [x, y], vx: Tuning.wind * 0.6 * Float.random(in: 0.7...1.3, using: &rng), fall: 18 + s * 9 + Float.random(in: 0...8, using: &rng),   // terminal speed grows with size
                         phase: phase, amp: Float.random(in: 5...15, using: &rng) * swayAmp(s), freq: Float.random(in: 0.8...2, using: &rng) * swayFreq(s),
                         size: s, alpha: max(0.35, depthAlpha(s) + Float.random(in: -0.06...0.06, using: &rng)), kind: .background,
                         seed: Float.random(in: 0..<1, using: &rng), fade: anywhere ? 1 : 0)
        default:
            let s = Float.random(in: 2.5...7, using: &rng)
            return Flake(pos: [x, y], vx: Tuning.wind * Float.random(in: 0.7...1.3, using: &rng), fall: 40 + s * 8 + Float.random(in: 0...10, using: &rng),
                         phase: phase, amp: Float.random(in: 8...25, using: &rng) * swayAmp(s), freq: Float.random(in: 0.8...2, using: &rng) * swayFreq(s),
                         size: s, alpha: min(1, depthAlpha(s) + Float.random(in: -0.06...0.06, using: &rng)), kind: .sky,
                         seed: Float.random(in: 0..<1, using: &rng), fade: anywhere ? 1 : 0)
        }
    }

    /// Bigger flakes sway wider and slower.
    func swayAmp(_ s: Float) -> Float { 0.7 + 0.04 * s }
    func swayFreq(_ s: Float) -> Float { 1.6 / (1 + 0.12 * s) }

    /// Bigger = nearer = more opaque: 0.5 at 1.5pt up to 1 at 7pt.
    func depthAlpha(_ s: Float) -> Float { 0.5 + 0.5 * (s - 1.5) / 5.5 }

    /// 0..<1 position of slot `i` among the active ones of its pool (the order they wake in during the intro).
    func introRank(_ i: Int) -> Float { i < skyCount ? Float(i) / Float(skyLimit) : Float(i - skyCount) / Float(bgLimit) }

    func isActive(_ i: Int) -> Bool { i < skyCount ? i < skyLimit : i - skyCount < bgLimit }

    /// Smooth gusts: slow sines with unrelated periods; sign flips over several seconds.
    func windShape() -> Float {
        0.55 * sin(time * 2 * .pi / 37) + 0.3 * sin(time * 2 * .pi / 17 + 1.3) + 0.25 * sin(time * 2 * .pi / 9 + 2.1)
    }

    func stepFlakes(dt: Float) {
        let x0 = liveX0 - 10, w = liveX1 - liveX0 + 20
        var liveSky = 0, liveBg = 0   // one past the last non-dormant slot of each pool
        for n in 0..<(skyEnd + bgEnd) {
            let i = n < skyEnd ? n : skyCount + n - skyEnd
            var f = flakes[i]
            if f.kind == .dormant {
                if isActive(i), !quiet, introDur > 0 ? introRank(i) < introT / introDur : Float.random(in: 0..<1, using: &rng) < dt * 0.3 { flakes[i] = spawn(i < skyCount ? .sky : .background, anywhere: false) }
                continue
            }
            let prevY = f.pos.y
            f.fade = quiet ? max(0, f.fade - dt * (melting && !calm ? 0.7 : 1.5)) : min(1, f.fade + dt * 2.5)   // ~0.4s fade-in; ~0.7s fade-out in the outro
            if quiet, f.fade == 0 { f.kind = .dormant; flakes[i] = f; continue }
            f.phase += f.freq * dt
            // Wind: a gust field varying across the screen and in time; flakes relax toward it (heavier = slower to respond).
            let gust = 1 + 0.5 * sin(f.pos.x * 0.005 + time * 0.35)
            f.wv += (wind * gust * f.vx / Tuning.wind - f.wv) * min(1, dt / (0.4 + 0.25 * f.size))
            // Sway: two incommensurate sines (flutter) instead of one.
            let sway = cos(f.phase) + 0.45 * cos(1.618 * f.phase + f.seed * 6.2832)
            f.pos.x += (f.vx + f.wv + 0.69 * f.amp * (calm ? Tuning.calmSway : 1) * musicSway * sway) * dt
            f.pos.y -= f.fall * dt * (calm ? 0.5 : 1 + (0.06 + 0.012 * f.size) * sin(2 * f.phase))   // vertical flutter, a bit more for big flakes
            if let p = pointer {
                let d = f.pos - p, d2 = d.x * d.x + d.y * d.y
                if d2 < Tuning.pointerRadius * Tuning.pointerRadius, d2 > 1e-4 {
                    // Radial push plus a tangential swirl (always one side, so a flake dead above the pointer slides off),
                    // stronger when close and when the pointer moves; decays smoothly to 0 at the radius.
                    let dist = d2.squareRoot(), k = 1 - dist / Tuning.pointerRadius, k2 = k * k
                    let gain = 1 + min((pointerVel.x * pointerVel.x + pointerVel.y * pointerVel.y).squareRoot() / 400, 2)
                    let radial = Tuning.pointerPush * k2 * gain / dist, swirl = Tuning.pointerSwirl * k2 * gain / dist
                    f.pos.x += (d.x * radial - d.y * swirl + pointerVel.x * 0.4 * k2) * dt
                    f.pos.y += (d.y * radial + d.x * swirl + pointerVel.y * 0.4 * k2) * dt
                }
            }
            if f.pos.x < x0 { f.pos.x += w } else if f.pos.x > x0 + w { f.pos.x -= w }
            if f.kind == .sky, tryLand(x: f.pos.x, prevY: prevY, newY: f.pos.y, volume: f.size * Tuning.depositScale) {
                f = spawn(.sky, anywhere: false)
            } else if f.pos.y < -f.size {
                f = spawn(f.kind, anywhere: false)
            }
            if !isActive(i), f.pos.y > liveTop { f.kind = .dormant }   // just respawned: retire
            flakes[i] = f
            if f.kind != .dormant { if i < skyCount { liveSky = i + 1 } else { liveBg = i - skyCount + 1 } }
        }
        skyEnd = max(skyLimit, liveSky); bgEnd = max(bgLimit, liveBg)
        if introT >= introDur { introDur = 0 }
    }

    func tryLand(x: Float, prevY: Float, newY: Float, volume: Float, fall: Float = 0, vol: Float = 0) -> Bool {
        if quiet { return false }   // nothing lands, so nothing rebuilds: snow falls through
        let c = column(x)
        var best = -1
        var bestTop = -Float.infinity
        for k in Int(offsets[c])..<Int(offsets[c + 1]) {
            let e = entries[k]
            let s = Int(e.surface)
            let top = e.edgeY + surfaces[s].pile.heights[c - surfaces[s].c0]
            if prevY >= e.edgeY, newY < top, top > bestTop { best = s; bestTop = top }
        }
        guard best >= 0 else { return false }
        if fall > Tuning.heavyFall, vol > Tuning.heavyVol { impact(surface: best, bin: c - surfaces[best].c0, x: x, top: bestTop, fall: fall, vol: vol) }
        else {
            let v = vol > 0 ? vol / Tuning.binWidth : volume
            if surfaces[best].id == 0 { deposit(dock: best, bin: c - surfaces[best].c0, volume: v, powder: vol == 0) } else { deposit(surface: best, bin: c - surfaces[best].c0, volume: v, powder: vol == 0) }
        }
        return true
    }
}
