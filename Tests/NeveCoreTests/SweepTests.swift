import CoreGraphics
import Testing
@testable import NeveCore

/// Window top edge at y=500, x 200...500, with a pile built by direct deposits.
private func pileField() -> SnowField {
    let f = makeField()
    f.update(windows: [win(1, 200, 300, 300, 200)])
    pileUp(f, id: 1)
    return f
}

@Test func sweepThroughAPileClearsOnlyThePathAndThrowsDebris() {
    let f = pileField()
    let before = f.pile(id: 1)!.heights, d0 = f.debris.count
    f.sweep(from: CGPoint(x: 340, y: 502), to: CGPoint(x: 360, y: 502), radius: 10)
    let after = f.pile(id: 1)!.heights
    #expect(f.debris.count > d0)
    // bin i covers x = 200 + 2i; path x 340...360 (+10) = bins 65...85
    #expect(after[75] < before[75])
    for i in [10, 40, 55, 100, 120] { #expect(after[i] == before[i]) }
}

@Test func sweepAboveThePileRemovesNothing() {
    let f = pileField()
    let before = f.pile(id: 1)!.heights, d0 = f.debris.count
    f.sweep(from: CGPoint(x: 250, y: 560), to: CGPoint(x: 450, y: 560), radius: 10)
    #expect(f.pile(id: 1)!.heights == before)
    #expect(f.debris.count == d0)
}

@Test func debrisFliesInTheCursorDirection() {
    for dir: CGFloat in [1, -1] {
        let f = pileField()
        let d0 = f.debris.count
        f.sweep(from: CGPoint(x: 350 - 10 * dir, y: 502), to: CGPoint(x: 350 + 10 * dir, y: 502), radius: 10)
        let vs = f.debris[d0...].map(\.vx)
        #expect(!vs.isEmpty)
        #expect(vs.allSatisfy { $0 * Float(dir) > 0 })
    }
}

@Test func draggedWindowsPileIsNotSwept() {
    let f = pileField()
    f.update(windows: [win(1, 230, 300, 300, 200)])   // same size, moved: being dragged
    #expect(f.draggingID == 1)
    let before = f.pile(id: 1)!.heights
    f.sweep(from: CGPoint(x: 340, y: 502), to: CGPoint(x: 400, y: 502), radius: 10)
    #expect(f.pile(id: 1)!.heights == before)
}

@Test func fallingSnowPartsAroundAStillPointer() {
    let f = makeField(flakes: 400)
    let ptr = SIMD2<Float>(500, 400)
    f.setPointer(ptr, velocity: .zero)
    var close: Float = .infinity, displaced = 0
    for n in 0..<900 {
        f.step(dt: 1 / 60)
        guard n > 60 else { continue }
        for fl in f.flakes where fl.kind != .dormant {
            let d = fl.pos - ptr
            close = min(close, (d.x * d.x + d.y * d.y).squareRoot())
            if abs(d.y) < 70, abs(d.x) > 20, abs(d.x) < 60 { displaced += 1 }
        }
    }
    #expect(close > 8)
    #expect(displaced > 0)
}

@Test func pointerFarAwayDoesNotMoveFlakes() {
    let a = makeField(flakes: 400), b = makeField(flakes: 400)
    b.setPointer([500, 400], velocity: [300, 0])
    for _ in 0..<10 { a.step(dt: 1 / 60); b.step(dt: 1 / 60) }
    for (x, y) in zip(a.flakes, b.flakes) where abs(x.pos.x - 500) > 100 || abs(x.pos.y - 400) > 100 { #expect(x.pos == y.pos) }
}
