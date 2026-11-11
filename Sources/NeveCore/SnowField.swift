// AGENT HEADER - Sources/NeveCore/SnowField.swift  (the per-screen simulation: state + lifecycle + the step() order)
// Role: `SnowField` (final class, one per screen, owned by an Overlay) holds ALL simulation state and `step(dt:)`; behaviour is split into `extension SnowField` across many files (Surfaces, SurfaceMap, Render, Flakes, Effects,
//   Avalanche, Frost, Icicles, Drips, Melt, DockPush, DockSpill, Coverage, Resize, Figures*, Fights, Walk, Snowball, Snowman, Gifts, CursorThrow, EventDirector wiring, Scene). Also `BusyReasons` (why the frame rate must be 60) and `Stashed`.
//   Pure data/logic: no AppKit, no I/O, no wall clock; time = sum of dt (`time`) plus a monotonic `clock` the app feeds through update(now:); randomness = SplitMix64 `rng`/`fxRng` seeded in init => deterministic tests (DeterminismTests).
// Coordinates/units: LOCAL to the screen, AppKit y-up, points. `origin` = screen.frame.origin (global AppKit); `groundY` = Dock-/visibleFrame-bottom height, `visibleTop` = under the menu bar. Pile columns are BINS of
//   Tuning.binWidth (2 pt): `numCols` global columns across the screen width; a surface's `c0` is its first GLOBAL column, `pile.heights[b]` is LOCAL bin b (global = c0 + b). `column(x)`, `binCenter(c)` convert.
// Pools: `flakes` is preallocated once for Nevasca (sky pool [0, skyCount) + background pool); intensity only changes `skyLimit/bgLimit` (active counts), `skyEnd/bgEnd` bound loops; dormant slots cost nothing. `debris`, glints, puffs, drops,
//   icicles, figures, balls, fights, shots, splats, carrots, gifts are capped arrays (Tuning.max*). `capacity` = max instances the GPU buffer must hold.
// step(dt) order: scene script -> snowman builder/director -> outro/intro/melt -> balls, gifts, figures, splats -> wind/music -> stepFlakes (landing -> deposit into piles) -> peel, ice, avalanche, debris, dock, bank, dock spill,
//   puffs, wind dust, glints, drips. The app drives it ~30/60 Hz from Overlay.tick (dt <= 0.06) and feeds windows at poll rate via `update(windows:)` (Surfaces.swift).
// Presentation state kept here on purpose (testable): `pileVersion`/`pilesDirty`, `pileWritten`, `pileEasing`, `Pile.shown`; the renderer rewrites the pile buffer only when pileVersion changes or easing is active (`pilesSettled`).
// Public flags the app sets each frame/pref change: pointer/optionHeld/music/calendarDay/timer, economy, snowmanEnabled/walkEnabled/visitorsEnabled/sleighEnabled/pointerPush/groundOnlyActors, frozen (still snow), setIntensity/setCalm/setLowPower.
// Gotchas: `clear()` is THE contract for removing accumulated effects (keep it in sync when adding state); anything new that persists across Space switches must join `Stashed`; `fxRng` is separate so ice/avalanche never perturb `rng`.
//   `markStale` = Space switch protocol (no deposits on window surfaces until the next changed snapshot). Perf: `timer` (non-nil only with NEVE_PERF) wraps stepFlakes; stepFlakes is the per-frame hot path (hundreds-1200 flakes).

import CoreGraphics
import Foundation

/// Per-screen simulation: flakes, surface map, piles. Local coords are points, y up.
public struct BusyReasons: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let drag = BusyReasons(rawValue: 1), dock = BusyReasons(rawValue: 2), shots = BusyReasons(rawValue: 4), fights = BusyReasons(rawValue: 8), debris = BusyReasons(rawValue: 16)
    public static let introOutro = BusyReasons(rawValue: 32), figures = BusyReasons(rawValue: 64), gust = BusyReasons(rawValue: 128), balls = BusyReasons(rawValue: 256)
    public static let names: [(BusyReasons, String)] = [(.drag, "drag"), (.dock, "dock"), (.shots, "shots"), (.fights, "fights"), (.debris, "debris"), (.introOutro, "intro"), (.figures, "figures"), (.gust, "gust"), (.balls, "balls")]
}

