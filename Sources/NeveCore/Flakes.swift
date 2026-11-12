// AGENT HEADER - Sources/NeveCore/Flakes.swift  (the snowfall: Flake struct, spawn, stepFlakes, landing)
// Role: `Flake` (plain-old-data shared by sky / background / near / debris / dormant: pos, vx, fall, phase/amp/freq sway, size, alpha, seed, fade, rot/spin, vol = carried snow area, delay (slab aloft timer, or puff/glint life left), shape,
//   packed chunk profile `prof`, vel for motion streaks, wv wind inertia), `FlakeKind` (.sky and .background are the pooled snowfall; ONLY .sky flakes land in stepFlakes; .near = rare big out-of-focus foreground discs, never land;
//   .debris lands through Debris.swift; .dormant = free slot) and SnowField `spawn` (during the Christmas tree's burst most respawns get their x around the tree, drawn from `treeRng` after the normal spawn: `rng` consumption is unchanged), `stepFlakes(dt:)` (THE per-frame hot path: gust LUT, per-flake sway with a bandGain notch near 0.2 Hz, wind, pointer push/swirl, live-region
//   wrap for compact mode, intro / outro / melt fade rules, landing test per flake), `tryLand(x:prevY:newY:volume:fall:vol:span:)` (highest OPEN surface top crossed this frame (`Pile.open`: not hidden and not under another window's body, any stacking order; the wind-leeward hop may cross a seam onto the touching neighbour) -> `deposit`, heavy falls -> Effects.impact; returns false
//   while `quiet`), `stepWindDust` (strong gusts: a puff + a sliver of crest volume moves one bin leeward, conserved; only between `open` bins), `edgeCalm` (Reduce Motion: slower / fewer flakes near the left / right 12 %), size / alpha / sway helpers,
//   `introRank` / `slotKind` / `isActive` (pool bookkeeping: sky slots [0, skyCount), background after it, the first nearLimit sky slots are .near).
// Perf: stepFlakes loops only [0, skyEnd) and [skyCount, skyCount + bgEnd), uses fastSin / fastCos (Util.swift), no allocation; its cost is timed through `timer` (flakesim in NEVE_PERF). Units: sim seconds, pt, pt/s, y up.
// Gotchas: changing RNG consumption order changes every seeded test (DeterminismTests, FlakeMotionTests); sizes are biased small (u^2.2); the wind-slide in tryLand uses a hash, not `rng`, to keep the stream unchanged. tryLand: a landing the pile cannot keep is no longer discarded: Pile.deposit owes it to the nearest window end (Pile.owe, SnowField.stepOverflow); the Dock bar / ground heap ceiling still refuses it (bankRefused).
// Callers: SnowField.step. Rendered by Render.writeInstances + the flake shader (Renderer.swift).

import CoreGraphics
import Foundation

public enum FlakeKind: UInt8 { case sky, background, debris, dormant, near }   // near: rare big out-of-focus foreground flakes (never land)

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
    var vel: SIMD2<Float> = .zero   // sky/background: velocity of the last step (pt/s), for the motion streak
    var wv: Float = 0       // sky/background: lateral speed from the wind field, relaxing toward it (inertia grows with size)
}

extension SnowField {
    /// Reduce Motion, HIG (avoid motion at the periphery): 1 in the middle, easing (smoothstep) down to 0.3 at the left/right screen edge over the outer 12% of the width.
    /// Scales fall and sway of the flakes there and the share of new flakes spawned there.
    static func edgeCalm(x: Float, width: Float) -> Float {
        guard width > 0 else { return 1 }
        let t = min(max(min(x, width - x) / (0.12 * width), 0), 1)
        return 0.3 + 0.7 * t * t * (3 - 2 * t)
    }

    /// A new flake. During the Christmas tree's warning gust most respawns appear within `burstHalfWidth` of the tree's x (x drawn from `treeRng` AFTER the normal spawn, so `rng` is consumed exactly as without a burst).
    func spawn(_ kind: FlakeKind, anywhere: Bool) -> Flake {
        var f = spawnPlain(kind, anywhere: anywhere)
        if let b = burst, !anywhere, kind != .near, Float.random(in: 0..<1, using: &treeRng) < 0.85 { f.pos.x = b.x + Float.random(in: -Tuning.burstHalfWidth...Tuning.burstHalfWidth, using: &treeRng) }
        return f
    }

