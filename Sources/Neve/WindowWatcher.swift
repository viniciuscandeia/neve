import AppKit
import ApplicationServices
import os

/// Event-driven window tracking: one AXObserver per regular app reports window move / resize / minimize / create / destroy / hide.
/// Events only mark "dirty"; `onChange` fires at most every 1/30 s, so the caller does one CGWindowList read per burst
/// (AX says *that* something changed; window order and numbers still come from CGWindowList).
@MainActor
final class WindowWatcher {
    private(set) var active = false
    var onChange: (@MainActor () -> Void)?
    private var observers: [pid_t: AXObserver] = [:]
    private var pending = false
    private var lastFire = Date.distantPast
    private static let minInterval = 1.0 / 30
    private static let log = Logger(subsystem: "io.github.viniciuscandeia.neve", category: "watcher")
    private static let appEvents = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
                                    kAXWindowDeminiaturizedNotification, kAXWindowCreatedNotification, kAXApplicationHiddenNotification,
                                    kAXApplicationShownNotification, kAXFocusedWindowChangedNotification]
    private(set) var eventCount = 0, fireCount = 0

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        let ws = NSWorkspace.shared.notificationCenter
        if on {
            ws.addObserver(self, selector: #selector(launched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
            ws.addObserver(self, selector: #selector(terminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
            for app in NSWorkspace.shared.runningApplications { attach(app) }
            Self.log.info("watching \(self.observers.count) apps")
        } else {
            ws.removeObserver(self)
            for pid in Array(observers.keys) { detach(pid) }
        }
    }

    @objc private func launched(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { attach(app) }
    }
    @objc private func terminated(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { detach(app.processIdentifier) }
        mark()
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var obs: AXObserver?
        let err = AXObserverCreate(pid, windowCallback, &obs)
        guard err == .success, let obs else { Self.log.info("skip \(app.localizedName ?? "?") (create: \(err.rawValue))"); return }
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)   // a hung app must not stall the main thread
        let me = Unmanaged.passUnretained(self).toOpaque()
        var ok = 0
        for n in Self.appEvents where AXObserverAddNotification(obs, el, n as CFString, me) == .success { ok += 1 }
        guard ok > 0 else { Self.log.info("skip \(app.localizedName ?? "?") (no notifications)"); return }
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v) == .success, let ws = v as? [AXUIElement] {
            for w in ws { _ = AXObserverAddNotification(obs, w, kAXUIElementDestroyedNotification as CFString, me) }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
    }

    private func detach(_ pid: pid_t) {
        guard let o = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
    }

    fileprivate func event(_ element: AXUIElement, _ name: String) {
        eventCount += 1
        if name == kAXWindowCreatedNotification {   // watch the new window's destruction
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, let o = observers[pid] {
                _ = AXObserverAddNotification(o, element, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        mark()
    }

    /// Coalesce: at most one `onChange` per `minInterval`, however many events arrive.
    private func mark() {
        guard !pending else { return }
        pending = true
        let wait = max(0, Self.minInterval - Date().timeIntervalSince(lastFire))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                self.lastFire = Date()
                self.fireCount += 1
                self.onChange?()
            }
        }
    }
}

/// Runs on the main run loop (sources are added to CFRunLoopGetMain), so main-actor isolation holds.
private let windowCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let name = notification as String
    nonisolated(unsafe) let el = element
    let w = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { w.event(el, name) }
}
