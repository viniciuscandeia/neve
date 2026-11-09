import CoreGraphics
import Testing
@testable import NeveCore

private func tallPile(calm: Bool = false) -> SnowField {
    let f = makeField(seed: 3)
    f.setCalm(calm)
    f.update(windows: [win(1, 300, 300, 400, 200)])
    return f
}

private func setHeights(_ f: SnowField, _ r: Range<Int>, _ h: Float) {
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for b in r { f.surfaces[i].pile.heights[b] = h }
}

@Test func knockOffOfATallPileMakesSlabsThatCarryItsVolume() {
    let f = tallPile()
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    setHeights(f, 40..<60, 10)   // 20 bins, h = 10
    let n = f.knockOff(f.surfaces[i])
    #expect(n == f.debris.count)
    #expect(f.debris.contains { $0.shape == 2 })
    #expect(abs(f.debris.reduce(0) { $0 + $1.vol } - 400) <= 1)
    #expect(f.debris.filter { $0.shape == 2 }.allSatisfy { $0.size >= 8 && $0.size <= 80 })
}

@Test func lowPilesKeepPlainDots() {
    let f = tallPile()
    setHeights(f, 40..<60, 2)
    _ = f.knockOff(f.surfaces.first { $0.id == 1 }!)
    #expect(!f.debris.isEmpty && f.debris.allSatisfy { $0.shape == 0 })
}

@Test func heavySlabLandingDigsACraterWithARimAndThrowsClumpsUp() {
    let f = makeField(seed: 5)
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    let bin = 100
    f.debris.append(Flake(pos: [Float(f.surfaces[i].c0 + bin) * 2 + 1, 504], vx: 0, fall: 500, phase: 0, amp: 0, freq: 0, size: 16, alpha: 1, kind: .debris, vol: 20, shape: 2))
    f.step(dt: 1 / 60)
    let h = f.surfaces[i].pile.heights
    #expect(h[bin] > 0 && h[bin] < h[bin + 3] && h[bin] < h[bin - 3])
    #expect(f.debris.contains { $0.shape == 1 && $0.fall < 0 })
    #expect(!f.puffs.isEmpty)
}

@Test func reduceMotionSlabsFallStraightWithoutDust() {
    let f = tallPile(calm: true)
    setHeights(f, 40..<60, 10)
    _ = f.knockOff(f.surfaces.first { $0.id == 1 }!)
    setHeights(f, 40..<60, 0)   // the window is gone: nothing underneath to break on
    #expect(f.debris.contains { $0.shape == 2 })
    #expect(f.puffs.isEmpty && f.debris.allSatisfy { $0.shape == 2 && $0.spin == 0 && $0.vx == 0 && $0.fall == Tuning.calmDebrisFall })
    for _ in 0..<30 { f.step(dt: 1 / 30) }
    #expect(f.glints.isEmpty && f.debris.allSatisfy { $0.shape == 2 })   // no puffs, glints or breaks
}

@Test func slabSplitConservesVolume() {
    let f = tallPile()
    setHeights(f, 40..<48, 10)
    _ = f.knockOff(f.surfaces.first { $0.id == 1 }!)
    setHeights(f, 40..<48, 0)
    f.debris.removeAll { $0.shape != 2 }
    let before = f.debris.reduce(0) { $0 + $1.vol }
    #expect(before > 0)
    var split = false
    f.debris[0].delay = 0.3   // aloft long enough; breaks at 1.5 per second
    for _ in 0..<400 where !split {
        f.splitSlab(0, dt: 1 / 30)
        split = f.debris.count == 2
    }
    #expect(split)
    #expect(abs(f.debris.reduce(0) { $0 + $1.vol } - before) < 0.01)
}

