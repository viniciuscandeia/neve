// AGENT HEADER - Sources/NeveCore/Tree.swift  (the one Christmas tree: warning gust, fall, landing, pick-up, window following)
// Origin z: the snow of `shakeTree` is stamped with the tree's surface z (`withSpawnZ(originZ(id:))`). `treeEnabled = false` goes through `removeTree()` (also the tree stashed with a window on another Space).
// Role: Tuning tree constants, `Tree` (foot-centre `pos`, state held / falling / resting, `surface` it stands on, `land` seconds since touchdown, `snow` = 0...1 snow counter per branch layer (SIMD4, bottom layer first), `tilt`, `out` fade),
//   `Burst` (x + seconds of the warning gust) and SnowField code. API: `dropTree(replacing:)` (menu / auto timer: starts the ~2 s burst at a random x away from the edges, false when disabled, quiet or one already exists; `replacing` first `removeTree()`s the existing one: the menu), `hasTree` (tree, burst or a tree
//   stashed with a window: the uniqueness test AppController uses across screens), `pickTree(at:)` / `dragTree(to:dt:)` / `releaseTree(throwing:)` (Option-click pick-up, mirrors Snowball held / drop), `takeTree()` / `adoptTree(_:at:)` (the drag
//   crosses to a neighbour screen's field), `treeUnder` (hitTest), `writeTreePrims` (Rig.tree, honours the drag `shift`; fade * `hide`, draw-only, see Snowball.swift `stepCovered`).
// Simulation `stepTree` (SnowField.step, after gifts): burst timer -> `startTreeFall` (from above the top edge at the burst x) -> falls like a Gift (same integrator) and lands on `treeSupport` (highest surface whose three foot columns are all `open` and
//   `landable`, so never on a covered bin) at `standY` (drawn snow) sunk `treeSink`; landing = `impact` crater + puffs + the branch snow shaken off as debris + 2-4 gifts around the foot (Gift list, may exceed Tuning.maxGifts, capped at +4).
//   Resting: follows the drawn pile each frame; the support gone (closed / minimised window, any of the three foot columns hidden or off the pile and not continued across a seam: `footHolds`) = falls again. `transportTree` (window moved: x shift; a fast move only shakes the branches, it never knocks it down).
//   Snow on the branches grows with snowfall (full in ~50 s) and falls as debris when shaken (drag, fast window, landing). quiet (outro / melt) fades it out.
// Randomness: ONLY `treeRng` (own generator) for the placement, the burst flake x and the debris / gift velocities; spawn() keeps consuming `rng` exactly as before (DeterminismTests), the burst just overrides the x afterwards.
// Lifecycle: `clear()` removes tree + burst; Stashed.tree keeps it across a Space switch (knockOff of a window that never returns makes it fall); `resetWorld` via clear; Resize scales x. Busy: BusyReasons.tree while a burst, a fall or a hold lasts.
// Size: Tuning.treeHeight 118 pt at scale 1 (x snowmanScale 1...1.5), halfFoot 30; geometry lives in Rig+Tree (treeTiers / treeWidth) so hit box, shed-snow origin and lights follow it. Coordinates: local AppKit pt, y up. Tests: TreeTests.

import CoreGraphics
import Foundation

extension Tuning {
    static let treeHeight: Float = 118         // pt at scale 1 (star tip; was 66, ~1.75x)
    static let treeHalfFoot: Float = 30        // half width of the foot that must stand on open snow
    static let treeSink: Float = 2.6           // pt the trunk sinks into the drawn pile
    static let burstDur: Float = 2             // s of the warning gust
    static let burstHalfWidth: Float = 56      // pt either side of the drawn x where the gust flakes appear
}

public struct Tree {
    public enum State: Equatable { case held, falling, resting }
    public internal(set) var pos: SIMD2<Float>             // foot centre (trunk base)
    var vel: SIMD2<Float> = .zero
    public internal(set) var state = State.falling
    public internal(set) var surface: Int?                 // nil unless resting
    public internal(set) var land: Float = 1               // seconds since touching down (squash + wobble)
    public internal(set) var snow = SIMD4<Float>(repeating: 0)   // 0...1 per branch layer, bottom first
    public internal(set) var tilt: Float = 0
    public var scale: Float = 1
    var grab: SIMD2<Float> = .zero                         // foot minus cursor while held
    var age: Float = 0
    var shedT: Float = 0                                   // cooldown between two shakes
    public internal(set) var hide: Float = 1               // drawing only: 1 -> 0 (0.2 s) while a window brought to front covers its surface (SnowField.stepCovered)
    var out: Float = 1
    public var height: Float { Tuning.treeHeight * scale }
    public var halfFoot: Float { Tuning.treeHalfFoot * scale }
    public var fade: Float { max(out, 0) }
}

