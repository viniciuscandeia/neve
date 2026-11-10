/// Hitch accounting from presented timestamps (seconds). A frame is a hitch when its presented interval exceeds 1.5x the interval it was
/// scheduled for (consecutive target timestamps, so the 30/60 fps adaptive rate is not a hitch); lateness is the excess in ms.
/// Gaps scheduled longer than `maxExpected` (pause, occlusion, wake) are not frames to judge.
public struct HitchMeter: Sendable {
    public var hitchMs = 0.0, drops = 0, frames = 0
    private var lastPresented = 0.0, lastTarget = 0.0
    public static let maxExpected = 0.2
    public init() {}
    public mutating func present(at presented: Double, target: Double) {
        defer { lastPresented = presented; lastTarget = target }
        guard presented > 0, lastPresented > 0, lastTarget > 0 else { return }
        let expected = target - lastTarget, actual = presented - lastPresented
        guard expected > 0, expected <= Self.maxExpected else { return }
        frames += 1
        if actual > expected * 1.5 { drops += 1; hitchMs += (actual - expected) * 1000 }
    }
    /// Reports the window and clears the counters (the last timestamps stay, so the next interval is still measured).
    public mutating func take(wall: Double) -> (msPerSecond: Double, dropsPerSecond: Double) {
        defer { hitchMs = 0; drops = 0; frames = 0 }
        return wall <= 0 ? (0, 0) : (hitchMs / wall, Double(drops) / wall)
    }
}
