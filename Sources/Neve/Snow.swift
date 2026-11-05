import CoreGraphics
import Foundation

/// Tuning knobs.
enum Tuning {
    static let flakes = 400                 // per 1440x900 screen (scaled by area)
    static let backgroundFraction: Float = 0.35
    static let maxPileHeight: Float = 18
    static let binWidth: Float = 2
    static let slope: Float = 0.7           // max height step between neighbouring bins (~19 degree repose)
    static let cornerInset: Float = 6       // piles taper to 0 this far from surface ends
    static let windowRadius: CGFloat = 20   // macOS 26 window corner radius
    static let depositScale: Float = 1.2    // pile volume per flake size
    static let wind: Float = 6
    static let maxDebris = 1200
}

/// Snow amount; `multiplier` scales the base flake count. Nevasca adds strong gusty wind.
enum Intensity: Int, CaseIterable {
    case leve, media, forte, nevasca
    static let key = "intensity"
    static var saved: Intensity { Intensity(rawValue: UserDefaults.standard.object(forKey: key) as? Int ?? 1) ?? .media }
    var title: String { ["Leve", "Média", "Forte", "Nevasca"][rawValue] }
    var multiplier: Float { [0.4, 1.0, 1.8, 3.0][rawValue] }
    var windGain: Float { self == .nevasca ? 100 : 8 }   // peak sideways speed, points/s
}

// MARK: - Window list

struct WindowInfo: Equatable {
    let number: Int     // 0 = Dock bar
    let frame: CGRect   // global AppKit coordinates (y up)
    var radius: CGFloat = Tuning.windowRadius
}

/// CG (origin top-left of primary screen, y down) -> AppKit (y up).
func appKitFrame(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
}

/// On-screen normal windows, front to back. Bounds need no Screen Recording permission.
func readWindows(primaryHeight: CGFloat) -> [WindowInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return [] }
    let me = getpid()
    // Read CF values directly: bridging every dictionary to Swift costs more than the call itself.
    func int(_ d: CFDictionary, _ k: CFString) -> Int? {
        guard let v = CFDictionaryGetValue(d, Unmanaged.passUnretained(k).toOpaque()) else { return nil }
        var n = 0
        return CFNumberGetValue(unsafeBitCast(v, to: CFNumber.self), .longType, &n) ? n : nil
    }
    var out: [WindowInfo] = []
    for i in 0..<CFArrayGetCount(list) {
        let w = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: CFDictionary.self)
        guard int(w, kCGWindowLayer) == 0,
              int(w, kCGWindowOwnerPID) != Int(me),
              let number = int(w, kCGWindowNumber),
              let b = CFDictionaryGetValue(w, Unmanaged.passUnretained(kCGWindowBounds).toOpaque()),
              let r = CGRect(dictionaryRepresentation: unsafeBitCast(b, to: CFDictionary.self)),
              r.width >= 40, r.height >= 20 else { continue }
        if let a = CFDictionaryGetValue(w, Unmanaged.passUnretained(kCGWindowAlpha).toOpaque()) {
            var alpha = 1.0
            if CFNumberGetValue(unsafeBitCast(a, to: CFNumber.self), .doubleType, &alpha), alpha <= 0 { continue }
        }
        out.append(WindowInfo(number: number, frame: appKitFrame(fromCG: r, primaryHeight: primaryHeight)))
    }
    return out
}

// MARK: - Pile

/// Snow height per bin along one surface.
struct Pile {
    var heights: [Float]
    var visible: [Bool]
    var base: [Float]            // baseline offset per bin (<= 0): drops along rounded corners
    let inset: Float
    var spillL: Float = 0        // snow slid off each end, turned into debris by SnowField
    var spillR: Float = 0

