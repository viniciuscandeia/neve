import CoreGraphics
import Foundation

extension Tuning {
    static let avaFrontSpeed: Float = 150     // pt/s
    static let avaFullFraction: Float = 0.85  // mean height over avaSpan / mean limit there
    static let avaSpan: Float = 60
    static let avaDriftFraction: Float = 0.9  // a drift is full from this share of its boost up to its limit
    static let avaGroup: Float = 16           // one slab per 8 columns
    static let avaCooldown: Float = 60
    static let avaImpactRange: Float = 80
    static let avaCascadeChance: Float = 0.5
    static let avaMaxCascades = 3
    static let avaSpontaneous: Float = 300    // s a pile must stay full
    static let avaSpontaneousMean: Float = 600
    static let avaJoltLow: Float = 150
    static let avaJoltHigh: Float = 400
}

/// One front sliding along a window's pile toward a drop-off end: every group of 8 columns it passes lets go 60-80% as one slab.
struct AvaFront {
    var win: Int
    var dir: Float
    var startX: Float
    var length: Float      // band length (pt) from startX to the end (<= width, 40-120)
    var speed: Float       // slab launch speed (flushRuns halves v.x: 40-90pt/s result)
    var passed: Float = 0
    var group = 0          // groups released so far
}

/// At most one chain at a time: the first front plus cascades onto lower full piles (depth <= 3), then a cooldown.
struct AvaChain {
    var fronts: [AvaFront] = []
    var cascades = 0
    var cooldownUntil: Double = 0
    var scanT: Float = 0
    var fullTime: [Int: Float] = [:]   // window id -> seconds its pile has been full (spontaneous trigger)
    var started = 0                     // chains begun (tests)
    var demoT: Float = 0
    var released: Float = 0             // volume (pt^2) turned into debris (tests)
    init() { fronts.reserveCapacity(4); fullTime.reserveCapacity(16) }
}

extension SnowField {
    var avalancheActive: Bool { !chain.fronts.isEmpty }

    /// Where a window's pile is "full" within global x in [lo, hi]: mean over 60pt >= 85% of the mean `limit` there (the wavy, tapered, drift-raised ceiling),
    /// or a drift (boost >= half the maximum) within 10% of its limit. Returns x.
    func fullSpot(si: Int, lo: Float = -.infinity, hi: Float = .infinity) -> Float? {
        let p = surfaces[si].pile, n = p.heights.count, c0 = surfaces[si].c0
        let win = Int(Tuning.avaSpan * invBin)
        let b0 = max(0, lo.isFinite ? Int(lo * invBin) - c0 : 0), b1 = min(n - 1, hi.isFinite ? Int(hi * invBin) - c0 : n - 1)
        guard b0 <= b1 else { return nil }
        var sum: Float = 0, cap: Float = 0, best: Float = 0, bestAt = b0
        func heap(_ b: Int) -> Bool { !p.mound.isEmpty && p.mound[b] > 0 }   // a pushed heap is the user's: it never counts toward a slide
        func lim(_ b: Int) -> Float { p.visible[b] && !heap(b) ? max(p.limit(b), 0) : 0 }
        for b in b0...b1 {
            let h = p.visible[b] && !heap(b) ? p.heights[b] : 0
            if !p.boost.isEmpty, p.visible[b], p.boost[b] >= 0.5 * Tuning.maxDrift, h >= p.limit(b) - (1 - Tuning.avaDriftFraction) * p.boost[b] { return binCenter(c0 + b) }
            sum += h; cap += lim(b)
            if b - b0 >= win { sum -= p.visible[b - win] && !heap(b - win) ? p.heights[b - win] : 0; cap -= lim(b - win) }
            if b - b0 >= win - 1, cap > 0, sum / cap > best { best = sum / cap; bestAt = b - win / 2 }
        }
        return best >= Tuning.avaFullFraction ? binCenter(c0 + bestAt) : nil
    }

    private func canStart() -> Bool { !calm && chain.fronts.isEmpty && time >= chain.cooldownUntil }