    private func spawnPlain(_ kind: FlakeKind, anywhere: Bool) -> Flake {
        // Compact mode: new snow appears just above the live strip (behind the window); `anywhere` spans the whole screen.
        var x = anywhere ? Float.random(in: 0...size.x, using: &rng) : Float.random(in: liveX0...max(liveX0, liveX1), using: &rng)
        if calm {   // fewer flakes at the edges: rejection sampling against edgeCalm (3 redraws; the rare 4th is kept)
            for _ in 0..<3 where Float.random(in: 0..<1, using: &rng) >= Self.edgeCalm(x: x, width: size.x) {
                x = anywhere ? Float.random(in: 0...size.x, using: &rng) : Float.random(in: liveX0...max(liveX0, liveX1), using: &rng)
            }
        }
        let y = anywhere ? Float.random(in: 0...size.y, using: &rng) : liveTop + Float.random(in: 0...40, using: &rng)
        let phase = Float.random(in: 0...(2 * .pi), using: &rng)
        switch kind {
        case .background:
            let s = Self.sampleSize(1.5, 3.5, u: Float.random(in: 0..<1, using: &rng))
            return Flake(pos: [x, y], vx: Tuning.wind * 0.6 * Float.random(in: 0.7...1.3, using: &rng), fall: 18 + s * 9 + Float.random(in: 0...8, using: &rng),   // terminal speed grows with size
                         phase: phase, amp: Float.random(in: 5...15, using: &rng) * swayAmp(s), freq: Float.random(in: 0.8...2, using: &rng) * swayFreq(s),
                         size: s, alpha: max(0.35, depthAlpha(s) + Float.random(in: -0.06...0.06, using: &rng)), kind: .background,
                         seed: Float.random(in: 0..<1, using: &rng), fade: anywhere ? 1 : 0)
        case .near:
            let s = Float.random(in: 8...13, using: &rng)
            return Flake(pos: [x, y], vx: Tuning.wind * Float.random(in: 0.7...1.3, using: &rng), fall: Float.random(in: 75...100, using: &rng),
                         phase: phase, amp: Float.random(in: 30...55, using: &rng) * swayAmp(s), freq: Float.random(in: 0.35...0.7, using: &rng) * swayFreq(s),
                         size: s, alpha: Tuning.nearAlpha + Float.random(in: -0.04...0.04, using: &rng), kind: .near,
                         seed: Float.random(in: 0..<1, using: &rng), fade: anywhere ? 1 : 0)
        default:
            let s = Self.sampleSize(2.5, 7, u: Float.random(in: 0..<1, using: &rng))
            return Flake(pos: [x, y], vx: Tuning.wind * Float.random(in: 0.7...1.3, using: &rng), fall: 40 + s * 8 + Float.random(in: 0...10, using: &rng),
                         phase: phase, amp: Float.random(in: 8...25, using: &rng) * swayAmp(s), freq: Float.random(in: 0.8...2, using: &rng) * swayFreq(s),
                         size: s, alpha: min(1, depthAlpha(s) + Float.random(in: -0.06...0.06, using: &rng)), kind: .sky,
                         seed: Float.random(in: 0..<1, using: &rng), fade: anywhere ? 1 : 0)
        }
    }

    /// Sizes biased small: lo + (hi - lo) * u^2.2 (median of the sky range ~3.5pt); only the rare big ones get the crystal outline.
    static func sampleSize(_ lo: Float, _ hi: Float, u: Float) -> Float { lo + (hi - lo) * pow(u, 2.2) }

    /// Bigger flakes sway wider and slower.
    func swayAmp(_ s: Float) -> Float { 0.7 + 0.04 * s }
    func swayFreq(_ s: Float) -> Float { 1.6 / (1 + 0.12 * s) }

    /// Bigger = nearer = more opaque: 0.5 at 1.5pt up to 1 at 7pt.
    func depthAlpha(_ s: Float) -> Float { 0.5 + 0.5 * (s - 1.5) / 5.5 }

    /// 0..<1 position of slot `i` among the active ones of its pool (the order they wake in during the intro).
    func introRank(_ i: Int) -> Float { i < skyCount ? Float(i) / Float(skyLimit) : Float(i - skyCount) / Float(bgLimit) }

    /// Kind a respawn in slot `i` takes: the first `nearLimit` sky slots hold the rare out-of-focus flakes.
    func slotKind(_ i: Int) -> FlakeKind { i >= skyCount ? .background : i < nearLimit ? .near : .sky }

    func isActive(_ i: Int) -> Bool { i < skyCount ? i < skyLimit : i - skyCount < bgLimit }

    /// Global wind: smooth noise in time (Util.windNoise), so it never visibly repeats.
    func windShape() -> Float { windNoise(time) }

    /// Sway attenuation near 0.2 Hz (Apple HIG: avoid sustained ambient oscillation there): 1 outside 0.15...0.25 Hz, 0.35 at 0.2 Hz.
    static func bandGain(_ omega: Float) -> Float {
        let d = abs(omega * 0.159_155 - 0.2) / 0.05
        return d >= 1 ? 1 : 0.35 + 0.65 * d * d
    }