struct Burst { var x: Float; var t: Float }

extension SnowField {
    public var hasTree: Bool { tree != nil || burst != nil || stash.values.contains { $0.tree != nil } }
    public var treeState: Tree? { tree }
    public var treeHeld: Bool { tree?.state == .held }

    /// Menu / auto timer: warns with a ~2 s gust at a random x (12-88 % of the width) and then the tree falls there. Reduce Motion skips the gust.
    @discardableResult
    public func dropTree(replacing: Bool = false) -> Bool {
        guard treeEnabled, !quiet, size.x > 200, replacing || !hasTree else { return false }
        if replacing { removeTree() }
        let half = Tuning.treeHalfFoot * snowmanScale
        for _ in 0..<16 {   // an x with open snow ground under the foot (a covered stretch is skipped)
            let x = Float.random(in: size.x * 0.12...size.x * 0.88, using: &treeRng)
            if treeSupport(x: x, fromY: size.y, half: half) != nil { burst = Burst(x: x, t: calm ? Tuning.burstDur : 0); return true }
        }
        return false
    }

    /// Menu "Soltar árvore" with one about: the current tree / burst / tree stashed with a window goes away (no gifts, no crater) before the new gust.
    public func removeTree() {
        tree = nil; burst = nil
        for k in stash.keys { stash[k]?.tree = nil }
    }

    func startTreeFall(x: Float) {
        var t = Tree(pos: SIMD2(x, size.y + Tuning.treeHeight * snowmanScale), vel: SIMD2(0, -80), scale: snowmanScale)
        t.snow = SIMD4(repeating: 0.3)
        tree = t
    }

    // MARK: pick-up

    /// Inside the tree's silhouette (a few points of slack).
    func treeUnder(_ q: SIMD2<Float>) -> Bool {
        guard let t = tree, t.state != .held, openAt(surface: t.surface, x: t.pos.x) else { return false }
        let dy = (q.y - t.pos.y) / t.scale, dx = abs(q.x - t.pos.x) / t.scale
        guard dy >= -4, dy <= Tuning.treeHeight + 6 else { return false }
        return dx <= Rig.treeWidth(min(max(dy, 0), Tuning.treeHeight - 8)) + 6
    }

    /// Option-click on the tree: it is held (the cursor keeps its offset to the foot).
    public func pickTree(at p: CGPoint) -> Bool {
        let q = SIMD2(Float(p.x), Float(p.y))
        guard treeUnder(q), var t = tree else { return false }
        t.state = .held; t.surface = nil; t.vel = .zero; t.grab = t.pos - q
        tree = t
        return true
    }

    /// Moves the held tree so that its foot keeps the offset it was grabbed with; the velocity is smoothed over 60 ms (the tilt and the throw follow it).
    public func dragTree(to p: CGPoint, dt: Float) {
        guard var t = tree, t.state == .held else { return }
        let q = SIMD2(Float(p.x), Float(p.y))
        var np = q + t.grab
        np.x = min(max(np.x, t.halfFoot), size.x - t.halfFoot)
        if dt > 0 { t.vel += ((np - t.pos) / dt - t.vel) * (1 - exp(-dt / 0.06)) }
        t.pos = np
        tree = t
    }

    /// Lets go: it falls to the first surface below.
    public func releaseTree(throwing: Bool = false) {
        guard var t = tree, t.state == .held else { return }
        t.state = .falling; t.vel = (throwing ? t.vel : .zero).limited(400)
        tree = t
    }

    /// Takes the tree out of this field (the drag crosses to another screen); the caller hands it to `adoptTree`.
    public func takeTree() -> Tree? { defer { tree = nil }; return tree }

    /// Receives a tree held by the cursor at `p` (local coords); keeps the grab offset, clamped into this screen.
    public func adoptTree(_ t: Tree, at p: CGPoint) {
        var t = t
        t.state = .held; t.surface = nil
        t.pos = SIMD2(min(max(Float(p.x) + t.grab.x, t.halfFoot), size.x - t.halfFoot), Float(p.y) + t.grab.y)
        tree = t
    }

    // MARK: simulation

