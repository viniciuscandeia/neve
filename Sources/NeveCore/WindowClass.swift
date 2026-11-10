import CoreGraphics
import Foundation

public enum WindowClass: Equatable, Sendable { case surface, occluder, ignore }

/// Window-server owners that are never snow-bearing (their windows sit above layer 0 too).
let systemOwners: Set<String> = ["Dock", "Window Server", "Control Center", "Notification Center", "SystemUIServer", "Spotlight", "loginwindow"]

/// One class per raw window (same order). Layer 0: a surface. Layers 1...20 (floating panels, HUDs, always-on-top windows): a surface too,
/// except an occluder only (it hides snow, holds none) when it is under 40x20 or a larger window of the same process intersects it
/// (a toolbar / inspector palette of that app); system owners and Neve's own windows are ignored; everything else (menu bar, > 20) is ignored.
public func classifyWindows(_ raw: [RawWindow], ownPID: Int? = nil) -> [WindowClass] {
    raw.map { w in
        guard let layer = w.layer else { return .ignore }
        if layer == 0 { return .surface }
        guard (1...20).contains(layer), let r = w.bounds else { return .ignore }
        if let o = w.owner, systemOwners.contains(o) { return .ignore }
        if let p = w.pid, p == ownPID { return .ignore }
        if r.width < 40 || r.height < 20 { return .occluder }
        let area = r.width * r.height
        let sibling = raw.contains { o in
            o.pid != nil && o.pid == w.pid && o.number != w.number && (o.layer ?? 99) <= 20
                && (o.bounds.map { $0.width * $0.height > area && $0.intersects(r) } ?? false)
        }
        return sibling ? .occluder : .surface
    }
}

/// Mission Control (Exposé): the Dock owns a window above layer 20 that covers a whole screen. The title needs Screen Recording, so it is not used.
/// `screens` in the same (CG) coordinates as the raw bounds.
public func isMissionControl(_ raw: [RawWindow], screens: [CGRect]) -> Bool {
    raw.contains { w in
        guard w.owner == "Dock", (w.layer ?? 0) > 20, let r = w.bounds else { return false }
        return screens.contains { r.insetBy(dx: -1, dy: -1).contains($0) }
    }
}
