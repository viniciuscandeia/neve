import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

// Equivalence of the shipped `writePiles` with the pre-optimisation copy in WritePilesEquivalenceTests.swift (`writePilesRef`).

private func dockWin(_ x0: CGFloat, _ x1: CGFloat) -> WindowInfo { WindowInfo(number: 0, frame: CGRect(x: x0, y: 10, width: x1 - x0, height: 84), radius: 25.2) }

private func blank() -> [PileSeg] { [PileSeg](repeating: PileSeg(x0: -7, x1: -7, top0: -7, top1: -7, base0: -7, base1: -7, slope: -7, dragged: 9, n0: -7, n1: -7), count: 1 << 14) }

private func same(_ a: PileSeg, _ b: PileSeg) -> Bool {
    a.x0 == b.x0 && a.x1 == b.x1 && a.top0 == b.top0 && a.top1 == b.top1 && a.base0 == b.base0 && a.base1 == b.base1
        && a.slope == b.slope && a.dragged == b.dragged && a.n0 == b.n0 && a.n1 == b.n1 && a.inset == b.inset
}

/// Reference vs shipped writer on two identically built fields; every field of the whole buffer (past `n` too), the count and the drop count must match.
@discardableResult
private func compare(_ ref: SnowField, _ new: SnowField, capacity: Int = 1 << 14, dt: Float = 1 / 60, sourceLocation: SourceLocation = #_sourceLocation) -> Int {
    var ba = blank(), bb = blank(), da = 0, db = 0
    let na = ba.withUnsafeMutableBufferPointer { ref.writePilesRef(to: $0.baseAddress!, capacity: capacity, dt: dt, force: true, dropped: &da) }
    let nb = bb.withUnsafeMutableBufferPointer { new.writePiles(to: $0.baseAddress!, capacity: capacity, dt: dt, force: true, dropped: &db) }
    #expect(na == nb && da == db, sourceLocation: sourceLocation)
    let bad = ba.indices.filter { !same(ba[$0], bb[$0]) }.count
    #expect(bad == 0, "\(bad) differing slices", sourceLocation: sourceLocation)
    return na ?? 0
}

private func world(dock: WindowInfo? = dockWin(300, 700)) -> SnowField {
    let f = makeField()
    f.update(windows: (dock.map { [$0] } ?? []) + [win(1, 100, 300, 250, 120), win(2, 330, 380, 200, 120), win(3, 800, 250, 150, 100), win(4, 553, 380, 150, 90)])
    return f
}

@Test func writePilesMatchesReferenceAcrossPileShapes() {
    var maxN = 0
    for (g, d, w) in [(0, 0, 0), (1, 1, 2), (3, 0, 6), (12, 3, 12), (12, 12, 12), (2, 12, 4), (12, 1, 0), (6, 6, 6)] {
        let a = world(), b = world()
        for f in [a, b] { pileUp(f, id: Tuning.groundID, rounds: g); pileUp(f, id: 0, rounds: d); for id in 1...4 { pileUp(f, id: id, rounds: w) } }
        maxN = max(maxN, compare(a, b))
        for f in [a, b] { pileUp(f, id: Tuning.groundID, rounds: g); pileUp(f, id: 0, rounds: d) }   // eased, not settled
        compare(a, b)
    }
    #expect(maxN > 100)
}

@Test func writePilesMatchesReferenceWhileTheDockGrowsAndShrinks() {
    let a = world(), b = world()
    for f in [a, b] { pileUp(f, id: Tuning.groundID, rounds: 12); pileUp(f, id: 0, rounds: 12) }
    var most = compare(a, b)
    for fr: (CGFloat, CGFloat) in [(300, 700), (260, 760), (200, 900), (320, 900), (400, 600), (450, 520), (300, 700)] {
        for f in [a, b] {
            f.update(windows: [dockWin(fr.0, fr.1), win(1, 100, 300, 250, 120), win(3, 800, 250, 150, 100)])
            pileUp(f, id: Tuning.groundID, rounds: 3); pileUp(f, id: 0, rounds: 3); pileUp(f, id: 1, rounds: 3); pileUp(f, id: 3, rounds: 3)
        }
        most = max(most, compare(a, b))
    }
    #expect(most > 100)
    // Animated through the real Dock stepper (isolated rebuilds, slump relax) as well.
    let c = world(dock: dockWin(700, 1000)), d = world(dock: dockWin(700, 1000))
    for f in [c, d] { pileUp(f, id: Tuning.groundID, rounds: 12); pileUp(f, id: 0, rounds: 12) }
    for f in [c, d] { f.update(windows: [dockWin(300, 1300), win(3, 800, 250, 150, 100)]) }
    for _ in 0..<90 { c.step(dt: 1 / 60); d.step(dt: 1 / 60); compare(c, d) }
}

