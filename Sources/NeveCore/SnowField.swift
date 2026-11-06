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
    var glints: [Flake] = []     // sparkles on pile crests (Effects.swift), kept out of `debris`
    var puffs: [Flake] = []      // dust clouds (Effects.swift)
    var glintT: Float = 0
    var runBins: [RunBin] = []   // consecutive snow columns being released, grouped into one slab (Effects.swift)
    var runV: SIMD2<Float> = .zero
    public var economy = false   // Economy mode: no glints
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
    // MARK: P3-0 live region (Coverage.swift): flakes spawn / wrap inside [liveX0, liveX1], just above liveTop; limits scale with areaScale
    var liveX0: Float = 0, liveX1: Float = 0, liveTop: Float = 0
    var areaScale: Float = 1
    var lowPower = false
    private(set) var calm = false
    var time: Float = 0
    var windGain: Float = 8
    var wind: Float = 0
    public var pilesDirty = false { didSet { if pilesDirty { pileVersion &+= 1 } } }
    /// Bumps whenever pile heights or geometry may have changed; `writePiles` rewrites only then (or while easing).
    public internal(set) var pileVersion = 0
    var pileWritten = -1, pileEasing = false
    var pileEnds: [PileEnd] = []
    /// Everyone standing on a surface (at most `Tuning.maxFigures`): the auto snowman, snowmen made of user balls; see Figures.swift.
    /// `figuresVersion` changes whenever one moves, poses, appears or leaves.
    public internal(set) var figures: [Figure] = []
    public internal(set) var figuresVersion = 0
    var nextFigureID = 1
    public internal(set) var fights: [Fight] = []     // snowball fights; see Fights.swift
    public internal(set) var shots: [Shot] = []
    public var walkEnabled = true      // figures walk and fight (Walk.swift)
    var gustOverride: Float?           // tests
    public var snowmanEnabled = true { didSet { if !snowmanEnabled { dropAutoFigure() } } }
    var snowmanCooldown: Float = 0      // snowfall seconds (x speed) before the next auto build may start
    var snowmanScan: Float = 0
    /// Loose snowballs the user rolled; see Snowball.swift. `ballsVersion` changes whenever one moves / grows / fades.
    public internal(set) var balls: [Snowball] = []
    public internal(set) var ballsVersion = 0
    var nextBallID = 1
    var pointer: SIMD2<Float>?
    var pointerVel: SIMD2<Float> = .zero
    var pollDt: Float = 0.1        // seconds between the last two window polls
    var rng: SplitMix64
    var silentUntil: Float = 0   // simulation time until which knock-off debris is muted (Space switches)
    var silent: Bool { time < silentUntil }
    let config: SimConfig
    var introT: Float = 0, introDur: Float = 0   // intro: flake slots wake in order over introDur seconds (0 = no intro running)
    public private(set) var outro = false                // outro: no new snow, flakes fade, nothing lands (see collapseAll)
    var outroT: Float = 0, outroSpread: Float = 0, outroRel: Float = 1   // piles released so far: 0...1 of the spread (1 = all)

    public var capacity: Int { flakes.count + Tuning.maxDebris + Tuning.maxGlints + Tuning.maxPuffs }

    public init(size: CGSize, origin: CGPoint, groundY: CGFloat, visibleTop: CGFloat, flakeCount: Int,
                config: SimConfig = .init(), seed: UInt64 = .random(in: 0...UInt64.max)) {
        self.config = config
        rng = SplitMix64(seed: seed)
        self.size = SIMD2(Float(size.width), Float(size.height))
        self.origin = origin
        self.groundY = Float(groundY)
        self.visibleTop = Float(visibleTop)
        liveX1 = self.size.x; liveTop = self.size.y
        numCols = max(1, Int((Float(size.width) / Tuning.binWidth).rounded(.up)))
        offsets = [Int32](repeating: 0, count: numCols + 1)
        let pool = Int(Float(flakeCount) * Intensity.nevasca.multiplier)   // allocated once for the max level
        skyCount = Int(Float(pool) * (1 - Tuning.backgroundFraction))
        debris.reserveCapacity(Tuning.maxDebris)
        glints.reserveCapacity(Tuning.maxGlints); puffs.reserveCapacity(Tuning.maxPuffs); runBins.reserveCapacity(8)
        figures.reserveCapacity(Tuning.maxFigures); fights.reserveCapacity(4); shots.reserveCapacity(6)
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
        let m = v.multiplier / Intensity.nevasca.multiplier * areaScale
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
        silentUntil = time + 1.5
        let n = balls.count
        balls.removeAll { $0.state != .held && $0.surfaceID != nil && $0.surfaceID != Tuning.groundID }   // windows vanish: so do balls on them
        if balls.count != n { ballsVersion &+= 1 }
        dropWindowFigures()
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
        for i in figures.indices.reversed() where i < figures.count { shatter(figures[i].id) }   // stacks go at once, the auto one fades
        snowmanCooldown = .infinity
        while !balls.isEmpty { pop(balls.count - 1, .zero) }
        ballsVersion &+= 1
        outroT = 0; outroSpread = max(spread, 0.001); outroRel = -1
        if spread <= 0 { releasePiles(from: -1, to: 1); outroRel = 1 }
        pilesDirty = true
    }

    public func clear() {
        figures.removeAll(keepingCapacity: true); fights.removeAll(keepingCapacity: true); shots.removeAll(keepingCapacity: true)
        figuresVersion &+= 1
        if !balls.isEmpty { balls.removeAll(); ballsVersion &+= 1 }
        for i in surfaces.indices { surfaces[i].pile.empty() }
        debris.removeAll(keepingCapacity: true); glints.removeAll(keepingCapacity: true); puffs.removeAll(keepingCapacity: true)
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
        stepBuilder(dt: dt)
        if outro, outroRel < 1 {
            outroT += dt
            let to = min(1, outroT / outroSpread)
            releasePiles(from: outroRel, to: to)
            outroRel = to
        }
        if introDur > 0 { introT += dt }
        stepBalls(dt: dt)
        stepFigures(dt: dt)
        windGain += (intensity.windGain - windGain) * min(1, dt * 0.5)
        wind = calm ? 0 : windGain * windShape()
        stepFlakes(dt: dt)
        stepDebris(dt: dt)
        stepPuffs(dt: dt)
        stepGlints(dt: dt)
    }
}
