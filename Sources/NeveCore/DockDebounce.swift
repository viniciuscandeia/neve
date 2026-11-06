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

    /// Trust lost / Dock moved to a side: no grace.
    public mutating func reset() { frame = nil; misses = 0 }
}
