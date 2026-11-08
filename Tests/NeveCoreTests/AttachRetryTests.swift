import Testing
@testable import NeveCore

@Test func attachRetryIsBoundedAndBacksOff() {
    #expect(AttachRetry.delay(afterFailedAttempt: 1) == 1)
    #expect(AttachRetry.delay(afterFailedAttempt: 2) == 2)
    #expect(AttachRetry.delay(afterFailedAttempt: AttachRetry.maxAttempts) == nil)
    #expect(AttachRetry.delay(afterFailedAttempt: 0) == nil)
}
