import CoreGraphics

extension SnowField {
    /// The one "dragged window": the id the mouse confirmed (`dragTarget`), set by the overlay before each `update`. Pile layer, shedding, avalanches
    /// and figures all read `draggingID`; nothing guesses it from "the first surface that moved" any more.
    public func setDragTarget(_ id: Int?) {
        guard draggingID != id else { return }
        draggingID = id
        pilesDirty = true
    }

    /// Cheap "would a cursor sweep a->b (local coords) cut anything?": visible pile snow, or a ball / figure / gift at the end point, within `radius` of the segment.
    /// Same bin walk as `sweep` (a few dozen bins at most). Decides whether a fast cursor needs 60 fps even with "Cursor empurra" off (piles only count when the cursor pushes them).
    public func snowNear(from a: CGPoint, to b: CGPoint, radius: Float = 10) -> Bool {
        let ay = Float(a.y), by = Float(b.y)
        let lo = min(ay, by) - radius, hi = max(ay, by) + radius
        let x0 = Float(min(a.x, b.x)) - radius, x1 = Float(max(a.x, b.x)) + radius
        if hitTest(point: b) { return true }
        for s in surfaces where pointerPush {
            let c0 = s.c0, n = s.pile.heights.count
            let k0 = max(0, Int(x0 * invBin) - c0), k1 = min(n - 1, Int(x1 * invBin) - c0)
            guard k0 <= k1 else { continue }
            for k in k0...k1 where s.pile.heights[k] > 0.5 && s.pile.visible[k] {
                let bottom = s.edgeY + s.pile.base[k]
                if hi >= bottom && lo <= bottom + s.pile.heights[k] { return true }
            }
        }
        return false
    }
}
