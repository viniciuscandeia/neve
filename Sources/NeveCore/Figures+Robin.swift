import CoreGraphics
import Foundation

extension Tuning {
    static let robinSpeed: Float = 60           // pt/s along the path
    static let robinAmp: Float = 12             // pt, sine amplitude
    static let robinWave: Float = 80            // pt, sine wavelength
    static let robinRun: Float = 80             // visible window-top run the visit needs
    static let robinShakeAt: Float = 2          // s after landing
    static let robinShakeLen: Float = 0.4
    static let robinHop: Float = 0.22
    static let robinShot: Float = 60            // startle radii
    static let robinCursor: Float = 40
    static let robinCursorSpeed: Float = 300
    static let robinImpact: Float = 50
    static let robinSurfaceSpeed: Float = 40    // pt/s of its window
    static let robinStoryWait: Float = 25       // s the rabbit waits for the story robin
}

/// Robin bookkeeping (lives in `Figure.robin`).
struct RobinState {
    enum Stage: UInt8 { case fly, hop, perch, shake, leave }
    var stage = Stage.fly
    var stageT: Float = 0
    var sid = 0                                  // surface it lands on
    var from = SIMD2<Float>.zero, to = SIMD2<Float>.zero, travel: Float = 0, len: Float = 1
    var hopsLeft = 0, hopT: Float = 0, hopFrom: Float = 0, hopTo: Float = 0, hopping = false
    var landedT: Float = 0, stay: Float = 12
    var shook = false, startled = false
    var wing: Float = 0, wiggle: Float = 0
    var exitDir: Float = 1, speed: Float = Tuning.robinSpeed, climb: Float = 25
    var carved: Float = 0                        // pile removed by the shake (tests)
    var flying: Bool { stage == .fly || stage == .leave }
}

/// Story state (`EventDirector.story`): a rabbit visit that first stages a robin and then aims its misses at it.
struct StoryState {
    var active = false, pending = false
    var chance: Float = 1.0 / 3
    var x: Float?, surface: Int?
}

extension SnowField {
    private typealias V = SIMD2<Float>

    /// Best window-top spot (global x) for a robin: a visible run >= 80pt, the fullest pile (nearest `px`, on `pref`, when given).
    func robinSpot(near px: Float?, on pref: Int?) -> (si: Int, x: Float)? {
        var best: (si: Int, x: Float)?, top = -Float.infinity
        for si in surfaces.indices where surfaces[si].id > 0 && surfaces[si].id != draggingID {
            let s = surfaces[si], mh = max(s.pile.maxHeight, 1)
            for run in s.runs {
                let lo = max(Float(s.c0 + run.lowerBound) * Tuning.binWidth, s.pile.x0), hi = min(Float(s.c0 + run.upperBound) * Tuning.binWidth, s.pile.x1)
                guard hi - lo >= Tuning.robinRun else { continue }
                var x = lo + 12
                while x <= hi - 12 {
                    let c = min(max(column(x) - s.c0, 0), s.pile.heights.count - 1)
                    var score = s.pile.heights[c] / mh - abs(x - (lo + hi) / 2) * 0.0003   // plateau ties go to the middle
                    if let px { score += (s.id == pref ? 1 : 0) - abs(px - x) * 0.002 } else { score += Float.random(in: 0..<0.05, using: &director.rng) }
                    if score > top { top = score; best = (si, x) }
                    x += 6
                }
            }
        }
        return best
    }

    /// A robin flies in from the nearer screen edge toward a window-top pile. False in compact / behind-windows mode, with one already
    /// about, or without a spot.
    func startRobin() -> Bool {
        guard !visitorsGroundOnly, !figures.contains(where: { $0.kind == .robin }),
              let spot = robinSpot(near: director.story.x, on: director.story.surface) else { return false }
        director.story.pending = false; director.story.x = nil; director.story.surface = nil
        let s = surfaces[spot.si], ty = standY(si: spot.si, x: spot.x)
        let fromLeft = spot.x < size.x / 2
        let from = V(fromLeft ? -12 : size.x + 12, ty + 70)
        var f = Figure(id: nextFigureID, kind: .robin, foot: from, radii: SIMD3(repeating: 11.5 * snowmanScale), fromBalls: true)
        nextFigureID += 1
        var r = RobinState()
        let d = V(spot.x, ty) - from
        r.sid = s.id; r.from = from; r.to = V(spot.x, ty)
        r.len = max((d.x * d.x + d.y * d.y).squareRoot(), 1)
        r.stay = Float.random(in: 8...20, using: &director.rng)
        r.exitDir = fromLeft ? -1 : 1
        f.robin = r
        f.facing = fromLeft ? 1 : -1
        figures.append(f)
        figuresVersion &+= 1
        return true
    }

