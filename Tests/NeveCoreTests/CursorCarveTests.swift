import CoreGraphics
import Testing
@testable import NeveCore

private func field() -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 0, config: SimConfig(), seed: 1)
    f.update(windows: [win(1, 100, 300, 800, 200)])
    for b in f.surfaces[f.index[1]!].pile.heights.indices { f.surfaces[f.index[1]!].pile.heights[b] = 12 }
    return f
}
private func total(_ f: SnowField) -> Float { f.pile(id: 1)!.heights.reduce(0, +) * Tuning.binWidth }
private func topY(_ f: SnowField) -> Float { f.surfaces[f.index[1]!].edgeY }
private func sweep(_ f: SnowField, y: Float, vx: Float = 300) {
    for k in 0..<3 { f.setPointer(SIMD2(500 + Float(k) * 3, y), velocity: SIMD2(vx, 0)); f.stepCursorCarve() }
}

@Test func cursorCarveLowersAndConserves() {
    let f = field(), t0 = total(f)
    sweep(f, y: topY(f) + 8)
    let dropped = t0 - total(f)
    #expect(f.pilesDirty && f.pile(id: 1)!.heights[f.column(500) - f.surfaces[f.index[1]!].c0] < 12)
    // cut = banked (stays in the pile) + sprayed (debris puffs + pending)
    let sprayed = f.carveSpray + Float(f.debris.count) * Tuning.penguinPuff
    #expect(dropped > 0)
    #expect(abs(dropped - sprayed) < 1.5 * Tuning.penguinPuff)
}

@Test func cursorCarveIgnoredWhenSlowOrOffOrBusy() {
    for c in 0..<4 {
        let f = field(), t0 = total(f)
        switch c {
        case 0: sweep(f, y: topY(f) + 8, vx: 10)
        case 1: f.pointerPush = false; sweep(f, y: topY(f) + 8)
        case 2: f.optionHeld = true; sweep(f, y: topY(f) + 8)
        default: sweep(f, y: topY(f) + 60)   // cursor above the pile top
        }
        #expect(total(f) == t0)
    }
}
