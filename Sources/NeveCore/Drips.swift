import CoreGraphics
import Foundation

/// Meltwater: a droplet swells at a pile end / snowman (0.3 s), detaches, falls, and splashes into 2-3 micro-droplets (or leaves the screen).
/// Only during the idle melt; none under Reduce Motion, economy or low power. Uses `fxRng`.
struct Drop {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float> = .zero
    var age: Float = 0
    var size: Float
    var src: Int              // surface id it hangs from (a drop never lands on its own source)
    var state: State = .forming
    enum State: UInt8 { case forming, falling, splash }
    static let swell: Float = 0.3, splashLife: Float = 0.3, gravity: Float = 900
}

extension SnowField {
    var dripsAllowed: Bool { melting && !meltDone && !calm && !economy && !lowPower }

    func stepDrips(dt: Float) {
        guard dripsAllowed else { drops.removeAll(keepingCapacity: true); dripT = 0; return }
        if meltT / meltDur < 0.85 {
            dripT += dt * Tuning.dripRate
            if dripT >= 1 { dripT -= 1; if drops.count < Tuning.maxDrops { startDrop() } }
        }
        var i = drops.count - 1
        while i >= 0 {
            defer { i -= 1 }
            drops[i].age += dt
            switch drops[i].state {
            case .forming:
                if drops[i].age >= Drop.swell { drops[i].state = .falling }
            case .falling:
                let prev = drops[i].pos.y
                drops[i].vel.y -= Drop.gravity * dt
                drops[i].pos += drops[i].vel * dt
                let p = drops[i].pos
                if p.y < -drops[i].size { drops.swapAt(i, drops.count - 1); drops.removeLast(); continue }
                if let top = landing(x: p.x, prevY: prev, newY: p.y, src: drops[i].src) {
                    let at = SIMD2(p.x, top)
                    drops.swapAt(i, drops.count - 1); drops.removeLast()
                    for _ in 0..<Int.random(in: 2...3, using: &fxRng) where drops.count < Tuning.maxDrops {
                        drops.append(Drop(pos: at, vel: [Float.random(in: -50...50, using: &fxRng), Float.random(in: 40...100, using: &fxRng)], size: Float.random(in: 1.5...2.5, using: &fxRng), src: -2, state: .splash))
                    }
                }
            case .splash:
                drops[i].vel.y -= Drop.gravity * dt
                drops[i].pos += drops[i].vel * dt
                if drops[i].age >= Drop.splashLife { drops.swapAt(i, drops.count - 1); drops.removeLast() }
            }
        }
    }

    /// A drop hangs from a random pile end (window / Dock bar) or a sagging snowman.
    private func startDrop() {
        let size = Float.random(in: 4...6, using: &fxRng)
        let snowmen = figures.indices.filter { figures[$0].kind == .snowman && figures[$0].phase != .collapsing }   // ponytail: tiny alloc per drop (<= 4/s), not per frame
        if !snowmen.isEmpty, Float.random(in: 0..<1, using: &fxRng) < 0.35 {
            let f = figures[snowmen[Int.random(in: 0..<snowmen.count, using: &fxRng)]]
            let side: Float = Bool.random(using: &fxRng) ? 1 : -1
            drops.append(Drop(pos: [f.foot.x + side * f.radii.y * 0.9, f.foot.y + f.radii.x * 1.3], size: size, src: f.surfaceID ?? -2))
            return
        }
        guard !surfaces.isEmpty else { return }
        let s = Int.random(in: 0..<surfaces.count, using: &fxRng), left = Bool.random(using: &fxRng)
        let n = surfaces[s].pile.heights.count
        for k in 0..<min(n, 24) {   // first bin from the chosen end with real snow
            let b = left ? k : n - 1 - k
            let h = surfaces[s].pile.heights[b]
            guard h >= 1.5, surfaces[s].pile.visible[b] else { continue }
            drops.append(Drop(pos: [binCenter(surfaces[s].c0 + b), surfaces[s].edgeY + surfaces[s].pile.base[b] + h * 0.5], size: size, src: surfaces[s].id))
            return
        }
    }

    /// Top of the first other surface's pile crossed between `prevY` and `newY` at x (like `tryLand`), nil = in the air.
    private func landing(x: Float, prevY: Float, newY: Float, src: Int) -> Float? {
        let c = column(x)
        var best: Float?
        for k in Int(offsets[c])..<Int(offsets[c + 1]) {
            let e = entries[k], s = Int(e.surface)
            guard surfaces[s].id != src else { continue }
            let top = e.edgeY + surfaces[s].pile.heights[c - surfaces[s].c0]
            if prevY >= e.edgeY, newY < top, !(top <= best ?? -Float.infinity) { best = top }
        }
        return best
    }

    func writeDrops(to p: UnsafeMutablePointer<Instance>, n: inout Int) {
        for d in drops {
            switch d.state {
            case .forming:
                let t = min(d.age / Drop.swell, 1)   // swells, hanging a little lower as it fills
                p[n] = Instance(pos: d.pos - [0, d.size * 0.3 * t], size: d.size * t, alpha: 0.7, seed: 0, rot: 0, kind: 5)
            case .falling:
                p[n] = Instance(pos: d.pos, size: d.size, alpha: 0.7, seed: 0, rot: 0, kind: 5)
            case .splash:
                p[n] = Instance(pos: d.pos, size: d.size, alpha: 0.7 * (1 - d.age / Drop.splashLife), seed: 0, rot: 0, kind: 5)
            }
            n += 1
        }
    }
}
