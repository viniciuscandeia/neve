import Foundation

/// Bounded retry for attaching an Accessibility observer to an app that is not ready (no AX server yet, or hung).
public enum AttachRetry {
    public static let maxAttempts = 3
    /// Seconds to wait before the next try after attempt `n` (1-based) failed; nil = give up. Linear: 1 s, 2 s.
    public static func delay(afterFailedAttempt n: Int) -> Double? { n >= 1 && n < maxAttempts ? Double(n) : nil }
}

/// Result of one AX call during acquisition, reduced to what the decision needs.
public enum AXStep: Sendable { case ok, transient /* .cannotComplete */, unsupported /* anything else */ }

public enum AttachOutcome: Sendable, Equatable { case complete, transient, incompatible }

extension AttachRetry {
    /// Any transient failure means a partial attach: discard and retry. Otherwise at least one success = complete; none = permanently incompatible.
    public static func classify(_ steps: [AXStep]) -> AttachOutcome {
        if steps.contains(.transient) { return .transient }
        return steps.contains(.ok) ? .complete : .incompatible
    }
}

/// Tickets + generation for off-main AX acquisition. Thread-safe: the worker asks `isCurrent` before doing AX calls.
/// A deactivation bumps the generation, so queued work and sleeping retries from before it are dropped.
public final class AttachGate: @unchecked Sendable {
    private let lock = NSLock()
    private var gen = 0, ticket = 0
    private var inflight: [Int32: Int] = [:]
    public init() {}

    public var generation: Int { lock.withLock { gen } }

    /// Starts an acquisition (first try or a woken retry). nil if the generation is stale, the pid is observed, or one is already in flight.
    public func begin(pid: Int32, generation g: Int, hasObserver: Bool) -> Int? {
        lock.withLock {
            guard g == gen, !hasObserver, inflight[pid] == nil else { return nil }
            ticket += 1; inflight[pid] = ticket
            return ticket
        }
    }
    public func isCurrent(pid: Int32, ticket t: Int, generation g: Int) -> Bool { lock.withLock { g == gen && inflight[pid] == t } }
    /// Consumes the ticket; false = cancelled meanwhile, discard the result.
    public func finish(pid: Int32, ticket t: Int) -> Bool {
        lock.withLock { guard inflight[pid] == t else { return false }; inflight[pid] = nil; return true }
    }
    public func cancel(pid: Int32) { lock.withLock { inflight[pid] = nil } }
    public func cancelAll() { lock.withLock { gen += 1; inflight.removeAll() } }
}
