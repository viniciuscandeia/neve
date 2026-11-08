import CoreGraphics
import Foundation

/// One column slice waiting to be grouped into a slab (see `shedBin`).
struct RunBin {
    var col: Int
    var y: Float   // bottom of the slice
    var h: Float
}

/// Snow-in-motion effects: slabs, crumbs, dust puffs, impact craters, crest glints. Everything lives in `debris` / `glints` as
/// plain flakes with a `shape`, so the writer, the cap and the landing code stay shared.
extension SnowField {
    /// Snow of one column slice [from, from+amount] falls. Consecutive columns (up to 8 = 16pt, same velocity) are collected and
    /// emitted together by `flushRuns`, which every releasing entry point calls when it is done; this returns what an earlier run flushed.
    func shedBin(col: Int, edgeY: Float, from: Float, amount h: Float, velocity v: SIMD2<Float>) -> Int {
        guard h > 0.5, !silent else { return 0 }
        var n = 0
        if let last = runBins.last, col != last.col + 1 || runBins.count == 8 || v != runV { n = flushRuns() }
        runBins.append(RunBin(col: col, y: edgeY + from, h: h))
        runV = v
        return n
    }

    /// Emits the pending run: one slab (+ crumbs and dust) when it is >= 8pt wide and averages >= 3pt; else plain dots.
    @discardableResult
    func flushRuns() -> Int {
        let k = runBins.count
        guard k > 0 else { return 0 }
        defer { runBins.removeAll(keepingCapacity: true) }
        let bw = Tuning.binWidth, v = runV
        var sum: Float = 0, cy: Float = 0
        for b in runBins { sum += b.h; cy += (b.y + b.h / 2) * b.h }
        var n = 0
        if Float(k) * bw < 8 || sum / Float(k) < 3 {
            for b in runBins { n += shedDots(col: b.col, edgeY: b.y, amount: b.h, velocity: v) }
        } else {
            let width = Float(k) * bw, x = (Float(runBins[0].col) + Float(k) / 2) * bw, y = cy / sum
            let vx = (calm ? 0 : Float.random(in: -12...12, using: &rng)) + v.x * 0.5
            let fall = (calm ? Tuning.calmDebrisFall : Float.random(in: 10...50, using: &rng)) - v.y * 0.5
            let spin: Float = calm ? 0 : Float.random(in: 0.5...2, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            guard put(Flake(pos: [x, y], vx: vx, fall: max(fall, 0), phase: 0, amp: 0, freq: 0, size: width, alpha: 0.95, kind: .debris,
                            seed: Float.random(in: 0..<1, using: &rng), fade: 1, spin: spin, vol: sum * bw, shape: 2)) else { return 0 }
            n = 1
            if !calm {
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    let c = Flake(pos: [x + Float.random(in: -width / 2...width / 2, using: &rng), y + Float.random(in: -3...3, using: &rng)],
                                  vx: vx + Float.random(in: -8...8, using: &rng), fall: max(fall + Float.random(in: -15...15, using: &rng), 0),
                                  phase: 0, amp: 0, freq: 0, size: Float.random(in: 3...5, using: &rng), alpha: 0.95, kind: .debris,
                                  seed: Float.random(in: 0..<1, using: &rng), fade: 1, spin: Float.random(in: -2...2, using: &rng), shape: 1)
                    if put(c) { n += 1 }
                }
                for _ in 0..<Int(width / 20 + Float.random(in: 0..<1, using: &rng)) { addPuff(x: x + Float.random(in: -width / 2...width / 2, using: &rng), y: y) }
            }
        }
        if n > 0 { pilesDirty = true }
        return n
    }

    func put(_ f: Flake) -> Bool {
        guard debris.count < Tuning.maxDebris else { return false }
        debris.append(f)
        return true
    }

