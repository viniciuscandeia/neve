// AGENT HEADER - Sources/NeveCore/Countdown.swift  (N completions -> one callback; used by AppController in Sources/Neve/main.swift for per-overlay outro and idle-melt (startIdleMelt) completion; `hit()` is true exactly once)

/// Counts `n` completions; `hit()` is true exactly once, on the last one (extra hits are ignored).
public struct Countdown {
    private var left: Int
    public init(_ n: Int) { left = max(n, 0) }
    public var isDone: Bool { left == 0 }
    public mutating func hit() -> Bool { guard left > 0 else { return false }; left -= 1; return left == 0 }
}
