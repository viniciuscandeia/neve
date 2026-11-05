import NeveCore
import AppKit
import ApplicationServices

/// Finds the Dock bar frame through the Accessibility API (needs trust). Only a bottom Dock counts.
@MainActor
final class DockWatcher {
    /// Bar frame in global AppKit coordinates, nil when untrusted / hidden / on the side.
    private(set) var frame: CGRect?
    private var busy = false
    var onChange: (@MainActor () -> Void)?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0

    /// Subscribes to the Dock list's move/resize/destroy so no polling is needed. Idempotent; re-attaches after a Dock restart.
    func observe() {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return stop() }
        if observer != nil && pid == observedPid { return }
        stop()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var obs: AXObserver?
        guard AXObserverCreate(pid, dockCallback, &obs) == .success, let obs else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        var kids: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids)
        for k in (kids as? [AXUIElement]) ?? [] {
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(k, kAXRoleAttribute as CFString, &role) == .success, role as? String == "AXList" else { continue }
            for n in [kAXResizedNotification, kAXMovedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(obs, k, n as CFString, me)
            }
        }
        AXObserverAddNotification(obs, app, kAXCreatedNotification as CFString, me)   // list recreated
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        observedPid = pid
    }

    private func stop() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) }
        observer = nil
        observedPid = 0
    }

    fileprivate func axEvent(destroyed: Bool) {
        if destroyed { stop() }   // re-attached by the next observe()
        onChange?()
    }

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
        return CGRect(x: p.x, y: p.y + 8, width: s.width, height: s.height - 8)   // AX list includes ~8pt of transparent margin above the glass
    }
    return nil
}

/// Runs on the main run loop (source added to CFRunLoopGetMain), so main-actor isolation holds.
private let dockCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let destroyed = (notification as String) == kAXUIElementDestroyedNotification
    let watcher = Unmanaged<DockWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.axEvent(destroyed: destroyed) }
}
