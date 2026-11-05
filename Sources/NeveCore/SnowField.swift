import CoreGraphics
import Foundation

/// Per-screen simulation: flakes, surface map, piles. Local coords are points, y up.
public final class SnowField {
    public let size: SIMD2<Float>
    let origin: CGPoint
    private(set) var groundY: Float
    private(set) var visibleTop: Float
    var boundsDirty = false
    public internal(set) var flakes: [Flake] = []
    public internal(set) var debris: [Flake] = []
    var surfaces: [Surface] = []
    var index: [Int: Int] = [:]   // surface id -> index into `surfaces`, rebuilt with them in updateSurfaces
    var offsets: [Int32]       // CSR: per column range into entries
    var entries: [Entry] = []
    var lastWindows: [WindowInfo] = []
    /// Window moved (same size) in the last poll: the overlay may slide its pile layer with the mouse until the next poll.
    public internal(set) var draggingID: Int?
    let numCols: Int
    let invBin = 1 / Tuning.binWidth
    let skyCount: Int      // sky pool size; the rest of `flakes` is background
    var skyLimit = 0        // active counts for the current intensity
    var bgLimit = 0
    var skyEnd = 0          // slots [0, skyEnd) of the sky pool / [skyCount, skyCount+bgEnd) of the background pool
    var bgEnd = 0           // may be live or spawning; everything beyond is dormant, so step/write skip it
    var intensity = Intensity.media
    var lowPower = false
    private(set) var calm = false
    var time: Float = 0
    var windGain: Float = 8
    var wind: Float = 0
    public var pilesDirty = false
    /// The snowman (at most one per screen) and its bookkeeping; see Snowman.swift.
    public internal(set) var snowman: Snowman?
    public var walk = WalkState()      // walking snowmen and snowball fights; see Walkers.swift
    public var snowmanEnabled = true { didSet { if !snowmanEnabled { snowman = nil } } }
    var snowmanCooldown: Float = 0      // snowfall seconds (x speed) before the next build may start
    var snowmanScan: Float = 0
    /// Snowballs the user rolled and stacked; see Snowball.swift. `ballsVersion` changes whenever one moves / grows / fades.
    public internal(set) var balls: [Snowball] = []
    public internal(set) var ballsVersion = 0
    var nextBallID = 1
    var pointer: SIMD2<Float>?
    var pointerVel: SIMD2<Float> = .zero
    var pollDt: Float = 0.1        // seconds between the last two window polls
    var lastPoll: CFAbsoluteTime = 0
    var rng: SplitMix64
    var silentUntil: CFAbsoluteTime = 0   // no knock-off debris until then (Space switches)
    var introT: Float = 0, introDur: Float = 0   // intro: flake slots wake in order over introDur seconds (0 = no intro running)
    public private(set) var outro = false                // outro: no new snow, flakes fade, nothing lands (see collapseAll)
    var outroT: Float = 0, outroSpread: Float = 0, outroRel: Float = 1   // piles released so far: 0...1 of the spread (1 = all)

    public var capacity: Int { flakes.count + Tuning.maxDebris }

    public init(size: CGSize, origin: CGPoint, groundY: CGFloat, visibleTop: CGFloat, flakeCount: Int,
                seed: UInt64 = .random(in: 0...UInt64.max)) {
        rng = SplitMix64(seed: seed)
        self.size = SIMD2(Float(size.width), Float(size.height))
        self.origin = origin
        self.groundY = Float(groundY)
        self.visibleTop = Float(visibleTop)
        numCols = max(1, Int((Float(size.width) / Tuning.binWidth).rounded(.up)))
        offsets = [Int32](repeating: 0, count: numCols + 1)
        let pool = Int(Float(flakeCount) * Intensity.nevasca.multiplier)   // allocated once for the max level
        skyCount = Int(Float(pool) * (1 - Tuning.backgroundFraction))
        debris.reserveCapacity(Tuning.maxDebris)
        flakes.reserveCapacity(pool)
        for i in 0..<pool { flakes.append(spawn(i < skyCount ? .sky : .background, anywhere: true)) }
        skyEnd = skyCount; bgEnd = pool - skyCount
        setIntensity(.media, immediate: true)
        updateSurfaces(windows: [])
    }
    var moved: Int?   // scratch for updateSurfaces/buildSurface