    /// Dust cloud (no landing, not counted as debris); at most `maxPuffs` alive.
    func addPuff(x: Float, y: Float) {
        guard puffs.count < Tuning.maxPuffs else { return }
        puffs.append(Flake(pos: [x, y], vx: 0, fall: 0, phase: 0, amp: 0, freq: 0, size: Float.random(in: 9...13, using: &rng), alpha: 0.35, kind: .debris,
                           seed: Float.random(in: 0..<1, using: &rng), fade: 1, delay: Tuning.puffLife, shape: 3))
    }

    /// Puffs drift with a little of the wind, rise 6pt/s and live 0.6s.
    func stepPuffs(dt: Float) {
        var i = puffs.count - 1
        while i >= 0 {
            puffs[i].delay -= dt
            puffs[i].pos.x += wind * 0.3 * dt
            puffs[i].pos.y += 6 * dt
            if puffs[i].delay <= 0 { puffs.swapAt(i, puffs.count - 1); puffs.removeLast() }
            i -= 1
        }
    }

    /// Debris (~1 flake per 3pt of snow) for one bin's slice of snow starting at `edgeY`.
    func shedDots(col: Int, edgeY: Float, amount h: Float, velocity v: SIMD2<Float>) -> Int {
        var n = 0
        for _ in 0..<max(1, Int(h / 3)) {
            guard debris.count < Tuning.maxDebris else { break }
            let x = (Float(col) + Float.random(in: 0...1, using: &rng)) * Tuning.binWidth
            let y = edgeY + Float.random(in: 0...h, using: &rng)
            let vx = (calm ? 0 : Float.random(in: -12...12, using: &rng)) + v.x * 0.5
            let fall = (calm ? Tuning.calmDebrisFall : Float.random(in: 10...50, using: &rng)) - v.y * 0.5
            if addDebris(x: x, y: y, vx: vx, fall: fall, size: Float.random(in: 3...5, using: &rng) + min(h, 18) / 9) { n += 1 }
            // Taller piles break off in clumps: a few dots close together with nearly the same velocity.
            if !calm, Float.random(in: 0..<1, using: &rng) < min(0.6, h / 25) {
                for _ in 0..<Int.random(in: 2...(2 + Int(h / 6)), using: &rng) {
                    if addDebris(x: x + Float.random(in: -3...3, using: &rng), y: y + Float.random(in: -3...3, using: &rng),
                                 vx: vx + Float.random(in: -4...4, using: &rng), fall: fall + Float.random(in: -15...15, using: &rng), size: Float.random(in: 2.5...4.5, using: &rng)) { n += 1 }
                }
            }
        }
        return n
    }

    /// A slab that has been aloft > 0.25s may break into two clumps (1.5 per second); the volume is split between them.
    func splitSlab(_ i: Int, dt: Float) {
        debris[i].delay += dt
        guard debris[i].delay > 0.25, debris.count < Tuning.maxDebris, Float.random(in: 0..<1, using: &rng) < 1.5 * dt else { return }
        var a = debris[i]
        a.vol /= 2; a.size *= 0.6; a.delay = 0
        if a.size < 6 { a.shape = 1 }   // still a slab (half the volume, 0.6x as wide) until it is small
        var b = a
        let d = a.size * 0.5, kick = Float.random(in: 5...15, using: &rng)
        a.pos.x -= d; a.vx -= kick; a.spin = Float.random(in: -2...2, using: &rng)
        b.pos.x += d; b.vx += kick; b.spin = Float.random(in: -2...2, using: &rng); b.seed = Float.random(in: 0..<1, using: &rng)
        debris[i] = a
        debris.append(b)
        if !calm { addPuff(x: (a.pos.x + b.pos.x) / 2, y: a.pos.y) }
    }