    func stepFlakes(dt: Float) {
        let gt = Float((time * 0.12).truncatingRemainder(dividingBy: 4096))   // gust clock (noise lattice wraps at 4096), once per call
        let dn = Float((time * 0.05).truncatingRemainder(dividingBy: 4096)) * 6.2832   // per-flake drift clock (~20 s)
        let x0 = liveX0 - 10, w = liveX1 - liveX0 + 20
        // The gust field depends on one diagonal coordinate s = 0.004x + 0.0025y: sample it once per step into a table.
        let gs0 = (x0 - 60) * 0.004 + (-300) * 0.0025 + 33, gs1 = (x0 + w + 60) * 0.004 + (size.y + 300) * 0.0025 + 33
        let gn = gustLUT.count - 1, gStep = max(1e-3, (gs1 - gs0) / Float(gn)), gInv = 1 / gStep
        for k in 0...gn { gustLUT[k] = 1 + 0.6 * valueNoise(gs0 + Float(k) * gStep, gt) }
        nearLimit = calm || economy || lowPower ? 0 : Int((Float(skyLimit) * Tuning.nearFraction).rounded())   // off in the economy modes (still snow never steps)
        var liveSky = 0, liveBg = 0   // one past the last non-dormant slot of each pool
        for n in 0..<(skyEnd + bgEnd) {
            let i = n < skyEnd ? n : skyCount + n - skyEnd
            var f = flakes[i]
            if f.kind == .dormant {
                if isActive(i), !quiet, introDur > 0 ? introRank(i) < introT / introDur : Float.random(in: 0..<1, using: &rng) < dt * 0.3 { flakes[i] = spawn(slotKind(i), anywhere: false) }
                continue
            }
            let prevY = f.pos.y
            let q = quiet || (f.kind == .near && i >= nearLimit)   // near flakes fade out when their layer switches off
            f.fade = q ? max(0, f.fade - dt * (melting && !calm ? 0.7 : 1.5)) : min(1, f.fade + dt * 2.5)   // ~0.4s fade-in; ~0.7s fade-out in the outro
            if q, f.fade == 0 { f.kind = .dormant; flakes[i] = f; continue }
            let p0 = f.pos
            // Frequency and amplitude drift slowly per flake (seeded noise); amplitude is cut near 0.2 Hz.
            // Each sky flake drifts at its own slow rate and phase (one sin/cos pair); far background flakes keep their own constant sway.
            var omega = f.freq, ampNow = f.amp
            if f.kind != .background {
                let dp = dn * (0.7 + 0.6 * f.seed) + f.seed * 40
                omega *= 1 + 0.25 * fastSin(dp); ampNow *= 1 + 0.3 * fastCos(dp)
            }
            f.phase += omega * dt
            ampNow *= Self.bandGain(omega)
            // Wind: a gust field (value noise over position and time, no travelling band); flakes relax toward it (heavier = slower to respond).
            let gq = min(max((f.pos.x * 0.004 + f.pos.y * 0.0025 + 33 - gs0) * gInv, 0), Float(gn) - 0.001)
            let gk = Int(gq), gust = gustLUT[gk] + (gustLUT[gk + 1] - gustLUT[gk]) * (gq - Float(gk))
            f.wv += (wind * gust * f.vx / Tuning.wind - f.wv) * min(1, dt / (0.4 + 0.25 * f.size))
            // Sway: two incommensurate sines (flutter) instead of one.
            let sway = fastCos(f.phase) + 0.45 * fastCos(1.618 * f.phase + f.seed * 6.2832)
            let ek = calm ? Self.edgeCalm(x: f.pos.x, width: size.x) : 1   // Reduce Motion: slower toward the screen edges
            f.pos.x += (f.vx + f.wv + 0.69 * ampNow * (calm ? Tuning.calmSway : 1) * musicSway * sway) * dt * ek
            f.pos.y -= f.fall * dt * ek * (calm ? 0.5 : 1 + (0.06 + 0.012 * f.size) * fastSin(1.37 * f.phase + f.seed * 6.2832 + 2))   // vertical flutter (own frequency, not locked to the sway), a bit more for big flakes
            if pointerPush, let p = pointer {
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
            else if dt > 0 { f.vel = (f.pos - p0) / dt }   // a wrap would fake a screen-wide jump: keep the previous velocity
            if f.kind == .sky, tryLand(x: f.pos.x, prevY: prevY, newY: f.pos.y, volume: f.size * Tuning.depositScale) {
                f = spawn(slotKind(i), anywhere: false)
            } else if f.pos.y < -f.size {
                f = spawn(slotKind(i), anywhere: false)
            }
            if !isActive(i), f.pos.y > liveTop { f.kind = .dormant }   // just respawned: retire
            flakes[i] = f
            if f.kind != .dormant { if i < skyCount { liveSky = i + 1 } else { liveBg = i - skyCount + 1 } }
        }
        skyEnd = max(skyLimit, liveSky); bgEnd = max(bgLimit, liveBg)
        if introT >= introDur { introDur = 0 }
    }

    func tryLand(x: Float, prevY: Float, newY: Float, volume: Float, fall: Float = 0, vol: Float = 0, span: Float = 0) -> Bool {
        if quiet { return false }   // nothing lands, so nothing rebuilds: snow falls through
        let c = column(x)
        var best = -1
        var bestTop = -Float.infinity
        for k in Int(offsets[c])..<Int(offsets[c + 1]) {
            let e = entries[k]
            let s = Int(e.surface)
            guard landable(s), surfaces[s].pile.open(c - surfaces[s].c0) else { continue }   // landing support = visible and not under another window's body (geometry, any stacking order)
            let top = e.edgeY + surfaces[s].pile.heights[c - surfaces[s].c0]
            if prevY >= e.edgeY, newY < top, top > bestTop { best = s; bestTop = top }
        }
        guard best >= 0 else { return false }
        if fall > Tuning.heavyFall, vol > Tuning.heavyVol { impact(surface: best, bin: c - surfaces[best].c0, x: x, top: bestTop, fall: fall, vol: vol) }
        else {
            let v = vol > 0 ? vol / Tuning.binWidth : volume
            // A landing slab (span = its width) lays its volume along that width, not on three bins: no spike.
            var n = surfaces[best].pile.heights.count
            var b = c - surfaces[best].c0
            // Sustained wind: a flake landing on a crest slides one bin leeward when that bin is lower (volume only moves, never lost); past a seam end it hops onto the touching neighbour.
            if vol == 0, !calm, abs(windSlow) > 1 {
                let dir = windSlow > 0 ? 1 : -1, nb = b + dir, p = min(Tuning.windBiasMax, abs(windSlow) / Tuning.windBiasRef * Tuning.windBiasMax)
                let roll = Float(noise(c &* 7919 &+ Int(time * 997)) + 1) * 0.5   // hash, not rng: keeps the seeded random stream unchanged
                func top(_ s: Int, _ k: Int) -> Float { surfaces[s].edgeY + surfaces[s].pile.base[k] + surfaces[s].pile.heights[k] }
                if nb >= 0, nb < n { if surfaces[best].pile.open(nb), surfaces[best].pile.heights[nb] < surfaces[best].pile.heights[b], roll < p { b = nb } }
                else if roll < p, let nx = neighbor(si: best, dir: dir), landable(nx.si), surfaces[nx.si].pile.open(nx.bin), top(nx.si, nx.bin) < top(best, b) {
                    best = nx.si; b = nx.bin; n = surfaces[best].pile.heights.count
                }
            }
            let half = Int(span * invBin / 2)
            let lo = max(0, b - half), hi = min(n - 1, b + half), k = span > 2 * Tuning.binWidth && vol > 0 ? hi - lo + 1 : 1
            for i in (k > 1 ? lo...hi : b...b) {
                if surfaces[best].id == 0 { deposit(dock: best, bin: i, volume: v / Float(k), powder: vol == 0) } else { deposit(surface: best, bin: i, volume: v / Float(k), powder: vol == 0) }
            }
        }
        return true
    }
}

extension SnowField {
    /// Strong gusts lift a little dust from crests: a puff, and a sliver of the crest's volume moves to the lower leeward bin (conserved).
    func stepWindDust(dt: Float) {
        let a = abs(wind)
        guard !calm, !quiet, !economy, a > Tuning.dustWind, !surfaces.isEmpty, Float.random(in: 0..<1, using: &rng) < dt * Tuning.dustRate * (a / Tuning.dustWind - 1) else { return }
        let si = Int.random(in: 0..<surfaces.count, using: &rng)
        guard landable(si) else { return }
        let n = surfaces[si].pile.heights.count
        guard n > 2 else { return }
        let b = Int.random(in: 0..<n, using: &rng), nb = wind > 0 ? b + 1 : b - 1
        guard nb >= 0, nb < n, surfaces[si].pile.open(b), surfaces[si].pile.open(nb) else { return }
        let h = surfaces[si].pile.heights[b], hn = surfaces[si].pile.heights[nb]
        let v = min(Tuning.dustVol, (h - hn) * 0.25)
        guard h > Tuning.speckFloor, v > 0.01, hn + v <= surfaces[si].pile.limit(nb) else { return }
        surfaces[si].pile.heights[b] = h - v
        surfaces[si].pile.heights[nb] = hn + v
        pilesDirty = true
        addPuff(x: Float(surfaces[si].c0 + b) * Tuning.binWidth + Tuning.binWidth / 2, y: surfaces[si].edgeY + h)
    }
}
