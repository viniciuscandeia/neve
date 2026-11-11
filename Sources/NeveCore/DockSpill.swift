// AGENT HEADER - Sources/NeveCore/DockSpill.swift  (Dock-top overflow trickles down to the ground bank)
// Role: `DockTrickle` (pending volume + wait per Dock end) and `deposit(dock:bin:volume:powder:)` (the deposit path for the Dock surface, number 0): volume the pile rejects within `trickleBins` (10 bins) of a bar end (measured via
//   a +-10 bin height sum; powder melting on bare bins excluded) becomes pending volume, capped at trickleCap 30 per end. `stepDockSpill` (in SnowField.step after stepBank): once pending >= trickleMin 3.6 and the wait is over it
//   adds one debris clump (<= 5 pt) at the bar's rounded corner, then waits 0.5-2 s (x2 in Economy); in calm the volume goes straight into the ground bank column. Uses `rng`. Reset when the Dock/ground surface is missing
//   and by Resize. Tests: DockSpillTests.

import CoreGraphics
import Foundation

/// Snow a full Dock-top pile cannot hold near a bar end (clamped away by `Pile.deposit`) trickles down the bar's side to the ground bank instead.
struct DockTrickle {
    var vol: (Float, Float) = (0, 0)      // pending volume per end (left, right), in pile height units
    var wait: (Float, Float) = (0, 0)     // seconds until the next clump may leave each end
}

extension SnowField {
    static let trickleBins = 10           // a deposit this close (bins) to a bar end feeds that end's trickle
    static let trickleMin: Float = 3.6    // smallest clump (volume)
    static let trickleCap: Float = 30     // pending volume cap (no waterfall after a burst)

    /// `deposit` on the Dock surface: volume the pile rejected near an end becomes pending trickle volume.
    func deposit(dock si: Int, bin: Int, volume: Float, powder: Bool = false) {
        let n = surfaces[si].pile.heights.count, near = bin < Self.trickleBins ? 0 : (bin >= n - Self.trickleBins ? 1 : -1)
        // Powder on a bare bin partly melts on contact (Pile.deposit speck rule): that loss is not overflow, so it never feeds the trickle.
        let melts = powder && bin >= 0 && bin < n && surfaces[si].pile.heights[bin] < Tuning.speckFloor
        guard near >= 0, !melts else { deposit(surface: si, bin: bin, volume: volume, powder: powder); return }
        func sum() -> Float { var s: Float = 0; for i in max(0, bin - 10)...min(n - 1, bin + 10) { s += surfaces[si].pile.heights[i] }; return s + surfaces[si].pile.spillL + surfaces[si].pile.spillR }
        let before = sum()
        deposit(surface: si, bin: bin, volume: volume, powder: powder)
        let lost = volume - (sum() - before)
        guard lost > 0.01, bin >= 0, bin < n, surfaces[si].pile.visible[bin] else { return }
        if near == 0 { dockTrickle.vol.0 = min(dockTrickle.vol.0 + lost, Self.trickleCap) } else { dockTrickle.vol.1 = min(dockTrickle.vol.1 + lost, Self.trickleCap) }
    }

    /// Releases pending Dock-end volume: a small clump every 0.5-2 s per end (slower in Economy), falling beside the bar's rounded side onto the bank;
    /// under Reduce Motion the volume goes straight into the bank column.
    func stepDockSpill(dt: Float) {
        guard let si = index[0], let gi = index[Tuning.groundID] else { dockTrickle = DockTrickle(); return }
        for side in 0..<2 {   // (no per-frame array literal)
            let left = side == 0
            let v = left ? dockTrickle.vol.0 : dockTrickle.vol.1
            var w = (left ? dockTrickle.wait.0 : dockTrickle.wait.1) - dt
            defer { if left { dockTrickle.wait.0 = w } else { dockTrickle.wait.1 = w } }
            guard v >= Self.trickleMin, w <= 0 else { continue }
            let s = surfaces[si], r = s.radius, sign: Float = left ? -1 : 1
            let x = left ? s.pile.x0 : s.pile.x1
            let size = min(v / Tuning.depositScale, 5)
            let used = size * Tuning.depositScale
            if left { dockTrickle.vol.0 -= used } else { dockTrickle.vol.1 -= used }
            w = Float.random(in: 0.5...2, using: &rng) * (economy ? 2 : 1)
            if calm {
                deposit(surface: gi, bin: column(x + sign * 2), volume: used)
            } else if addDebris(x: x - sign * (r * 0.29 - 1), y: s.edgeY - r * 0.3, vx: sign * 6, fall: 15, size: size) {
                // starts on the corner arc (0.3 r below the top) and slides off it as gravity bends the path outward
            } else { if left { dockTrickle.vol.0 += used } else { dockTrickle.vol.1 += used } }
        }
    }
}