    /// Heavy landing: the carried volume goes into a crater with a raised rim (+-4 columns, rim ~2x the centre) and clumps jump up.
    func impact(surface s: Int, bin: Int, x: Float, top: Float, fall: Float, vol: Float) {
        let total = vol / Tuning.binWidth
        func weight(_ o: Int) -> Float { abs(o) == 4 ? 0.9 : 0.6 + 0.2 * Float(abs(o)) }
        var wsum: Float = 0
        for o in -4...4 { wsum += weight(o) }
        var changed = false
        for o in -4...4 {
            let i = bin + o
            guard i >= 0, i < surfaces[s].pile.heights.count, surfaces[s].pile.visible[i], surfaces[s].pile.cap[i] >= Tuning.minRoom else { continue }
            let before = surfaces[s].pile.heights[i]
            surfaces[s].pile.heights[i] = max(before, min(before + total * weight(o) / wsum, surfaces[s].pile.limit(i)))
            if surfaces[s].pile.heights[i] != before { changed = true }
        }
        if changed { pilesDirty = true }
        for _ in 0..<Int.random(in: 3...6, using: &rng) {
            let sign: Float = Bool.random(using: &rng) ? 1 : -1
            _ = put(Flake(pos: [x + Float.random(in: -6...6, using: &rng), top + 1], vx: sign * Float.random(in: 20...60, using: &rng), fall: -Float.random(in: 80...150, using: &rng),
                          phase: 0, amp: 0, freq: 0, size: Float.random(in: 2.5...4, using: &rng), alpha: 0.95, kind: .debris,
                          seed: Float.random(in: 0..<1, using: &rng), fade: 1, spin: Float.random(in: -2...2, using: &rng), shape: 1))
        }
        if !calm { addPuff(x: x, y: top + 3) }
        impactAt = (x, top, time)
        avalancheImpact(surface: s, x: x)
    }

    /// Sparkles on crests of piles >= 6pt: at most 6 alive, one new every 2s, 0 -> 1 -> 0 over 0.6s. Off for Reduce Motion, economy, low power.
    func stepGlints(dt: Float) {
        guard !calm, !economy, !lowPower, !quiet else { glints.removeAll(keepingCapacity: true); return }
        var i = glints.count - 1
        while i >= 0 {
            glints[i].delay -= dt
            if glints[i].delay <= 0 { glints.swapAt(i, glints.count - 1); glints.removeLast() }
            i -= 1
        }
        glintT += dt * 0.5 * musicGlint
        guard glintT >= 1, !surfaces.isEmpty else { return }
        glintT -= 1
        guard glints.count < Tuning.maxGlints else { return }
        for _ in 0..<3 {
            let s = Int.random(in: 0..<surfaces.count, using: &rng), b = Int.random(in: 0..<surfaces[s].pile.heights.count, using: &rng)
            let h = surfaces[s].pile.heights[b]
            guard h >= 6, surfaces[s].pile.visible[b], surfaces[s].id != draggingID else { continue }
            glints.append(Flake(pos: [binCenter(surfaces[s].c0 + b), surfaces[s].edgeY + surfaces[s].pile.base[b] + h], vx: 0, fall: 0, phase: 0, amp: 0, freq: 0,
                                size: Float.random(in: 3...5, using: &rng), alpha: 1, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1, delay: Tuning.glintLife, shape: 4))
            return
        }
    }
}

/// Intact falling chunks (`Flake.amp` > 0, shape 2): a vanished window's pile slides off as chunks that keep the pile's profile (`Flake.prof`),
/// let go in a ripple, shed crumbs and powder while falling, and break up on impact (small ones also mid-air: soft snow is fragile).
extension Flake {
    /// Packed profile: bits 0-8 thickness in half-points, then left / middle / right height as 5-bit fractions of it (the shader draws the crest from them).
    static func pack(thickness t: Float, left: Float, mid: Float, right: Float) -> UInt32 {
        func q(_ r: Float) -> UInt32 { UInt32(min(max(r, 0), 1) * 31 + 0.5) }
        return UInt32(min(max(t * 2, 1), 511)) | q(left) << 9 | q(mid) << 14 | q(right) << 19
    }
    var blockThickness: Float { Float(prof & 511) * 0.5 }
}