@Test func writePilesMatchesReferenceWithBridgesSeamsCoveredRunsAndShortBuffers() {
    // Ground<->Dock bridges, a ground bank lower than the Dock snow (held slice kept), hidden columns, drifts, windows side by side.
    func scene(_ g: Int, _ d: Int) -> SnowField {
        let f = makeField()
        f.update(windows: [dockWin(300, 700), win(1, 100, 300, 250, 120), win(2, 350, 330, 200, 120), win(5, 553, 330, 150, 120), win(6, 520, 250, 60, 100), win(7, 800, 120, 100, 300)])
        pileUp(f, id: Tuning.groundID, rounds: g)
        for id in [0, 1, 2, 5, 6, 7] { pileUp(f, id: id, rounds: d) }
        return f
    }
    var sawBank = false, sawDropped = false
    for (g, d) in [(12, 12), (12, 2), (0, 12), (5, 12), (12, 0)] {
        var buf = blank()
        let n = buf.withUnsafeMutableBufferPointer { scene(g, d).writePilesRef(to: $0.baseAddress!, capacity: 1 << 14, dt: 10, force: true) }!
        sawBank = sawBank || buf[0..<n].contains { $0.dragged & 2 != 0 }
        for cap in 0...(n + 1) where cap >= n - 12 || cap < 3 {   // short buffers: drops land on run slices, bridges and held slices alike
            var da = 0, db = 0, ba = blank(), bb = blank()
            let na = ba.withUnsafeMutableBufferPointer { scene(g, d).writePilesRef(to: $0.baseAddress!, capacity: cap, dt: 10, force: true, dropped: &da) }
            let nb = bb.withUnsafeMutableBufferPointer { scene(g, d).writePiles(to: $0.baseAddress!, capacity: cap, dt: 10, force: true, dropped: &db) }
            #expect(na == nb && da == db)
            #expect(ba.indices.allSatisfy { same(ba[$0], bb[$0]) })
            sawDropped = sawDropped || da > 0
        }
        compare(scene(g, d), scene(g, d))
    }
    #expect(sawBank && sawDropped)
}

@Test func writePilesMatchesReferenceWithADraggedWindow() {
    let a = world(), b = world()
    for f in [a, b] {
        pileUp(f, id: 2, rounds: 8); pileUp(f, id: 0, rounds: 8)
        f.update(windows: [dockWin(300, 700), win(1, 100, 300, 250, 120), win(2, 360, 380, 200, 120), win(3, 800, 250, 150, 100)], dt: 0.04)
    }
    compare(a, b)
}

/// `NEVE_BENCH=1 Tests/run.sh -r WritePilesBench`: ns per call, reference vs shipped, on a 3000pt screen with a Dock and six wide snowy windows.
@Test func writePilesBench() {
    guard getenv("NEVE_BENCH") != nil else { return }
    let f = SnowField(size: CGSize(width: 3000, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 1)
    let ws = [dockWin(900, 2100)] + (0..<6).map { win($0 + 1, CGFloat($0) * 20, 120 + CGFloat($0) * 110, 2900 - CGFloat($0) * 40, 90) }
    f.update(windows: ws)
    for w in ws { pileUp(f, id: w.number, rounds: 6) }
    pileUp(f, id: Tuning.groundID, rounds: 6)
    let cap = f.pileSegDemand
    let p = UnsafeMutablePointer<PileSeg>.allocate(capacity: cap)
    defer { p.deallocate() }
    func time(_ label: String, _ body: () -> Int?) {
        for _ in 0..<50 { _ = body() }
        var best = Double.infinity, n = 0
        for _ in 0..<7 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<300 { n = body() ?? 0 }
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 300)
        }
        print("BENCH writePiles \(label): \(Int(best)) ns/call (\(n) slices)")
    }
    time("reference") { f.writePilesRef(to: p, capacity: cap, dt: 10, force: true) }
    time("shipped  ") { f.writePiles(to: p, capacity: cap, dt: 10, force: true) }
}

/// The ground bank reaches (or not) the Dock snow on each side independently: bridge both sides / one side / none, with the plain slice kept or replaced.
@Test func writePilesMatchesReferenceForBankHeightsAgainstTheDock() {
    var sawBridgeWithHeld = false
    for (l, r, d) in [(150, 150, 1), (150, 20, 1), (20, 150, 1), (20, 20, 1), (150, 150, 12), (60, 60, 6), (0, 150, 3), (150, 0, 3)] as [(Float, Float, Int)] {
        func scene() -> SnowField {
            let f = world()
            pileUp(f, id: 0, rounds: d)
            let gi = f.index[Tuning.groundID]!
            for b in f.surfaces[gi].pile.heights.indices { f.surfaces[gi].pile.heights[b] = binCenterX(f, b) < 500 ? l : r }
            return f
        }
        let a = scene(), b = scene()
        let n = compare(a, b)
        #expect(n > 100)
        var buf = blank()
        let m = buf.withUnsafeMutableBufferPointer { scene().writePilesRef(to: $0.baseAddress!, capacity: 1 << 14, dt: 10, force: true) }!
        if m > 0, l >= 150 || r >= 150 { sawBridgeWithHeld = true }
        for cap in stride(from: m + 1, through: max(m - 6, 0), by: -1) { compare(scene(), scene(), capacity: cap, dt: 10) }
    }
    #expect(sawBridgeWithHeld)
}

private func binCenterX(_ f: SnowField, _ b: Int) -> Float { (Float(f.surfaces[f.index[Tuning.groundID]!].c0 + b) + 0.5) * Tuning.binWidth }
