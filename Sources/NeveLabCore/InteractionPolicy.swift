// AGENT HEADER - Sources/NeveLabCore/InteractionPolicy.swift  (pure cursor/Option/button policy, mirror of Overlay's input logic, no AppKit)
// Role: `InteractionTarget` (the SnowField calls the policy needs; SnowField conforms below; tests use a mock) and `InteractionPolicy` (value type holding what Overlay keeps in `held`, `heldTree`, `pressing`, `lastDragTime`, `lostRelease`, `lastCursor`).
//   Events: `mouseDown` (order gifts -> tree -> existing ball -> scoop, only when Option is down and the point is over something interactive), `mouseDragged`, `buttonUp` (the real mouse-up event: a throw when the last drag event is < 0.08 s old),
//   `tick` (once per frame BEFORE field.step: Option released while holding -> let go without throw; button no longer down for > 0.1 s while holding = lost release -> let go without throw; one cursor sweep segment per frame when not Option / button / holding and not the first frame; pointer position + velocity; optionHeld; returns whether the panel would be interactive).
// Coordinates: simulation coordinates (y-up, screen-local pt); times in seconds on one clock. Written so Overlay can later replace its AppKit logic by calling this (events -> adapters).
// Differences vs Overlay (the app is unchanged): (1) the app gates a click by the panel's `ignoresMouseEvents`, refreshed each tick (hit test of the PREVIOUS frame's cursor); `mouseDown` here tests Option + hitTest at press time. (2) The app's tree drag crosses to a neighbour screen's field (single screen here).
//   (3) The app reads Option / buttons from NSEvent each tick; here they are inputs. (4) Overlay.mouseUp(throwing:) leaves `pressing` set until the button state shows 0 or the real up event; same here (`buttonUp` / tick clear it). (5) Not mirrored: panel hitTest rules for `showing`/`suspended`, still-mode link pause, slowmo, scene mode (cursor ignored), FakePointer.
// Tests: Tests/NeveLabCoreTests/PolicyTests.swift.

import CoreGraphics
import Foundation
import NeveCore

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
    public mutating func mouseDown(at p: CGPoint, option: Bool, now: Double, on t: InteractionTarget) -> Press {
        guard option, t.hitTest(point: p) else { return .passThrough }
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

    /// One frame, before the simulation step. `resumed` = first frame (no sweep, zero velocity). Returns whether the overlay panel would take the mouse.
    @discardableResult
    public mutating func tick(cursor: CGPoint, option: Bool, buttonDown: Bool, realDt: Double, resumed: Bool, screen: CGSize, on t: InteractionTarget) -> Bool {
        if holding, !option { release(throwing: false, on: t) }   // Option let go mid-drag
        if !buttonDown { pressing = false }
        if holding, !buttonDown { lostRelease += realDt; if lostRelease > Self.lostReleaseLimit { release(throwing: false, on: t) } } else { lostRelease = 0 }
        let inside = CGRect(origin: .zero, size: screen).contains(cursor)
        interactive = holding || pressing || (option && !buttonDown && inside && t.hitTest(point: cursor))
        let prev = lastCursor ?? cursor
        let sweeping = !resumed && lastCursor != nil && prev != cursor && !buttonDown && !option && !holding
        // A segment that never comes within 80 pt of the screen cuts nothing.
        let near = CGRect(origin: .zero, size: screen).insetBy(dx: -80, dy: -80).intersects(CGRect(x: min(prev.x, cursor.x), y: min(prev.y, cursor.y), width: max(abs(cursor.x - prev.x), 1), height: max(abs(cursor.y - prev.y), 1)))
        if sweeping, near { t.plow(from: prev, to: cursor, dt: Float(max(realDt, 1.0 / 240))) }
        let moved = FrameRate.pointerVelocity(dx: Float(cursor.x - prev.x), dy: Float(cursor.y - prev.y), realDt: realDt)
        t.optionHeld = option
        t.setPointer(inside ? SIMD2(Float(cursor.x), Float(cursor.y)) : nil, velocity: resumed ? .zero : moved)
        lastCursor = cursor
        return interactive
    }
}
