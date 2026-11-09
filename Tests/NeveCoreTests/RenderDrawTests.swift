import CoreGraphics
import Testing
@testable import NeveCore

// Drawing inputs: block instances, pile depth fed to the shader, the seam lift.

@Test func profilelessSlabsDrawAsBlocksNeverGlints() {
    let f = makeField()
    f.debris.removeAll()
    for amp: Float in [0, 1] {   // flushed run / split slab (amp 0) and an avalanche slab that lost its profile
        f.debris.append(Flake(pos: [100, 500], vx: 0, fall: 10, phase: 0, amp: amp, freq: 0, size: 24, alpha: 1, kind: .debris, seed: 0.3, fade: 1, shape: 2))
    }
    f.debris.append(Flake(pos: [200, 500], vx: 0, fall: 10, phase: 0, amp: 1, freq: 0, size: 40, alpha: 1, kind: .debris, seed: 0.3, fade: 1, shape: 2, prof: Flake.pack(thickness: 8, left: 0.5, mid: 0.9, right: 0.5)))
    let p = UnsafeMutablePointer<Instance>.allocate(capacity: f.capacity)
    defer { p.deallocate() }
    let n = f.writeInstances(to: p)
    let slabs = (0..<n).map { p[$0] }.filter { $0.kind & 255 == 2 }
    #expect(slabs.count == 3)
    #expect(slabs.allSatisfy { $0.kind >> 8 > 0 })   // every slab carries a profile: the shader's chunk branch, not the glint
}

@Test func pileSegCarriesTheRealEdgeInset() {
    #expect(MemoryLayout<PileSeg>.offset(of: \PileSeg.inset) == 40)
    let f = makeField()
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for b in 100..<104 { f.deposit(surface: i, bin: b, volume: 6) }
    let s = pileSegs(f).filter { $0.x0 > 300 && $0.x1 < 700 }
    #expect(!s.isEmpty && s.allSatisfy { $0.inset == 1 })
    let first = s.min { $0.x0 < $1.x0 }!, last = s.max { $0.x1 < $1.x1 }!
    // The stretch ends have little snow (the blur of the neighbouring bin): the depth the shader measures is ~0, where top - base alone would read >= 1.
    #expect(first.top0 - first.base0 - first.inset < 0.7)
    #expect(last.top1 - last.base1 - last.inset < 0.7)
    #expect(s.map { $0.top0 - $0.base0 - $0.inset }.max()! > 2)   // the speck itself is real snow
}

private func ramp(top: Float, base: Float, width: Float) -> (UnsafeMutablePointer<PileSeg>, PileEnd) {
    let n = 40, w = width / Float(n)
    let p = UnsafeMutablePointer<PileSeg>.allocate(capacity: n)
    for k in 0..<n { p[k] = PileSeg(x0: Float(k) * w, x1: Float(k + 1) * w, top0: top, top1: top, base0: base, base1: base, slope: 0, dragged: 0) }
    return (p, PileEnd(id: 1, first: (0, top, base), last: (width, top, base), drag: false, segs: 0..<n))
}

@Test func seamLiftIsBoundedAndSkipsThinStretches() {
    let f = makeField()
    let (p, a0) = ramp(top: 10, base: 0, width: 200)
    defer { p.deallocate() }
    var a = a0, c = a0
    c.first.t = 34   // a 24pt step: the old ramp rose ~24pt over ~80pt
    f.liftSeam(p, &a, &c)
    #expect((0..<40).map { p[$0].top1 }.max()! <= 16.001)   // at most 6pt, however big the step
    #expect(a.last.t == 16)
    // A speck (real depth < 1 under the 1pt inset): nothing is lifted.
    let (q, t0) = ramp(top: 10, base: 9.5, width: 200)
    defer { q.deallocate() }
    var t = t0, c2 = t0
    c2.first.t = 20
    f.liftSeam(q, &t, &c2)
    #expect((0..<40).allSatisfy { q[$0].top1 == 10 } && t.last.t == 10)
    // A short stretch: the ramp stays inside it with slope <= 0.3.
    let (r, s0) = ramp(top: 10, base: 0, width: 8)
    defer { r.deallocate() }
    var s = s0, c3 = s0
    c3.first.t = 30
    f.liftSeam(r, &s, &c3)
    #expect(s.last.t - 10 <= 0.3 * 8 + 0.001)
}

@Test func seamLiftStaysUnderTheLowerPilesCeiling() {
    let f = makeField()
    f.update(windows: [win(1, 0, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for b in f.surfaces[i].pile.cap.indices { f.surfaces[i].pile.cap[b] = 12 - f.surfaces[i].edgeY - f.surfaces[i].pile.base[b] }   // a third window caps it at y = 12
    let (p, a0) = ramp(top: 10, base: 0, width: 200)
    defer { p.deallocate() }
    var a = a0, c = a0
    c.first.t = 34
    f.liftSeam(p, &a, &c)
    #expect((0..<40).map { p[$0].top1 }.max()! <= 12.001 && a.last.t <= 12.001)
}
