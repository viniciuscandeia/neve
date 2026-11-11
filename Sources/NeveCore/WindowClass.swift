import CoreGraphics
import Foundation

public enum WindowClass: Equatable, Sendable { case surface, occluder, ignore }

/// Window-server owners that are never snow-bearing (their windows sit above layer 0 too).
let systemOwners: Set<String> = ["Dock", "Window Server", "Control Center", "Notification Center", "SystemUIServer", "Spotlight", "loginwindow"]

/// One class per raw window (same order). Layer 0: a surface. Layers 1...20 (floating panels, HUDs, always-on-top windows): a surface too,
/// except an occluder only (it hides snow, holds none) when it is under 40x20 or a larger window of the same process intersects it
/// (a toolbar / inspector palette of that app); system owners and Neve's own windows are ignored; everything else (menu bar, > 20) is ignored.
public func classifyWindows(_ raw: [RawWindow], ownPID: Int? = nil, screens: [CGRect] = []) -> [WindowClass] {
    raw.map { w in
        guard let layer = w.layer else { return .ignore }
        if layer == 0 { return .surface }
        guard (1...20).contains(layer), let r = w.bounds else { return .ignore }
        if let o = w.owner, systemOwners.contains(o) { return .ignore }
        if let p = w.pid, p == ownPID { return .ignore }
        // A screen dimmer / overlay of another app (>= 90% of a screen): neither a surface nor an occluder.
        if screens.contains(where: { s in
            let i = r.intersection(s)
            return !i.isNull && i.width * i.height >= 0.9 * s.width * s.height
        }) { return .ignore }
        if r.width < 40 || r.height < 20 { return .occluder }
        let area = r.width * r.height
        let sibling = raw.contains { o in
            o.pid != nil && o.pid == w.pid && o.number != w.number && (o.layer ?? 99) <= 20
                && (o.bounds.map { $0.width * $0.height > area && $0.intersects(r) } ?? false)
        }
        return sibling ? .occluder : .surface
    }
}

/// Mission Control (Exposé): live data shows no Dock window above layer 20. Normally the Dock owns exactly ONE full-screen window at layer 20 (named "Dock")
/// plus a wallpaper window at a huge negative layer; Mission Control adds a second full-screen Dock window at layer 20 and a third at 18. So: two or more
/// Dock-owned windows with layer 18...20 and alpha > 0.3, each covering a whole screen, on the same screen. Titles are not used (they need Screen Recording).
/// `screens` in the same (CG) coordinates as the raw bounds.
public func isMissionControl(_ raw: [RawWindow], screens: [CGRect]) -> Bool {
    screens.contains { sc in
        raw.filter { w in
            guard w.owner == "Dock", (18...20).contains(w.layer ?? 0), w.alpha > 0.3, let r = w.bounds else { return false }
            return r.insetBy(dx: -1, dy: -1).contains(sc)
        }.count >= 2
    }
}

/// Mission Control suspension as a state machine fed one raw read per poll: it suspends after 2 consecutive positive reads, releases on the first
/// negative one (or `release`: Esc / click), and a watchdog forces release after `maxSeconds`; after a forced / manual release it stays off until a negative read.
public struct MissionControlGate: Sendable {
    public private(set) var active = false
    public private(set) var hits = 0
    private var since = 0.0, latched = false, lastPositive = false
    public static let maxSeconds = 15.0
    public init() {}
    /// True when a positive read is still unconfirmed (the caller should look again soon).
    public var pending: Bool { hits > 0 && !active }
    /// `strong`: the read was triggered by a change of the on-screen window list (see `WindowIDWatch`), so one positive read is enough.
    /// True while the window list is still the Exposé layout (suspended, or released by Esc / watchdog but reads still positive): the caller must not touch the piles.
    public var holdsPiles: Bool { active || (latched && lastPositive) }
    @discardableResult public mutating func read(_ positive: Bool, now: Double, strong: Bool = false) -> Bool {
        lastPositive = positive
        guard positive else { hits = 0; active = false; latched = false; return false }
        if latched { return false }
        hits += 1
        if active, now - since > Self.maxSeconds { active = false; latched = true; hits = 0; return false }
        if !active, hits >= (strong ? 1 : 2) { active = true; since = now }
        return active
    }
    public mutating func release() { if active || hits > 0 { latched = true }; active = false; hits = 0 }
}

/// The screen saver's host process (modern engine or the legacy sandbox host).
public func isScreensaverEngine(_ bundleID: String?) -> Bool { bundleID == "com.apple.ScreenSaver.Engine" || bundleID == "com.apple.ScreenSaver.legacyScreenSaver" || bundleID == "com.apple.legacyScreenSaver" }

/// Menu-bar item: ⌥-click opens Ajustes directly. ⌃⌥ is VoiceOver's modifier pair, and a keyboard open (no mouse event) must still show the menu.
public func optionClickOpensSettings(option: Bool, control: Bool, mouse: Bool) -> Bool { option && !control && mouse }


/// Cheap change detector for the on-screen window ID list (front to back): Mission Control adds Dock windows, so the list changes ~at once.
public struct WindowIDWatch: Sendable {
    private var last: [Int]?
    public init() {}
    /// True when `ids` differs from the previous call's (the first call counts as a change).
    public mutating func changed(_ ids: [Int]) -> Bool { defer { last = ids }; return ids != last }
}
