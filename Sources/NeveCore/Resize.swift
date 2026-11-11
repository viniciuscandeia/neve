// AGENT HEADER - Sources/NeveCore/Resize.swift  (screen size / scale change)
// Role: `remapHeights(_:to:)` (heights carried to a new column count by x proportion, area-weighted mean per new column) and `SnowField.resize(size:origin:groundY:visibleTop:)`: window piles (surfaces with id > 0, and what stands on them) are stashed by
//   window id (stashAway) and return with the windows; the ground keeps its heights and mounds by x proportion; the Dock pile waits in `dockCarry` / `dockMoundCarry` (only WHERE a heap stood; its allowance is recomputed from the carried heights on rebuild; applied only to a rebuild within ~2 s, `dockCarryUntil`); flakes / balls / figures /
//   gifts keep their x proportion (x scaled by the width ratio); effects tied to the old geometry (debris, glints, puffs, drops, icicles, carrots, confetti, splats, fights, shots) and chain / dockTrickle / seams / dock animation state are dropped. The
//   surfaces are reduced to the ground only; the next `update` rebuilds the rest (boundsDirty). Also resets the live region (liveX0/X1/liveTop) to the whole screen.
// Caller: Overlay (rebuildGeometry, Sources/Neve/Overlay.swift). Tests: WindowClassTests (resize cases), SweepTests.

import CoreGraphics
import Foundation

/// Ground heights carried to a new column count by x proportion (column i of n covers [i/n, (i+1)/n) of the width): each new column takes the
/// area-weighted mean of the old columns it overlaps, so a ridge keeps its place and height when the screen only scales.
public func remapHeights(_ old: [Float], to n: Int) -> [Float] {
    guard n > 0 else { return [] }
    guard !old.isEmpty else { return [Float](repeating: 0, count: n) }
    if old.count == n { return old }
    let m = Float(old.count)
    return (0..<n).map { i in
        let a = Float(i) / Float(n) * m, b = Float(i + 1) / Float(n) * m
        var sum: Float = 0
        var k = Int(a)
        while Float(k) < b, k < old.count {
            sum += old[k] * (min(b, Float(k + 1)) - max(a, Float(k)))
            k += 1
        }
        return sum / (b - a)
    }
}

extension SnowField {
    /// The screen changed size / scale / place: window piles (and what stands on them) are set aside by window id and come back with the windows,
    /// the ground keeps its heights by x proportion, flakes / balls / figures / gifts keep their x proportion, and effects tied to the old geometry
    /// (debris, glints, puffs, drops, icicles, fights, shots) are dropped. The next `update` rebuilds the surfaces at the new size.
    public func resize(size s: CGSize, origin o: CGPoint, groundY g: CGFloat, visibleTop t: CGFloat) {
        let newSize = SIMD2(Float(s.width), Float(s.height))
        stashAway(surfaces.filter { $0.id > 0 })
        let oldGround = surfaces.first { $0.id == Tuning.groundID }?.pile.heights ?? [], oldGroundMound = surfaces.first { $0.id == Tuning.groundID }?.pile.mound ?? []
        var oldDock = [Float](repeating: 0, count: numCols), oldDockMound = oldDock   // the Dock pile by global column, carried like the ground (applied when its surface is rebuilt)
        if let d = surfaces.first(where: { $0.id == 0 }) { for (k, h) in d.pile.heights.enumerated() where d.c0 + k >= 0 && d.c0 + k < numCols { oldDock[d.c0 + k] = h; if !d.pile.mound.isEmpty { oldDockMound[d.c0 + k] = d.pile.mound[k] } } }
        let k = size.x > 0 ? newSize.x / size.x : 1
        size = newSize; origin = o; groundY = Float(g); visibleTop = Float(t)
        numCols = max(1, Int((newSize.x / Tuning.binWidth).rounded(.up)))
        offsets = [Int32](repeating: 0, count: numCols + 1)
        entries.removeAll()
        liveX0 = 0; liveX1 = newSize.x; liveTop = newSize.y
        for i in flakes.indices { flakes[i].pos.x *= k }
        for i in balls.indices { balls[i].pos.x *= k }
        for i in giftState.gifts.indices { giftState.gifts[i].pos.x *= k }
        clearFights()
        for i in figures.indices {
            figures[i].foot.x *= k
            if case .surface(let id, let x) = figures[i].at { figures[i].at = .surface(id: id, x: x * k) }
            figures[i].critter.fetchX = nil
        }
        debris.removeAll(keepingCapacity: true); glints.removeAll(keepingCapacity: true); puffs.removeAll(keepingCapacity: true)
        drops.removeAll(keepingCapacity: true); icicles.removeAll(keepingCapacity: true); carrots.removeAll(keepingCapacity: true)
        giftState.confetti.removeAll(keepingCapacity: true); splats.removeAll(keepingCapacity: true)
        chain = AvaChain(); dockTrickle = DockTrickle(); sweepOwed = 0
        overhang.removeAll(); spaceSwitchIDs = []
        groundWinKey = []; groundWinCeil = []; groundWinHidden = []
        dockTarget = nil; dockCur = nil; dockPrev = nil
        var pile = Pile(columns: numCols, inset: 0, c0: 0, x0: -1e5, x1: 2e5 + newSize.x)
        pile.maxHeight = Tuning.groundMaxHeight
        pile.heights = remapHeights(oldGround, to: numCols)
        if oldGroundMound.contains(where: { $0 > 0 }) { pile.mound = (0..<numCols).map { max(0, pile.heights[$0] - pile.rawLimit($0)) } }   // from the remapped heights, not remapped on its own
        surfaces = [Surface(id: Tuning.groundID, frame: CGRect(x: -1e5, y: -1, width: 2e5 + CGFloat(newSize.x), height: 1), edgeY: 0, c0: 0, anchor: 0, pile: pile)]
        index = [Tuning.groundID: 0]
        dockCarryUntil = time + 2; dockCarry = oldDock.contains { $0 > 0 } ? remapHeights(oldDock, to: numCols) : []
        dockMoundCarry = oldDockMound.contains { $0 > 0 } ? remapHeights(oldDockMound, to: numCols) : []   // only says WHERE a heap stood; its allowance is recomputed from the carried heights when the Dock is rebuilt
        seams = []
        lastWindows = []; boundsDirty = true
        buildColumns()
        pilesDirty = true
    }
}
