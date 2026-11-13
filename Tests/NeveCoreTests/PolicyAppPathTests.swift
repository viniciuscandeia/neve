// AGENT HEADER - Tests/NeveCoreTests/PolicyAppPathTests.swift  (InteractionPolicy driven the way the app's Overlay adapter drives it, against PolicyMock)
// Role: recorded event sequences mirroring the OLD Overlay code paths, asserting the same target calls: press without hit test (hitGate false) gated only by Option, scoop / roll / carry / throw (0.08 s window, 1/240 dt floor),
//   Option released mid-drag (let go, no throw, `pressing` kept until the button is up), lost release (> 0.1 s, counter reset by a held button), tree hold + cancelTree (menu) + cancel (pauseLink), reset / clear,
//   sweep gating (still mode, left button only, Option, no move, first frame, 80 pt screen test) with a non-zero screen origin, interactive verdict (canInteract, button, other screen). PolicyMock lives in PolicyTests.swift.

import CoreGraphics
import Testing
@testable import NeveCore

private let screen = CGSize(width: 1280, height: 800)
private let pt = CGPoint(x: 100, y: 100)
private let origin = CGPoint(x: 1440, y: 0)   // a second screen to the right

private func frame(_ p: inout InteractionPolicy, _ m: PolicyMock, cursor: CGPoint, option: Bool, buttons: Int = 0, dt: Double = 1.0 / 60, resumed: Bool = false, still: Bool = false, interactive: Bool = true) -> InteractionPolicy.Tick {
    p.tick(cursor: cursor, origin: origin, option: option, buttonDown: buttons != 0, leftDown: buttons & 1 != 0, realDt: dt, resumed: resumed, screen: screen, canInteract: interactive, canSweep: !still, on: m)
}

@Test func appPressHasNoHitTestAndOnlyOptionGatesIt() {   // old Overlay.mouseDown: guard option else hand the click back; the panel had gated it
    var p = InteractionPolicy(), m = PolicyMock()
    m.hit = false; m.ball = 3
    #expect(p.mouseDown(at: pt, option: false, hitGate: false, now: 0, on: m) == .passThrough && m.log.isEmpty && !p.pressing)
    #expect(p.mouseDown(at: pt, option: true, hitGate: false, now: 0, on: m) == .ball(3) && p.pressing && p.held == .ball(3))
}

@Test func pressScoopCarryThrowSequence() {
    var p = InteractionPolicy(), m = PolicyMock()
    m.scooped = 7
    #expect(p.mouseDown(at: pt, option: true, hitGate: false, now: 10, on: m) == .scoop(7))
    p.mouseDragged(to: CGPoint(x: 120, y: 100), now: 10.016, on: m)
    p.mouseDragged(to: CGPoint(x: 140, y: 100), now: 10.1, on: m)
    p.buttonUp(now: 10.14, on: m)   // 0.04 s since the last drag: throw
    #expect(m.log.count == 7 && Array(m.log.prefix(4)) == ["gift", "tree", "pick", "scoop"] && m.log[4].hasPrefix("drag 7 0.016") && m.log[5].hasPrefix("drag 7 0.08") && m.log[6] == "drop 7 true")
    #expect(!p.holding && !p.pressing)
    m.log = []; m.scooped = nil; m.ball = 2   // existing ball; drag dt floor 1/240; a pause of over 0.08 s before release is no throw
    _ = p.mouseDown(at: pt, option: true, hitGate: false, now: 20, on: m)
    p.mouseDragged(to: pt, now: 20, on: m)
    p.buttonUp(now: 20.125, on: m)
    #expect(m.log.last == "drop 2 false" && m.log.contains { $0.hasPrefix("drag 2 0.004") })
}

@Test func optionReleasedMidDragLetsGoWithoutThrowAndKeepsPressingUntilButtonUp() {
    var p = InteractionPolicy(), m = PolicyMock()
    m.ball = 1
    _ = p.mouseDown(at: pt, option: true, hitGate: false, now: 0, on: m)
    let c = CGPoint(x: origin.x + 100, y: 100)
    let r = frame(&p, m, cursor: c, option: false, buttons: 1)
    #expect(m.log.last == "drop 1 false" && !p.holding && p.pressing && r.interactive)   // the up event is still ours
    _ = frame(&p, m, cursor: c, option: false, buttons: 0)
    #expect(!p.pressing)
}

@Test func lostReleaseAfterMoreThanATenthOfASecond() {   // Cmd-Tab: the mouse-up never arrives
    var p = InteractionPolicy(), m = PolicyMock()
    m.ball = 1
    _ = p.mouseDown(at: pt, option: true, hitGate: false, now: 0, on: m)
    let c = CGPoint(x: origin.x + 100, y: 100)
    for _ in 0..<2 { _ = frame(&p, m, cursor: c, option: true, buttons: 1) }   // button down: counter stays 0
    var n = 0
    while p.holding && n < 20 { _ = frame(&p, m, cursor: c, option: true, buttons: 0); n += 1 }
    #expect(n == 7 && m.log.last == "drop 1 false")   // 7 / 60 > 0.1, 6 / 60 is not
    p = InteractionPolicy(); m.log = []
    _ = p.mouseDown(at: pt, option: true, hitGate: false, now: 0, on: m)
    for _ in 0..<5 { _ = frame(&p, m, cursor: c, option: true, buttons: 0) }
    _ = frame(&p, m, cursor: c, option: true, buttons: 1)   // a held button resets the counter
    for _ in 0..<5 { _ = frame(&p, m, cursor: c, option: true, buttons: 0) }
    #expect(p.holding)
}

