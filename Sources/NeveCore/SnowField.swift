import CoreGraphics
import Foundation

/// Per-screen simulation: flakes, surface map, piles. Local coords are points, y up.
public final class SnowField {
    public let size: SIMD2<Float>
    let origin: CGPoint
    private(set) var groundY: Float
    private(set) var visibleTop: Float
    var boundsDirty = false
    public internal(set) var windowsStale = false   // after a Space switch: no deposits on window surfaces until the next snapshot reconciles
    var stash: [Int: (heights: [Float], stamp: Double)] = [:]   // window piles kept across a Space switch, by window number (cap 64, 30 min)
    var clock = 0.0, stamps: [Int: Double] = [:]   // monotonic time and each window's last sample, for per-window dt
    public internal(set) var flakes: [Flake] = []
    public internal(set) var debris: [Flake] = []
    var glints: [Flake] = []     // sparkles on pile crests (Effects.swift), kept out of `debris`
    var puffs: [Flake] = []      // dust clouds (Effects.swift)
    var glintT: Float = 0
    var drops: [Drop] = []       // meltwater (Drips.swift)
    var dripT: Float = 0
    var icicles: [Icicle] = []   // Icicles.swift: stalactites under frozen windows; iceT = seconds since the last spawn scan
    var iceT: Float = 0
    var iceWin: [WinIce] = []   // Frost.swift: per-window freeze progress
    var chain = AvaChain()       // Avalanche.swift
    var fxRng: SplitMix64        // icicles / avalanches: kept apart from `rng` so they never perturb the other sequences
    var runBins: [RunBin] = []   // consecutive snow columns being released, grouped into one slab (Effects.swift)
    var sweepOwed: Float = 0     // cursor-dent volume (pt^2) not yet launched as debris
    var runV: SIMD2<Float> = .zero
    public var economy = false   // Economy mode: no glints
    var surfaces: [Surface] = []
    var dockTrickle = DockTrickle()   // DockSpill.swift
    var index: [Int: Int] = [:]   // surface id -> index into `surfaces`, rebuilt with them in updateSurfaces
    var offsets: [Int32]       // CSR: per column range into entries
    var entries: [Entry] = []
    var lastWindows: [WindowInfo] = []
    var dockTarget: CGRect?, dockCur: CGRect?, dockPrev: CGRect?   // DockPush.swift: read frame, animated frame, frame before this rebuild
    var dockSlump: Float = 0
    var bankLevel: (l: Float, r: Float) = (Tuning.groundMaxHeight, Tuning.groundMaxHeight), bankT: Float = 0   // ground bank ramp level per Dock side, DockPush.swift
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
    var groundWinKey: [CGRect] = [], groundWinCeil: [Float] = [], groundWinHidden: [Bool] = []   // buildGround cache (non-Dock windows)
    /// "Neve parada": `step` is never called, so nothing can animate: the Dock jumps to its target at once.
    public var frozen = false { didSet { if frozen, !oldValue, dockCur != dockTarget { dockCur = dockTarget; boundsDirty = true } } }
    var time: Float = 0
    var windGain: Float = 8
    var wind: Float = 0
    public var music = MusicInput.silent   // injected each frame by the app (Music.swift)
    var musicKick: Float = 0, musicDir: Float = 1, musicEdge = false, musicSway: Float = 1, musicGlint: Float = 1, musicBoost: Float = 1
    public var pilesDirty = false { didSet { if pilesDirty { pileVersion &+= 1 } } }
    /// Bumps whenever pile heights or geometry may have changed; `writePiles` rewrites only then (or while easing).
    public internal(set) var pileVersion = 0
    var pileWritten = -1, pileEasing = false
    var pileEnds: [PileEnd] = []
    /// Everyone standing on a surface (at most `Tuning.maxFigures`): the auto snowman, snowmen made of user balls; see Figures.swift.
    public internal(set) var figures: [Figure] = []
    var nextFigureID = 1
    public internal(set) var fights: [Fight] = []     // snowball fights; see Fights.swift
    public internal(set) var shots: [Shot] = []
    public internal(set) var splats: [Splat] = []    // <= Tuning.maxSplats, pool
    public var visitorsEnabled = false   // the EventDirector may start visitors (the app sets it from Pref.visitors; tests opt in)
    public var groundOnlyActors = false  // behind-windows mode: visitors only on the ground / Dock (compact mode, areaScale < 1, implies it)
    public internal(set) var director: EventDirector
    public var sleighEnabled = false     // the sleigh may fly (the app sets it from Pref.sleigh; tests opt in)
    public var calendarDay: (month: Int, day: Int) = (0, 0)   // injected by the app (tests set Dec 24): picks the sleigh frequency
    var scene: SceneState?               // NEVE_SCENE script (Scene.swift): nil = a normal run
    var giftState = GiftState()          // gifts + confetti (Gifts.swift)
    var cursorThrow = CursorThrow()      // snowman throws at the held-still cursor (CursorThrow.swift)
    /// Profiling only (nil = free): seconds clock; time spent in `stepFlakes` accumulates in `flakeSeconds` (reader zeroes it) over `flakeSteps` calls.
    public var timer: (() -> Double)?
    public var flakeSeconds = 0.0, flakeSteps = 0
    /// Profiling only (needs `timer`): `writePiles` split into easing / contour (runs, bridges, seams) / n0-n1 joins; the reader zeroes it.
    public var pileSeconds = (ease: 0.0, contour: 0.0, join: 0.0)
    public var optionHeld = false        // the overlay reports the ⌥ key every frame
    var carrots: [Carrot] = []           // stolen noses lying on a pile or falling (Figures+Rabbit.swift)
    var shotLand: (p: SIMD2<Float>, t: Float)?, impactAt: (x: Float, y: Float, t: Float)?   // last landings (robin startle)
    var rabbitHitScale = Tuning.rabbitHitScale   // tests force hits (large) or misses (0)
    public var walkEnabled = true      // figures walk and fight (Walk.swift)
    public var pointerPush = true      // the cursor pushes and swirls the flakes (off saves CPU; every other cursor feature is unaffected)
    var gustOverride: Float?           // tests
    public var snowmanEnabled = true { didSet { if !snowmanEnabled { dropAutoFigure() } } }
    var snowmanCooldown: Float = 0      // snowfall seconds (x speed) before the next auto build may start
    var snowmanScan: Float = 0
    /// Loose snowballs the user rolled; see Snowball.swift.
    public internal(set) var balls: [Snowball] = []
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
    var melting = false                                  // idle melt (Melt.swift): no new snow, everything thaws away over meltDur
    var meltT: Float = 0, meltDur: Float = 1, meltRate: Float = 0
    var quiet: Bool { outro || melting }
    var outroT: Float = 0, outroSpread: Float = 0, outroRel: Float = 1   // piles released so far: 0...1 of the spread (1 = all)

