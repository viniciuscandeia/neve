// AGENT HEADER - Sources/NeveCore/Debris.swift  (falling snow chunks)
// Role: `addDebris(x:y:vx:fall:size:)` (capped by Tuning.maxDebris 1200) and `stepDebris(dt:)`: packed snow accelerates (gravity 1400 pt/s^2, terminal 1700), lands through the shared `tryLand` (volume `vol` is deposited; heavy falls call Effects.impact),
//   or vanishes past a screen edge / below the bottom. Debris are `Flake`s of kind .debris (shape 1 clump, 2 slab, ...). A slab with `amp > 0` is an INTACT block (amp = seconds aloft + 1): it breaks only on a hit or randomly when fragile (`breakSlab`);
//   `delay > 0` = held back until the release ripple reaches it (Tuning.rippleSpeed); `phase` < 0 = freshly swept off, cannot land for a moment. Loop removes by swap-with-last (order not preserved). Hot when avalanches/shedding run;
//   Tuning.busyDebris (24) or any slab raises the frame rate (BusyReasons.debris).

import CoreGraphics
import Foundation

extension SnowField {
    /// `fall` is the current downward speed; `step` accelerates it. Heavy snow: bigger and brighter than sky flakes.
    @discardableResult
    func addDebris(x: Float, y: Float, vx: Float, fall: Float, size: Float? = nil) -> Bool {
        guard debris.count < Tuning.maxDebris else { return false }
        debris.append(Flake(pos: [x, y], vx: vx, fall: max(fall, 0), phase: 0, amp: 0, freq: 0, size: size ?? Float.random(in: 3...5, using: &rng), alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1))
        return true
    }

    func stepDebris(dt: Float) {
        let w = size.x
        var i = debris.count - 1
        while i >= 0 {
            var f = debris[i]
            if f.amp > 0, f.delay > 0 { f.delay -= dt; f.rot += f.spin * dt * 0.5; f.pos.y -= 8 * dt; f.pos.x += f.vx * 0.3 * dt; debris[i] = f; i -= 1; continue }   // the release ripple has not reached this chunk yet: it starts to sag and slide
            let prevY = f.pos.y
            f.fade = min(1, f.fade + dt * 2.5)
            f.phase -= dt   // swept-off snow cannot land back for a moment (see sweep)
            f.vx -= (f.vx - wind * 0.15) * 0.5 * dt
            f.fall = min(f.fall + Tuning.debrisGravity * dt, Tuning.debrisTerminal)
            // A held slab keeps the 0.3x slide of its hold and speeds up over 0.15 s after release (`phase` counts -seconds since release): no lurch.
            f.pos.x += f.vx * dt * (f.amp > 0 ? 0.3 + 0.7 * min(1, -f.phase / 0.15) : 1)
            f.pos.y -= f.fall * dt
            f.rot += f.spin * dt
            if f.amp > 0 {   // intact block: breaks only when it hits something
                let top = slabHit(f, prevY: prevY)
                f.amp += dt   // seconds aloft (+1)
                let fragile = !calm && f.amp > 1.15 && f.size < 40 && Float.random(in: 0..<1, using: &rng) < (f.size < 24 ? 1.0 : 0.2) * dt
                if let top { breakSlab(f, top: top) } else if fragile { breakSlab(f, top: f.pos.y, air: true) }
                if top != nil || fragile || f.pos.y < -f.size || f.pos.x < -f.size / 2 || f.pos.x > w + f.size / 2 { debris[i] = debris[debris.count - 1]; debris.removeLast() }
                else { trailPowder(&f, dt: dt); debris[i] = f }
                i -= 1; continue
            }
            let off = f.pos.x < -f.size / 2 || f.pos.x > w + f.size / 2   // gone only when it is fully past the screen edge
            if f.pos.y < -f.size || off
                || (f.phase <= 0 && f.pos.x >= 0 && f.pos.x <= w && tryLand(x: f.pos.x, prevY: prevY, newY: f.pos.y, volume: f.size * Tuning.depositScale, fall: f.fall, vol: f.vol, span: f.shape == 2 ? f.size : 0)) {
                debris[i] = debris[debris.count - 1]
                debris.removeLast()
            } else {
                debris[i] = f
                if f.shape == 2, !calm { splitSlab(i, dt: dt) }
            }
            i -= 1
        }
    }
}
