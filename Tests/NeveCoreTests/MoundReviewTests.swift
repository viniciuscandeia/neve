// AGENT HEADER - Tests/NeveCoreTests/MoundReviewTests.swift  (Pile.mound stays self-correcting when snow leaves a heap without trackMound; clear() resets dockMoundCarry)
import Testing
@testable import NeveCore

private func heapPile() -> Pile {
    var p = Pile(columns: 100, inset: 0, c0: 0, x0: 0, x1: 200)
    p.mound = [Float](repeating: 0, count: 100)
    for k in 40..<60 { p.heights[k] = 120; p.trackMound(k) }
    return p
}
private func flood(_ p: inout Pile) { for _ in 0..<400 { for b in stride(from: 0, to: 100, by: 3) { p.deposit(bin: b, volume: 4) } } }

// Melt / releasePiles / takeSnow lower heights directly; snowfall must then fill only to the normal ceiling, not regrow the old heap.
@Test func lowerHeapDoesNotRegrowFromSnowfall() {
    for lower in [{ (p: inout Pile) in for k in 40..<60 { p.heights[k] = 0 } },          // release
                  { (p: inout Pile) in for k in 40..<60 { p.heights[k] = max(0, p.heights[k] - 119) } },   // melt
                  { (p: inout Pile) in for k in 40..<60 { p.heights[k] *= 0.5 } }] {   // takeSnow-like
        var p = heapPile()
        lower(&p)
        let ceiling = max(p.heights.max()!, p.heights.indices.map { p.rawLimit($0) }.max()!) + 0.01   // what is left, or the normal ceiling
        flood(&p)
        #expect(p.heights.max()! <= ceiling, "regrown heap \(p.heights.max()!)")
    }
}

@Test func clearResetsDockMoundCarry() {
    let f = makeField()
    f.dockCarry = [1]; f.dockMoundCarry = [1]
    f.clear()
    #expect(f.dockCarry.isEmpty && f.dockMoundCarry.isEmpty)
}
