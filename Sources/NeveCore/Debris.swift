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
            f.pos.x += f.vx * dt
            f.pos.y -= f.fall * dt
            f.rot += f.spin * dt
            if f.amp > 0 {   // intact block: breaks only when it hits something
                let top = slabHit(f, prevY: prevY)
                f.amp += dt   // seconds aloft (+1)
                let fragile = !calm && f.amp > 1.15 && f.size < 40 && Float.random(in: 0..<1, using: &rng) < (f.size < 24 ? 1.0 : 0.2) * dt
                if let top { breakSlab(f, top: top) } else if fragile { breakSlab(f, top: f.pos.y, air: true) }
                if top != nil || fragile || f.pos.y < -f.size || f.pos.x < 0 || f.pos.x > w { debris[i] = debris[debris.count - 1]; debris.removeLast() }
                else { trailPowder(&f, dt: dt); debris[i] = f }
                i -= 1; continue
            }
            if f.pos.y < -f.size || f.pos.x < 0 || f.pos.x > w
                || (f.phase <= 0 && tryLand(x: f.pos.x, prevY: prevY, newY: f.pos.y, volume: f.size * Tuning.depositScale, fall: f.fall, vol: f.vol)) {
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
