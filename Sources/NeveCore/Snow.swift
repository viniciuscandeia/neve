import CoreGraphics
import Foundation

/// Tuning knobs.
public enum Tuning {
    public static let flakes = 400                 // per 1440x900 screen (scaled by area)
    static let backgroundFraction: Float = 0.35
    static let maxPileHeight: Float = 18
    static let groundMaxHeight: Float = 24  // screen-bottom pile (lower-traffic, wide open, can sit deeper)
    static let groundID = -1
    static let minHeadroom: Float = 18      // a window top needs this much free space below the menu bar to carry snow
    static let minRoom: Float = 4           // columns with less room under a front window take no deposits
    static let binWidth: Float = 2
    static let slope: Float = 0.7           // max height step between neighbouring bins (~19 degree repose)
    static let cornerInset: Float = 6       // piles taper to 0 this far from surface ends
    /// Window corner radius: ~20pt from macOS 26 (Tahoe) on, ~10pt before.
    static func windowRadius(for v: OperatingSystemVersion) -> CGFloat { v.majorVersion >= 26 ? 20 : 10 }
    public static let windowRadius = windowRadius(for: ProcessInfo.processInfo.operatingSystemVersion)
    static let calmSway: Float = 0.25       // Reduce Motion: share of the lateral flake sway kept
    static let calmDebrisFall: Float = 30   // Reduce Motion: uniform initial fall speed of knocked-off snow
    static let depositScale: Float = 1.2    // pile volume per flake size
    static let wind: Float = 6
    static let maxDebris = 1200
    /// NEVE_SNOWMAN_FAST=1 (demos): builds 20x faster and on a shallower pile.
    static let snowmanFast = ProcessInfo.processInfo.environment["NEVE_SNOWMAN_FAST"] == "1"
    static let snowmanSpeed: Float = snowmanFast ? 20 : 1
    static let snowmanDepth: Float = snowmanFast ? 4 : 14   // average pile height over the stretch that triggers a build
    static let snowmanStretch: Float = 70                   // pt of visible ground the snowman needs
    static let snowmanClearance: Float = 20                 // pt kept free to the Dock ends, covering windows and screen edges
    static let ballStart: Float = 5                         // scooped snowball radius (10pt across)
    static let ballMax: Float = 20                          // rolled snowball radius cap (40pt across)
    static let ballGrowth: Float = 0.1                      // radius per pt rolled
    public static let maxBalls = 6
    static let snowmanCooldown: Float = 120                 // s of snowfall after a collapse
    static let pointerRadius: Float = 60     // falling snow avoids the cursor within this distance
    static let pointerPush: Float = 450      // pt/s radial speed at point blank (scaled by (1 - d/R)^2)
    static let pointerSwirl: Float = 250     // tangential counterpart
    static let debrisGravity: Float = 1400   // pt/s^2: packed snow accelerates instead of floating
    static let debrisTerminal: Float = 1700  // pt/s
    // Moving a window: the pile travels with it; `shed` (0...1) of it falls off, rising smoothly with speed.
    static let shedStart: Float = 400        // pt/s: below this nothing falls off
    static let shedFull: Float = 2500        // pt/s: at or above this everything falls off
    static let velSmoothing: Float = 0.1     // s: window velocity low-pass time constant
    static let shedRefDt: Float = 0.1        // s: update interval the shed fractions are calibrated for
    static let shedUp: Float = 0.8           // upward speed counts less (snow is pressed onto the roof) ...
    static let shedDown: Float = 1.3         // ... downward counts more (faster than gravity: snow floats off)
    static let shakeGain: Float = 0.7        // direction reversal: effective speed = this * |velocity change|
    static let shedEdgeBias: Float = 1.5     // extra shed at the window ends ...
    static let shedEdgeZone: Float = 0.15    // ... within this fraction of the width
}

/// Snow amount; `multiplier` scales the base flake count. Nevasca adds strong gusty wind.
public enum Intensity: Int, CaseIterable {
    case leve, media, forte, nevasca
    public static let key = "intensity"
    public static var saved: Intensity { Intensity(rawValue: UserDefaults.standard.object(forKey: key) as? Int ?? 1) ?? .media }
    public var title: String { ["Leve", "Média", "Forte", "Nevasca"][rawValue] }
    var multiplier: Float { [0.4, 1.0, 1.8, 3.0][rawValue] }
    var windGain: Float { self == .nevasca ? 100 : 8 }   // peak sideways speed, points/s
}

// MARK: - Window list

public struct WindowInfo: Equatable, Sendable {
    public let number: Int     // 0 = Dock bar
    public let frame: CGRect   // global AppKit coordinates (y up)
    public var radius: CGFloat = Tuning.windowRadius
    public init(number: Int, frame: CGRect, radius: CGFloat = Tuning.windowRadius) {
        self.number = number; self.frame = frame; self.radius = radius
    }
}

/// CG (origin top-left of primary screen, y down) -> AppKit (y up).
public func appKitFrame(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
}

/// One CGWindowList entry as plain values (nil = key missing). `alpha` defaults to 1 when absent.
public struct RawWindow {
    public var number: Int?, pid: Int?, layer: Int?
    public var alpha: Double
    public var bounds: CGRect?   // CG coordinates
    public init(number: Int?, pid: Int?, layer: Int?, alpha: Double = 1, bounds: CGRect?) {
        self.number = number; self.pid = pid; self.layer = layer; self.alpha = alpha; self.bounds = bounds
    }
}