    public var capacity: Int { flakes.count + Tuning.maxDebris + Tuning.maxGlints + Tuning.maxPuffs + Tuning.maxDrops }

    public init(size: CGSize, origin: CGPoint, groundY: CGFloat, visibleTop: CGFloat, flakeCount: Int,
                config: SimConfig = .init(), seed: UInt64 = .random(in: 0...UInt64.max)) {
        self.config = config
        rng = SplitMix64(seed: seed)
        fxRng = SplitMix64(seed: seed ^ 0x1CE1CEA7A1A)
        director = EventDirector(seed: seed ^ 0xD1EC_7042, speed: config.directorSpeed)
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
        icicles.reserveCapacity(Tuning.maxStalactitesPerScreen); iceWin.reserveCapacity(16)
        glints.reserveCapacity(Tuning.maxGlints); puffs.reserveCapacity(Tuning.maxPuffs); drops.reserveCapacity(Tuning.maxDrops); runBins.reserveCapacity(8)
        figures.reserveCapacity(Tuning.maxFigures + EventDirector.maxAmbient); carrots.reserveCapacity(4); fights.reserveCapacity(4); shots.reserveCapacity(6); splats.reserveCapacity(Tuning.maxSplats + 1)
        flakes.reserveCapacity(pool)
        for i in 0..<pool { flakes.append(spawn(i < skyCount ? .sky : .background, anywhere: true)) }
        skyEnd = skyCount; bgEnd = pool - skyCount
        setIntensity(.media, immediate: true)
        updateSurfaces(windows: [])
    }
    var seams: [SeamLink] = []    // windows whose piles read as one snowbank (SurfaceMap.swift), rebuilt with the surfaces
    var peeledVolume: Float = 0   // drift snow let go so far (tests)
    var moved: Int?   // scratch for updateSurfaces/buildSurface