    /// Starts a front on surface `si` from global `x` toward the nearest drop-off end of that visible run; the band is
    /// `width` (40-120pt) long and ends at the window end. False when nothing drops off, or the surface already slides.
    @discardableResult
    func startFront(si: Int, x: Float) -> Bool {
        let s = surfaces[si].id
        guard s > 0, s != draggingID, chain.fronts.count < 4, !chain.fronts.contains(where: { $0.win == s }) else { return false }
        let n = surfaces[si].pile.heights.count, c0 = surfaces[si].c0, fr = surfaces[si].frame
        let bin = min(max(Int(x * invBin) - c0, 0), n - 1)
        guard let run = visibleRun(si: si, bin: bin) else { return false }
        let left = run.lowerBound == 0 && !surfaces[si].pile.supportL && fr.minX >= 0
        let right = run.upperBound == n && !surfaces[si].pile.supportR && fr.maxX <= CGFloat(size.x)
        guard left || right else { return false }
        let dl = x - binCenter(c0), dr = binCenter(c0 + n - 1) - x
        let toRight = left ? (right && dr < dl) : true
        let dist = toRight ? dr : dl
        guard dist >= 8 else { return false }
        let length = min(dist, Float.random(in: 40...120, using: &fxRng))
        let dir: Float = toRight ? 1 : -1, endX = x + dir * dist
        chain.fronts.append(AvaFront(win: s, dir: dir, startX: endX - dir * length, length: length, speed: dir * Float.random(in: 80...180, using: &fxRng)))
        return true
    }

    /// Robin / any actor: loosens the nearest full window pile around local point `p` (within 80pt). False in cooldown, while another
    /// chain runs, in Reduce Motion, or when nothing is full there.
    @discardableResult
    public func triggerAvalanche(near p: CGPoint) -> Bool {
        guard canStart() else { return false }
        let px = Float(p.x), py = Float(p.y)
        var best: Int?, bestD = Float.infinity
        for si in surfaces.indices where surfaces[si].id > 0 && surfaces[si].id != draggingID {
            let fr = surfaces[si].frame, d = abs(py - surfaces[si].edgeY)
            guard d < Tuning.avaImpactRange, px >= Float(fr.minX) - 10, px <= Float(fr.maxX) + 10, d < bestD else { continue }
            best = si; bestD = d
        }
        guard let si = best, fullSpot(si: si, lo: px - Tuning.avaImpactRange, hi: px + Tuning.avaImpactRange) != nil, startFront(si: si, x: px) else { return false }
        chain.started += 1; chain.cascades = 0
        return true
    }

    /// Heavy landing on surface `s` at x: starts a chain (pile full within 80pt) or, inside a chain, cascades (p 0.5, depth <= 3).
    func avalancheImpact(surface s: Int, x: Float) {
        guard !calm, surfaces[s].id > 0, fullSpot(si: s, lo: x - Tuning.avaImpactRange, hi: x + Tuning.avaImpactRange) != nil else { return }
        if chain.fronts.isEmpty {
            guard time >= chain.cooldownUntil, startFront(si: s, x: x) else { return }
            chain.started += 1; chain.cascades = 0
        } else if chain.cascades < Tuning.avaMaxCascades, !chain.fronts.contains(where: { $0.win == surfaces[s].id }),
                  Float.random(in: 0..<1, using: &fxRng) < Tuning.avaCascadeChance, startFront(si: s, x: x) {
            chain.cascades += 1
        }
    }