extension SnowField {
    /// Cuts pile bins [b0, b1) into chunks of mixed size (20-120pt), cutting at the thin points of the pile. Thin runs fall as plain dots.
    /// The chunks are released in a ripple that spreads from `originX` at `Tuning.rippleSpeed` (Reduce Motion: all at once). Returns the debris made.
    func dropBlocks(_ s: Surface, from b0: Int, to b1: Int, velocity v: SIMD2<Float>, originX: Float) -> Int {
        let bw = Tuning.binWidth
        let vx0 = v.x * 0.5 + (calm ? 0 : Float.random(in: -8...8, using: &rng))
        let fall0 = (calm ? Tuning.calmDebrisFall : Float.random(in: 0...15, using: &rng)) - v.y * 0.5
        var n = 0, a = b0
        while a < b1 {
            let remain = b1 - a
            let r = Float.random(in: 0..<1, using: &rng)
            var cnt = max(4, Int((r < 0.35 ? Float.random(in: 70...120, using: &rng) : r < 0.75 ? Float.random(in: 36...70, using: &rng) : Float.random(in: 20...36, using: &rng)) / bw))
            if remain - cnt < 6 { cnt = remain } else {   // cut where the pile is thinnest within +-25%
                let lo = a + max(3, cnt - cnt / 4), hi = min(a + cnt + cnt / 4, b1 - 6)
                if lo <= hi {
                    var best = lo
                    for k in lo...hi where s.pile.heights[k] < s.pile.heights[best] { best = k }
                    cnt = best - a
                }
            }
            let e = a + cnt
            defer { a = e }
            var sum: Float = 0, base: Float = .infinity, top: Float = 0
            for k in a..<e { sum += s.pile.heights[k]; base = min(base, s.pile.base[k]); top = max(top, s.pile.heights[k]) }
            let width = Float(cnt) * bw, mean = sum / Float(cnt)
            if mean < 3 {
                for k in a..<e { n += shedBin(col: s.c0 + k, edgeY: s.edgeY + s.pile.base[k], from: 0, amount: s.pile.heights[k], velocity: v) }
                n += flushRuns()
                continue
            }
            func avg(_ lo: Int, _ hi: Int) -> Float { var t: Float = 0; for k in lo..<hi { t += s.pile.heights[k] }; return t / Float(hi - lo) / top }
            let w = max(1, cnt / 6), m = a + cnt / 2
            let prof = Flake.pack(thickness: top, left: avg(a, a + w), mid: avg(max(a, m - w / 2), min(e, m + w / 2 + 1)), right: avg(e - w, e))
            let cx = (Float(s.c0 + a) + Float(cnt) / 2) * bw
            let lean = calm ? 0 : cx < originX ? Float.random(in: -14...0, using: &rng) : Float.random(in: 0...14, using: &rng)
            let hold = calm ? 0 : min(abs(cx - originX) / Tuning.rippleSpeed + Float.random(in: 0...0.08, using: &rng), 0.35)
            guard put(Flake(pos: [cx, s.edgeY + base + top / 2], vx: vx0 + lean, fall: max(fall0 + (calm ? 0 : Float.random(in: -6...10, using: &rng)), 0), phase: 0, amp: 1, freq: 0,
                            size: width, alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1, rot: calm ? 0 : Float.random(in: -0.06...0.06, using: &rng),
                            spin: calm ? 0 : Float.random(in: -0.35...0.35, using: &rng), vol: sum * bw, delay: hold, shape: 2, prof: prof)) else { return n }
            n += 1
        }
        if n > 0 { pilesDirty = true }
        return n
    }

    /// Top of the surface the chunk's lower edge crossed this step (probing left, centre, right), or nil. Nothing is hit while `quiet`.
    func slabHit(_ f: Flake, prevY: Float) -> Float? {
        guard !quiet else { return nil }
        let half = f.blockThickness / 2
        var best: Float?
        for dx in [Float(-0.4), 0, 0.4] as [Float] {
            let c = column(f.pos.x + dx * f.size)
            for k in Int(offsets[c])..<Int(offsets[c + 1]) {
                let e = entries[k], top = e.edgeY + surfaces[Int(e.surface)].pile.heights[c - surfaces[Int(e.surface)].c0]
                if prevY - half >= e.edgeY, top > f.pos.y - half, top > (best ?? -.infinity) { best = top }
            }
        }
        return best
    }