/// A window's snow (and freeze progress) set aside while its window is on another Space.
struct Stashed {
    var heights: [Float], stamp: Double
    var mound: [Float] = []            // a pushed heap's extra allowance (Pile.mound), so it is not trimmed on return
    var ice: WinIce? = nil
    var overhang: [Int: Float] = [:]   // snow past the screen edge, by column relative to the old surface's c0
    var topY: Float = 0                // ... and its top edge (the window may return at another height)
    var minX: Float = 0                // the window's left edge then: what stood on it is shifted by the move when it returns
    var balls: [Snowball] = [], figures: [Figure] = [], gifts: [Gift] = []   // what stood on it (user snowmen, resting balls, gifts)
}

public final class SnowField {
    public internal(set) var size: SIMD2<Float>
    var origin: CGPoint
    var groundY: Float
    var visibleTop: Float
    var boundsDirty = false
    var dragOnlyRebuild = true   // false (tests): every snapshot rebuilds all surfaces
    public internal(set) var windowsStale = false   // after a Space switch: no deposits on window surfaces until the next snapshot reconciles
    var stashBack: [(dx: Float, dy: Float, x: ClosedRange<Float>, e: Stashed)] = []   // windows back from another Space this update: their snowmen / balls / gifts are put back after the transports
    var stash: [Int: Stashed] = [:]   // window piles (and their frost) kept across a Space switch, by window number (cap 64, 30 min)
    var overhang: [Int: [Int: Float]] = [:]   // per window: snow on columns past the screen edge (global column -> height), kept until they come back on screen
    var spaceSwitchIDs: Set<Int> = []; var spaceSwitchUntil = 0.0   // windows present at the Space switch; they may be stashed (if they vanish) until the monotonic `clock` passes this
    var staleUntil = 0.0          // `windowsStale` lapses at this simulation time even without a changed snapshot (an identical one right after the switch proves nothing)
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
    var sweptAt = -1.0           // `time` of the last cursor push (Surfaces.sweep): pushed heaps slump toward their repose slope once the blade has moved on
    var runV: SIMD2<Float> = .zero
    public var economy = false   // Economy mode: no glints
    var surfaces: [Surface] = []
    var dockTrickle = DockTrickle()   // DockSpill.swift
    var index: [Int: Int] = [:]   // surface id -> index into `surfaces`, rebuilt with them in updateSurfaces
    var offsets: [Int32]       // CSR: per column range into entries
    var entries: [Entry] = []
    var lastWindows: [WindowInfo] = []
    var pendingGone: [Int: (s: Surface, since: Double)] = [:]   // windows missing from the latest poll: snow stashed, knocked off only after Tuning.goneGrace (Mission Control / minimise flicker)
    var goneGrace = Tuning.goneGrace   // s a window may be missing before its pile is knocked off (tests set 0 for the old immediate knock-off)
    var orderOnly = false   // the current rebuild only reorders the same windows (Cmd-Tab): buildSurface keeps all snow
    var dockCarryUntil = 0.0   // the carried Dock pile only applies to a rebuild within ~2 s of the resize (an auto-hidden Dock showing up later starts fresh)
    var dockMoundCarry: [Float] = []   // ... and its pushed-heap allowance
    var dockCarry: [Float] = []   // Resize.swift: Dock pile heights by (new) global column, waiting for the Dock surface to be rebuilt
    var dockTarget: CGRect?, dockCur: CGRect?, dockPrev: CGRect?   // DockPush.swift: read frame, animated frame, frame before this rebuild
    var dockSlump: Float = 0
    var bankLevel: (l: Float, r: Float) = (Tuning.groundMaxHeight, Tuning.groundMaxHeight), bankT: Float = 0   // ground bank ramp level per Dock side, DockPush.swift
    /// Window moved (same size) in the last poll: the overlay may slide its pile layer with the mouse until the next poll.
    public internal(set) var draggingID: Int?
    var numCols: Int
    let invBin = 1 / Tuning.binWidth
    let skyCount: Int      // sky pool size; the rest of `flakes` is background
    var nearLimit = 0       // sky slots [0, nearLimit) respawn as out-of-focus `.near` flakes (set each step)
    var skyLimit = 0        // active counts for the current intensity
    var bgLimit = 0
    var skyEnd = 0          // slots [0, skyEnd) of the sky pool / [skyCount, skyCount+bgEnd) of the background pool
    var bgEnd = 0           // may be live or spawning; everything beyond is dormant, so step/write skip it
    var intensity = Intensity.media
    // MARK: live region (Coverage.swift): flakes spawn / wrap inside [liveX0, liveX1], just above liveTop; limits scale with areaScale
    var liveX0: Float = 0, liveX1: Float = 0, liveTop: Float = 0
    var areaScale: Float = 1
    var lowPower = false
    private(set) var calm = false
    var groundWinKey: [CGRect] = [], groundWinCeil: [Float] = [], groundWinHidden: [Bool] = []   // buildGround cache (non-Dock windows)
    /// "Neve parada": `step` is never called, so nothing can animate: the Dock jumps to its target at once.
    public var frozen = false { didSet { if frozen, !oldValue, dockCur != dockTarget { dockCur = dockTarget; boundsDirty = true } } }
    var time: Double = 0
    var windGain: Float = 8
    var wind: Float = 0
    var gustLUT = [Float](repeating: 1, count: 129)   // gust along the diagonal coordinate, rebuilt once per step (one lerp per flake instead of a 2D noise)
    var windSlow: Float = 0   // wind relaxed over ~6 s: only sustained wind biases landings
    public var music = MusicInput.silent   // injected each frame by the app (Music.swift)
    var musicKick: Float = 0, musicDir: Float = 1, musicEdge = false, musicSway: Float = 1, musicGlint: Float = 1, musicBoost: Float = 1
    public var pilesDirty = false { didSet { if pilesDirty { pileVersion &+= 1 } } }
    /// Bumps whenever pile heights or geometry may have changed; `writePiles` rewrites only then (or while easing).
    public internal(set) var pileVersion = 0
    var pileWritten = -1, pileEasing = false
    var pileEnds: [PileEnd] = []
    /// Every window (and the Dock bar), front to back, local pt: a pile slice with `z` is hidden inside each entry whose index is < z (the overlay window sits above all windows, so the GPU clips what physics cannot).
    /// Rebuilt with the surfaces; capped at `maxOccluders` (the frontmost ones). `zOf`: surface id -> z; `groundZ` = behind all.
    public internal(set) var occluders: [Occluder] = []
    var zOf: [Int: UInt32] = [:]
    var groundZ: UInt32 = 0
    public static let maxOccluders = 32
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
    var shotLand: (p: SIMD2<Float>, t: Double)?, impactAt: (x: Float, y: Float, t: Double)?   // last landings (robin startle)
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
    var silentUntil: Double = 0   // simulation time until which knock-off debris is muted (Space switches)
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

