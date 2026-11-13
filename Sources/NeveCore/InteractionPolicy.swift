// AGENT HEADER - Sources/NeveCore/InteractionPolicy.swift  (the ONE cursor/Option/button policy, shared by the app's Overlay and Neve Lab's LabWorld; no AppKit)
// Role: `InteractionTarget` (the SnowField calls the policy needs; SnowField conforms below; Overlay conforms as the app adapter; tests use a mock) and `InteractionPolicy` (value type holding what Overlay used to keep in `held`, `heldTree`, `pressing`, `lastDragTime`, `lostRelease`, `lastCursor`).
//   Events: `mouseDown` (order gifts -> tree -> existing ball -> scoop; needs Option; `hitGate` true = also only when the point is over something interactive, the lab; the app passes false because its panel already gated the click by the previous frame's hit test), `mouseDragged`, `buttonUp` (the real mouse-up: a throw when the last drag event is < 0.08 s old),
//   `cancel` (pauseLink: let go without throw, no longer pressing), `cancelTree` (tree removed by the menu), `reset` (geometry rebuild: drop hold, forget the last cursor), `clear` (field cleared: drop hold),
//   `tick` (once per frame BEFORE field.step: Option released while holding -> let go without throw; no button for > 0.1 s while holding = lost release -> let go without throw; one cursor sweep segment per frame when no Option / left button / hold, `canSweep`, not the first frame, segment within 80 pt of the screen; optionHeld; pointer position + velocity; returns `Tick` = interactive verdict for the panel + the sweep/velocity facts the app's frame-rate heuristic needs).
// Coordinates: `tick` takes the cursor in GLOBAL points and the screen `origin` (the lab passes origin .zero); every target call gets screen-local simulation coordinates (y-up). Times in seconds on one clock.
// Intentional differences left (the app's adapter supplies them through parameters): (1) `canInteract` (app: showing && !suspended; lab: always), `canSweep` (app: not still mode), `leftDown` (app: left button only for the sweep, any button for lost release / pressing; lab: one button), `slowmo` (NEVE_SLOWMO; lab 1).
//   (2) The tree drag crossing to a neighbour screen is the app adapter's: it implements dragTree / releaseTree on the overlay that now hosts the tree; the policy only knows "a tree is held". (3) Lab only: fixed 30 Hz window poll, no Dock / Mission Control / Spaces / compact mode / still mode / scenes / FakePointer (inputs are virtual: Option and buttons are parameters, not NSEvent reads).
// Tests: Tests/NeveCoreTests/PolicyTests.swift (mock target, incl. recorded sequences mirroring the old Overlay paths); LabWorld tests in Tests/NeveLabCoreTests.

import CoreGraphics
import Foundation

public protocol InteractionTarget: AnyObject {
    var optionHeld: Bool { get set }
    func hitTest(point: CGPoint) -> Bool
    func openGift(at p: CGPoint) -> Bool
    func pickTree(at p: CGPoint) -> Bool
    func dragTree(to p: CGPoint, dt: Float)
    func releaseTree(throwing: Bool)
    func pickSnowball(at p: CGPoint) -> Int?
    func scoop(at p: CGPoint) -> Int?
    func drag(_ id: Int, to p: CGPoint, dt: Float)
    func drop(_ id: Int, throwing: Bool)
    func plow(from a: CGPoint, to b: CGPoint, dt: Float)
    func setPointer(_ p: SIMD2<Float>?, velocity: SIMD2<Float>)
}

extension SnowField: InteractionTarget {
    public func plow(from a: CGPoint, to b: CGPoint, dt: Float) { sweep(from: a, to: b, dt: dt) }
}

public struct InteractionPolicy: Sendable {
    public enum Held: Equatable, Sendable { case ball(Int), tree }
    public enum Press: Equatable, Sendable { case passThrough, gift, tree, ball(Int), scoop(Int), nothing }
    public static let throwWindow = 0.08, lostReleaseLimit = 0.1

    public private(set) var held: Held?
    public private(set) var pressing = false
    public private(set) var interactive = false
    private var lastDragTime = 0.0, lostRelease = 0.0, lastCursor: CGPoint?
    public init() {}

    public var holding: Bool { held != nil }

    /// Left press. Not ours (no Option, or nothing interactive under the point): the click passes through and nothing happens.
    public mutating func mouseDown(at p: CGPoint, option: Bool, hitGate: Bool = true, now: Double, on t: InteractionTarget) -> Press {
        guard option, !hitGate || t.hitTest(point: p) else { return .passThrough }
        pressing = true
        if t.openGift(at: p) { return .gift }
        if t.pickTree(at: p) { held = .tree; lastDragTime = now; return .tree }
        lastDragTime = now
        if let id = t.pickSnowball(at: p) { held = .ball(id); return .ball(id) }
        if let id = t.scoop(at: p) { held = .ball(id); return .scoop(id) }
        return .nothing
    }

