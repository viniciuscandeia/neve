import AppKit
import ApplicationServices

/// Finds the Dock bar frame through the Accessibility API (needs trust). Only a bottom Dock counts.
@MainActor
final class DockWatcher {
    /// Bar frame in global AppKit coordinates, nil when untrusted / hidden / on the side.
    private(set) var frame: CGRect?
    private var rawRect: CGRect?   // AX (top-left) coordinates; converted with current geometry at publish time
    private var busy = false, dirty = false
    private var generation = 0     // bumped when trust is lost: in-flight results are discarded
    var onChange: (@MainActor () -> Void)?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0

    /// Subscribes to the Dock list's move/resize/destroy so no polling is needed. Only counts as attached if the list subscription succeeded.
    private func attach(pid: pid_t, list: AXUIElement) {
        stop()
        var obs: AXObserver?
        guard AXObserverCreate(pid, dockCallback, &obs) == .success, let obs else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        var ok = false
        for n in [kAXResizedNotification, kAXMovedNotification, kAXUIElementDestroyedNotification] {
            if AXObserverAddNotification(obs, list, n as CFString, me) == .success { ok = true }
        }
        guard ok else { return }   // retried by the next refresh
        _ = AXObserverAddNotification(obs, AXUIElementCreateApplication(pid), kAXCreatedNotification as CFString, me)   // list recreated
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
        if destroyed { stop() }   // re-attached by the next refresh
        onChange?()
    }

    /// Async refresh off the main thread (AX reads can block); `done` runs on main only if the frame changed.
    /// Requests arriving while a query is in flight set `dirty`, so exactly one more query runs afterwards.
    func refresh(done: @escaping @MainActor () -> Void) {
        guard AXIsProcessTrusted() else {
            generation += 1
            stop()
            rawRect = nil
            if frame != nil { frame = nil; done() }
            return
        }
        guard !busy else { dirty = true; return }
        busy = true
        let gen = generation
        Task.detached(priority: .utility) {
            let q = queryDockBar()
            await MainActor.run { [self] in
                busy = false
                if gen == generation && AXIsProcessTrusted() {
                    if let pid = q.pid {
                        if let list = q.list, observer == nil || pid != observedPid { attach(pid: pid, list: list) }
                    } else { stop() }
                    rawRect = q.rect
                    let new = q.rect.flatMap { r in NSScreen.screens.first.map { appKitFrame(fromCG: r, primaryHeight: $0.frame.height) } }
                    if new != frame { frame = new; done() }
                }
                if dirty || gen != generation { dirty = false; refresh(done: done) }
            }
        }
    }
}

/// @unchecked: AXUIElement is an immutable CF handle (an IPC reference) that is never mutated here, and the AX API is safe to call from any thread.
struct DockQuery: @unchecked Sendable {
    var pid: pid_t?
    var list: AXUIElement?
    var rect: CGRect?   // raw AX coordinates; nil when the Dock is not a bottom bar
}

/// Dock's AXList child = the bar.
private func queryDockBar() -> DockQuery {
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return DockQuery() }
    var q = DockQuery(pid: pid)
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
          let kids = value as? [AXUIElement] else { return q }
    for k in kids {
        var role: CFTypeRef?, pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(k, kAXRoleAttribute as CFString, &role) == .success, role as? String == "AXList" else { continue }
        q.list = k
        guard AXUIElementCopyAttributeValue(k, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(k, kAXSizeAttribute as CFString, &size) == .success else { return q }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
              s.width > s.height * 1.5 else { return q }
        q.rect = CGRect(x: p.x, y: p.y + 8, width: s.width, height: s.height - 8)   // AX list includes ~8pt of transparent margin above the glass
        return q
    }
    return q
}

/// Runs on the main run loop (source added to CFRunLoopGetMain), so main-actor isolation holds.
private let dockCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let destroyed = (notification as String) == kAXUIElementDestroyedNotification
    let watcher = Unmanaged<DockWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.axEvent(destroyed: destroyed) }
}
