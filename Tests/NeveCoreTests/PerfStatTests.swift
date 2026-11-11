// AGENT HEADER - Tests/NeveCoreTests/PerfStatTests.swift  (PerfStat: ms per frame vs per second)

import Testing
@testable import NeveCore

@Suite struct PerfStatTests {
    @Test func perFrameAndPerSecond() {
        var s = PerfStat()
        s.add(2_000_000); s.add(4_000_000)   // 6 ms over 2 samples
        #expect(s.n == 2 && s.peakMs == 4)
        #expect(s.msPerFrame(3) == 2)        // per presented frame, not per sample (1 frame had no sample)
        #expect(s.msPerSecond(2) == 3)
        #expect(PerfStat().msPerFrame(0) == 0)
    }
}