    /// `EventDirector.storyBias` default: 1 in 3 rabbit visits is a story; a robin is requested near the snowman's x first.
    func storyStarted(_ kind: FigureKind) {
        guard kind == .rabbit, !calm, Float.random(in: 0..<1, using: &director.rng) < director.story.chance,
              let r = figures.last(where: { $0.kind == .rabbit }), let t = figureIndex(r.critter.target) else { return }
        let sn = figures[t]
        var others = 0
        for f in figures where f.kind != .snowman { others += 1 }
        guard !visitorsGroundOnly, time >= director.cooldownUntil[Int(FigureKind.robin.rawValue)], others < (economy || lowPower ? 1 : EventDirector.maxAmbient),
              !figures.contains(where: { $0.kind == .robin }), robinSpot(near: sn.foot.x, on: sn.surfaceID) != nil else { return }   // else: a normal visit
        director.story.active = true; director.story.pending = true
        director.story.x = sn.foot.x; director.story.surface = sn.surfaceID
        director.request(.robin, after: 0, now: time)
    }

    /// The rabbit keeps sniffing while the story robin is still on its way (at most `robinStoryWait` s).
    func storyWaiting(_ stageT: Float) -> Bool {
        guard director.story.active, stageT < Tuning.robinStoryWait else { return false }
        return director.story.pending || figures.contains { $0.kind == .robin && ($0.robin.stage == .fly || $0.robin.stage == .hop) }
    }

    /// A story miss lands up to 45pt toward the robin (when one sits within 200pt of the rabbit) instead of a random side.
    func storyMiss(_ x: Float, rabbitX: Float) -> Float {
        guard director.story.active, let r = figures.first(where: { $0.kind == .robin && !$0.robin.flying }), abs(r.foot.x - rabbitX) <= 200 else { return x }
        return x + min(max(r.foot.x - x, -45), 45)
    }

    /// One step of a robin visit. False when removed.
    func stepRobin(_ i: Int, _ dt: Float) -> Bool {
        var f = figures[i]
        var r = f.robin
        f.phaseT += dt; r.stageT += dt
        r.wing += dt * 8 * 2 * .pi
        f.pose.hop = 0; r.wiggle = 0
        switch r.stage {
        case .fly:
            guard let si = index[r.sid] else { launch(&f, &r, fast: false); break }
            r.to.y = standY(si: si, x: r.to.x)
            r.travel += Tuning.robinSpeed * dt
            if r.travel >= r.len {
                f.foot = r.to; f.at = .surface(id: r.sid, x: r.to.x)
                r.stage = .hop; r.stageT = 0; r.landedT = 0
                r.hopsLeft = Int.random(in: 2...3, using: &director.rng)
            } else {
                let d = (r.to - r.from) / r.len, k = r.travel / r.len
                let off = Tuning.robinAmp * sin(2 * .pi * r.travel / Tuning.robinWave) * min(1, (r.len - r.travel) / 30)
                f.foot = r.from + (r.to - r.from) * k + V(-d.y, d.x) * off
                f.facing = d.x >= 0 ? 1 : -1
            }
        case .hop, .perch, .shake:
            guard let si = index[r.sid], let run = visibleRun(si: si, bin: column(f.foot.x) - surfaces[si].c0) else { launch(&f, &r, fast: true); break }
            let s = surfaces[si]
            r.landedT += dt
            if startled(f, si, dt) { knock(si: si, x: f.foot.x, dir: f.foot.x < size.x / 2 ? -1 : 1); launch(&f, &r, fast: true); r.startled = true; break }
            let lo = max(Float(s.c0 + run.lowerBound) * Tuning.binWidth, s.pile.x0), hi = min(Float(s.c0 + run.upperBound) * Tuning.binWidth, s.pile.x1)
            if r.stage == .hop {
                if !r.hopping {
                    let dir: Float = Bool.random(using: &director.rng) ? 1 : -1
                    r.hopFrom = f.foot.x; r.hopTo = min(max(f.foot.x + dir * 6, lo + 8), max(lo + 8, hi - 8)); r.hopT = 0; r.hopping = true
                    f.facing = r.hopTo >= r.hopFrom ? 1 : -1
                }
                r.hopT += dt
                let u = min(r.hopT / Tuning.robinHop, 1)
                f.foot.x = r.hopFrom + (r.hopTo - r.hopFrom) * u
                f.pose.hop = 12 * u * (1 - u)
                if u >= 1 { r.hopping = false; r.hopsLeft -= 1; if r.hopsLeft <= 0 { r.stage = .perch; r.stageT = 0 } }
            } else if r.stage == .perch, !r.shook, r.landedT >= Tuning.robinShakeAt {
                r.stage = .shake; r.stageT = 0; r.shook = true
                shake(si: si, x: f.foot.x, &r)
            } else if r.stage == .shake {
                r.wiggle = sin(r.stageT * 50) * max(0, 1 - r.stageT / Tuning.robinShakeLen)
                if r.stageT >= Tuning.robinShakeLen { r.stage = .perch; r.stageT = 0 }
            }
            if r.stage != .hop, r.landedT >= r.stay { launch(&f, &r, fast: false); break }
            f.foot.y = standY(si: si, x: f.foot.x)
            f.at = .surface(id: r.sid, x: f.foot.x)
        case .leave:
            let s = r.stageT * r.speed
            f.foot.x += r.exitDir * r.speed * dt
            f.foot.y += (r.climb + Tuning.robinAmp * 2 * .pi / Tuning.robinWave * r.speed * cos(2 * .pi * s / Tuning.robinWave)) * dt
            if f.foot.x < -30 || f.foot.x > size.x + 30 || f.foot.y > size.y + 30 { removeFigure(i); return false }
        }
        f.robin = r
        figures[i] = f
        return true
    }

