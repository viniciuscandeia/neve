// AGENT HEADER - Tests/NeveCoreTests/AttachRetryTests.swift  (Sources/NeveCore/AttachRetry.swift: bounded backoff, partial attach = transient, AttachGate drops old retries after reactivation; pure, no AX calls)

import Testing
@testable import NeveCore

@Test func attachRetryIsBoundedAndBacksOff() {
    #expect(AttachRetry.delay(afterFailedAttempt: 1) == 1)
    #expect(AttachRetry.delay(afterFailedAttempt: 2) == 2)
    #expect(AttachRetry.delay(afterFailedAttempt: AttachRetry.maxAttempts) == nil)
    #expect(AttachRetry.delay(afterFailedAttempt: 0) == nil)
}

@Test func classifyPartialAttachIsTransient() {
    #expect(AttachRetry.classify([.ok, .ok, .ok]) == .complete)
    #expect(AttachRetry.classify([.ok, .transient, .ok]) == .transient)
    #expect(AttachRetry.classify([.ok, .unsupported]) == .complete)
    #expect(AttachRetry.classify([.ok, .ok, .transient]) == .transient)   // enumeration failed transiently
    #expect(AttachRetry.classify([.unsupported, .unsupported]) == .incompatible)
    #expect(AttachRetry.classify([]) == .incompatible)
}

@Test func gateDropsOldRetryAfterReactivation() {
    let g = AttachGate()
    let gen1 = g.generation
    let old = g.begin(pid: 7, generation: gen1, hasObserver: false)!
    g.cancelAll()                                              // deactivate while the acquisition is blocked
    #expect(!g.isCurrent(pid: 7, ticket: old, generation: gen1))   // queued worker block bails
    let gen2 = g.generation
    let fresh = g.begin(pid: 7, generation: gen2, hasObserver: false)!   // reactivate
    #expect(g.begin(pid: 7, generation: gen1, hasObserver: false) == nil)   // old retry wakes: stale generation
    #expect(!g.finish(pid: 7, ticket: old))                    // old result discarded, newer ticket untouched
    #expect(g.isCurrent(pid: 7, ticket: fresh, generation: gen2))
    #expect(g.begin(pid: 7, generation: gen2, hasObserver: false) == nil)   // a retry can't replace an inflight acquisition
    #expect(g.finish(pid: 7, ticket: fresh))
    #expect(g.begin(pid: 7, generation: gen2, hasObserver: true) == nil)    // already observed
    #expect(g.begin(pid: 7, generation: gen2, hasObserver: false) != nil)
}
