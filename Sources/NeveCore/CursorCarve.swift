import CoreGraphics
import Foundation

extension Tuning {
    static let carveRadius: Float = 10        // pt: cursor circle that cuts the snow
    static let carveMinSpeed: Float = 20      // pt/s
    static let carveMaxStep: Float = 0.8      // pt a bin may lose per frame (a slow pass does not wipe a title bar at once)
    static let carveMinArea: Float = 0.3      // pt^2 per frame below which nothing is cut
    static let carveBerm: Float = 0.6         // share of the cut area banked beside the cursor; the rest sprays
    static let carveBermDist: Float = 14      // pt from the cursor to the berm
}

extension SnowField {
    /// A fast cursor lowers the snow it touches to the circle's lower edge, banks 60% as a berm and sprays the rest as debris.
    /// Skipped while ⌥ is held, a ball is held, or a window is dragged (those use the cursor themselves).
    func stepCursorCarve() {
        guard pointerPush, !calm, let p = pointer, !optionHeld, draggingID == nil,
              pointerVel.x * pointerVel.x + pointerVel.y * pointerVel.y > Tuning.carveMinSpeed * Tuning.carveMinSpeed,
              !balls.contains(where: { $0.state == .held }) else { return }
        let r = Tuning.carveRadius, bw = Tuning.binWidth, v = pointerVel
        var removed: Float = 0, kept: Float = 0
        for si in surfaces.indices {
            let s = surfaces[si]
            guard p.x >= Float(s.c0) * bw - r, p.x <= Float(s.c0 + s.pile.heights.count) * bw + r,
                  p.y > s.edgeY - r, p.y - r < s.edgeY + s.pile.maxHeight + Tuning.driftFar else { continue }
            let c0 = s.c0, n = s.pile.heights.count
            let lo = max(0, Int(((p.x - r) / bw).rounded(.down)) - c0), hi = min(n - 1, Int(((p.x + r) / bw).rounded(.up)) - c0)
            guard lo <= hi else { continue }
            var cut = [Float](repeating: 0, count: hi - lo + 1), area: Float = 0
            for i in lo...hi where s.pile.visible[i] {
                let dx = binCenter(c0 + i) - p.x
                guard abs(dx) < r else { continue }
                let target = max(p.y - (r * r - dx * dx).squareRoot() - s.edgeY - s.pile.base[i], 0)
                let dh = min(s.pile.heights[i] - target, Tuning.carveMaxStep)
                if dh > 0 { cut[i - lo] = dh; area += dh * bw }
            }
            guard area >= Tuning.carveMinArea else { continue }
            for k in cut.indices { surfaces[si].pile.heights[lo + k] -= cut[k] }
            removed += area
            let sides: [Float] = abs(v.x) > 0.5 * abs(v.y) ? [v.x > 0 ? 1 : -1] : [-1, 1]
            let share = Tuning.carveBerm * area / Float(sides.count)
            for sd in sides {
                let bin = column(p.x + sd * Tuning.carveBermDist) - c0
                guard bin >= 0, bin < n else { continue }
                let before = surfaces[si].pile.heights.reduce(0, +)
                surfaces[si].pile.deposit(bin: bin, volume: share / bw)
                kept += (surfaces[si].pile.heights.reduce(0, +) - before) * bw
            }
            pilesDirty = true
        }
        guard removed > 0 else { return }
        carveSpray += removed - kept   // what could not be banked sprays too
        let dir: Float = v.x >= 0 ? 1 : -1
        while carveSpray >= Tuning.penguinPuff {
            let size = Tuning.penguinPuff / (Tuning.depositScale * bw)
            guard addDebris(x: p.x, y: p.y + 4, vx: 0.3 * v.x + Float.random(in: -30...30, using: &rng) + dir * 20, fall: Float.random(in: 0...30, using: &rng), size: size) else { break }
            carveSpray -= Tuning.penguinPuff
        }
    }
}