/// Keeps layer-0, visible, foreign, at-least-40x20 windows; converts bounds to AppKit coordinates. Order preserved.
public func filterWindows(_ raw: [RawWindow], ownPID: Int, primaryHeight: CGFloat) -> [WindowInfo] {
    raw.compactMap { w in
        guard w.layer == 0, w.pid != ownPID, w.alpha > 0, let number = w.number, let r = w.bounds,
              r.width >= 40, r.height >= 20 else { return nil }
        return WindowInfo(number: number, frame: appKitFrame(fromCG: r, primaryHeight: primaryHeight))
    }
}

/// On-screen normal windows, front to back. Bounds need no Screen Recording permission.
public func readWindows(primaryHeight: CGFloat) -> [WindowInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return [] }
    // Read CF values directly: bridging every dictionary to Swift costs more than the call itself.
    func int(_ d: CFDictionary, _ k: CFString) -> Int? {
        guard let v = CFDictionaryGetValue(d, Unmanaged.passUnretained(k).toOpaque()) else { return nil }
        var n = 0
        return CFNumberGetValue(unsafeBitCast(v, to: CFNumber.self), .longType, &n) ? n : nil
    }
    var raw: [RawWindow] = []
    for i in 0..<CFArrayGetCount(list) {
        let w = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: CFDictionary.self)
        var alpha = 1.0
        if let a = CFDictionaryGetValue(w, Unmanaged.passUnretained(kCGWindowAlpha).toOpaque()) {
            CFNumberGetValue(unsafeBitCast(a, to: CFNumber.self), .doubleType, &alpha)
        }
        var bounds: CGRect?
        if let b = CFDictionaryGetValue(w, Unmanaged.passUnretained(kCGWindowBounds).toOpaque()) {
            bounds = CGRect(dictionaryRepresentation: unsafeBitCast(b, to: CFDictionary.self))
        }
        raw.append(RawWindow(number: int(w, kCGWindowNumber), pid: int(w, kCGWindowOwnerPID), layer: int(w, kCGWindowLayer), alpha: alpha, bounds: bounds))
    }
    return filterWindows(raw, ownPID: Int(getpid()), primaryHeight: primaryHeight)
}

// MARK: - Pile

/// Snow height per bin along one surface.
public struct Pile {
    var heights: [Float]
    var visible: [Bool]
    var base: [Float]            // baseline offset per bin (<= 0): drops along rounded corners
    var cap: [Float]             // per-bin height ceiling imposed by windows in front (inf = none)
    let inset: Float
    var maxHeight = Tuning.maxPileHeight
    let c0: Int                  // first global column, and the REAL (unclipped) window ends in x:
    let x0: Float, x1: Float     // taper and spill-off are measured against these, not the screen-clipped pile
    var spillL: Float = 0        // snow slid off each end, turned into debris by SnowField
    var spillR: Float = 0

    init(columns: Int, inset: Float, c0: Int = 0, x0: Float = 0, x1: Float? = nil) {
        self.c0 = c0; self.x0 = x0; self.x1 = x1 ?? Float(c0 + columns) * Tuning.binWidth
        cap = [Float](repeating: .infinity, count: columns)
        heights = [Float](repeating: 0, count: columns)
        visible = [Bool](repeating: true, count: columns)
        base = [Float](repeating: 0, count: columns)
        self.inset = inset
    }

    mutating func empty() { for b in heights.indices { heights[b] = 0 } }

    /// Baseline follows the corner arcs within `radius` of each end.
    mutating func round(radius: Float, c0: Int, minX: Float, maxX: Float) {
        guard radius > 0 else { return }
        for b in base.indices {
            let x = binCenter(c0 + b)
            let d = max(min(x - minX, maxX - x), 0)
            if d < radius { let k = radius - d; base[b] = -(radius - (radius * radius - k * k).squareRoot()) }
        }
    }

    func limit(_ bin: Int) -> Float {
        var l = maxHeight
        if inset > 0 {
            let x = binCenter(c0 + bin)
            l *= min(1, max(min(x - x0, x1 - x), 0) / inset)
        }
        return min(l, cap[bin])
    }

    /// Adds snow around `bin` (spread 1/4-1/2-1/4 so no single-bin spikes), then relaxes locally.
    /// Returns whether anything changed.
    @discardableResult
    mutating func deposit(bin: Int, volume: Float) -> Bool {
        guard bin >= 0, bin < heights.count, visible[bin], cap[bin] >= Tuning.minRoom else { return false }
        var changed = false
        for o in -1...1 {
            var i = bin + o
            if i < 0 || i >= heights.count || !visible[i] { i = bin }
            guard cap[i] >= Tuning.minRoom else { continue }
            let before = heights[i]
            heights[i] = max(before, min(before + volume * (o == 0 ? 0.5 : 0.25), limit(i)))
            if heights[i] != before { changed = true }
        }
        let lo = max(0, bin - 8), hi = min(heights.count - 1, bin + 8)
        for _ in 0..<6 {
            for i in lo...hi {
                if relax(i, i - 1) { changed = true }
                if relax(i, i + 1) { changed = true }
            }
        }
        for i in max(lo - 1, 0)...min(hi + 1, heights.count - 1) {   // relaxation reaches one bin past the window
            let over = heights[i] - max(limit(i), 0)
            guard over > 0 else { continue }
            heights[i] -= over
            if i == 0 { spillL += over } else if i == heights.count - 1 { spillR += over }
            changed = true
        }
        return changed
    }

