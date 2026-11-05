import CoreGraphics
import Foundation

/// Tuning knobs.
public enum Tuning {
    public static let flakes = 400                 // per 1440x900 screen (scaled by area)
    static let backgroundFraction: Float = 0.35
    static let maxPileHeight: Float = 18
    static let binWidth: Float = 2
    static let slope: Float = 0.7           // max height step between neighbouring bins (~19 degree repose)
    static let cornerInset: Float = 6       // piles taper to 0 this far from surface ends
    public static let windowRadius: CGFloat = 20   // macOS 26 window corner radius
    static let depositScale: Float = 1.2    // pile volume per flake size
    static let wind: Float = 6
    static let maxDebris = 1200
    static let debrisGravity: Float = 1400   // pt/s^2: packed snow accelerates instead of floating
    static let debrisTerminal: Float = 1700  // pt/s
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
    public internal(set) var heights: [Float]
    public internal(set) var visible: [Bool]
    var base: [Float]            // baseline offset per bin (<= 0): drops along rounded corners
    var cap: [Float]             // per-bin height ceiling imposed by windows in front (inf = none)
    let inset: Float
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

    /// Baseline follows the corner arcs within `radius` of each end.
    mutating func round(radius: Float, c0: Int, minX: Float, maxX: Float) {
        guard radius > 0 else { return }
        for b in base.indices {
            let x = (Float(c0 + b) + 0.5) * Tuning.binWidth
            let d = max(min(x - minX, maxX - x), 0)
            if d < radius { let k = radius - d; base[b] = -(radius - (radius * radius - k * k).squareRoot()) }
        }
    }

    func limit(_ bin: Int) -> Float {
        var l = Tuning.maxPileHeight
        if inset > 0 {
            let x = (Float(c0 + bin) + 0.5) * Tuning.binWidth
            l *= min(1, max(min(x - x0, x1 - x), 0) / inset)
        }
        return min(l, cap[bin])
    }

    /// Adds snow around `bin` (spread 1/4-1/2-1/4 so no single-bin spikes), then relaxes locally.
    /// Returns whether anything changed.
    @discardableResult
    mutating func deposit(bin: Int, volume: Float) -> Bool {
        guard bin >= 0, bin < heights.count, visible[bin] else { return false }
        var changed = false
        for o in -1...1 {
            var i = bin + o
            if i < 0 || i >= heights.count || !visible[i] { i = bin }
            let before = heights[i]
            heights[i] = max(before, min(before + volume * (o == 0 ? 0.5 : 0.25), limit(i)))
            if heights[i] != before { changed = true }
        }
        let lo = max(0, bin - 8), hi = min(heights.count - 1, bin + 8)
        for _ in 0..<6 {
            for i in lo...hi {
                if shed(i, i - 1) { changed = true }
                if shed(i, i + 1) { changed = true }
            }
        }
        for i in lo...hi { heights[i] = min(heights[i], max(limit(i), 0)) }
        return changed
    }

