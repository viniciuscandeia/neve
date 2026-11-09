/// Profiling accumulator for one timed slot (nanoseconds): total, worst single sample and sample count.
public struct PerfStat {
    public var sum: UInt64 = 0, peak: UInt64 = 0, n = 0
    public init() {}
    public mutating func add(_ d: UInt64) { sum &+= d; n += 1; if d > peak { peak = d } }
    /// Average cost per presented frame (not per sample): a slot sampled twice or skipped on some frames is still spread over `frames`.
    public func msPerFrame(_ frames: Int) -> Double { frames == 0 ? 0 : Double(sum) / Double(frames) / 1e6 }
    /// CPU milliseconds spent per wall-clock second.
    public func msPerSecond(_ wall: Double) -> Double { wall <= 0 ? 0 : Double(sum) / wall / 1e6 }
    public var peakMs: Double { Double(peak) / 1e6 }
}
