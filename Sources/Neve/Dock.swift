import NeveCore
import AppKit
import ApplicationServices

/// Finds the Dock bar frame through the Accessibility API (needs trust). Only a bottom Dock counts.
@MainActor
final class DockWatcher {
    /// Bar frame in global AppKit coordinates, nil when untrusted / hidden / on the side.
    private(set) var frame: CGRect?
    private var busy = false

    /// Async refresh off the main thread; `done` runs on main only if the frame changed.
    func refresh(primaryHeight: CGFloat, done: @escaping @MainActor () -> Void) {
        guard AXIsProcessTrusted() else {
            if frame != nil { frame = nil; done() }
            return
        }
        guard !busy else { return }
        busy = true
        Task.detached(priority: .utility) {
            let cg = queryDockBar()
            await MainActor.run { [self] in
                busy = false
                let new = cg.map { appKitFrame(fromCG: $0, primaryHeight: primaryHeight) }
                if new != frame { frame = new; done() }
            }
        }
    }
}

/// Dock's AXList child = the bar. nil when the Dock is on a side or not found.
private func queryDockBar() -> CGRect? {
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
          let kids = value as? [AXUIElement] else { return nil }
    for k in kids {
        var role: CFTypeRef?, pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(k, kAXRoleAttribute as CFString, &role) == .success, role as? String == "AXList",
              AXUIElementCopyAttributeValue(k, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(k, kAXSizeAttribute as CFString, &size) == .success else { continue }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
              s.width > s.height * 1.5 else { return nil }
        return CGRect(origin: p, size: s)
    }
    return nil
}
