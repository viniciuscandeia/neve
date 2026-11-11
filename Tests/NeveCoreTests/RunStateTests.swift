// AGENT HEADER - Tests/NeveCoreTests/RunStateTests.swift  (RunState predicates: running/polling/rendering per pause reason; idleAction: melt after the timeout unless ambient/scene/already idle, wake on fresh input. Related: RunState.swift.)

import Testing
@testable import NeveCore

@Test func runStatePredicates() {
    var s = RunState()
    #expect(s.running(enabled: true) && s.polling(enabled: true, hot: false) && s.rendering(enabled: true, hot: false, userIdle: false))
    #expect(!s.running(enabled: false))
    s.outroing = true
    #expect(s.running(enabled: false))   // the outro keeps it up
    #expect(s.running(enabled: true) && !s.polling(enabled: true, hot: true))
    #expect(!s.rendering(enabled: true, hot: false, userIdle: true))
    for set in [{ s.screensAsleep = true }, { s.sessionInactive = true }, { s.screensaver = true }] {
        s = RunState(); set()
        #expect(!s.running(enabled: true))
    }
}

@Test func idleActionMeltsAndWakes() {
    func a(_ since: Double, idle: Bool = false, melting: Bool = false, ambient: Bool = false, scene: Bool = false, gap: Double = 2) -> IdleAction {
        idleAction(since: since, userIdle: idle, idleMelting: melting, ambient: ambient, scene: scene, idleSecs: 300, timerGap: gap)
    }
    #expect(a(299) == .none && a(300) == .melt)
    #expect(a(400, ambient: true) == .none && a(400, scene: true) == .none)
    #expect(a(400, idle: true) == .none && a(400, melting: true) == .none)
    #expect(a(1, idle: true) == .wake && a(1, melting: true) == .wake)
    #expect(a(2.4, idle: true) == .wake && a(2.5, idle: true) == .none)
    #expect(a(5.4, idle: true, gap: 5) == .wake && a(5.5, idle: true, gap: 5) == .none)
}