    /// The window continues past the screen edge on that side, so the end of the pile there is not a drop-off.
    private func continuesPastScreen(left: Bool) -> Bool {
        left ? x0 < Float(c0 - 1) * Tuning.binWidth : x1 > Float(c0 + heights.count + 1) * Tuning.binWidth
    }

    /// Moves half the excess slope (on baseline + height) from bin i to lower neighbour j.
    /// Hidden j drains silently; past the ends the snow spills off as debris.
    private mutating func relax(_ i: Int, _ j: Int) -> Bool {
        let inRange = j >= 0 && j < heights.count
        if !inRange && continuesPastScreen(left: j < 0) { return false }
        let ok = inRange && visible[j]
        let tj = ok ? base[j] + heights[j] : (inRange ? base[i] : base[i] - 4)
        let excess = base[i] + heights[i] - tj - Tuning.slope
        guard excess > 0, heights[i] > 0 else { return false }
        let m = min(excess * 0.5, heights[i])
        heights[i] -= m
        if ok { heights[j] += m } else if !inRange { if j < 0 { spillL += m } else { spillR += m } }
        return true
    }
}

// MARK: - Flakes

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
}

/// GPU instance, 24 bytes (8-aligned); layout mirrors the Metal struct.
public struct Instance {
    var pos: SIMD2<Float>
    var size: Float
    var alpha: Float
    var seed: Float
}

struct Surface {
    let id: Int          // window number; 0 = Dock bar, Tuning.groundID = screen bottom
    let frame: CGRect    // unclipped, local coords
    let edgeY: Float
    let c0: Int          // first global column
    let anchor: Int      // window's left edge in whole columns (absolute): pile moves are differences of these, so rounding never accumulates
    var pile: Pile
    var vel: SIMD2<Float> = .zero   // window velocity (pt/s) at the last poll that moved it
}

struct Entry {
    let surface: Int32
    let edgeY: Float
}

// MARK: - SnowField

/// Small seedable generator so simulations are reproducible in tests.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Per-screen simulation: flakes, surface map, piles. Local coords are points, y up.
public final class SnowField {
    public let size: SIMD2<Float>
    let origin: CGPoint
    private(set) var groundY: Float
    private(set) var visibleTop: Float
    private var boundsDirty = false
    public private(set) var flakes: [Flake] = []
    public internal(set) var debris: [Flake] = []
    var surfaces: [Surface] = []
    var offsets: [Int32]       // CSR: per column range into entries
    var entries: [Entry] = []
    private var lastWindows: [WindowInfo] = []
    /// Window moved (same size) in the last poll: the overlay may slide its pile layer with the mouse until the next poll.
    public private(set) var draggingID: Int?
    private let numCols: Int
    private let invBin = 1 / Tuning.binWidth
    private let skyCount: Int      // sky pool size; the rest of `flakes` is background
    private var skyLimit = 0        // active counts for the current intensity
    private var bgLimit = 0
    private var skyEnd = 0          // slots [0, skyEnd) of the sky pool / [skyCount, skyCount+bgEnd) of the background pool
    private var bgEnd = 0           // may be live or spawning; everything beyond is dormant, so step/write skip it
    private var intensity = Intensity.media
    private var lowPower = false
    private(set) var calm = false
    private var time: Float = 0
    private var windGain: Float = 8
    private(set) var wind: Float = 0
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
    private var pointer: SIMD2<Float>?
    private var pointerVel: SIMD2<Float> = .zero
    private var pollDt: Float = 0.1        // seconds between the last two window polls
    private var lastPoll: CFAbsoluteTime = 0
    var rng: SplitMix64
    var silentUntil: CFAbsoluteTime = 0   // no knock-off debris until then (Space switches)
    private var introT: Float = 0, introDur: Float = 0   // intro: flake slots wake in order over introDur seconds (0 = no intro running)
    public private(set) var outro = false                // outro: no new snow, flakes fade, nothing lands (see collapseAll)
    private var outroT: Float = 0, outroSpread: Float = 0, outroRel: Float = 1   // piles released so far: 0...1 of the spread (1 = all)

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

    private func spawn(_ kind: FlakeKind, anywhere: Bool) -> Flake {
        let x = Float.random(in: 0...size.x, using: &rng)
        let y = anywhere ? Float.random(in: 0...size.y, using: &rng) : size.y + Float.random(in: 0...40, using: &rng)
        let phase = Float.random(in: 0...(2 * .pi), using: &rng)
        switch kind {
        case .background:
            let s = Float.random(in: 1.5...3.5, using: &rng)
            return Flake(pos: [x, y], vx: Tuning.wind * Float.random(in: 0.7...1.3, using: &rng), fall: Float.random(in: 25...50, using: &rng),
                         phase: phase, amp: Float.random(in: 5...15, using: &rng), freq: Float.random(in: 0.8...2, using: &rng),
                         size: s, alpha: Float.random(in: 0.25...0.55, using: &rng), kind: .background,
                         seed: Float.random(in: 0..<1, using: &rng), fade: anywhere ? 1 : 0)
        default:
            let s = Float.random(in: 2.5...7, using: &rng)
            return Flake(pos: [x, y], vx: Tuning.wind * Float.random(in: 0.7...1.3, using: &rng), fall: 40 + s * 8 + Float.random(in: 0...10, using: &rng),
                         phase: phase, amp: Float.random(in: 8...25, using: &rng), freq: Float.random(in: 0.8...2, using: &rng),
                         size: s, alpha: Float.random(in: 0.7...1, using: &rng), kind: .sky,
                         seed: Float.random(in: 0..<1, using: &rng), fade: anywhere ? 1 : 0)
        }
    }

