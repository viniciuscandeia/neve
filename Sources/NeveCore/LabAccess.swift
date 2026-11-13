// AGENT HEADER - Sources/NeveCore/LabAccess.swift  (package-only read access + preparation helpers for the Neve Lab, NeveLabCore)
// Role: the ONLY door NeveLabCore uses into internal SnowField state, all `package` (visible to targets of this package, not to outside users): `labTree` (the Christmas tree), `labSurfaces` (per surface: id, volume pt^2, max height, bin heights),
//   `labPending` (window ids missing from the last poll, still ghosts inside Tuning.goneGrace) and `labFill(surface:height:)` (preparation: raises visible bins of ONE surface to `height`, never above the bin's limit; same recipe as Scenario.fillPiles).
//   Read-only except labFill; no behaviour of the simulation changes and no rng is consumed. Ground surface id = Tuning.groundID (-1), Dock bar = 0, windows = their number.
// Used by: Sources/NeveLabCore (LabWorld state()/digest, prepare commands). Tests: Tests/NeveLabCoreTests.

import Foundation

package struct LabSurface {
    package let id: Int
    package let volume: Float       // pt^2 of snow: sum of bin heights x Tuning.binWidth
    package let maxHeight: Float
    package let heights: [Float]    // local bins
}

extension SnowField {
    package var labTree: Tree? { tree }
    package var labSurfaces: [LabSurface] {
        surfaces.map { s in LabSurface(id: s.id, volume: s.pile.heights.reduce(0, +) * Tuning.binWidth, maxHeight: s.pile.heights.max() ?? 0, heights: s.pile.heights) }
    }
    package var labPending: [Int] { pendingGone.keys.sorted() }
    package static var labGroundID: Int { Tuning.groundID }

    /// Preparation: every visible bin of surface `id` rises to `height` (clamped to its own limit). False when there is no such surface.
    @discardableResult
    package func labFill(surface id: Int, height: Float) -> Bool {
        guard let si = index[id] else { return false }
        for b in surfaces[si].pile.heights.indices where surfaces[si].pile.visible[b] {
            let p = surfaces[si].pile
            surfaces[si].pile.heights[b] = max(p.heights[b], min(height, max(p.limit(b), 0)))
        }
        pilesDirty = true
        return true
    }
}
