import CoreGraphics
import Foundation

/// Tuning knobs.
enum Tuning {
    static let flakes = 400                 // per 1440x900 screen (scaled by area)
    static let backgroundFraction: Float = 0.35
    static let maxPileHeight: Float = 18
    static let binWidth: Float = 2
    static let slope: Float = 1.5           // max height step between neighbouring bins
    static let cornerInset: Float = 12      // piles taper to 0 this far from window ends
    static let depositScale: Float = 1.5    // pile volume per flake size
    static let wind: Float = 6
    static let maxDebris = 600
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
    let number: Int
    let frame: CGRect   // global AppKit coordinates (y up)
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
    let inset: Float

    init(columns: Int, inset: Float) {
        heights = [Float](repeating: 0, count: columns)
        visible = [Bool](repeating: true, count: columns)
        self.inset = inset
    }

    func limit(_ bin: Int) -> Float {
        guard inset > 0 else { return Tuning.maxPileHeight }
        let d = (Float(min(bin, heights.count - 1 - bin)) + 0.5) * Tuning.binWidth
        return Tuning.maxPileHeight * min(1, d / inset)
    }

    /// Adds snow at `bin`, then relaxes locally. Returns whether anything changed.
    @discardableResult
    mutating func deposit(bin: Int, volume: Float) -> Bool {
        guard bin >= 0, bin < heights.count, visible[bin] else { return false }
        let before = heights[bin]
        heights[bin] = max(before, min(before + volume, limit(bin)))
        var changed = heights[bin] != before
        let lo = max(0, bin - 3), hi = min(heights.count - 1, bin + 3)
        for _ in 0..<4 {
            for i in lo...hi {
                if shed(i, i - 1) { changed = true }
                if shed(i, i + 1) { changed = true }
            }
        }
        for i in lo...hi { heights[i] = min(heights[i], max(limit(i), 0)) }
        return changed
    }

    /// Moves half the excess slope from bin i to j. Hidden / out-of-range j drains the snow.
    private mutating func shed(_ i: Int, _ j: Int) -> Bool {
        let ok = j >= 0 && j < heights.count && visible[j]
        let excess = heights[i] - (ok ? heights[j] : 0) - Tuning.slope
        guard excess > 0 else { return false }
        heights[i] -= excess * 0.5
        if ok { heights[j] += excess * 0.5 }
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
    }

    func pile(id: Int) -> Pile? { surfaces.first { $0.id == id }?.pile }

    /// Rebuilds surfaces from the front-to-back window list. Returns debris spawned by knocked-off piles.
    @discardableResult
    func update(windows: [WindowInfo]) -> Int {
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
            let edge = Float(r.maxY)
            guard edge > groundY, edge < visibleTop - 1, r.maxX > 0, r.minX < CGFloat(size.x) else { continue }
            if let s = buildSurface(id: windows[i].number, frame: r, edgeY: edge, inset: Tuning.cornerInset, rects: rects, front: i, old: &old, spawned: &spawned) { built.append(s) }
        }
        let ground = CGRect(x: 0, y: 0, width: CGFloat(size.x), height: CGFloat(max(groundY, 1)))
        if let s = buildSurface(id: 0, frame: ground, edgeY: groundY, inset: 0, rects: rects, front: rects.count, old: &old, spawned: &spawned) { built.append(s) }
        for s in old { spawned += knockOff(s) }   // gone surfaces
        surfaces = built
        buildColumns()
        pilesDirty = true
        return spawned
    }

    private func buildSurface(id: Int, frame: CGRect, edgeY: Float, inset: Float, rects: [CGRect], front: Int,
                              old: inout [Surface], spawned: inout Int) -> Surface? {
        let bw = Tuning.binWidth
        let c0 = max(0, Int(((Float(frame.minX) - bw / 2) / bw).rounded(.up)))
        let c1 = min(numCols, Int(((Float(frame.maxX) - bw / 2) / bw).rounded(.down)) + 1)
        guard c1 > c0 else { return nil }
        var pile = Pile(columns: c1 - c0, inset: inset)
        let y = CGFloat(edgeY) + 1
        for b in 0..<(c1 - c0) {
            let x = CGFloat((Float(c0 + b) + 0.5) * bw)
            var hidden = false
            for j in 0..<front where rects[j].contains(CGPoint(x: x, y: y)) { hidden = true; break }
            pile.visible[b] = !hidden
        }
        if let k = old.firstIndex(where: { $0.id == id }) {
            let prev = old.swapRemove(k)
            if abs(prev.frame.minX - frame.minX) < 0.5, abs(prev.frame.minY - frame.minY) < 0.5,
               abs(prev.frame.width - frame.width) < 0.5, abs(prev.frame.height - frame.height) < 0.5, prev.pile.heights.count == pile.heights.count {
                var kept = prev.pile
                for b in kept.heights.indices where !pile.visible[b] { kept.heights[b] = 0 }
                kept.visible = pile.visible
                pile = kept
            } else {
                spawned += knockOff(prev)
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
                entries[Int(fill[c])] = Entry(surface: Int32(si), edgeY: s.edgeY)
                fill[c] += 1
            }
        }
    }

    /// Turns a pile into falling debris. Returns how many flakes were spawned.
    private func knockOff(_ s: Surface) -> Int {
        var n = 0
        for (b, h) in s.pile.heights.enumerated() where h > 1 {
            guard debris.count < Tuning.maxDebris else { break }
            let x = (Float(s.c0 + b) + Float.random(in: 0...1)) * Tuning.binWidth
            debris.append(Flake(pos: [x, s.edgeY + h], vx: Float.random(in: -35...35), fall: Float.random(in: 50...100),
                                phase: 0, amp: 0, freq: 0, size: Float.random(in: 1.5...3), alpha: 0.9, kind: .debris))
            n += 1
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

    /// One path for every pile on this screen: a closed subpath per visible run.
    func pilePath() -> CGPath {
        let path = CGMutablePath()
        let bw = CGFloat(Tuning.binWidth)
        for s in surfaces {
            let h = s.pile.heights, vis = s.pile.visible
            let n = h.count
            var b = 0
            while b < n {
                guard vis[b] else { b += 1; continue }
                var e = b
                var top: Float = 0
                while e < n && vis[e] { top = max(top, h[e]); e += 1 }
                if top > 0.3 {
                    let base = CGFloat(s.edgeY) - 1
                    path.move(to: CGPoint(x: CGFloat(s.c0 + b) * bw, y: base))
                    for i in b..<e {
                        let l = i > b ? h[i - 1] : 0, r = i < e - 1 ? h[i + 1] : 0
                        path.addLine(to: CGPoint(x: (CGFloat(s.c0 + i) + 0.5) * bw, y: CGFloat(s.edgeY) + CGFloat((l + 2 * h[i] + r) / 4)))
                    }
                    path.addLine(to: CGPoint(x: CGFloat(s.c0 + e) * bw, y: base))
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
