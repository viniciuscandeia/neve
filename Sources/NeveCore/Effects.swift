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
        a.shape = 1; a.vol /= 2; a.size *= 0.6; a.delay = 0
        var b = a
        let d = a.size * 0.5, kick = Float.random(in: 5...15, using: &rng)
        a.pos.x -= d; a.vx -= kick; a.spin = Float.random(in: -2...2, using: &rng)
        b.pos.x += d; b.vx += kick; b.spin = Float.random(in: -2...2, using: &rng); b.seed = Float.random(in: 0..<1, using: &rng)
        debris[i] = a
        debris.append(b)
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
        guard !calm, !economy, !lowPower, !outro else { glints.removeAll(keepingCapacity: true); return }
        var i = glints.count - 1
        while i >= 0 {
            glints[i].delay -= dt
            if glints[i].delay <= 0 { glints.swapAt(i, glints.count - 1); glints.removeLast() }
            i -= 1
        }
        glintT += dt * 0.5
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