    /// Moves half the excess slope (on baseline + height) from bin i to lower neighbour j.
    /// Hidden j drains silently; past the ends the snow spills off as debris.
    private mutating func shed(_ i: Int, _ j: Int) -> Bool {
        let inRange = j >= 0 && j < heights.count
        // The window continues past the screen edge: that end is not a drop-off.
        if !inRange, j < 0 ? x0 < Float(c0 - 1) * Tuning.binWidth : x1 > Float(c0 + heights.count + 1) * Tuning.binWidth { return false }
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
    var vx: Float
    public var fall: Float
    var phase: Float
    var amp: Float
    var freq: Float
    var size: Float
    var alpha: Float
    public var kind: FlakeKind
}

/// GPU instance, 16 bytes; layout mirrors the Metal struct.
public struct Instance {
    var pos: SIMD2<Float>
    var size: Float
    var alpha: Float
}

struct Surface {
    let id: Int          // window number, 0 = ground (dock top / screen bottom)
    let frame: CGRect    // unclipped, local coords
    let edgeY: Float
    let c0: Int          // first global column
    var pile: Pile
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
    let groundY: Float
    let visibleTop: Float
    public private(set) var flakes: [Flake] = []
    public private(set) var debris: [Flake] = []
    private(set) var surfaces: [Surface] = []
    private var offsets: [Int32]       // CSR: per column range into entries
    private var entries: [Entry] = []
    private var lastWindows: [WindowInfo] = []
    private let numCols: Int
    private let invBin = 1 / Tuning.binWidth
    private let skyCount: Int      // sky pool size; the rest of `flakes` is background
    private var skyLimit = 0        // active counts for the current intensity
    private var bgLimit = 0
    private var skyEnd = 0          // slots [0, skyEnd) of the sky pool / [skyCount, skyCount+bgEnd) of the background pool
    private var bgEnd = 0           // may be live or spawning; everything beyond is dormant, so step/write skip it
    private var intensity = Intensity.media
    private var lowPower = false
    private var time: Float = 0
    private var windGain: Float = 8
    private var wind: Float = 0
    public var pilesDirty = false
    private var pollDt: Float = 0.1        // seconds between the last two window polls
    private var lastPoll: CFAbsoluteTime = 0
    private var rng: SplitMix64
    private var silentUntil: CFAbsoluteTime = 0   // no knock-off debris until then (Space switches)

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
                         size: s, alpha: Float.random(in: 0.25...0.55, using: &rng), kind: .background)
        default:
            let s = Float.random(in: 2.5...7, using: &rng)
            return Flake(pos: [x, y], vx: Tuning.wind * Float.random(in: 0.7...1.3, using: &rng), fall: 40 + s * 8 + Float.random(in: 0...10, using: &rng),
                         phase: phase, amp: Float.random(in: 8...25, using: &rng), freq: Float.random(in: 0.8...2, using: &rng),
                         size: s, alpha: Float.random(in: 0.7...1, using: &rng), kind: .sky)
        }
    }

    private func isActive(_ i: Int) -> Bool { i < skyCount ? i < skyLimit : i - skyCount < bgLimit }

    /// Extra flakes retire when they next respawn; missing ones fade in from above (see `step`).
    public func setIntensity(_ v: Intensity, immediate: Bool = false) {
        intensity = v
        let m = v.multiplier / Intensity.nevasca.multiplier
        skyLimit = Int(Float(skyCount) * m * (lowPower ? 0.5 : 1))
        bgLimit = Int(Float(flakes.count - skyCount) * m)
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

    /// Smooth gusts: slow sines with unrelated periods; sign flips over several seconds.
    private func windShape() -> Float {
        0.55 * sin(time * 2 * .pi / 37) + 0.3 * sin(time * 2 * .pi / 17 + 1.3) + 0.25 * sin(time * 2 * .pi / 9 + 2.1)
    }

    /// Space switch: windows vanish all at once. Drop piles without debris (and mute knock-offs briefly).
    public func dropPiles() {
        silentUntil = CFAbsoluteTimeGetCurrent() + 1.5
        for i in surfaces.indices {
            for b in surfaces[i].pile.heights.indices { surfaces[i].pile.heights[b] = 0 }
        }
        pilesDirty = true
    }

    public func clear() {
        for i in surfaces.indices {
            for b in surfaces[i].pile.heights.indices { surfaces[i].pile.heights[b] = 0 }
        }
        debris.removeAll(keepingCapacity: true)
        pilesDirty = true
    }

    // MARK: Surface map

    private func column(_ x: Float) -> Int { min(max(Int(x * invBin), 0), numCols - 1) }

    public func edgeVisible(id: Int, x: Float) -> Bool {
        let c = column(x)
        for k in Int(offsets[c])..<Int(offsets[c + 1]) where surfaces[Int(entries[k].surface)].id == id { return true }
        return false
    }

    /// Direct deposit (used by the self-test).
    func deposit(surface: Int, bin: Int, volume: Float) {
        if surfaces[surface].pile.deposit(bin: bin, volume: volume) { pilesDirty = true }
        let p = surfaces[surface].pile
        if p.spillL > 2 || p.spillR > 2 { spill(surface) }
    }

    /// Snow that slid off a surface end falls as debris.
    private func spill(_ si: Int) {
        let s = surfaces[si], last = s.pile.heights.count - 1
        if s.pile.spillL > 2 { addDebris(x: Float(s.c0) * Tuning.binWidth, y: s.edgeY + s.pile.base[0], vx: -Float.random(in: 8...25, using: &rng), fall: Float.random(in: 10...30, using: &rng)) }
        if s.pile.spillR > 2 { addDebris(x: Float(s.c0 + last + 1) * Tuning.binWidth, y: s.edgeY + s.pile.base[last], vx: Float.random(in: 8...25, using: &rng), fall: Float.random(in: 10...30, using: &rng)) }
        if s.pile.spillL > 2 { surfaces[si].pile.spillL = 0 }
        if s.pile.spillR > 2 { surfaces[si].pile.spillR = 0 }
    }

    /// `fall` is the current downward speed; `step` accelerates it. Heavy snow: bigger and brighter than sky flakes.
    @discardableResult
    private func addDebris(x: Float, y: Float, vx: Float, fall: Float, size: Float? = nil) -> Bool {
        guard debris.count < Tuning.maxDebris else { return false }
        debris.append(Flake(pos: [x, y], vx: vx, fall: max(fall, 0), phase: 0, amp: 0, freq: 0, size: size ?? Float.random(in: 3...5, using: &rng), alpha: 0.95, kind: .debris))
        return true
    }

    public func pile(id: Int) -> Pile? { surfaces.first { $0.id == id }?.pile }

    /// Rebuilds surfaces from the front-to-back window list. Returns debris spawned by knocked-off piles.
    @discardableResult
    public func update(windows: [WindowInfo]) -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        pollDt = Float(min(max(now - lastPoll, 0.05), 0.5))
        lastPoll = now
        guard windows != lastWindows else { return 0 }
        lastWindows = windows
        return updateSurfaces(windows: windows)
    }

    @discardableResult
    private func updateSurfaces(windows: [WindowInfo]) -> Int {
        let ox = origin.x, oy = origin.y
        var rects: [CGRect] = []
        rects.reserveCapacity(windows.count)
        for w in windows { rects.append(w.frame.offsetBy(dx: -ox, dy: -oy)) }

        var old = surfaces
        var built: [Surface] = []
        var spawned = 0
        for (i, r) in rects.enumerated() {
            let id = windows[i].number, edge = Float(r.maxY)
            // Dock bar (id 0) sits below the visible frame's bottom; hidden/offscreen Dock has minY < 0.
            let lowOk = id == 0 ? r.minY >= -1 : edge > groundY
            guard lowOk, edge < visibleTop - 1, r.maxX > 0, r.minX < CGFloat(size.x) else { continue }
            if let s = buildSurface(id: id, frame: r, edgeY: edge, radius: windows[i].radius, rects: rects, front: i, old: &old, spawned: &spawned) { built.append(s) }
        }
        for s in old { spawned += knockOff(s) }   // gone surfaces
        surfaces = built
        buildColumns()
        pilesDirty = true
        return spawned
    }

    private func buildSurface(id: Int, frame: CGRect, edgeY: Float, radius: CGFloat, rects: [CGRect], front: Int,
                              old: inout [Surface], spawned: inout Int) -> Surface? {
        let bw = Tuning.binWidth
        let c0 = max(0, Int(((Float(frame.minX) - bw / 2) / bw).rounded(.up)))
        let c1 = min(numCols, Int(((Float(frame.maxX) - bw / 2) / bw).rounded(.down)) + 1)
        guard c1 > c0 else { return nil }
        var pile = Pile(columns: c1 - c0, inset: Tuning.cornerInset, c0: c0, x0: Float(frame.minX), x1: Float(frame.maxX))
        pile.round(radius: Float(min(radius, frame.width / 2, frame.height / 2)), c0: c0, minX: Float(frame.minX), maxX: Float(frame.maxX))
        let y = CGFloat(edgeY) + 1
        for b in 0..<(c1 - c0) {
            let x = CGFloat((Float(c0 + b) + 0.5) * bw)
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
        if let k = old.firstIndex(where: { $0.id == id }) {
            let prev = old.swapRemove(k)
            if id == 0 {   // Dock bar resizes when apps come and go: keep snow by global column
                for b in pile.heights.indices where pile.visible[b] {
                    let k = c0 + b - prev.c0
                    if k >= 0, k < prev.pile.heights.count { pile.heights[b] = min(prev.pile.heights[k], pile.limit(b)) }
                }
            } else if abs(prev.frame.minX - frame.minX) < 0.5, abs(prev.frame.minY - frame.minY) < 0.5,
               abs(prev.frame.width - frame.width) < 0.5, abs(prev.frame.height - frame.height) < 0.5, prev.pile.heights.count == pile.heights.count {
                var kept = prev.pile
                kept.visible = pile.visible
                kept.cap = pile.cap
                for b in kept.heights.indices { kept.heights[b] = pile.visible[b] ? min(kept.heights[b], kept.cap[b]) : 0 }
                pile = kept
            } else {
                let v = SIMD2(Float(frame.minX - prev.frame.minX), Float(frame.minY - prev.frame.minY)) / pollDt
                spawned += knockOff(prev, velocity: v.clamped(lowerBound: SIMD2(repeating: -800), upperBound: SIMD2(repeating: 800)))
            }
        }
        return Surface(id: id, frame: frame, edgeY: edgeY, c0: c0, pile: pile)
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

    /// Turns a pile into falling debris (~1 flake per 3pt of height per bin), inheriting some of the surface's motion.
    private func knockOff(_ s: Surface, velocity v: SIMD2<Float> = .zero) -> Int {
        guard CFAbsoluteTimeGetCurrent() >= silentUntil else { return 0 }
        var n = 0
        for (b, h) in s.pile.heights.enumerated() where h > 0.5 {
            for _ in 0..<max(1, Int(h / 3)) {
                guard debris.count < Tuning.maxDebris else { return n }
                let x = (Float(s.c0 + b) + Float.random(in: 0...1, using: &rng)) * Tuning.binWidth
                let y = s.edgeY + s.pile.base[b] + Float.random(in: 0...h, using: &rng)
                let vx = Float.random(in: -12...12, using: &rng) + v.x * 0.5, fall = Float.random(in: 10...50, using: &rng) - v.y * 0.5
                if addDebris(x: x, y: y, vx: vx, fall: fall, size: Float.random(in: 3...5, using: &rng) + min(h, 18) / 9) { n += 1 }
                // Taller piles break off in clumps: a few dots close together with nearly the same velocity.
                if Float.random(in: 0..<1, using: &rng) < min(0.6, h / 25) {
                    for _ in 0..<Int.random(in: 2...(2 + Int(h / 6)), using: &rng) {
                        if addDebris(x: x + Float.random(in: -3...3, using: &rng), y: y + Float.random(in: -3...3, using: &rng),
                                     vx: vx + Float.random(in: -4...4, using: &rng), fall: fall + Float.random(in: -15...15, using: &rng), size: Float.random(in: 2.5...4.5, using: &rng)) { n += 1 }
                    }
                }
            }
        }
        if n > 0 { pilesDirty = true }
        return n
    }

    // MARK: Physics

    private func tryLand(x: Float, prevY: Float, newY: Float, volume: Float) -> Bool {
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

    public func step(dt: Float) {
        let w = size.x
        time += dt
        windGain += (intensity.windGain - windGain) * min(1, dt * 0.5)
        wind = windGain * windShape()
        var liveSky = 0, liveBg = 0   // one past the last non-dormant slot of each pool
        for n in 0..<(skyEnd + bgEnd) {
            let i = n < skyEnd ? n : skyCount + n - skyEnd
            var f = flakes[i]
            if f.kind == .dormant {
                if isActive(i), Float.random(in: 0..<1, using: &rng) < dt * 0.3 { flakes[i] = spawn(i < skyCount ? .sky : .background, anywhere: false) }
                continue
            }
            let prevY = f.pos.y
            f.phase += f.freq * dt
            f.pos.x += (f.vx + wind * f.vx / Tuning.wind + f.amp * cos(f.phase)) * dt
            f.pos.y -= f.fall * dt
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
        var i = debris.count - 1
        while i >= 0 {
            var f = debris[i]
            let prevY = f.pos.y
            f.vx -= (f.vx - wind * 0.15) * 0.5 * dt
            f.fall = min(f.fall + Tuning.debrisGravity * dt, Tuning.debrisTerminal)
            f.pos.x += f.vx * dt
            f.pos.y -= f.fall * dt
            if f.pos.y < -f.size || f.pos.x < 0 || f.pos.x > w
                || tryLand(x: f.pos.x, prevY: prevY, newY: f.pos.y, volume: f.size * Tuning.depositScale) {
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
            if f.kind != .dormant { p[n] = Instance(pos: f.pos, size: f.size, alpha: f.alpha); n += 1 }
        }
        for f in debris { p[n] = Instance(pos: f.pos, size: f.size, alpha: f.alpha); n += 1 }
        return n
    }

    // MARK: Pile path

    /// One path for every pile on this screen: a closed, smooth subpath per snowy run.
    /// Top edge = midpoint quadratic curves through every 3rd bin of the lightly blurred surface.
    public func pilePath() -> CGPath {
        let path = CGMutablePath()
        let bw = CGFloat(Tuning.binWidth)
        var idx: [Int] = []
        for s in surfaces {
            let h = s.pile.heights, vis = s.pile.visible, base = s.pile.base
            let n = h.count
            let edge = CGFloat(s.edgeY)
            func x(_ i: Int) -> CGFloat { (CGFloat(s.c0 + i) + 0.5) * bw }
            func top(_ i: Int, _ b: Int, _ e: Int) -> CGPoint {
                let l = i > b ? h[i - 1] : 0, r = i < e - 1 ? h[i + 1] : 0
                return CGPoint(x: x(i), y: edge + CGFloat(base[i] + (l + 2 * h[i] + r) / 4))
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
                    idx.append(contentsOf: stride(from: lo, to: hi, by: 3))
                    idx.append(hi)
                    path.move(to: top(idx[0], b, e))
                    if idx.count > 2 {
                        for k in 1..<(idx.count - 1) {
                            let c = top(idx[k], b, e), nx = top(idx[k + 1], b, e)
                            path.addQuadCurve(to: CGPoint(x: (c.x + nx.x) / 2, y: (c.y + nx.y) / 2), control: c)
                        }
                    }
                    if idx.count > 1 { path.addLine(to: top(idx[idx.count - 1], b, e)) }
                    for k in idx.reversed() { path.addLine(to: CGPoint(x: x(k), y: edge + CGFloat(base[k]) - 1)) }
                    path.closeSubpath()
                }
                b = e
            }
        }
        return path
    }
}

private extension Array {
    mutating func swapRemove(_ i: Int) -> Element {
        swapAt(i, count - 1)
        return removeLast()
    }
}