    /// Highest surface whose columns under the whole foot (x - half, x, x + half) are open snow ground and landable, with the foot at or above its edge (within the sink, so a 20 pt step never tunnels) and the whole tree (star included) below `visibleTop`.
    func treeSupport(x: Float, fromY: Float, half: Float) -> (si: Int, y: Float)? {
        let c = column(x), height = Tuning.treeHeight * half / Tuning.treeHalfFoot
        var best: (si: Int, y: Float)?
        for k in Int(offsets[c])..<Int(offsets[c + 1]) {
            let e = entries[k], s = Int(e.surface)
            guard fromY + Tuning.treeSink * half / Tuning.treeHalfFoot >= e.edgeY, landable(s) else { continue }
            guard footHolds(si: s, x: x, half: half, open: true) else { continue }
            let y = standY(si: s, x: x)
            if y + height > visibleTop { continue }   // the star would hide under the menu bar
            if y > (best?.y ?? -.infinity) { best = (s, y) }
        }
        return best
    }

    /// Whether the three foot columns (x - half, x, x + half) all hold snow on surface `si` (`open`: landing, snow open to the sky; else `alive`: resting, a column hidden only by the stacking order still holds).
    /// A column past the pile end counts on the surface touching that end (`neighbor`, a seam), so a foot straddling two joined windows rests like on one.
    func footHolds(si: Int, x: Float, half: Float, open: Bool) -> Bool {
        let p = surfaces[si].pile
        for j in -1...1 {
            var pile = p, b = column(x + Float(j) * half) - surfaces[si].c0
            if b < 0 || b >= p.heights.count {
                guard let n = neighbor(si: si, dir: b < 0 ? -1 : 1) else { return false }
                pile = surfaces[n.si].pile; b = n.bin
            }
            if !(open ? pile.open(b) : pile.alive(b)) { return false }
        }
        return true
    }

    /// Branch snow falls as debris chunks (a share `fraction` of every layer); uses `treeRng` only.
    func shakeTree(_ t: inout Tree, fraction: Float) {
        for i in 0..<4 {
            let tier = Rig.treeTiers[Rig.treeCounterTier[i]]
            let amount = t.snow[i] * fraction
            guard amount > 0.04 else { continue }
            t.snow[i] -= amount
            guard !silent else { continue }
            for _ in 0..<(Int(amount * 3) + 1) {
                let r = tier.h * t.scale
                _ = withSpawnZ(originZ(id: t.surface)) { put(Flake(pos: SIMD2(t.pos.x + Float.random(in: -r...r, using: &treeRng) * 0.7, t.pos.y + tier.t * t.scale * Float.random(in: 0.7...1, using: &treeRng)),
                              vx: Float.random(in: -30...30, using: &treeRng) + t.vel.x * 0.2, fall: Float.random(in: 5...45, using: &treeRng) - t.vel.y * 0.1, phase: 0, amp: 0, freq: 0,
                              size: Float.random(in: 2.5...4.5, using: &treeRng), alpha: 0.95, kind: .debris, seed: Float.random(in: 0..<1, using: &treeRng), fade: 1,
                              spin: Float.random(in: -2...2, using: &treeRng), shape: 1)) }
            }
        }
    }

    private func land(_ t: inout Tree, on si: Int, y: Float) {
        t.pos.y = y - Tuning.treeSink * t.scale
        let fall = -t.vel.y
        t.state = .resting; t.surface = surfaces[si].id; t.vel = .zero; t.land = 0
        let bin = min(max(column(t.pos.x) - surfaces[si].c0, 0), surfaces[si].pile.heights.count - 1)
        impact(surface: si, bin: bin, x: t.pos.x, top: y, fall: fall, vol: 24 + 40 * (t.snow.sum() / 4))
        shakeTree(&t, fraction: 1)
        if !calm, !silent { for s: Float in [-1, 1] { addPuff(x: t.pos.x + s * t.halfFoot, y: y + 3) } }
        // 2-4 gifts hop out around the foot and fall like any gift (they may take the list past maxGifts: the sleigh waits).
        let n = Int.random(in: 2...4, using: &treeRng)
        for k in 0..<n where giftState.gifts.count < Tuning.maxGifts + 4 {
            let side: Float = k % 2 == 0 ? -1 : 1
            giftState.gifts.append(Gift(pos: SIMD2(t.pos.x + side * Float.random(in: 16...30, using: &treeRng), y + 6), vel: SIMD2(side * Float.random(in: 45...110, using: &treeRng), Float.random(in: 120...200, using: &treeRng)),
                                        surface: nil, rot: 0, spin: Float.random(in: -3...3, using: &treeRng), color: UInt8.random(in: 0...2, using: &treeRng), scale: snowmanScale))
        }
    }