    /// Extra flakes retire when they next respawn; missing ones fade in from above (see `step`).
    public func setIntensity(_ v: Intensity, immediate: Bool = false) {
        intensity = v
        let m = v.multiplier / Intensity.nevasca.multiplier * areaScale * musicBoost
        let k: Float = calm ? 0.3 : 1
        skyLimit = min(skyCount, Int(Float(skyCount) * m * (lowPower ? 0.5 : 1) * k))
        bgLimit = min(flakes.count - skyCount, Int(Float(flakes.count - skyCount) * m * k))
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
    public func markStale() { windowsStale = true }
    public func dropPiles() {
        silentUntil = time + 1.5
        balls.removeAll { $0.state != .held && $0.surfaceID != nil && $0.surfaceID != Tuning.groundID }   // windows vanish: so do balls on them
        dropWindowFigures()
        for s in surfaces where s.id > 0 && s.pile.heights.contains(where: { $0 > 0 }) { stash[s.id] = (s.pile.heights, clock) }   // plain windows only: they get their snow back when they return
        while stash.count > 64, let old = stash.min(by: { $0.value.stamp < $1.value.stamp })?.key { stash[old] = nil }
        for i in surfaces.indices where surfaces[i].id != Tuning.groundID { surfaces[i].pile.empty() }   // the ground is not tied to a window
        pilesDirty = true
    }

    /// Intro: every flake goes dormant, then wakes from above the top edge, one slot after another,
    /// so the active count ramps linearly from 0 to the intensity's target over `duration` seconds of stepping. Piles are kept.
    public func beginIntro(duration: Float) {
        outro = false; outroRel = 1; melting = false
        for i in figures.indices {
            figures[i].melt = 1
            if let k = figures[i].preMelt { figures[i].radii = k.radii; figures[i].built = k.built; figures[i].preMelt = nil }   // a resumed melt: stand tall again
        }
        snowmanCooldown = 0
        for i in flakes.indices { flakes[i].kind = .dormant }
        introT = 0; introDur = max(duration, 0.01)
    }

    /// Outro: spawning stops, flakes fade, balls and the snowman break, and every pile turns into heavy debris
    /// (capped by maxDebris), released left to right with jitter over `spread` seconds of stepping (0 = at once).
    /// Debris vanishes where it would land, so nothing rebuilds. `beginIntro` ends it.
    public func collapseAll(spread: Float) {
        outro = true; melting = false
        introDur = 0
        for i in figures.indices.reversed() where i < figures.count { shatter(figures[i].id) }   // stacks go at once, the auto one fades
        snowmanCooldown = .infinity
        while !balls.isEmpty { pop(balls.count - 1, .zero) }
        outroT = 0; outroSpread = max(spread, 0.001); outroRel = -1
        if spread <= 0 { releasePiles(from: -1, to: 1); outroRel = 1 }
        pilesDirty = true
    }

    /// The one clear contract: removes every accumulated effect (piles, balls, figures and their fights / shots / splats, debris, glints, puffs,
    /// frost, icicles, gifts + confetti, meltwater drops). Snowfall (flakes, intensity), cooldowns and the event director are left alone.
    public func clear() {
        carrots.removeAll(keepingCapacity: true)
        for g in figures where g.kind != .snowman { director.ended(g.kind, at: time) }   // visits end through the director: no infinite cooldown
        dockTrickle = DockTrickle(); sweepOwed = 0   // pending emission debts must not resurface as snow after clearing
        figures.removeAll(keepingCapacity: true); fights.removeAll(keepingCapacity: true); shots.removeAll(keepingCapacity: true); splats.removeAll(keepingCapacity: true)
        if !balls.isEmpty { balls.removeAll() }
        for i in surfaces.indices { surfaces[i].pile.empty() }
        stash.removeAll()
        debris.removeAll(keepingCapacity: true); glints.removeAll(keepingCapacity: true); puffs.removeAll(keepingCapacity: true)
        iceWin.removeAll(keepingCapacity: true); icicles.removeAll(keepingCapacity: true); drops.removeAll(keepingCapacity: true)
        giftState.gifts.removeAll(keepingCapacity: true); giftState.confetti.removeAll(keepingCapacity: true)
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

    /// Something moves fast enough to want the full frame rate (adaptive fps): drag, shots, fights, avalanche-sized debris,
    /// a ball in hand or in the air, a gust, intro / outro. Steady gentle snowfall is not.
    public var isBusy: Bool {
        draggingID != nil || dockCur != dockTarget || dockSlump > 0 || !shots.isEmpty || !fights.isEmpty || debris.count > 6 || (introDur > 0 && introT < introDur)
            || (outro && outroRel < 1) || figures.contains { $0.kind != .snowman } || abs(gust) > 0.15 || balls.contains { $0.state != .resting }
    }
    /// The pile buffer written last is still the current picture (no version change, no easing left).
    public var pilesSettled: Bool { pileVersion == pileWritten && !pileEasing }

    public func step(dt: Float) {
        time += dt
        if scene != nil { stepScene(dt: dt) }
        stepBuilder(dt: dt)
        stepDirector(dt: dt)
        if outro, outroRel < 1 {
            outroT += dt
            let to = min(1, outroT / outroSpread)
            releasePiles(from: outroRel, to: to)
            outroRel = to
        }
        if introDur > 0 { introT += dt }
        stepMelt(dt: dt)
        stepBalls(dt: dt)
        stepGifts(dt: dt)
        stepFigures(dt: dt)
        stepSplats(dt)
        windGain += (intensity.windGain - windGain) * min(1, dt * 0.5)
        stepMusic(dt: dt)
        wind = calm ? 0 : windGain * windShape() + musicKick
        if let timer { let t0 = timer(); stepFlakes(dt: dt); flakeSeconds += timer() - t0; flakeSteps += 1 } else { stepFlakes(dt: dt) }
        stepPeel(dt: dt)
        stepIce(dt: dt)
        stepAvalanche(dt: dt)
        stepDebris(dt: dt)
        stepDock(dt: dt)
        stepBank(dt: dt)
        stepDockSpill(dt: dt)
        stepPuffs(dt: dt)
        stepGlints(dt: dt)
        stepDrips(dt: dt)
    }
}
