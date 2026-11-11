// AGENT HEADER - Sources/NeveCore/DockDebounce.swift  (steadies the AX-read Dock rect)
// Role: `DockDebounce` (pure value type) ignores reading changes <= 2 pt on every edge and, after a failed read (nil), keeps the last frame for `grace` (3) further misses, so the ground bank neither reshapes nor sheds/regrows.
//   `feed(_:)` -> (changed, retry: ask the caller to re-read soon, only during the grace window); `feedSide()` (Dock read fine but on left/right/hidden = no bar: clears the frame at once, no grace); `reset()`.
// Caller: DockWatcher in Sources/Neve/Dock.swift. Tests: L7Tests, SurfaceMapTests.

import CoreGraphics

/// Steadies the Dock bar rect read through Accessibility: sub-2pt jitter is ignored and a transient failed read (AX timeout while the
/// Dock is busy) keeps the last frame for `grace` consecutive misses, so the bank beside the bar neither reshapes nor sheds and regrows.
public struct DockDebounce {
    public private(set) var frame: CGRect?
    private var misses = 0
    public let grace: Int, tolerance: CGFloat
    public init(grace: Int = 3, tolerance: CGFloat = 2) { self.grace = grace; self.tolerance = tolerance }

    /// Feeds one reading. Returns whether `frame` changed; `retry` asks the caller to read again soon (a miss within the grace period).
    public mutating func feed(_ reading: CGRect?) -> (changed: Bool, retry: Bool) {
        guard let r = reading else {
            guard frame != nil else { return (false, false) }
            misses += 1
            if misses <= grace { return (false, true) }
            frame = nil
            return (true, false)
        }
        misses = 0
        if let f = frame, abs(f.minX - r.minX) <= tolerance, abs(f.maxX - r.maxX) <= tolerance,
           abs(f.minY - r.minY) <= tolerance, abs(f.maxY - r.maxY) <= tolerance { return (false, false) }
        frame = r
        return (true, false)
    }

    /// The Dock was read fine but sits on the left / right side (or is hidden): there is no bar. Unlike a failed read, no grace period.
    public mutating func feedSide() -> (changed: Bool, retry: Bool) {
        let had = frame != nil
        reset()
        return (had, false)
    }

    /// Trust lost / Dock on a side: no grace.
    public mutating func reset() { frame = nil; misses = 0 }
}
