// AGENT HEADER - Tests/NeveCoreTests/PolicyTests.swift  (the shared InteractionPolicy against a recording mock target: no simulation involved)
// Role: pins the app's input rules in the pure policy: press order gifts -> tree -> existing ball -> scoop, Option required, throw only when the last drag event is < 0.08 s old, Option released / lost release (> 0.1 s without button) let go WITHOUT a throw,
//   one sweep per frame only when idle (no Option / button / hold, not the first frame), pointer position + velocity each frame.

import CoreGraphics
import Testing
@testable import NeveCore

final class PolicyMock: InteractionTarget {
    var optionHeld = false
    var log: [String] = []
    var hit = true, gift = false, tree = false, ball: Int?, scooped: Int?
    var pointer: SIMD2<Float>?, velocity = SIMD2<Float>.zero
    func hitTest(point: CGPoint) -> Bool { hit }
    func openGift(at p: CGPoint) -> Bool { log.append("gift"); return gift }
    func pickTree(at p: CGPoint) -> Bool { log.append("tree"); return tree }
    func dragTree(to p: CGPoint, dt: Float) { log.append("dragTree \(p.x) \(dt)") }
    func releaseTree(throwing: Bool) { log.append("releaseTree \(throwing)") }
    func pickSnowball(at p: CGPoint) -> Int? { log.append("pick"); return ball }
    func scoop(at p: CGPoint) -> Int? { log.append("scoop"); return scooped }
    func drag(_ id: Int, to p: CGPoint, dt: Float) { log.append("drag \(id) \(dt)") }
    func drop(_ id: Int, throwing: Bool) { log.append("drop \(id) \(throwing)") }
    func plow(from a: CGPoint, to b: CGPoint, dt: Float) { log.append("plow") }
    func setPointer(_ p: SIMD2<Float>?, velocity: SIMD2<Float>) { pointer = p; self.velocity = velocity }
}

private let screen = CGSize(width: 1280, height: 800)
private let pt = CGPoint(x: 100, y: 100)

@Test func pressOrderIsGiftTreeBallScoop() {
    var p = InteractionPolicy(), m = PolicyMock(), r = InteractionPolicy.Press.nothing
    r = p.mouseDown(at: pt, option: false, now: 0, on: m); #expect(r == .passThrough && m.log.isEmpty)
    m.hit = false
    r = p.mouseDown(at: pt, option: true, now: 0, on: m); #expect(r == .passThrough && m.log.isEmpty)
    m.hit = true; m.gift = true; m.tree = true; m.ball = 1; m.scooped = 2
    r = p.mouseDown(at: pt, option: true, now: 0, on: m); #expect(r == .gift && m.log == ["gift"] && !p.holding)
    m.log = []; m.gift = false
    p = InteractionPolicy()
    r = p.mouseDown(at: pt, option: true, now: 0, on: m); #expect(r == .tree && m.log == ["gift", "tree"] && p.held == .tree)
    m.log = []; m.tree = false; p = InteractionPolicy()
    r = p.mouseDown(at: pt, option: true, now: 0, on: m); #expect(r == .ball(1) && m.log == ["gift", "tree", "pick"])
    m.log = []; m.ball = nil; p = InteractionPolicy()
    r = p.mouseDown(at: pt, option: true, now: 0, on: m); #expect(r == .scoop(2) && m.log == ["gift", "tree", "pick", "scoop"] && p.held == .ball(2))
    m.scooped = nil; p = InteractionPolicy()
    r = p.mouseDown(at: pt, option: true, now: 0, on: m); #expect(r == .nothing && !p.holding && p.pressing)
}

@Test func throwOnlyWhenTheLastDragIsFresh() {
    var p = InteractionPolicy(), m = PolicyMock()
    m.ball = 1
    _ = p.mouseDown(at: pt, option: true, now: 1, on: m)
    p.mouseDragged(to: pt, now: 1.05, on: m)
    p.buttonUp(now: 1.1, on: m)
    #expect(m.log.last == "drop 1 true")
    p = InteractionPolicy(); _ = p.mouseDown(at: pt, option: true, now: 2, on: m)
    p.mouseDragged(to: pt, now: 2.01, on: m)
    p.buttonUp(now: 2.2, on: m)
    #expect(m.log.last == "drop 1 false")
    #expect(m.log.contains("drag 1 0.01") || m.log.contains { $0.hasPrefix("drag 1 0.0") })
}