    /// 0..<1 position of slot `i` among the active ones of its pool (the order they wake in during the intro).
    private func introRank(_ i: Int) -> Float { i < skyCount ? Float(i) / Float(skyLimit) : Float(i - skyCount) / Float(bgLimit) }

    private func isActive(_ i: Int) -> Bool { i < skyCount ? i < skyLimit : i - skyCount < bgLimit }

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

    /// Smooth gusts: slow sines with unrelated periods; sign flips over several seconds.
    private func windShape() -> Float {
        0.55 * sin(time * 2 * .pi / 37) + 0.3 * sin(time * 2 * .pi / 17 + 1.3) + 0.25 * sin(time * 2 * .pi / 9 + 2.1)
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

    /// Releases the bins whose (x-ordered, jittered) rank lies in (from, to].
    private func releasePiles(from: Float, to: Float) {
        for si in surfaces.indices {
            let c0 = surfaces[si].c0, edgeY = surfaces[si].edgeY
            for b in surfaces[si].pile.heights.indices {
                let h = surfaces[si].pile.heights[b], col = c0 + b
                guard h > 0 else { continue }
                let rank = 0.7 * binCenter(col) / size.x + 0.3 * Float(UInt32(truncatingIfNeeded: col &* 2654435761) % 1000) / 1000
                guard rank > from, rank <= to else { continue }
                surfaces[si].pile.heights[b] = 0
                _ = shedBin(col: col, edgeY: edgeY + surfaces[si].pile.base[b], from: 0, amount: h, velocity: .zero)
            }
        }
        pilesDirty = true
    }

    public func clear() {
        snowman = nil
        if !balls.isEmpty { balls.removeAll(); ballsVersion &+= 1 }
        for i in surfaces.indices { surfaces[i].pile.empty() }
        debris.removeAll(keepingCapacity: true)
        pilesDirty = true
    }

    // MARK: Surface map

    func column(_ x: Float) -> Int { min(max(Int(x * invBin), 0), numCols - 1) }

    func edgeVisible(id: Int, x: Float) -> Bool {
        let c = column(x)
        for k in Int(offsets[c])..<Int(offsets[c + 1]) where surfaces[Int(entries[k].surface)].id == id { return true }
        return false
    }

    /// One flake lands on a surface (also the test entry point for building piles without simulating snowfall).
    func deposit(surface: Int, bin: Int, volume: Float) {
        if surfaces[surface].pile.deposit(bin: bin, volume: volume) { pilesDirty = true }
        if surfaces[surface].pile.spillL > 2 || surfaces[surface].pile.spillR > 2 { spill(surface) }
    }

    /// Snow that slid off a surface end falls as debris.
    private func spill(_ si: Int) {
        let c0 = surfaces[si].c0, edgeY = surfaces[si].edgeY, last = surfaces[si].pile.heights.count - 1
        for left in [true, false] {
            let amount = left ? surfaces[si].pile.spillL : surfaces[si].pile.spillR
            guard amount > 2 else { continue }
            let sign: Float = left ? -1 : 1
            addDebris(x: Float(left ? c0 : c0 + last + 1) * Tuning.binWidth, y: edgeY + surfaces[si].pile.base[left ? 0 : last],
                      vx: sign * Float.random(in: 8...25, using: &rng), fall: Float.random(in: 10...30, using: &rng))
            if left { surfaces[si].pile.spillL = 0 } else { surfaces[si].pile.spillR = 0 }
        }
    }

    /// `fall` is the current downward speed; `step` accelerates it. Heavy snow: bigger and brighter than sky flakes.
    @discardableResult
    func addDebris(x: Float, y: Float, vx: Float, fall: Float, size: Float? = nil) -> Bool {
        guard debris.count < Tuning.maxDebris else { return false }
        debris.append(Flake(pos: [x, y], vx: vx, fall: max(fall, 0), phase: 0, amp: 0, freq: 0, size: size ?? Float.random(in: 3...5, using: &rng), alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1))
        return true
    }

    /// Dock / menu bar moved: keeps flakes and piles, surfaces are rebuilt on the next `update`.
    public func setBounds(groundY: CGFloat, visibleTop: CGFloat) {
        guard Float(groundY) != self.groundY || Float(visibleTop) != self.visibleTop else { return }
        self.groundY = Float(groundY)
        self.visibleTop = Float(visibleTop)
        boundsDirty = true
    }

    func pile(id: Int) -> Pile? { surfaces.first { $0.id == id }?.pile }

    /// Rebuilds surfaces from the front-to-back window list. Returns debris spawned by knocked-off piles.
    @discardableResult
    public func update(windows: [WindowInfo], dt: Float? = nil) -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        // Time since the last *change*: identical lists (event bursts, polls) must not shrink dt, or velocity is overestimated.
        pollDt = dt ?? Float(min(max(now - lastPoll, 1.0 / 240), 0.5))
        guard windows != lastWindows || boundsDirty else {
            if draggingID != nil { draggingID = nil; pilesDirty = true }
            for i in surfaces.indices { surfaces[i].vel = .zero }
            return 0
        }
        lastPoll = now
        boundsDirty = false
        lastWindows = windows
        return updateSurfaces(windows: windows)
    }

