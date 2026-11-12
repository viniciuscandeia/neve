import CoreGraphics
import Testing
@testable import NeveCore
func area(_ f: SnowField) -> Float { f.surfaces.reduce(0) { $0 + $1.pile.heights.reduce(0, +) * Tuning.binWidth + ($1.pile.spillL + $1.pile.spillR) * Tuning.binWidth + $1.pile.eaveL + $1.pile.eaveR + ($1.pile.owedL + $1.pile.owedR) * Tuning.binWidth } }
@Test func tmpProbe() {
    for (pre, auto) in [(0 as Int, false), (14, false), (0, true)] {
      for onWin in [true, false] {
        let f = makeField()
        f.update(windows: [win(1, 200, 400, 700, 150)])
        if pre > 0 { pileUp(f, id: 1, rounds: pre) }
        let sid = onWin ? 1 : Tuning.groundID
        let id = auto ? standAuto(f, x: 500, on: sid) : stand(f, x: 500, on: sid)
        let fg = fig(f, id)
        let a0 = area(f)
        let radii = f.anchors(of: fg)
        _ = radii
        f.shatter(id, velocity: .zero, burst: true)
        let air0 = f.debris.reduce(0) { $0 + $1.vol }
        var t: Float = 0
        while !f.debris.isEmpty && t < 30 { f.step(dt: 1/60); t += 1/60 }
        print("PROBE pre=\(pre) auto=\(auto) onWin=\(onWin) carried=\(air0) landedArea=\(area(f) - a0) debrisLeft=\(f.debris.count) t=\(t)")
      }
    }
}