    /// Takes off toward the nearer screen edge (`fast`: burst).
    private func launch(_ f: inout Figure, _ r: inout RobinState, fast: Bool) {
        r.stage = .leave; r.stageT = 0
        r.exitDir = f.foot.x < size.x / 2 ? -1 : 1
        r.speed = fast ? 150 : Tuning.robinSpeed; r.climb = fast ? 110 : 25
        f.at = .air; f.facing = r.exitDir; f.pose.hop = 0
    }

    /// A shot landed <= 60pt, the cursor is fast and <= 40pt, an impact <= 50pt, or its window moves.
    private func startled(_ f: Figure, _ si: Int, _ dt: Float) -> Bool {
        let p = f.foot + V(0, 4), recent = max(0.1, dt * 1.5)
        func near(_ q: V, _ r: Float) -> Bool { let d = q - p; return d.x * d.x + d.y * d.y <= r * r }
        if let s = shotLand, time - s.t <= recent, near(s.p, Tuning.robinShot) { return true }
        if let m = impactAt, time - m.t <= recent, near(V(m.x, m.y), Tuning.robinImpact) { return true }
        if let c = pointer, near(c, Tuning.robinCursor), pointerVel.x * pointerVel.x + pointerVel.y * pointerVel.y > Tuning.robinCursorSpeed * Tuning.robinCursorSpeed { return true }
        let v = surfaces[si].vel
        return v.x * v.x + v.y * v.y > Tuning.robinSurfaceSpeed * Tuning.robinSurfaceSpeed
    }

    /// Small shake: a 10pt-wide, 1.5pt-deep dent whose snow falls as clumps.
    private func shake(si: Int, x: Float, _ r: inout RobinState) {
        let removed = surfaces[si].pile.carve(centerX: x, halfWidth: 10, depth: 1.5, berm: 0.15)
        r.carved = removed
        guard removed > 0 else { return }
        pilesDirty = true
        guard !silent else { return }
        let y = standY(si: si, x: x) + 1
        for _ in 0..<3 {
            _ = put(Flake(pos: [x + Float.random(in: -8...8, using: &rng), y], vx: Float.random(in: -30...30, using: &rng), fall: Float.random(in: 10...40, using: &rng),
                          phase: 0.4, amp: 0, freq: 0, size: Float.random(in: 3...4, using: &rng), alpha: 0.95, kind: .debris,
                          seed: Float.random(in: 0..<1, using: &rng), fade: 1, spin: Float.random(in: -2...2, using: &rng), vol: removed / 3, shape: 1))
        }
    }

    /// Burst takeoff: a full pile (mean over +-60pt >= 85% of max) loosens an avalanche, then ~40% of the pile within +-20pt falls as slabs.
    private func knock(si: Int, x: Float, dir: Float) {
        if fullSpot(si: si, lo: x - 60, hi: x + 60) != nil { _ = triggerAvalanche(near: CGPoint(x: CGFloat(x), y: CGFloat(surfaces[si].edgeY))) }
        let c0 = surfaces[si].c0, edgeY = surfaces[si].edgeY, n = surfaces[si].pile.heights.count
        let b0 = max(0, Int((x - 20) * invBin) - c0), b1 = min(n - 1, Int((x + 20) * invBin) - 1 - c0)
        guard b0 <= b1 else { return }
        let first = debris.count
        defer { for j in first..<debris.count { debris[j].phase = 0.5 } }
        for b in b0...b1 where surfaces[si].pile.visible[b] {
            let h = surfaces[si].pile.heights[b], r = h * 0.4
            guard r > 0.3 else { continue }
            surfaces[si].pile.heights[b] = h - r
            _ = shedBin(col: c0 + b, edgeY: edgeY + surfaces[si].pile.base[b], from: h - r, amount: r, velocity: SIMD2(dir * 50, 0))
        }
        flushRuns()
        pilesDirty = true
    }

    public func robinLook(of f: Figure) -> RobinLook {
        RobinLook(foot: f.foot, facing: f.facing, scale: f.scale, hop: f.pose.hop, flying: f.robin.flying, wing: f.robin.wing, wiggle: f.robin.wiggle, fade: f.fade * f.melt)
    }
}