    private var moved: Int?   // scratch for updateSurfaces/buildSurface

    /// 0...1 share of a pile that falls off when its window moves with velocity `v` (previous poll's velocity `prev`).
    static func shedFraction(v: SIMD2<Float>, prev: SIMD2<Float>) -> Float {
        var s = (v.x * v.x + (v.y > 0 ? Tuning.shedUp : Tuning.shedDown) * (v.y > 0 ? Tuning.shedUp : Tuning.shedDown) * v.y * v.y).squareRoot()
        if v.x * prev.x + v.y * prev.y < 0 {   // sharp shake: reversal at speed
            let d = v - prev
            s = max(s, Tuning.shakeGain * (d.x * d.x + d.y * d.y).squareRoot())
        }
        let t = min(max((s - Tuning.shedStart) / (Tuning.shedFull - Tuning.shedStart), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Share removed per update, scaled so shedding depends on elapsed time, not update rate (reference: the old 10 Hz drag poll).
    static func perUpdate(_ f: Float, dt: Float) -> Float { dt >= Tuning.shedRefDt ? f : 1 - pow(1 - f, dt / Tuning.shedRefDt) }

    @discardableResult
    private func updateSurfaces(windows: [WindowInfo]) -> Int {
        let ox = origin.x, oy = origin.y
        var rects: [CGRect] = []
        rects.reserveCapacity(windows.count)
        for w in windows { rects.append(w.frame.offsetBy(dx: -ox, dy: -oy)) }

        let before = surfaces
        var old = before
        var built: [Surface] = []
        var spawned = 0
        moved = nil
        for (i, r) in rects.enumerated() {
            let id = windows[i].number, edge = Float(r.maxY)
            // Dock bar (id 0) sits below the visible frame's bottom; hidden/offscreen Dock has minY < 0.
            let lowOk = id == 0 ? r.minY >= -1 : edge > groundY
            guard lowOk, visibleTop - edge >= Tuning.minHeadroom, r.maxX > 0, r.minX < CGFloat(size.x) else { continue }
            if let s = buildSurface(id: id, frame: r, edgeY: edge, radius: windows[i].radius, rects: rects, front: i, old: &old, spawned: &spawned) { built.append(s) }
        }
        if let g = buildGround(rects: rects, windows: windows, old: &old) { built.append(g) }   // behind everything: every window and the Dock hide it
        for s in old { spawned += knockOff(s) }   // gone surfaces
        draggingID = moved
        surfaces = built
        buildColumns()
        transportBalls(before: before)
        pilesDirty = true
        return spawned
    }

    /// Screen-bottom pile: full width, flat, no taper, edges drain nothing. Snow under covered columns stays (hidden), not knocked off.
    private func buildGround(rects: [CGRect], windows: [WindowInfo], old: inout [Surface]) -> Surface? {
        let bw = Tuning.binWidth
        let frame = CGRect(x: -1e5, y: -1, width: 2e5 + CGFloat(size.x), height: 1)   // "window" extends past the screen: no edge spill
        var pile = Pile(columns: numCols, inset: 0, c0: 0, x0: Float(frame.minX), x1: Float(frame.maxX))
        pile.maxHeight = Tuning.groundMaxHeight
        for b in 0..<numCols {
            let x = CGFloat((Float(b) + 0.5) * bw)
            var ceiling = Float.infinity
            for (i, r) in rects.enumerated() {
                // The floating Dock bar hovers a few points above the screen bottom: it still hides the ground under it.
                let covers = windows[i].number == 0 ? r.maxY > 1 && x >= r.minX && x < r.maxX : r.contains(CGPoint(x: x, y: 1))
                if covers { pile.visible[b] = false; break }
                if r.minY > 1, x >= r.minX, x < r.maxX { ceiling = min(ceiling, Float(r.minY)) }
            }
            pile.cap[b] = ceiling
        }
        if let k = old.firstIndex(where: { $0.id == Tuning.groundID }) {
            let prev = old.swapRemove(k)
            for b in 0..<numCols { pile.heights[b] = min(prev.pile.heights[b], pile.limit(b)) }
        }
        return Surface(id: Tuning.groundID, frame: frame, edgeY: 0, c0: 0, anchor: 0, pile: pile)
    }

    private func buildSurface(id: Int, frame: CGRect, edgeY: Float, radius: CGFloat, rects: [CGRect], front: Int,
                              old: inout [Surface], spawned: inout Int) -> Surface? {
        let bw = Tuning.binWidth
        let c0 = max(0, Int(((Float(frame.minX) - bw / 2) / bw).rounded(.up)))
        let c1 = min(numCols, Int(((Float(frame.maxX) - bw / 2) / bw).rounded(.down)) + 1)
        guard c1 > c0 else { return nil }
        let anchor = Int((Float(frame.minX) / bw).rounded())
        var pile = Pile(columns: c1 - c0, inset: Tuning.cornerInset, c0: c0, x0: Float(frame.minX), x1: Float(frame.maxX))
        pile.round(radius: Float(min(radius, frame.width / 2, frame.height / 2)), c0: c0, minX: Float(frame.minX), maxX: Float(frame.maxX))
        let y = CGFloat(edgeY) + 1
        for b in 0..<(c1 - c0) {
            let x = CGFloat(binCenter(c0 + b))
            var hidden = false
            var ceiling = Float.infinity   // lowest underside of a front window above the edge in this column
            for j in 0..<front {
                let r = rects[j]
                if r.contains(CGPoint(x: x, y: y)) { hidden = true; break }
                if r.minY > y, x >= r.minX, x < r.maxX { ceiling = min(ceiling, Float(r.minY)) }
            }
            pile.visible[b] = !hidden
            pile.cap[b] = max(ceiling - edgeY - pile.base[b], 0)
        }
        var vel = SIMD2<Float>.zero
        if let k = old.firstIndex(where: { $0.id == id }) {
            let prev = old.swapRemove(k)
            let d = SIMD2(Float(frame.minX - prev.frame.minX), Float(frame.minY - prev.frame.minY))
            let sameSize = abs(prev.frame.width - frame.width) < 0.5 && abs(prev.frame.height - frame.height) < 0.5
            let shift = anchor - prev.anchor
            func carry(shift: Int) {   // heights by global column, clipped to what is visible / allowed now
                for b in pile.heights.indices where pile.visible[b] {
                    let k = c0 + b - shift - prev.c0
                    if k >= 0, k < prev.pile.heights.count { pile.heights[b] = min(prev.pile.heights[k], pile.limit(b)) }
                }
            }
            if id == 0 {   // Dock bar resizes when apps come and go: keep snow by global column
                carry(shift: 0)
            } else if sameSize, shift == 0, abs(d.y) < 0.5, prev.pile.heights.count == pile.heights.count {
                var kept = prev.pile
                kept.visible = pile.visible
                kept.cap = pile.cap
                for b in kept.heights.indices { kept.heights[b] = pile.visible[b] ? min(kept.heights[b], kept.cap[b]) : 0 }
                pile = kept
            } else if sameSize {   // moved: the pile travels with the window; a speed-dependent share falls off
                // Smooth over ~100 ms: at frame-rate updates raw d/dt is noisy; at the old 0.1-0.5 s polls this is ~raw.
                let a = exp(-pollDt / Tuning.velSmoothing)
                vel = prev.vel * a + d / pollDt * (1 - a)
                if moved == nil { moved = id }
                carry(shift: shift)
                spawned += shed(&pile, c0: c0, edgeY: edgeY, frame: frame, fraction: SnowField.perUpdate(SnowField.shedFraction(v: vel, prev: prev.vel), dt: pollDt), velocity: vel)
            } else {   // resized: snow stays where it is in x; the part no longer over the window falls
                carry(shift: 0)
                let v = (d / pollDt).limited()
                for k in prev.pile.heights.indices {
                    let col = prev.c0 + k
                    if col < c0 || col >= c1 { spawned += shedBin(col: col, edgeY: prev.edgeY + prev.pile.base[k], from: 0, amount: prev.pile.heights[k], velocity: v) }
                }
            }
        }
        return Surface(id: id, frame: frame, edgeY: edgeY, c0: c0, anchor: anchor, pile: pile, vel: vel)
    }

    private func buildColumns() {
        for i in offsets.indices { offsets[i] = 0 }
        for s in surfaces {
            for b in s.pile.heights.indices where s.pile.visible[b] { offsets[s.c0 + b + 1] += 1 }
        }
        for c in 0..<numCols { offsets[c + 1] += offsets[c] }
        entries = [Entry](repeating: Entry(surface: 0, edgeY: 0), count: Int(offsets[numCols]))
        var fill = offsets
        for (si, s) in surfaces.enumerated() {
            for b in s.pile.heights.indices where s.pile.visible[b] {
                let c = s.c0 + b
                entries[Int(fill[c])] = Entry(surface: Int32(si), edgeY: s.edgeY + s.pile.base[b])
                fill[c] += 1
            }
        }
    }

    /// Takes `fraction` of the pile off as debris, preferring the tops and the window ends.
    private func shed(_ pile: inout Pile, c0: Int, edgeY: Float, frame: CGRect, fraction: Float, velocity v: SIMD2<Float>) -> Int {
        guard fraction > 0 else { return 0 }
        let v = v.limited()
        let zone = max(Float(frame.width) * Tuning.shedEdgeZone, 1)
        var n = 0
        for b in pile.heights.indices where pile.heights[b] > 0.5 {
            let x = binCenter(c0 + b)
            let edge = max(0, 1 - min(x - Float(frame.minX), Float(frame.maxX) - x) / zone)
            let h = pile.heights[b], r = h * min(1, fraction * (1 + Tuning.shedEdgeBias * edge))
            n += shedBin(col: c0 + b, edgeY: edgeY + pile.base[b], from: h - r, amount: r, velocity: v)
            pile.heights[b] = h - r
        }
        return n
    }

    /// Cursor wipe: snow within `radius` of the segment a->b (local coords) above the cursor's lower edge is pushed off
    /// as debris flying along the cursor's motion (`dt` = time the move took). The dragged window's pile is left alone.
    public func sweep(from a: CGPoint, to b: CGPoint, radius: Float = 10, dt: Float = 1.0 / 60) {
        let ax = Float(a.x), ay = Float(a.y), dx = Float(b.x) - ax, dy = Float(b.y) - ay
        let len2 = dx * dx + dy * dy, r = radius
        guard len2 > 0, dt > 0 else { return }
        let v = (SIMD2(dx, dy) / dt).limited()
        let lo = min(ay, ay + dy) - r, hi = max(ay, ay + dy) + r
        let first = debris.count
        collapseIfSwept(ax, ay, Float(b.x), Float(b.y), r, v)
        breakBalls(ax, ay, Float(b.x), Float(b.y), r, v)
        defer { for j in first..<debris.count { debris[j].phase = 0.5 } }
        for si in surfaces.indices where surfaces[si].id != draggingID {
            let c = surfaces[si].c0, edgeY = surfaces[si].edgeY   // no `let s = surfaces[si]`: a live copy would force a copy of the heights on write
            guard hi >= edgeY - Tuning.maxPileHeight, lo <= edgeY + Tuning.maxPileHeight else { continue }
            let b0 = max(0, Int((min(ax, ax + dx) - r) * invBin) - c), b1 = min(surfaces[si].pile.heights.count - 1, Int((max(ax, ax + dx) + r) * invBin) - c)
            guard b0 <= b1 else { continue }
            for k in b0...b1 {
                let h = surfaces[si].pile.heights[k]
                guard h > 0.5 else { continue }
                let x = binCenter(c + k), bottom = edgeY + surfaces[si].pile.base[k], my = bottom + h / 2
                let t = min(max(((x - ax) * dx + (my - ay) * dy) / len2, 0), 1)
                let qx = ax + t * dx, qy = ay + t * dy
                guard abs(qx - x) <= r, abs(qy - my) <= r + h / 2 else { continue }
                let keep = min(max(qy - r - bottom, 0), h)
                guard keep < h else { continue }
                surfaces[si].pile.heights[k] = keep
                _ = shedBin(col: c + k, edgeY: bottom, from: keep, amount: h - keep, velocity: v)
            }
        }
    }

    /// Turns a whole pile into falling debris, inheriting some of the surface's motion.
    private func knockOff(_ s: Surface, velocity v: SIMD2<Float> = .zero) -> Int {
        var n = 0
        for (b, h) in s.pile.heights.enumerated() { n += shedBin(col: s.c0 + b, edgeY: s.edgeY + s.pile.base[b], from: 0, amount: h, velocity: v) }
        return n
    }

    /// Debris (~1 flake per 3pt of snow) for the slice [from, from+amount] of one bin's column of snow.
    private func shedBin(col: Int, edgeY: Float, from: Float, amount h: Float, velocity v: SIMD2<Float>) -> Int {
        guard h > 0.5, CFAbsoluteTimeGetCurrent() >= silentUntil else { return 0 }
        var n = 0
        for _ in 0..<max(1, Int(h / 3)) {
            guard debris.count < Tuning.maxDebris else { break }
            let x = (Float(col) + Float.random(in: 0...1, using: &rng)) * Tuning.binWidth
            let y = edgeY + from + Float.random(in: 0...h, using: &rng)
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
        if n > 0 { pilesDirty = true }
        return n
    }

    // MARK: Physics

    private func tryLand(x: Float, prevY: Float, newY: Float, volume: Float) -> Bool {
        if outro { return false }   // nothing lands, so nothing rebuilds: snow falls through
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
        deposit(surface: best, bin: c - surfaces[best].c0, volume: volume)
        return true
    }

    /// Pointer position (local coords, nil = not on this screen) and velocity (pt/s): falling snow swirls around it.
    public func setPointer(_ p: SIMD2<Float>?, velocity: SIMD2<Float>) { pointer = p; pointerVel = velocity }

    public func step(dt: Float) {
        let w = size.x
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
        var liveSky = 0, liveBg = 0   // one past the last non-dormant slot of each pool
        for n in 0..<(skyEnd + bgEnd) {
            let i = n < skyEnd ? n : skyCount + n - skyEnd
            var f = flakes[i]
            if f.kind == .dormant {
                if isActive(i), !outro, introDur > 0 ? introRank(i) < introT / introDur : Float.random(in: 0..<1, using: &rng) < dt * 0.3 { flakes[i] = spawn(i < skyCount ? .sky : .background, anywhere: false) }
                continue
            }
            let prevY = f.pos.y
            f.fade = outro ? max(0, f.fade - dt * 1.5) : min(1, f.fade + dt * 2.5)   // ~0.4s fade-in; ~0.7s fade-out in the outro
            if outro, f.fade == 0 { f.kind = .dormant; flakes[i] = f; continue }
            f.phase += f.freq * dt
            f.pos.x += (f.vx + wind * f.vx / Tuning.wind + f.amp * (calm ? Tuning.calmSway : 1) * cos(f.phase)) * dt
            f.pos.y -= f.fall * dt * (calm ? 0.5 : 1)
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
            if f.pos.x < -10 { f.pos.x += w + 20 } else if f.pos.x > w + 10 { f.pos.x -= w + 20 }
            if f.kind == .sky, tryLand(x: f.pos.x, prevY: prevY, newY: f.pos.y, volume: f.size * Tuning.depositScale) {
                f = spawn(.sky, anywhere: false)
            } else if f.pos.y < -f.size {
                f = spawn(f.kind, anywhere: false)
            }
            if !isActive(i), f.pos.y > size.y { f.kind = .dormant }   // just respawned: retire
            flakes[i] = f
            if f.kind != .dormant { if i < skyCount { liveSky = i + 1 } else { liveBg = i - skyCount + 1 } }
        }
        skyEnd = max(skyLimit, liveSky); bgEnd = max(bgLimit, liveBg)
        if introT >= introDur { introDur = 0 }
        var i = debris.count - 1
        while i >= 0 {
            var f = debris[i]
            let prevY = f.pos.y
            f.fade = min(1, f.fade + dt * 2.5)
            f.phase -= dt   // swept-off snow cannot land back for a moment (see sweep)
            f.vx -= (f.vx - wind * 0.15) * 0.5 * dt
            f.fall = min(f.fall + Tuning.debrisGravity * dt, Tuning.debrisTerminal)
            f.pos.x += f.vx * dt
            f.pos.y -= f.fall * dt
            if f.pos.y < -f.size || f.pos.x < 0 || f.pos.x > w
                || (f.phase <= 0 && tryLand(x: f.pos.x, prevY: prevY, newY: f.pos.y, volume: f.size * Tuning.depositScale)) {
                debris[i] = debris[debris.count - 1]
                debris.removeLast()
            } else {
                debris[i] = f
            }
            i -= 1
        }
    }

    /// Fills GPU instances; returns the count.
    public func writeInstances(to p: UnsafeMutablePointer<Instance>) -> Int {
        var n = 0
        for i in 0..<(skyEnd + bgEnd) {
            let f = flakes[i < skyEnd ? i : skyCount + i - skyEnd]
            if f.kind != .dormant { p[n] = Instance(pos: f.pos, size: f.size, alpha: f.alpha * f.fade, seed: f.seed); n += 1 }
        }
        for f in debris { p[n] = Instance(pos: f.pos, size: f.size, alpha: f.alpha * f.fade, seed: f.seed); n += 1 }
        return n
    }

    // MARK: Pile path

    /// One path for every pile on this screen: a closed, smooth subpath per snowy run.
    /// Top edge = midpoint quadratic curves through every 3rd bin of the lightly blurred surface.
    /// `forDrag` false: every pile except window `dragging`'s; true: only that one (it gets its own layer while dragged).
    public func pilePath(dragging: Int = -1, forDrag: Bool = false) -> CGPath {
        let path = CGMutablePath()
        let bw = CGFloat(Tuning.binWidth)
        var idx: [Int] = [], pts: [CGPoint] = []
        for s in surfaces where (s.id == dragging) == forDrag {
            let h = s.pile.heights, vis = s.pile.visible, base = s.pile.base
            let n = h.count
            let edge = CGFloat(s.edgeY)
            func x(_ i: Int) -> CGFloat { (CGFloat(s.c0 + i) + 0.5) * bw }
            func ceiling(_ i: Int) -> CGFloat { edge + CGFloat(base[i] + s.pile.cap[i]) }   // infinite where no window is in front
            func top(_ i: Int, _ b: Int, _ e: Int) -> CGPoint {
                let l = i > b ? h[i - 1] : 0, r = i < e - 1 ? h[i + 1] : 0
                let sm = (l + 2 * h[i] + r) / 4
                // Stable irregularity keyed on the window-relative column (travels with the pile), scaled by height so it vanishes at the ends.
                let n = Float(noise(s.c0 + i - s.anchor)) * min(sm * 0.08, 1.5)
                return CGPoint(x: x(i), y: min(edge + CGFloat(base[i] + sm + n), ceiling(i)))
            }
            var b = 0
            while b < n {
                guard vis[b] else { b += 1; continue }
                var e = b
                while e < n && vis[e] { e += 1 }
                var lo = b, hi = e - 1
                while lo <= hi && h[lo] <= 0.15 { lo += 1 }
                while hi >= lo && h[hi] <= 0.15 { hi -= 1 }
                if lo <= hi {
                    lo = max(b, lo - 1); hi = min(e - 1, hi + 1)
                    idx.removeAll(keepingCapacity: true)
                    for i in lo..<hi where i == lo || (s.c0 + i - s.anchor) % 3 == 0 { idx.append(i) }
                    idx.append(hi)
                    pts.removeAll(keepingCapacity: true)
                    for i in idx { pts.append(top(i, b, e)) }
                    path.move(to: pts[0])
                    if idx.count > 2 {
                        for k in 1..<(idx.count - 1) {
                            let c = pts[k], nx = pts[k + 1]
                            // Control and end points all stay under the ceiling, so the quad cannot cross it.
                            path.addQuadCurve(to: CGPoint(x: (c.x + nx.x) / 2, y: min((c.y + nx.y) / 2, ceiling(idx[k]), ceiling(idx[k + 1]))), control: c)
                        }
                    }
                    if idx.count > 1 { path.addLine(to: pts[idx.count - 1]) }
                    for k in idx.reversed() { path.addLine(to: CGPoint(x: x(k), y: edge + CGFloat(base[k]) - 1)) }
                    path.closeSubpath()
                }
                b = e
            }
        }
        return path
    }
}

/// Centre x (points) of global column `c`.
func binCenter(_ c: Int) -> Float { (Float(c) + 0.5) * Tuning.binWidth }

/// Deterministic value noise in -1...1 for a column index.
func noise(_ i: Int) -> CGFloat {
    var z = UInt64(bitPattern: Int64(i)) &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return CGFloat(Double((z ^ (z >> 31)) >> 11) / Double(1 << 52) - 1)
}

extension SIMD2<Float> {
    /// Debris launch speeds are capped per axis (pt/s).
    func limited(_ m: Float = 800) -> SIMD2<Float> { clamped(lowerBound: SIMD2(repeating: -m), upperBound: SIMD2(repeating: m)) }
}

private extension Array {
    mutating func swapRemove(_ i: Int) -> Element {
        swapAt(i, count - 1)
        return removeLast()
    }
}
