import CoreGraphics
import Testing
@testable import NeveCore

private func runs(_ h: ArraySlice<Float>) -> [Int] {   // lengths (bins) of the separate non-zero runs
    var r: [Int] = [], n = 0
    for v in h { if v > 0.3 { n += 1 } else if n > 0 { r.append(n); n = 0 } }
    if n > 0 { r.append(n) }
    return r
}

private func bareRun(_ seconds: Float, nevasca: Bool = false) -> ArraySlice<Float> {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: Tuning.flakes, seed: 3)
    if nevasca { f.setIntensity(.nevasca, immediate: true) }
    f.update(windows: [win(1, 300, 300, 800, 300)])
    advance(f, seconds, fps: 30)
    return f.surfaces.first { $0.id == 1 }!.pile.heights[10..<390]   // inside the corner taper
}

/// Medium snowfall on a bare 800pt window: isolated specks at 20 s, a continuous layer by 60 s (Nevasca about twice as fast).
@Test func firstSnowOnBareWindowIsIsolatedSpecksThenMerges() {
    let early = bareRun(20), r = runs(early)
    #expect(r.count >= 30)
    #expect(r.max()! <= early.count / 10)
    let late = bareRun(60)
    #expect(late.filter { $0 > 0.3 }.count >= late.count * 9 / 10)
    let nv = bareRun(30, nevasca: true)
    #expect(nv.filter { $0 > 0.3 }.count >= nv.count * 9 / 10)
}
