import CoreGraphics
import Testing
@testable import NeveCore

@Test func dragToleranceScalesWithMouseDelta() {
    let a = win(1, 100, 100, 300, 200)
    let fast = CGVector(dx: 200, dy: 0)   // the window lags the mouse by 30 pt: more than 8, within 30 %
    #expect(dragTarget(prev: [a], cur: [win(1, 270, 100, 300, 200)], mouseDelta: fast) == 1)
    #expect(dragTarget(prev: [a], cur: [win(1, 270, 100, 300, 200)], mouseDelta: fast, tol: 8) == nil)
    #expect(dragTarget(prev: [a], cur: [win(1, 150, 100, 300, 200)], mouseDelta: CGVector(dx: 10, dy: 0)) == nil)   // slow: still strict
}

@Test func dragTargetIsKeptUntilReleaseAndSwitchesOnlyOnAClearMatch() {
    let a = win(1, 100, 100, 300, 200), b = win(2, 600, 100, 300, 200), screens = [CGRect(x: 0, y: 0, width: 2000, height: 1000)]
    var t = DragTracker()
    let a2 = win(1, 150, 100, 300, 200)
    t.read(down: true, moved: true, prev: [a, b], cur: [a2, b], mouseDelta: CGVector(dx: 50, dy: 0), screens: screens)
    #expect(t.target == 1)
    t.read(down: true, moved: false, prev: [a2, b], cur: [a2, b], mouseDelta: .zero, screens: screens)   // identical snapshot: kept
    #expect(t.target == 1)
    t.read(down: true, moved: true, prev: [a2, b], cur: [a2, win(2, 640, 100, 300, 200)], mouseDelta: CGVector(dx: 40, dy: 0), screens: screens)
    #expect(t.target == 2)
    t.read(down: false, moved: false, prev: [a2, b], cur: [a2, b], mouseDelta: .zero, screens: screens)
    #expect(t.target == nil)
}

@Test func exemptWindowClearsOnOutsidePressOrWhenBackOnScreen() {
    let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
    let a = win(1, 100, 100, 300, 200), off = win(1, 950, 100, 300, 200)   // 50 of 300 wide on screen: mostly off
    func dragged() -> DragTracker {
        var t = DragTracker()
        t.read(down: true, moved: true, prev: [a], cur: [off], mouseDelta: CGVector(dx: 800, dy: 0), screens: screens)
        #expect(t.exempt == 1)
        return t
    }
    var t = dragged()
    t.read(down: false, moved: false, prev: [off], cur: [off], mouseDelta: .zero, screens: screens)
    #expect(t.exempt == 1)                                   // survives the release while it stays off screen
    t.pressed(at: CGPoint(x: 990, y: 150), windows: [off])   // press on it: kept
    #expect(t.exempt == 1)
    t.pressed(at: CGPoint(x: 10, y: 10), windows: [off])     // press elsewhere: cleared
    #expect(t.exempt == nil)
    t = dragged()
    t.read(down: false, moved: false, prev: [off], cur: [a], mouseDelta: .zero, screens: screens)   // back on screen
    #expect(t.exempt == nil)
}

@Test func extraReadComesAfterTheBurstEnds() {
    var s = PollScheduler()
    s.settleRead(now: 100)
    #expect(s.take(now: 100.3) == nil)
    #expect(s.take(now: 100.6) == .windows)
    #expect(s.nextDue(now: 101) == nil)
}

@Test func heldButtonOnABodyPollsOnlyOnceAFrameMoves() {
    var s = PollScheduler()
    s.mouseDown(now: 0, onDesktop: false, dragPlausible: false)
    _ = s.take(now: 0.1)
    s.mouseDragged()
    #expect(s.take(now: 0.2) == nil)   // text selection: no reads
    s.mouseDown(now: 1, onDesktop: false, dragPlausible: true)
    _ = s.take(now: 1.1)
    s.mouseDragged()
    #expect(s.take(now: 1.2) == .windows)
    let w = win(1, 0, 0, 300, 200)
    #expect(dragPlausible(at: CGPoint(x: 100, y: 190), windows: [w]))      // title strip
    #expect(!dragPlausible(at: CGPoint(x: 100, y: 50), windows: [w]))      // body
    #expect(dragPlausible(at: CGPoint(x: 299, y: 50), windows: [w]))       // edge (resize)
}

@Test func frameRatesDivideThePanelRate() {
    for hz in [120, 144, 75, 60, 50] {
        for calm in [true, false] {
            for economy in [true, false] {
                let r = FrameRate.range(lowPower: false, economy: economy, shrunk: false, calm: calm, maxFPS: hz).preferred
                let k = Float(hz) / r
                #expect(abs(k - k.rounded()) < 0.001, "\(hz) Hz -> \(r)")
            }
        }
    }
    #expect(FrameRate.range(lowPower: false, economy: false, shrunk: false, calm: false, maxFPS: 120).preferred == 60)
    #expect(FrameRate.range(lowPower: false, economy: false, shrunk: false, calm: true, maxFPS: 120).preferred == 30)
    #expect(FrameRate.range(lowPower: false, economy: true, shrunk: false, calm: true, maxFPS: 120).preferred == 24)
    #expect(FrameRate.range(lowPower: false, economy: false, shrunk: false, calm: false, maxFPS: 144).preferred == 72)
    #expect(FrameRate.holdDown >= 2)
}

@Test func pointerVelocityUsesRealTimeAndSlowmo() {
    #expect(FrameRate.pointerVelocity(dx: 10, dy: 0, realDt: 0.5).x == 20)           // a stall is not clamped to 0.06
    #expect(FrameRate.pointerVelocity(dx: 10, dy: 0, realDt: 0.1, slowmo: 0.5).x == 200)
    #expect(FrameRate.pointerVelocity(dx: 10, dy: 0, realDt: 0).x.isFinite)
}

@Test func snowNearFindsPilesUnderTheCursorPathOnly() {
    let f = makeField()
    f.update(windows: [win(1, 200, 300, 300, 200)])
    pileUp(f, id: 1)
    #expect(f.snowNear(from: CGPoint(x: 300, y: 502), to: CGPoint(x: 400, y: 502)))
    #expect(!f.snowNear(from: CGPoint(x: 300, y: 700), to: CGPoint(x: 400, y: 700)))   // well above
    #expect(!f.snowNear(from: CGPoint(x: 700, y: 502), to: CGPoint(x: 800, y: 502)))   // beside the window
}
