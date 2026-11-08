/// Bounded retry for attaching an Accessibility observer to an app that is not ready (no AX server yet, or hung).
public enum AttachRetry {
    public static let maxAttempts = 3
    /// Seconds to wait before the next try after attempt `n` (1-based) failed; nil = give up. Linear: 1 s, 2 s.
    public static func delay(afterFailedAttempt n: Int) -> Double? { n >= 1 && n < maxAttempts ? Double(n) : nil }
}