@Test func treeHoldRulesCancelTreeAndCancel() {
    var p = InteractionPolicy(), m = PolicyMock()
    m.tree = true
    #expect(p.mouseDown(at: pt, option: true, hitGate: false, now: 0, on: m) == .tree)
    p.mouseDragged(to: pt, now: 0.02, on: m)
    p.buttonUp(now: 0.03, on: m)
    #expect(m.log.count == 4 && m.log[2].hasPrefix("dragTree 100.0 0.02") && m.log[3] == "releaseTree true")
    p = InteractionPolicy(); m.log = []
    _ = p.mouseDown(at: pt, option: true, hitGate: false, now: 0, on: m)
    p.cancelTree()   // the menu removed the tree: no target call
    #expect(!p.holding && !p.pressing && m.log.last == "tree")
    _ = p.mouseDown(at: pt, option: true, hitGate: false, now: 0, on: m)
    p.cancel(on: m)   // pauseLink
    #expect(m.log.last == "releaseTree false" && !p.holding && !p.pressing)
    m.tree = false; m.ball = 4
    _ = p.mouseDown(at: pt, option: true, hitGate: false, now: 0, on: m)
    p.cancelTree()
    #expect(p.held == .ball(4))   // a held ball is not a tree
}

@Test func resetAndClearForgetTheHold() {
    var p = InteractionPolicy(), m = PolicyMock()
    m.ball = 1
    let c = CGPoint(x: origin.x + 100, y: 100), d = CGPoint(x: origin.x + 160, y: 100)
    _ = frame(&p, m, cursor: c, option: false, resumed: true)
    _ = p.mouseDown(at: pt, option: true, hitGate: false, now: 0, on: m)
    p.clear()
    #expect(!p.holding && !p.pressing)
    p.reset()   // the last cursor is forgotten: the next frame cannot sweep
    m.log = []
    _ = frame(&p, m, cursor: d, option: false)
    #expect(m.log.isEmpty)
    _ = frame(&p, m, cursor: c, option: false)
    #expect(m.log == ["plow"])
}

@Test func sweepGatingMatchesTheApp() {
    var p = InteractionPolicy(), m = PolicyMock()
    let a = CGPoint(x: origin.x + 100, y: 100), b = CGPoint(x: origin.x + 160, y: 100)
    _ = frame(&p, m, cursor: a, option: false, resumed: true)
    var t = frame(&p, m, cursor: b, option: false, still: true)   // still mode: no sweep
    #expect(m.log.isEmpty && !t.sweeping)
    t = frame(&p, m, cursor: a, option: false)
    #expect(m.log == ["plow"] && t.sweeping && t.from == b)
    m.log = []
    _ = frame(&p, m, cursor: b, option: false, buttons: 1)   // left button: none
    #expect(m.log.isEmpty)
    _ = frame(&p, m, cursor: a, option: false, buttons: 2)   // right button only: the app still sweeps
    #expect(m.log == ["plow"])
    m.log = []
    _ = frame(&p, m, cursor: b, option: true)    // Option: none
    _ = frame(&p, m, cursor: b, option: false)   // not moved: none
    #expect(m.log.isEmpty)
    _ = frame(&p, m, cursor: CGPoint(x: origin.x - 3000, y: 100), option: false); m.log = []   // a segment far from this screen: reported, not plowed
    t = frame(&p, m, cursor: CGPoint(x: origin.x - 3100, y: 100), option: false)
    #expect(t.sweeping && m.log.isEmpty && m.pointer == nil)
}

@Test func interactiveVerdictAndLocalCoordinates() {
    var p = InteractionPolicy(), m = PolicyMock()
    let c = CGPoint(x: origin.x + 100, y: 120)
    _ = frame(&p, m, cursor: c, option: false, resumed: true)
    #expect(frame(&p, m, cursor: c, option: true).interactive)
    #expect(m.pointer == SIMD2(100, 120) && m.optionHeld)   // the target gets screen-local coordinates
    #expect(!frame(&p, m, cursor: c, option: true, interactive: false).interactive)   // hidden / suspended
    #expect(!frame(&p, m, cursor: c, option: true, buttons: 1).interactive)           // button down, not holding
    #expect(!frame(&p, m, cursor: CGPoint(x: 0, y: 0), option: true).interactive)     // the cursor is on another screen
}

@Test func firstFrameHasNoSweepAndZeroPointerVelocity() {
    var p = InteractionPolicy(), m = PolicyMock()
    let t = frame(&p, m, cursor: CGPoint(x: origin.x + 100, y: 100), option: false, resumed: true)
    #expect(m.velocity == .zero && !t.sweeping && t.moved == .zero)
}
