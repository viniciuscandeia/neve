import AppKit
import ApplicationServices
import os
import NeveCore

/// Event-driven window tracking: one AXObserver per regular app reports window move / resize / minimize / create / destroy / hide.
/// Each event calls `onChange` (the caller's PollScheduler coalesces: one CGWindowList read per burst; AX says *that* something changed,
/// window order and numbers still come from CGWindowList). Minimize / hide events also call `onSettle`: the animation outlasts the burst.
@MainActor
final class WindowWatcher {
    private(set) var active = false
    var onChange: (@MainActor () -> Void)?
    var onSettle: (@MainActor () -> Void)?
    private var observers: [pid_t: AXObserver] = [:]
    private nonisolated static let log = Logger(subsystem: "io.github.viniciuscandeia.neve", category: "watcher")
    private nonisolated static let appEvents = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
                                    kAXWindowDeminiaturizedNotification, kAXWindowCreatedNotification, kAXApplicationHiddenNotification,
                                    kAXApplicationShownNotification, kAXFocusedWindowChangedNotification]
    /// AX acquisition (create, subscribe, enumerate windows) can block for the messaging timeout per call on a hung app:
    /// it runs here, never on main. Only the run-loop source install and the publish happen on main.
    private static let axQueue = DispatchQueue(label: "io.github.viniciuscandeia.neve.axattach", qos: .utility)
    private let gate = AttachGate()   // tickets + generation: deactivation drops queued work and sleeping retries

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        let ws = NSWorkspace.shared.notificationCenter
        if on {
            ws.addObserver(self, selector: #selector(launched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
            ws.addObserver(self, selector: #selector(terminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
            ws.addObserver(self, selector: #selector(activated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
            for app in NSWorkspace.shared.runningApplications { attach(app) }   // non-blocking: the serial queue works through them
        } else {
            ws.removeObserver(self)
            gate.cancelAll()
            for pid in Array(observers.keys) { detach(pid) }
        }
    }

    @objc private func launched(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attach(app)
    }
    /// Apps that turn `.regular` after launch (Electron, Java, Qt) were skipped at launch: they get their observer when first activated.
    @objc private func activated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, observers[app.processIdentifier] == nil else { return }
        attach(app)
    }
    @objc private func terminated(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { detach(app.processIdentifier) }
        onChange?()
    }

    private func attach(_ app: NSRunningApplication, attempt: Int = 1, generation: Int? = nil) {
        let pid = app.processIdentifier
        let gen = generation ?? gate.generation
        guard active, app.activationPolicy == .regular, pid != getpid(),
              let mine = gate.begin(pid: pid, generation: gen, hasObserver: observers[pid] != nil) else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        nonisolated(unsafe) let ref = me
        let gate = self.gate
        Self.axQueue.async {
            guard gate.isCurrent(pid: pid, ticket: mine, generation: gen) else { return }   // cancelled while queued
            let r = Self.acquire(pid: pid, refcon: ref)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gate.finish(pid: pid, ticket: mine) else { return }   // detached or deactivated meanwhile: the observer is dropped
                    if r.outcome == .complete, let obs = r.observer, self.active, !app.isTerminated {
                        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
                        self.observers[pid] = obs
                    } else if r.outcome == .transient, !app.isTerminated, let d = AttachRetry.delay(afterFailedAttempt: attempt) {
                        // partial attach: the observer is discarded and the whole acquisition retried (only if still the same generation)
                        Task { try? await Task.sleep(for: .seconds(d)); self.attach(app, attempt: attempt + 1, generation: gen) }
                    }
                }
            }
        }
    }

    /// Off-main. `.cannotComplete` (hung / not ready app) bails at once instead of paying a timeout per remaining call.
    private nonisolated static func acquire(pid: pid_t, refcon: UnsafeMutableRawPointer) -> Acquired {
        func step(_ e: AXError) -> AXStep { e == .success ? .ok : e == .cannotComplete ? .transient : .unsupported }
        var obs: AXObserver?
        let err = AXObserverCreate(pid, windowCallback, &obs)
        guard err == .success, let obs else {
            log.info("skip pid \(pid) (create: \(err.rawValue))")
            return Acquired(observer: nil, outcome: err == .cannotComplete ? .transient : .incompatible)
        }
        let el = AXUIElementCreateApplication(pid)   // the global AX messaging timeout (set at startup) bounds every call
        var steps: [AXStep] = []
        for n in appEvents {
            steps.append(step(AXObserverAddNotification(obs, el, n as CFString, refcon)))
            if steps.last == .transient { break }
        }
        if !steps.contains(.transient) {
            var v: CFTypeRef?
            let w = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v)
            if w == .success, let ws = v as? [AXUIElement] {
                for win in ws {
                    let s = step(AXObserverAddNotification(obs, win, kAXUIElementDestroyedNotification as CFString, refcon))
                    if s == .transient { steps.append(s); break }
                }
            } else if w == .cannotComplete { steps.append(.transient) }
        }
        let outcome = AttachRetry.classify(steps)
        if outcome != .complete { log.info("pid \(pid) attach \(String(describing: outcome))") }
        return Acquired(observer: outcome == .complete ? obs : nil, outcome: outcome)
    }

    private func detach(_ pid: pid_t) {
        gate.cancel(pid: pid)
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
        if name == kAXWindowMiniaturizedNotification || name == kAXApplicationHiddenNotification { onSettle?() }
        onChange?()
    }
}

/// @unchecked: an AXObserver is a CF handle used by one thread at a time (built on the AX queue, then handed to main).
private struct Acquired: @unchecked Sendable { var observer: AXObserver?; var outcome: AttachOutcome }

/// Runs on the main run loop (sources are added to CFRunLoopGetMain), so main-actor isolation holds.
private let windowCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let name = notification as String
    nonisolated(unsafe) let el = element
    let w = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { w.event(el, name) }
}
