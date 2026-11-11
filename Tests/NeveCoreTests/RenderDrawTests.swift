// AGENT HEADER - Tests/NeveCoreTests/RenderDrawTests.swift  (drawing inputs: slabs without a profile draw as blocks (never glints), PileSeg carries the real edge `inset` for the shader's depth maths Related: Render.swift, PileShader.swift.)

import CoreGraphics
import Testing
@testable import NeveCore

// Drawing inputs: block instances and the pile depth fed to the shader.

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