    /// Mouse moved with the button down.
    public mutating func mouseDragged(to p: CGPoint, now: Double, on t: InteractionTarget) {
        let dt = Float(max(now - lastDragTime, 1.0 / 240))
        switch held {
        case .tree: t.dragTree(to: p, dt: dt)
        case .ball(let id): t.drag(id, to: p, dt: dt)
        case nil: return
        }
        lastDragTime = now
    }

    /// The real mouse-up event: a pause before letting go is not a throw.
    public mutating func buttonUp(now: Double, on t: InteractionTarget) {
        pressing = false
        release(throwing: now - lastDragTime < Self.throwWindow, on: t)
    }

    private mutating func release(throwing: Bool, on t: InteractionTarget) {
        guard let h = held else { return }
        held = nil
        switch h {
        case .tree: t.releaseTree(throwing: throwing)
        case .ball(let id): t.drop(id, throwing: throwing)
        }
    }

    /// Let go without a throw and stop being "pressing" (the link pauses: a paused tick can no longer do it).
    public mutating func cancel(on t: InteractionTarget) { release(throwing: false, on: t); pressing = false }
    /// The menu removed the tree: a tree drag ends with it.
    public mutating func cancelTree() { if held == .tree { held = nil; pressing = false } }
    /// The field was cleared: forget the hold without calling the target.
    public mutating func clear() { held = nil; pressing = false }
    /// Geometry rebuilt: forget the hold and the last cursor.
    public mutating func reset() { clear(); lastCursor = nil }

    public struct Tick: Sendable {
        public var interactive: Bool
        public var sweeping: Bool          // a sweep segment was due (before the 80 pt screen test)
        public var from: CGPoint           // previous cursor (global; = cursor when there was none)
        public var moved: SIMD2<Float>     // pointer velocity as handed to the field
    }

    /// One frame, before the simulation step. `resumed` = first frame (no sweep, zero velocity). `buttonDown` = any button, `leftDown` = left button (default: same).
    @discardableResult
    public mutating func tick(cursor: CGPoint, origin: CGPoint = .zero, option: Bool, buttonDown: Bool, leftDown: Bool? = nil, realDt: Double, resumed: Bool, screen: CGSize,
                              canInteract: Bool = true, canSweep: Bool = true, slowmo: Float = 1, on t: InteractionTarget) -> Tick {
        let here = CGPoint(x: cursor.x - origin.x, y: cursor.y - origin.y)
        if holding, !option { release(throwing: false, on: t) }   // Option let go mid-drag
        if !buttonDown { pressing = false }
        if holding, !buttonDown { lostRelease += realDt; if lostRelease > Self.lostReleaseLimit { release(throwing: false, on: t) } } else { lostRelease = 0 }
        let frame = CGRect(origin: origin, size: screen)
        let inside = frame.contains(cursor)
        interactive = holding || pressing || (option && !buttonDown && canInteract && inside && t.hitTest(point: here))
        let prev = lastCursor ?? cursor
        let sweeping = !resumed && canSweep && lastCursor != nil && prev != cursor && !(leftDown ?? buttonDown) && !option && !holding
        let from = CGPoint(x: prev.x - origin.x, y: prev.y - origin.y)
        // A segment that never comes within 80 pt (sweep radius + the tallest pile / figure) of the screen cuts nothing.
        let near = CGRect(origin: .zero, size: screen).insetBy(dx: -80, dy: -80).intersects(CGRect(x: min(from.x, here.x), y: min(from.y, here.y), width: max(abs(here.x - from.x), 1), height: max(abs(here.y - from.y), 1)))
        if sweeping, near { t.plow(from: from, to: here, dt: Float(max(realDt * Double(slowmo), 1.0 / 240))) }
        let moved = FrameRate.pointerVelocity(dx: Float(cursor.x - prev.x), dy: Float(cursor.y - prev.y), realDt: realDt, slowmo: slowmo)
        t.optionHeld = option
        t.setPointer(inside ? SIMD2(Float(here.x), Float(here.y)) : nil, velocity: resumed ? .zero : moved)
        lastCursor = cursor
        return Tick(interactive: interactive, sweeping: sweeping, from: prev, moved: moved)   // unzeroed on the first frame, like the app's local
    }
}
