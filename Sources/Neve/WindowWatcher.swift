import AppKit
import ApplicationServices
import os
import NeveCore

/// Event-driven window tracking: one AXObserver per regular app reports window move / resize / minimize / create / destroy / hide.
/// Events only mark "dirty"; `onChange` fires at most every 1/30 s, so the caller does one CGWindowList read per burst
/// (AX says *that* something changed; window order and numbers still come from CGWindowList).
@MainActor
final class WindowWatcher {
    private(set) var active = false
    var onChange: (@MainActor () -> Void)?
    var onAppear: (@MainActor () -> Void)?   // a window was created / focused / shown: it animates in, so the caller bursts polls
    private var observers: [pid_t: AXObserver] = [:]
    private var pending = false
    private var lastFire = Date.distantPast
    private static let minInterval = 1.0 / 30
    private nonisolated static let log = Logger(subsystem: "io.github.viniciuscandeia.neve", category: "watcher")
    private nonisolated static let appEvents = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
                                    kAXWindowDeminiaturizedNotification, kAXWindowCreatedNotification, kAXApplicationHiddenNotification,
                                    kAXApplicationShownNotification, kAXFocusedWindowChangedNotification]
    /// AX acquisition (create, subscribe, enumerate windows) can block for the messaging timeout per call on a hung app:
    /// it runs here, never on main. Only the run-loop source install and the publish happen on main.
    private static let axQueue = DispatchQueue(label: "io.github.viniciuscandeia.neve.axattach", qos: .utility)
    private var inflight: [pid_t: Int] = [:]   // pid -> ticket; a result whose ticket is gone (detach / deactivate) is discarded
    private var ticket = 0

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        let ws = NSWorkspace.shared.notificationCenter
        if on {
            ws.addObserver(self, selector: #selector(launched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
            ws.addObserver(self, selector: #selector(terminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
            for app in NSWorkspace.shared.runningApplications { attach(app) }   // non-blocking: the serial queue works through them
        } else {
            ws.removeObserver(self)
            inflight.removeAll()
            for pid in Array(observers.keys) { detach(pid) }
        }
    }

    @objc private func launched(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attach(app)
    }
    @objc private func terminated(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { detach(app.processIdentifier) }
        mark()
    }

    private func attach(_ app: NSRunningApplication, attempt: Int = 1) {
        let pid = app.processIdentifier
        guard active, app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil, (attempt > 1 || inflight[pid] == nil) else { return }
        ticket += 1
        let mine = ticket
        inflight[pid] = mine
        let me = Unmanaged.passUnretained(self).toOpaque()
        nonisolated(unsafe) let ref = me
        Self.axQueue.async {
            let r = Self.acquire(pid: pid, refcon: ref)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.inflight[pid] == mine else { return }   // detached or deactivated meanwhile: the observer is dropped
                    self.inflight[pid] = nil
                    if let obs = r.observer, self.active, !app.isTerminated {
                        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
                        self.observers[pid] = obs
                    } else if r.observer == nil, !app.isTerminated, let d = AttachRetry.delay(afterFailedAttempt: attempt) {
                        Task { try? await Task.sleep(for: .seconds(d)); self.attach(app, attempt: attempt + 1) }
                    }
                }
            }
        }
    }

    /// Off-main. `.cannotComplete` (hung / not ready app) bails at once instead of paying a timeout per remaining call.
    private nonisolated static func acquire(pid: pid_t, refcon: UnsafeMutableRawPointer) -> Acquired {
        var obs: AXObserver?
        let err = AXObserverCreate(pid, windowCallback, &obs)
        guard err == .success, let obs else { log.info("skip pid \(pid) (create: \(err.rawValue))"); return Acquired() }
        let el = AXUIElementCreateApplication(pid)   // the global AX messaging timeout (set at startup) bounds every call
        var ok = 0
        for n in appEvents {
            let e = AXObserverAddNotification(obs, el, n as CFString, refcon)
            if e == .success { ok += 1 } else if e == .cannotComplete { break }
        }
        guard ok > 0 else { log.info("skip pid \(pid) (no notifications)"); return Acquired() }
        var v: CFTypeRef?
        let w = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v)
        if w == .success, let ws = v as? [AXUIElement] {
            for win in ws where AXObserverAddNotification(obs, win, kAXUIElementDestroyedNotification as CFString, refcon) == .cannotComplete { break }
        }
        return Acquired(observer: obs)
    }

    private func detach(_ pid: pid_t) {
        inflight[pid] = nil
        guard let o = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
    }

    fileprivate func event(_ element: AXUIElement, _ name: String) {
        if name == kAXWindowCreatedNotification {   // watch the new window's destruction
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, let o = observers[pid] {
                _ = AXObserverAddNotification(o, element, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        if name == kAXWindowCreatedNotification || name == kAXFocusedWindowChangedNotification || name == kAXApplicationShownNotification { onAppear?() }
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
                self.onChange?()
            }
        }
    }
}

/// @unchecked: an AXObserver is a CF handle used by one thread at a time (built on the AX queue, then handed to main).
private struct Acquired: @unchecked Sendable { var observer: AXObserver? }

/// Runs on the main run loop (sources are added to CFRunLoopGetMain), so main-actor isolation holds.
private let windowCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let name = notification as String
    nonisolated(unsafe) let el = element
    let w = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { w.event(el, name) }
}