    /// It fell past everything (the stretch under it is covered): it comes down again at the nearest x that has open ground, else it is gone.
    private func relocate(_ t: inout Tree) {
        for d in stride(from: Float(0), to: size.x, by: 8) {
            for s: Float in [-1, 1] {
                let x = min(max(t.pos.x + s * d, t.halfFoot), size.x - t.halfFoot)
                if treeSupport(x: x, fromY: size.y, half: t.halfFoot) != nil { t.pos = SIMD2(x, size.y + t.height); t.vel = SIMD2(0, -80); return }
            }
        }
        t.out = 0   // nowhere to stand: gone (the pointer / menu can bring another)
    }

    func stepTree(dt: Float) {
        if quiet { burst = nil }
        if burst != nil {
            burst!.t += dt
            if burst!.t >= Tuning.burstDur { startTreeFall(x: burst!.x); burst = nil }
        }
        guard var t = tree else { return }
        if quiet { t.out -= dt * fadeK / 0.4 }
        if t.out <= 0 { tree = nil; return }
        t.age += dt; t.land += dt; t.shedT -= dt
        if !quiet {   // snow settles on the branches (full in ~50 s of steady snowfall; the upper layers a little later)
            let r = dt / 50 * (0.4 + Float(skyLimit) / Float(max(skyCount, 1)))
            t.snow = pointwiseMin(t.snow + SIMD4(1, 0.9, 0.8, 0.7) * r, SIMD4(repeating: 1))
        }
        switch t.state {
        case .held:
            let target = min(max(-t.vel.x * 0.0012, -0.35), 0.35)
            t.tilt += (target - t.tilt) * min(1, dt * 8)
            if t.shedT <= 0, t.vel.x * t.vel.x + t.vel.y * t.vel.y > 240 * 240 { shakeTree(&t, fraction: 0.3); t.shedT = 0.25 }
        case .falling:
            let prev = t.pos
            t.vel.y = max(t.vel.y - Tuning.debrisGravity * 0.8 * dt, -1300)
            t.vel.x -= t.vel.x * 1.5 * dt
            t.pos += t.vel * dt
            t.pos.x = min(max(t.pos.x, t.halfFoot), size.x - t.halfFoot)
            t.tilt = 0.1 * sin(t.age * 5) * min(1, t.age)
            if let (si, y) = treeSupport(x: t.pos.x, fromY: prev.y, half: t.halfFoot), t.pos.y <= y - Tuning.treeSink * t.scale { land(&t, on: si, y: y) }
            else if t.pos.y < -t.height { relocate(&t) }
        case .resting:
            t.tilt = 0.07 * sin(t.land * 13) * exp(-t.land * 3.2)
            guard let sid = t.surface, let si = index[sid], footHolds(si: si, x: t.pos.x, half: t.halfFoot, open: false) else {
                t.state = .falling; t.surface = nil; t.vel = .zero   // the support is gone: it falls again
                tree = t; return
            }
            t.pos.y = standY(si: si, x: t.pos.x) - Tuning.treeSink * t.scale
        }
        tree = t
    }

    /// Windows moved / closed: a tree on one travels along in x; a fast move shakes the branches (it never knocks the tree down); a vanished window drops it.
    func transportTree(before: [Surface]) {
        guard var t = tree, t.state == .resting, let sid = t.surface, sid != Tuning.groundID, sid != 0 else { return }
        guard let ni = index[sid], let o = before.first(where: { $0.id == sid }) else { t.state = .falling; t.surface = nil; t.vel = .zero; tree = t; return }
        let n = surfaces[ni]
        if SnowField.shedFraction(v: n.vel, prev: o.vel) > 0.5 { shakeTree(&t, fraction: 0.6) }
        t.pos.x += Float(n.frame.minX - o.frame.minX)
        tree = t
    }

    /// The tree as prims; `shift` gives the drag offset of a surface id.
    public func writeTreePrims(_ w: inout PrimWriter, contrast: Bool = false, shift: (Int?) -> SIMD2<Float>) {
        guard let t = tree, t.hide > 0.001 else { return }
        let sq: Float = t.state == .resting && t.land < 0.1 ? 1 : 0
        Rig.tree(TreeLook(foot: t.pos + shift(t.surface), scale: t.scale, tilt: t.tilt, squash: sq, snow: t.snow, fade: t.fade * t.hide, grounded: t.state == .resting), contrast: contrast, into: &w)
    }
}