@Test func optionReleaseAndLostReleaseLetGoWithoutThrow() {
    var p = InteractionPolicy(), m = PolicyMock()
    m.ball = 1
    _ = p.mouseDown(at: pt, option: true, now: 0, on: m)
    p.tick(cursor: pt, option: false, buttonDown: true, realDt: 1.0 / 60, resumed: false, screen: screen, on: m)
    #expect(m.log.last == "drop 1 false" && !p.holding)
    p = InteractionPolicy(); m.log = []
    _ = p.mouseDown(at: pt, option: true, now: 0, on: m)
    for _ in 0..<6 { p.tick(cursor: pt, option: true, buttonDown: false, realDt: 1.0 / 60, resumed: false, screen: screen, on: m) }   // 0.1 s: not yet
    #expect(p.holding)
    p.tick(cursor: pt, option: true, buttonDown: false, realDt: 1.0 / 60, resumed: false, screen: screen, on: m)
    #expect(m.log.last == "drop 1 false" && !p.holding)
}

@Test func sweepOnlyWhenIdleAndPointerEveryFrame() {
    var p = InteractionPolicy(), m = PolicyMock()
    let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 160, y: 100)
    p.tick(cursor: a, option: false, buttonDown: false, realDt: 1.0 / 60, resumed: true, screen: screen, on: m)
    #expect(m.velocity == .zero && m.pointer == SIMD2(100, 100) && !m.log.contains("plow"))
    p.tick(cursor: b, option: false, buttonDown: false, realDt: 1.0 / 60, resumed: false, screen: screen, on: m)
    #expect(m.log == ["plow"] && abs(m.velocity.x - 3600) < 1)
    m.log = []
    p.tick(cursor: a, option: true, buttonDown: false, realDt: 1.0 / 60, resumed: false, screen: screen, on: m)   // Option: no sweep
    p.tick(cursor: b, option: false, buttonDown: true, realDt: 1.0 / 60, resumed: false, screen: screen, on: m)   // button: no sweep
    p.tick(cursor: a, option: false, buttonDown: false, realDt: 1.0 / 60, resumed: false, screen: screen, on: m)   // still cursor afterwards
    p.tick(cursor: a, option: false, buttonDown: false, realDt: 1.0 / 60, resumed: false, screen: screen, on: m)
    #expect(m.log.isEmpty || m.log == ["plow"])   // only the a<-b move after the button ended may sweep
    m.log = []
    p.tick(cursor: CGPoint(x: -500, y: 100), option: false, buttonDown: false, realDt: 1.0 / 60, resumed: false, screen: screen, on: m)   // a segment that crosses the screen
    m.log = []
    p.tick(cursor: CGPoint(x: -700, y: 100), option: false, buttonDown: false, realDt: 1.0 / 60, resumed: false, screen: screen, on: m)
    #expect(m.pointer == nil && m.log.isEmpty)   // far outside the screen: no pointer, no sweep
}

@Test func interactiveOnlyOverSnowWithOptionAndNoButton() {
    var p = InteractionPolicy(), m = PolicyMock(), r = false
    r = p.tick(cursor: pt, option: false, buttonDown: false, realDt: 1.0 / 60, resumed: true, screen: screen, on: m).interactive; #expect(!r)
    r = p.tick(cursor: pt, option: true, buttonDown: false, realDt: 1.0 / 60, resumed: false, screen: screen, on: m).interactive; #expect(r)
    m.hit = false
    r = p.tick(cursor: pt, option: true, buttonDown: false, realDt: 1.0 / 60, resumed: false, screen: screen, on: m).interactive; #expect(!r)
}