    /// Space switch: nothing is emptied. Knock-offs are muted briefly and the window list is marked stale; the next changed snapshot
    /// stashes the windows that vanished (silently) and leaves the ones still present, the Dock, the ground and what stands on them alone.
    /// The windows present now are remembered (`spaceSwitchIDs`): any of them that vanishes from a changed snapshot within `spaceSwitchWindow` seconds of the monotonic
    /// clock (`now`, default the field's own) is stashed, however long the sim was paused or occluded in between.
    public func markStale(now: Double? = nil) {
        windowsStale = true; staleUntil = time + 4
        spaceSwitchIDs = Set(surfaces.lazy.map(\.id).filter { $0 > 0 }); spaceSwitchUntil = (now ?? clock) + Self.spaceSwitchWindow
    }
    static let spaceSwitchWindow = 6.0
    public func dropPiles() {
        silentUntil = time + 1.5
        pilesDirty = true
    }

    /// Intro: every flake goes dormant, then wakes from above the top edge, one slot after another,
    /// so the active count ramps linearly from 0 to the intensity's target over `duration` seconds of stepping. Piles are kept.
    public func beginIntro(duration: Float) {
        let wasQuiet = quiet
        endOutro()
        // Out of an outro / melt the flakes still fading out just fade back in (no pop); only dormant slots wake on the ramp. A fresh start goes dormant first.
        for i in flakes.indices where !(wasQuiet && flakes[i].kind != .dormant) { flakes[i].kind = .dormant }
        introT = 0; introDur = max(duration, 0.01)
    }