    /// The chunk breaks into clumps (carrying its volume, which lands as usual) and powder. On impact (`top` = the surface) they burst up and out
    /// with puffs; in the air (`air`) they just fall apart where they are.
    func breakSlab(_ f: Flake, top: Float, air: Bool = false) {
        let k = air ? min(max(Int(f.size / 8), 2), 4) : min(max(Int(f.size / 9), 3), 8)
        let powder = calm ? 0 : min(Int(f.size / 8), 8, Int(f.vol * 0.3 / 0.8))
        let vol = (f.vol - Float(powder) * 0.8) / Float(k), y = air ? f.pos.y : top + 1.5
        for j in 0..<k {
            let u = (Float(j) + Float.random(in: 0.2...0.8, using: &rng)) / Float(k) - 0.5   // -0.5...0.5 across the chunk
            let fall = air ? f.fall + Float.random(in: -10...30, using: &rng) : -Float.random(in: calm ? 15...40 : 50...130, using: &rng)
            _ = put(Flake(pos: [f.pos.x + u * f.size, y], vx: f.vx * (air ? 1 : 0.5) + u * (air ? Float.random(in: 15...40, using: &rng) : Float.random(in: 30...80, using: &rng)), fall: fall, phase: air ? 0 : 0.12, amp: 0, freq: 0,
                          size: min(max(vol.squareRoot() * 0.9, 3), 9), alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1,
                          spin: Float.random(in: -3...3, using: &rng), vol: vol, shape: 1))
        }
        for _ in 0..<powder {
            _ = put(Flake(pos: [f.pos.x + Float.random(in: -0.5...0.5, using: &rng) * f.size, y + Float.random(in: 0...2, using: &rng)], vx: f.vx * 0.5 + Float.random(in: -45...45, using: &rng),
                          fall: air ? f.fall * 0.8 : -Float.random(in: 30...110, using: &rng), phase: air ? 0 : 0.12, amp: 0, freq: 0, size: Float.random(in: 2.2...3.2, using: &rng),
                          alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1, vol: 0.8))
        }
        guard !calm else { return }
        for _ in 0..<(air ? 1 : Int(f.size / 20) + 1) { addPuff(x: f.pos.x + Float.random(in: -0.5...0.5, using: &rng) * f.size, y: air ? f.pos.y : top + 3) }
    }

    /// Soft snow sheds crumbs and powder off its underside while it falls; they carry their volume out of the chunk.
    func trailPowder(_ f: inout Flake, dt: Float) {
        guard !calm, f.vol > 30, Float.random(in: 0..<1, using: &rng) < (3 + f.size / 12) * dt else { return }
        let crumb = Float.random(in: 0..<1, using: &rng) < 0.35, v: Float = crumb ? 2 : 0.8, t = f.blockThickness
        guard put(Flake(pos: [f.pos.x + Float.random(in: -0.5...0.5, using: &rng) * f.size, f.pos.y - t * Float.random(in: 0.2...0.5, using: &rng)], vx: f.vx + Float.random(in: -10...10, using: &rng), fall: f.fall * 0.85,
                        phase: 0, amp: 0, freq: 0, size: crumb ? Float.random(in: 2.8...4, using: &rng) : Float.random(in: 2.2...3.2, using: &rng), alpha: 0.95, kind: .debris,
                        seed: Float.random(in: 0..<1, using: &rng), fade: 1, spin: crumb ? Float.random(in: -3...3, using: &rng) : 0, vol: v, shape: crumb ? 1 : 0)) else { return }
        f.vol -= v
    }
}