    init(columns: Int, inset: Float) {
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
        guard inset > 0 else { return Tuning.maxPileHeight }
        let d = (Float(min(bin, heights.count - 1 - bin)) + 0.5) * Tuning.binWidth
        return Tuning.maxPileHeight * min(1, d / inset)
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

enum FlakeKind: UInt8 { case sky, background, debris, dormant }

/// Plain-old-data flake (no references).
struct Flake {
    var pos: SIMD2<Float>
    var vx: Float
    var fall: Float
    var phase: Float
    var amp: Float
    var freq: Float
    var size: Float
    var alpha: Float
    var kind: FlakeKind
}

/// GPU instance, 16 bytes; layout mirrors the Metal struct.
struct Instance {
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

/// Per-screen simulation: flakes, surface map, piles. Local coords are points, y up.
final class SnowField {
    let size: SIMD2<Float>
    let origin: CGPoint
    let groundY: Float
    let visibleTop: Float
    private(set) var flakes: [Flake] = []
    private(set) var debris: [Flake] = []
    private(set) var surfaces: [Surface] = []
    private var offsets: [Int32]       // CSR: per column range into entries
    private var entries: [Entry] = []
    private var lastWindows: [WindowInfo] = []
    private let numCols: Int
    private let invBin = 1 / Tuning.binWidth
    private let skyCount: Int      // sky pool size; the rest of `flakes` is background
    private var skyLimit = 0        // active counts for the current intensity
    private var bgLimit = 0
    private var intensity = Intensity.media
    private var lowPower = false
    private var time: Float = 0
    private var windGain: Float = 8
    private var wind: Float = 0
    var pilesDirty = false
    private var pollDt: Float = 0.1        // seconds between the last two window polls
    private var lastPoll: CFAbsoluteTime = 0
    private var silentUntil: CFAbsoluteTime = 0   // no knock-off debris until then (Space switches)

    var capacity: Int { flakes.count + Tuning.maxDebris }

    init(size: CGSize, origin: CGPoint, groundY: CGFloat, visibleTop: CGFloat, flakeCount: Int) {
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
        setIntensity(.media, immediate: true)
        updateSurfaces(windows: [])
    }

    private func spawn(_ kind: FlakeKind, anywhere: Bool) -> Flake {
        let x = Float.random(in: 0...size.x)
        let y = anywhere ? Float.random(in: 0...size.y) : size.y + Float.random(in: 0...40)
        let phase = Float.random(in: 0...(2 * .pi))
        switch kind {
        case .background:
            let s = Float.random(in: 1.5...3.5)
            return Flake(pos: [x, y], vx: Tuning.wind * Float.random(in: 0.7...1.3), fall: Float.random(in: 25...50),
                         phase: phase, amp: Float.random(in: 5...15), freq: Float.random(in: 0.8...2),
                         size: s, alpha: Float.random(in: 0.25...0.55), kind: .background)
        default:
            let s = Float.random(in: 2.5...7)
            return Flake(pos: [x, y], vx: Tuning.wind * Float.random(in: 0.7...1.3), fall: 40 + s * 8 + Float.random(in: 0...10),
                         phase: phase, amp: Float.random(in: 8...25), freq: Float.random(in: 0.8...2),
                         size: s, alpha: Float.random(in: 0.7...1), kind: .sky)
        }
    }

    private func isActive(_ i: Int) -> Bool { i < skyCount ? i < skyLimit : i - skyCount < bgLimit }

    /// Extra flakes retire when they next respawn; missing ones fade in from above (see `step`).
    func setIntensity(_ v: Intensity, immediate: Bool = false) {
        intensity = v
        let m = v.multiplier / Intensity.nevasca.multiplier
        skyLimit = Int(Float(skyCount) * m * (lowPower ? 0.5 : 1))
        bgLimit = Int(Float(flakes.count - skyCount) * m)
        if immediate {
            for i in flakes.indices where !isActive(i) { flakes[i].kind = .dormant }
        }
    }

    /// Low Power Mode: halve the colliding sky flakes.
    func setLowPower(_ on: Bool) {
        lowPower = on
        setIntensity(intensity)
    }

    /// Smooth gusts: slow sines with unrelated periods; sign flips over several seconds.
    private func windShape() -> Float {
        0.55 * sin(time * 2 * .pi / 37) + 0.3 * sin(time * 2 * .pi / 17 + 1.3) + 0.25 * sin(time * 2 * .pi / 9 + 2.1)
    }

    /// Space switch: windows vanish all at once. Drop piles without debris (and mute knock-offs briefly).
    func dropPiles() {
        silentUntil = CFAbsoluteTimeGetCurrent() + 1.5
        for i in surfaces.indices {
            for b in surfaces[i].pile.heights.indices { surfaces[i].pile.heights[b] = 0 }
        }
        pilesDirty = true
    }

    func clear() {
        for i in surfaces.indices {
            for b in surfaces[i].pile.heights.indices { surfaces[i].pile.heights[b] = 0 }
        }
        debris.removeAll(keepingCapacity: true)
        pilesDirty = true
    }

    // MARK: Surface map

    private func column(_ x: Float) -> Int { min(max(Int(x * invBin), 0), numCols - 1) }

    func edgeVisible(id: Int, x: Float) -> Bool {
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
        if s.pile.spillL > 2 { addDebris(x: Float(s.c0) * Tuning.binWidth, y: s.edgeY + s.pile.base[0], vx: -Float.random(in: 8...25), fall: Float.random(in: 40...70)) }
        if s.pile.spillR > 2 { addDebris(x: Float(s.c0 + last + 1) * Tuning.binWidth, y: s.edgeY + s.pile.base[last], vx: Float.random(in: 8...25), fall: Float.random(in: 40...70)) }
        if s.pile.spillL > 2 { surfaces[si].pile.spillL = 0 }
        if s.pile.spillR > 2 { surfaces[si].pile.spillR = 0 }
    }

    private func addDebris(x: Float, y: Float, vx: Float, fall: Float) {
        guard debris.count < Tuning.maxDebris else { return }
        debris.append(Flake(pos: [x, y], vx: vx, fall: max(fall, 5), phase: 0, amp: 0, freq: 0, size: Float.random(in: 2...3.5), alpha: 0.9, kind: .debris))
    }

    func pile(id: Int) -> Pile? { surfaces.first { $0.id == id }?.pile }

    /// Rebuilds surfaces from the front-to-back window list. Returns debris spawned by knocked-off piles.
    @discardableResult
    func update(windows: [WindowInfo]) -> Int {
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
        var pile = Pile(columns: c1 - c0, inset: Tuning.cornerInset)
        pile.round(radius: Float(min(radius, frame.width / 2, frame.height / 2)), c0: c0, minX: Float(frame.minX), maxX: Float(frame.maxX))
        let y = CGFloat(edgeY) + 1
        for b in 0..<(c1 - c0) {
            let x = CGFloat((Float(c0 + b) + 0.5) * bw)
            var hidden = false
            for j in 0..<front where rects[j].contains(CGPoint(x: x, y: y)) { hidden = true; break }
            pile.visible[b] = !hidden
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
                for b in kept.heights.indices where !pile.visible[b] { kept.heights[b] = 0 }
                kept.visible = pile.visible
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
                let x = (Float(s.c0 + b) + Float.random(in: 0...1)) * Tuning.binWidth
                addDebris(x: x, y: s.edgeY + s.pile.base[b] + Float.random(in: 0...h),
                          vx: Float.random(in: -35...35) + v.x * 0.5, fall: Float.random(in: 40...90) - v.y * 0.5)
                n += 1
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

    func step(dt: Float) {
        let w = size.x
        time += dt
        windGain += (intensity.windGain - windGain) * min(1, dt * 0.5)
        wind = windGain * windShape()
        for i in 0..<flakes.count {
            var f = flakes[i]
            if f.kind == .dormant {
                if isActive(i), Float.random(in: 0..<1) < dt * 0.3 { flakes[i] = spawn(i < skyCount ? .sky : .background, anywhere: false) }
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
        }
        var i = debris.count - 1
        while i >= 0 {
            var f = debris[i]
            let prevY = f.pos.y
            f.vx -= (f.vx - wind * 0.6) * 1.5 * dt
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
    func writeInstances(to p: UnsafeMutablePointer<Instance>) -> Int {
        var n = 0
        for f in flakes where f.kind != .dormant { p[n] = Instance(pos: f.pos, size: f.size, alpha: f.alpha); n += 1 }
        for f in debris { p[n] = Instance(pos: f.pos, size: f.size, alpha: f.alpha); n += 1 }
        return n
    }

    // MARK: Pile path

    /// One path for every pile on this screen: a closed, smooth subpath per snowy run.
    /// Top edge = midpoint quadratic curves through every 3rd bin of the lightly blurred surface.
    func pilePath() -> CGPath {
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