    /// Extra flakes retire when they next respawn; missing ones fade in from above (see `step`).
    public func setIntensity(_ v: Intensity, immediate: Bool = false) {
        intensity = v
        let m = v.multiplier / Intensity.nevasca.multiplier
        let k: Float = calm ? 0.3 : 1
        skyLimit = Int(Float(skyCount) * m * (lowPower ? 0.5 : 1) * k)
        bgLimit = Int(Float(flakes.count - skyCount) * m * k)
        skyEnd = max(skyEnd, skyLimit); bgEnd = max(bgEnd, bgLimit)
        if immediate {
            for i in flakes.indices where !isActive(i) { flakes[i].kind = .dormant }
        }
    }

    /// Low Power Mode: halve the colliding sky flakes.
    public func setLowPower(_ on: Bool) {
        lowPower = on
        setIntensity(intensity)
    }

    /// Reduce Motion: ~30% of the flakes, half the fall speed, no gusts.
    public func setCalm(_ on: Bool) {
        calm = on
        setIntensity(intensity)
    }

    /// Space switch: windows vanish all at once. Drop piles without debris (and mute knock-offs briefly).
    public func dropPiles() {
        silentUntil = CFAbsoluteTimeGetCurrent() + 1.5
        let n = balls.count
        balls.removeAll { $0.state != .held && $0.surfaceID != nil && $0.surfaceID != Tuning.groundID }   // windows vanish: so do balls on them
        if balls.count != n { ballsVersion &+= 1 }
        for i in surfaces.indices where surfaces[i].id != Tuning.groundID { surfaces[i].pile.empty() }   // the ground is not tied to a window
        pilesDirty = true
    }

    /// Intro: every flake goes dormant, then wakes from above the top edge, one slot after another,
    /// so the active count ramps linearly from 0 to the intensity's target over `duration` seconds of stepping. Piles are kept.
    public func beginIntro(duration: Float) {
        outro = false; outroRel = 1
        snowmanCooldown = 0
        for i in flakes.indices { flakes[i].kind = .dormant }
        introT = 0; introDur = max(duration, 0.01)
    }

    /// Outro: spawning stops, flakes fade, balls and the snowman break, and every pile turns into heavy debris
    /// (capped by maxDebris), released left to right with jitter over `spread` seconds of stepping (0 = at once).
    /// Debris vanishes where it would land, so nothing rebuilds. `beginIntro` ends it.
    public func collapseAll(spread: Float) {
        outro = true
        introDur = 0
        snowmanCooldown = .infinity
        collapse()
        while !balls.isEmpty { pop(balls.count - 1, .zero) }
        ballsVersion &+= 1
        outroT = 0; outroSpread = max(spread, 0.001); outroRel = -1
        if spread <= 0 { releasePiles(from: -1, to: 1); outroRel = 1 }
        pilesDirty = true
    }

    public func clear() {
        snowman = nil
        if !balls.isEmpty { balls.removeAll(); ballsVersion &+= 1 }
        for i in surfaces.indices { surfaces[i].pile.empty() }
        debris.removeAll(keepingCapacity: true)
        pilesDirty = true
    }

    /// Dock / menu bar moved: keeps flakes and piles, surfaces are rebuilt on the next `update`.
    public func setBounds(groundY: CGFloat, visibleTop: CGFloat) {
        guard Float(groundY) != self.groundY || Float(visibleTop) != self.visibleTop else { return }
        self.groundY = Float(groundY)
        self.visibleTop = Float(visibleTop)
        boundsDirty = true
    }

    /// Pointer position (local coords, nil = not on this screen) and velocity (pt/s): falling snow swirls around it.
    public func setPointer(_ p: SIMD2<Float>?, velocity: SIMD2<Float>) { pointer = p; pointerVel = velocity }

    public func step(dt: Float) {
        time += dt
        stepSnowman(dt: dt)
        if outro, outroRel < 1 {
            outroT += dt
            let to = min(1, outroT / outroSpread)
            releasePiles(from: outroRel, to: to)
            outroRel = to
        }
        if introDur > 0 { introT += dt }
        stepBalls(dt: dt)
        stepWalkers(dt: dt)
        windGain += (intensity.windGain - windGain) * min(1, dt * 0.5)
        wind = calm ? 0 : windGain * windShape()
        stepFlakes(dt: dt)
        stepDebris(dt: dt)
    }
}