@Test func puffAndGlintCapsHold() {
    let f = makeField(seed: 9)
    f.update(windows: [win(1, 300, 300, 400, 200)])
    for _ in 0..<100 { f.addPuff(x: 500, y: 400) }
    #expect(f.puffs.count == Tuning.maxPuffs)
    setHeights(f, 0..<200, 10)
    for _ in 0..<600 { f.step(dt: 1 / 30); #expect(f.glints.count <= Tuning.maxGlints) }
    f.economy = true
    for _ in 0..<10 { f.step(dt: 1 / 30) }   // live glints fade out over ~0.17 s, none are born
    #expect(f.glints.isEmpty)
}

// MARK: - Vanished pile falls as blocks

private func vanish(calm: Bool = false) -> (f: SnowField, vol: Float) {
    let f = tallPile(calm: calm)
    setHeights(f, 20..<180, 10)   // 320pt of 10pt snow
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    let vol = f.surfaces[i].pile.heights.reduce(0, +) * Tuning.binWidth
    f.debris.removeAll()
    f.update(windows: [])   // the window closes: its pile falls, the surface is gone
    return (f, vol)
}

@Test func vanishedPileBecomesAMixOfFewChunks() {
    let (f, vol) = vanish()
    #expect(f.debris.count <= 12 && f.debris.count >= 3)
    #expect(f.debris.allSatisfy { $0.shape == 2 && $0.amp > 0 && $0.prof > 0 && $0.size >= 8 && $0.size <= 130 })
    #expect(abs(f.debris.reduce(0) { $0 + $1.vol } - vol) < 0.01)
    #expect(f.puffs.isEmpty)
}

@Test func chunkSizesVaryAndCutsFallOnThinPoints() {
    var sizes: [Float] = [], cutH: Float = 0, cuts = 0
    for seed in UInt64(1)...6 {
        let f = makeField(seed: seed)
        f.update(windows: [win(1, 300, 300, 600, 200)])
        let i = f.surfaces.firstIndex { $0.id == 1 }!
        let c0 = f.surfaces[i].c0
        for b in 10..<290 { f.surfaces[i].pile.heights[b] = 8 + 5 * sin(Float(b) * 0.35) }   // lumpy pile: thin points every ~18 bins
        f.debris.removeAll()
        f.update(windows: [])
        let chunks = f.debris.filter { $0.shape == 2 }.sorted { $0.pos.x < $1.pos.x }
        sizes += chunks.map { $0.size }
        for c in chunks.dropLast() {   // the cut sits at the right end of the chunk
            let b = Int((c.pos.x + c.size / 2) / Tuning.binWidth) - c0
            cutH += 8 + 5 * sin(Float(b) * 0.35); cuts += 1
        }
    }
    #expect((sizes.max() ?? 0) - (sizes.min() ?? 0) > 30)   // big and small, not even cuts
    #expect(sizes.filter { $0 < 30 }.count > 0 && sizes.filter { $0 > 60 }.count > 0)
    #expect(cuts > 0 && cutH / Float(cuts) < 7)   // cuts sit in the valleys (below the mean height 8)
}

@Test func chunkKeepsThePilesProfile() {
    let f = tallPile()
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for b in 20..<60 { f.surfaces[i].pile.heights[b] = 4 + Float(b - 20) * 0.3 }   // ramps up to the right
    f.debris.removeAll()
    f.update(windows: [])
    let r = f.debris.filter { $0.shape == 2 }.max { $0.size < $1.size }!
    let left = Float((r.prof >> 9) & 31), right = Float((r.prof >> 19) & 31)
    #expect(right >= left)   // taller on the right
    #expect(r.blockThickness > 4 && r.blockThickness <= 16)
}

@Test func releaseRipplesChunksAreHeldThenFall() {
    let (f, _) = vanish()
    let holds = f.debris.map { $0.delay }
    #expect(holds.max()! > 0.05 && holds.max()! <= 0.5 && holds.min()! < holds.max()!)
    let n = f.debris.count
    for _ in 0..<4 { f.step(dt: 1 / 60) }
    let held = f.debris.filter { $0.delay > 0 }.count
    #expect(held > 0 && held < n)   // some are falling already, others still waiting for the ripple
}

@Test func largeChunksStayIntactInTheAirAndBreakOnImpact() {
    let f = tallPile()
    f.debris.removeAll()
    f.update(windows: [])
    let prof = Flake.pack(thickness: 10, left: 0.8, mid: 1, right: 0.7)
    f.debris.append(Flake(pos: [500, 700], vx: 0, fall: 0, phase: 0, amp: 1, freq: 0, size: 90, alpha: 1, kind: .debris, vol: 900, shape: 2, prof: prof))
    var steps = 0, lastY: Float = 700
    while let c = f.debris.first(where: { $0.shape == 2 }), steps < 600 { lastY = c.pos.y; f.step(dt: 1 / 60); steps += 1 }
    #expect(lastY < 130 && steps > 30 && steps < 600)   // fell ~600pt intact, then broke on the ground
    #expect(!f.puffs.isEmpty)
}

@Test func smallChunksCrumbleMidAirAndKeepTheirVolume() {
    let f = tallPile()
    f.debris.removeAll()
    f.update(windows: [])
    f.debris.append(Flake(pos: [500, 900], vx: 0, fall: 0, phase: 0, amp: 1, freq: 0, size: 16, alpha: 1, kind: .debris, vol: 120, shape: 2, prof: Flake.pack(thickness: 8, left: 0.9, mid: 1, right: 0.9)))
    var steps = 0
    while f.debris.contains(where: { $0.shape == 2 }) && steps < 120 { f.step(dt: 1 / 60); steps += 1 }
    #expect(!f.debris.contains { $0.shape == 2 } && f.debris.contains { $0.shape == 1 })
    #expect(abs(f.debris.reduce(0) { $0 + $1.vol } - 120) < 0.01)
}

@Test func breakingAChunkHandsAllItsVolumeToItsPieces() {
    let (f, _) = vanish()
    let slab = f.debris.first { $0.shape == 2 }!
    f.debris.removeAll()
    f.breakSlab(slab, top: 100)
    #expect(f.debris.count >= 3 && f.debris.allSatisfy { $0.phase > 0 && $0.shape <= 1 })
    #expect(abs(f.debris.reduce(0) { $0 + $1.vol } - slab.vol) < 0.01)
}

@Test func crumbsShedWhileFallingComeOutOfTheChunksVolume() {
    let (f, vol) = vanish()
    for _ in 0..<40 { f.step(dt: 1 / 60) }   // ~0.67 s: the ripple has passed, chunks are falling
    #expect(f.debris.contains { $0.shape != 2 && $0.vol > 0 })   // some crumbs/powder came off
    #expect(abs(f.debris.reduce(0) { $0 + $1.vol } - vol) < 0.01)
}

@Test func staleSpaceWindowTakesNoHeavyImpactBeforeTheNextSnapshot() {
    func run(stale: Bool) -> Float {
        let f = makeField(seed: 5)
        f.update(windows: [win(1, 300, 300, 400, 200)])
        let i = f.surfaces.firstIndex { $0.id == 1 }!
        f.dropPiles()
        if stale { f.markStale() }
        f.debris.append(Flake(pos: [Float(f.surfaces[i].c0 + 100) * 2 + 1, 504], vx: 0, fall: 500, phase: 0, amp: 0, freq: 0, size: 16, alpha: 1, kind: .debris, vol: 20, shape: 2))
        f.step(dt: 1 / 60)
        return f.surfaces[i].pile.heights.reduce(0, +)
    }
    #expect(run(stale: false) > 0)   // control: the same fragment does dig in when the list is fresh
    #expect(run(stale: true) == 0)
}
