import CoreGraphics
import Foundation

// Maximized-window mode (P3-0): how much of the usable screen windows hide, and the strip that stays live.

/// `fraction` of `area` hidden by `windows` (grid of cols x rows sampled at cell centres) and the bounding box of the uncovered cells (nil = none).
public func coverage(of windows: [CGRect], in area: CGRect, cols: Int = 48, rows: Int = 30) -> (fraction: Float, uncovered: CGRect?) {
    guard area.width > 0, area.height > 0 else { return (1, nil) }
    let cw = area.width / CGFloat(cols), ch = area.height / CGFloat(rows)
    var hidden = 0
    var box: CGRect?
    for r in 0..<rows {
        for c in 0..<cols {
            let p = CGPoint(x: area.minX + (CGFloat(c) + 0.5) * cw, y: area.minY + (CGFloat(r) + 0.5) * ch)
            if windows.contains(where: { $0.contains(p) }) { hidden += 1; continue }
            let cell = CGRect(x: area.minX + CGFloat(c) * cw, y: area.minY + CGFloat(r) * ch, width: cw, height: ch)
            box = box.map { $0.union(cell) } ?? cell
        }
    }
    return (Float(hidden) / Float(cols * rows), box)
}

/// Live region = uncovered part of `visible` plus the Dock / side strips of `frame` (menu bar excluded), clipped to `frame`. nil = nothing live.
public func liveRect(frame: CGRect, visible: CGRect, uncovered: CGRect?) -> CGRect? {
    let top = visible.maxY   // everything above is the menu bar
    let strips = [
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: visible.minY - frame.minY),
        CGRect(x: frame.minX, y: frame.minY, width: visible.minX - frame.minX, height: top - frame.minY),
        CGRect(x: visible.maxX, y: frame.minY, width: frame.maxX - visible.maxX, height: top - frame.minY),
    ]
    var r = uncovered
    for s in strips where s.width > 0 && s.height > 0 { r = r.map { $0.union(s) } ?? s }
    guard let u = r?.intersection(frame), !u.isNull, !u.isEmpty else { return nil }
    return u
}

public enum CoverState: Sendable { case normal, compact, covered }

/// Hysteresis for the maximized-window mode: enter when >= 90% of the usable area stays hidden for 0.6s,
/// leave when < 85% for 0.2s. Frozen while a mouse button is down (a window being dragged / resized).
/// `covered` = compact with a live strip under 8pt: the overlay pauses like for a fullscreen app.
public struct CompactState: Sendable {
    public static let enterAt: Float = 0.90, exitBelow: Float = 0.85, enterAfter: Float = 0.6, exitAfter: Float = 0.2, minLive: CGFloat = 8
    public private(set) var state = CoverState.normal
    var enterT: Float = 0, exitT: Float = 0
    public init() {}
    /// A change is on its way (a timer is running): a caller that is not ticking should look again soon.
    public var pending: Bool { enterT > 0 || exitT > 0 }

    @discardableResult
    public mutating func update(fraction: Float, liveHeight: CGFloat, mouseDown: Bool, dt: Float) -> CoverState {
        if mouseDown { return state }
        if state == .normal {
            guard fraction >= Self.enterAt else { enterT = 0; return state }
            enterT += dt
            if enterT >= Self.enterAfter { state = liveHeight < Self.minLive ? .covered : .compact; enterT = 0; exitT = 0 }
        } else if fraction < Self.exitBelow {
            exitT += dt
            if exitT >= Self.exitAfter { state = .normal; enterT = 0; exitT = 0 }
        } else {
            exitT = 0
            state = liveHeight < Self.minLive ? .covered : .compact
        }
        return state
    }
}

// MARK: Live region of the simulation

extension SnowField {
    /// Compact mode: flakes live (and spawn, just above the top edge = from behind the window) only in `r` (local coords);
    /// their number follows the area. nil = the whole screen. Piles are untouched.
    public func setLive(_ r: CGRect?) {
        let full = CGRect(x: 0, y: 0, width: CGFloat(size.x), height: CGFloat(size.y))
        let r = (r ?? full).intersection(full)
        liveX0 = Float(r.minX); liveX1 = Float(r.maxX); liveTop = Float(r.maxY)
        areaScale = r == full ? 1 : max(0.08, Float(r.width * r.height) / (size.x * size.y))
        setIntensity(intensity)
    }

    /// Leaving compact mode: `fraction` of the missing flakes appear anywhere, fading in.
    public func wake(fraction: Float) {
        for i in flakes.indices where flakes[i].kind == .dormant && isActive(i) && Float.random(in: 0..<1, using: &rng) < fraction {
            var f = spawn(i < skyCount ? .sky : .background, anywhere: true)
            f.fade = 0
            flakes[i] = f
        }
        skyEnd = max(skyEnd, skyLimit); bgEnd = max(bgEnd, bgLimit)
    }

    /// Flakes alive (not dormant) in the sky + background pools.
    public var activeFlakes: Int { flakes.reduce(0) { $0 + ($1.kind == .dormant ? 0 : 1) } }
}
