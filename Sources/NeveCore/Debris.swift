// AGENT HEADER - Sources/NeveCore/Debris.swift  (falling snow chunks)
// Role: `addDebris(x:y:vx:fall:size:vol:)` (false when Tuning.maxDebris 1200 is reached) and `stepDebris(dt:)`, the per-frame loop over `debris` (Flakes of kind .debris; `shape` 1 clump, 2 slab...). Snow accelerates (gravity 1400 pt/s^2, terminal
//   1700), vx relaxes toward wind, and it lands through the shared `tryLand` (Flakes.swift: deposits `size*depositScale` volume; heavy falls there call Effects.impact) or vanishes past a side edge / below the bottom. Shape-2 slabs may `splitSlab`.
// Flake fields used here: `phase` > 0 = freshly shed, cannot land yet (counts down by dt; shed paths set it, e.g. 0.5 in Avalanche); on a held slab phase < 0 = seconds since release (ramps the slide up over 0.15 s). `amp` > 0 = INTACT
//   slab (amp = seconds aloft + 1): breaks via `slabHit`/`breakSlab` on a hit, or randomly when fragile (size < 40, aloft > 0.15 s; not in calm). `delay` > 0 on an intact slab = held until the release ripple reaches it (sags, slides at 0.3x); on a plain shape-2 slab it is the aloft timer for splitSlab.
// Window bodies are walls: `blockByWindows` (after the move) keeps a piece from entering the outline of a window in FRONT of its origin (`SnowField.occluders` index < `Flake.oz`, `Occluder.hides`) sideways: x back, vx 0, it slides down the wall.
//   Origin z: `Flake.oz` is stamped by `addDebris(oz:)` / `put` from `spawnZ` (`withSpawnZ(originZ(si:)) { ... }` at the spawn sites: overflow, spill, eave, avalanche, impact crumbs, figure bursts, shed runs; chunks and powder of a broken slab inherit it). Default .max = ground / Dock / sweep / loose = blocked by all.
// Removal is swap-with-last, iterating backwards (order not preserved). Hot when shedding / avalanches run: a weighted count over Tuning.busyDebris (24: plain dots and small slabs 1, crumbs (shape 1) 1/2, dots carrying volume (overflow lumps, sweep powder, end sheds) 0) or an intact slab >= Tuning.busySlab (24 pt) raises BusyReasons.debris (SnowField.busyReasons).

import CoreGraphics
import Foundation

extension SnowField {
    /// `fall` is the current downward speed; `step` accelerates it. Heavy snow: bigger and brighter than sky flakes.
    @discardableResult
    func addDebris(x: Float, y: Float, vx: Float, fall: Float, size: Float? = nil, vol: Float = 0, oz: UInt16? = nil) -> Bool {
        guard debris.count < Tuning.maxDebris else { return false }
        debris.append(Flake(pos: [x, y], vx: vx, fall: max(fall, 0), phase: 0, amp: 0, freq: 0, size: size ?? Float.random(in: 3...5, using: &rng), alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &rng), fade: 1, vol: vol, oz: oz ?? spawnZ))
        return true
    }

    /// Origin z of surface id `id` (its window's index in the front-to-back list); ground, Dock and unknown ids are `.max` (behind every window).
    func originZ(id: Int?) -> UInt16 { id.flatMap { zOf[$0] }.map { UInt16(truncatingIfNeeded: $0) } ?? .max }
    func originZ(si: Int) -> UInt16 { originZ(id: surfaces[si].id) }

    /// Runs `body` with every debris spawned inside stamped with origin z `z` (a front window's pieces then cross the windows behind it).
    @discardableResult func withSpawnZ<T>(_ z: UInt16, _ body: () -> T) -> T { let old = spawnZ; spawnZ = z; defer { spawnZ = old }; return body() }

    /// A piece that crossed INTO a window's outline sideways (its previous x was outside) stays at the wall with vx = 0 and slides down it; already inside (born there) or entering from above (tryLand) is left alone.
    /// Only occluders in FRONT of the piece's origin (index < `oz`) count: a piece leaving a front window crosses the ones behind it; ground / Dock / loose pieces (`oz` .max) are blocked by every window.
    @inline(__always) func blockByWindows(_ f: inout Flake, prevX: Float) {
        guard f.pos.x != prevX else { return }
        for (k, o) in occluders.enumerated() where k < Int(f.oz) && o.hides(x: f.pos.x, y: f.pos.y) && !o.hides(x: prevX, y: f.pos.y) { f.pos.x = prevX; f.vx = 0; return }
    }

    func stepDebris(dt: Float) {
        let w = size.x
        var i = debris.count - 1
        while i >= 0 {
            var f = debris[i]
            if f.amp > 0, f.delay > 0 { f.delay -= dt; f.rot += f.spin * dt * 0.5; f.pos.y -= 8 * dt; f.pos.x += f.vx * 0.3 * dt; debris[i] = f; i -= 1; continue }   // the release ripple has not reached this chunk yet: it starts to sag and slide
            let prevY = f.pos.y, prevX = f.pos.x
            f.fade = min(1, f.fade + dt * 2.5)
            f.phase -= dt   // swept-off snow cannot land back for a moment (see sweep)
            f.vx -= (f.vx - wind * 0.15) * 0.5 * dt
            f.fall = min(f.fall + Tuning.debrisGravity * dt, Tuning.debrisTerminal)
            // A held slab keeps the 0.3x slide of its hold and speeds up over 0.15 s after release (`phase` counts -seconds since release): no lurch.
            f.pos.x += f.vx * dt * (f.amp > 0 ? 0.3 + 0.7 * min(1, -f.phase / 0.15) : 1)
            f.pos.y -= f.fall * dt
            f.rot += f.spin * dt
            blockByWindows(&f, prevX: prevX)
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