    /// Ends an outro or melt without touching the flakes (Reduce Motion's plain fade-in: spawning resumes on its own). Visitors fade back in and a
    /// sagged snowman eases back to its size (see stepFigure); `beginIntro` does this too.
    public func endOutro() {
        outro = false; outroRel = 1; melting = false
        snowmanCooldown = 0
        for i in figures.indices {
            if let k = figures[i].preMelt, figures[i].built != k.built { figures[i].built = k.built; figures[i].stageAge = 0 }   // accessories come back: the newest eases in
        }
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
        chain = AvaChain(); cursorThrow = CursorThrow()   // a front still sliding / a windup in flight would act on snow that is gone
        bankLevel = (Tuning.groundMaxHeight, Tuning.groundMaxHeight); bankT = 0; boundsDirty = true   // the ground ramp was earned by snow that is gone: rebuilt with the ground
        for g in figures where g.kind != .snowman { director.ended(g.kind, at: time) }   // visits end through the director: no infinite cooldown
        dockTrickle = DockTrickle(); sweepOwed = 0   // pending emission debts must not resurface as snow after clearing
        figures.removeAll(keepingCapacity: true); fights.removeAll(keepingCapacity: true); shots.removeAll(keepingCapacity: true); splats.removeAll(keepingCapacity: true)
        if !balls.isEmpty { balls.removeAll() }
        for i in surfaces.indices { surfaces[i].pile.empty() }
        stash.removeAll(); overhang.removeAll(); spaceSwitchIDs = []; dockCarry = []; dockMoundCarry = []
        windSlow = 0; stashBack.removeAll()
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
    public var isBusy: Bool { !busyReasons.isEmpty }

    /// Every reason `isBusy` holds right now (all of them, not just the first; NEVE_PERF counts frames per reason).
    public var busyReasons: BusyReasons {
        var r: BusyReasons = []
        if draggingID != nil { r.insert(.drag) }
        if dockCur != dockTarget || dockSlump > 0 { r.insert(.dock) }
        if !shots.isEmpty { r.insert(.shots) }
        if !fights.isEmpty { r.insert(.fights) }
        // Gentle shedding off window / pile ends (a dozen small chunks, always some in Nevasca) is fine at 30 fps; slabs and bursts are not.
        if debris.count > Tuning.busyDebris || debris.contains(where: { $0.amp > 0 }) { r.insert(.debris) }
        if (introDur > 0 && introT < introDur) || (outro && outroRel < 1) { r.insert(.introOutro) }
        if figures.contains(where: { $0.kind != .snowman }) { r.insert(.figures) }
        if abs(gust) > 0.15, !figures.isEmpty { r.insert(.gust) }   // a gust only moves figures (flutter, shots, balls have their own reasons); flakes drift fine at 30 fps
        if balls.contains(where: { $0.state != .resting }) { r.insert(.balls) }
        return r
    }
    /// The pile buffer written last is still the current picture (no version change, no easing left).
    public var pilesSettled: Bool { pileVersion == pileWritten && !pileEasing }

    public func step(dt: Float) {
        time += Double(dt)
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
        windSlow += (wind - windSlow) * min(1, dt / 6)
        if let timer { let t0 = timer(); stepFlakes(dt: dt); flakeSeconds += timer() - t0; flakeSteps += 1 } else { stepFlakes(dt: dt) }
        stepPeel(dt: dt)
        stepIce(dt: dt)
        stepAvalanche(dt: dt)
        stepDebris(dt: dt)
        stepDock(dt: dt)
        stepBank(dt: dt)
        stepDockSpill(dt: dt)
        stepSlump()
        stepPuffs(dt: dt)
        stepWindDust(dt: dt)
        stepGlints(dt: dt)
        stepDrips(dt: dt)
    }
}