    func stepAvalanche(dt: Float) {
        guard !calm else { chain.fronts.removeAll(keepingCapacity: true); return }
        if config.avalancheDemo > 0 { stepDemoAvalanche(dt: dt) }
        // Jolt: a window shaken below shed speed loosens its full pile.
        if canStart() {
            for si in surfaces.indices where surfaces[si].id > 0 {
                let v = surfaces[si].vel, sp = (v.x * v.x + v.y * v.y).squareRoot()
                if sp >= Tuning.avaJoltLow, sp <= Tuning.avaJoltHigh, let x = fullSpot(si: si), startFront(si: si, x: x) {
                    chain.started += 1; chain.cascades = 0
                    break
                }
            }
        }
        // Once a second: how long each window has been full; a pile full for 5 min lets go about once in 10.
        chain.scanT += dt
        if chain.scanT >= 1 {
            let tick = chain.scanT
            chain.scanT = 0
            if chain.fullTime.count > surfaces.count { chain.fullTime = chain.fullTime.filter { index[$0.key] != nil } }   // gone windows (rare)
            for si in surfaces.indices where surfaces[si].id > 0 {
                let id = surfaces[si].id
                guard let x = fullSpot(si: si) else { chain.fullTime[id] = nil; continue }
                let t = (chain.fullTime[id] ?? 0) + tick
                chain.fullTime[id] = t
                if t > Tuning.avaSpontaneous, canStart(), id != draggingID,
                   Float.random(in: 0..<1, using: &fxRng) < tick / Tuning.avaSpontaneousMean, startFront(si: si, x: x) {
                    chain.started += 1; chain.cascades = 0; chain.fullTime[id] = 0
                }
            }
        }
        guard !chain.fronts.isEmpty else { return }
        var i = chain.fronts.count - 1
        while i >= 0 {
            var f = chain.fronts[i]
            guard let si = index[f.win] else { chain.fronts.swapAt(i, chain.fronts.count - 1); chain.fronts.removeLast(); i -= 1; continue }
            f.passed += Tuning.avaFrontSpeed * dt
            while Float(f.group) * Tuning.avaGroup < f.length, f.passed >= min(Float(f.group + 1) * Tuning.avaGroup, f.length) {
                let a = f.startX + f.dir * Float(f.group) * Tuning.avaGroup, b = f.startX + f.dir * min(Float(f.group + 1) * Tuning.avaGroup, f.length)
                releaseGroup(si: si, from: min(a, b), to: max(a, b), speed: f.speed)
                f.group += 1
            }
            if Float(f.group) * Tuning.avaGroup >= f.length { chain.fronts.swapAt(i, chain.fronts.count - 1); chain.fronts.removeLast() } else { chain.fronts[i] = f }
            i -= 1
        }
        if chain.fronts.isEmpty { chain.cooldownUntil = time + Double(Tuning.avaCooldown); chain.cascades = 0 }
    }

    /// 60-80% of every visible column in [from, to] leaves as one slab run (volume conserved: removed == released).
    func releaseGroup(si: Int, from: Float, to: Float, speed: Float) {
        let c0 = surfaces[si].c0, edgeY = surfaces[si].edgeY, n = surfaces[si].pile.heights.count, bw = Tuning.binWidth
        let b0 = max(0, Int(from * invBin) - c0), b1 = min(n - 1, Int((to * invBin).rounded(.up)) - 1 - c0)
        guard b0 <= b1 else { return }
        let frac = Float.random(in: 0.6...0.8, using: &fxRng), first = debris.count
        defer { for j in first..<debris.count { debris[j].phase = 0.5 } }   // like a sweep: no landing back on the pile for a moment, so the slab clears the edge
        for b in b0...b1 where surfaces[si].pile.visible[b] {
            let h = surfaces[si].pile.heights[b], r = h * frac
            guard r > 0.5 else { continue }
            surfaces[si].pile.heights[b] = h - r
            chain.released += r * bw
            _ = shedBin(col: c0 + b, edgeY: edgeY + surfaces[si].pile.base[b], from: h - r, amount: r, velocity: SIMD2(speed, 0))
        }
        flushRuns()
        pilesDirty = true
    }
}

extension SnowField {
    /// NEVE_DEMO_AVALANCHE: every `avalancheDemo` seconds all window piles are filled to their limit and the highest window lets go.
    func stepDemoAvalanche(dt: Float) {
        chain.demoT += dt
        guard chain.demoT >= config.avalancheDemo, chain.fronts.isEmpty else { return }
        chain.demoT = 0
        var top: Int?
        for si in surfaces.indices where surfaces[si].id > 0 {
            for b in surfaces[si].pile.heights.indices where surfaces[si].pile.visible[b] { surfaces[si].pile.heights[b] = max(surfaces[si].pile.heights[b], surfaces[si].pile.limit(b)) }
            if top == nil || surfaces[si].edgeY > surfaces[top!].edgeY { top = si }
        }
        pilesDirty = true
        guard let si = top else { return }
        chain.cooldownUntil = 0
        let fr = surfaces[si].frame
        if triggerAvalanche(near: CGPoint(x: fr.midX, y: CGFloat(surfaces[si].edgeY))) { return }
    }
}
