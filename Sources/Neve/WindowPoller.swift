// AGENT HEADER - Sources/Neve/WindowPoller.swift  (window-read coordination, MainActor; split out of AppController)
// Role: everything between "something may have changed" and `Overlay.update(...)`: the PollScheduler (`sched`: coalesced, <=30/s, bursts bounded) and its one-shot timer (arm / runScheduled),
//   requestPoll / transitionPoll / settlePoll (the entry points AX events, notifications and timers call), the global mouse monitor (down / up / drag) and Option flagsChanged monitor (-> Overlay.optionDown; both installed only while polling, in syncMouseMonitor),
//   pollWindows (CGWindowList read -> DragTracker + MissionControlGate -> offscreen filter -> Dock rect (WindowInfo number 0) -> Overlay.update), the Mission Control gate (setMissionControl,
//   mcProbeTick = the 0.3 s on-screen-ID probe; the probe TIMER stays in AppController.scheduleSafety) and scene mode (NEVE_SCENE demo / fight: SceneStage windows, 60 Hz timer).
// Host: `unowned host: AppController` supplies overlays, polling, idle, behind, dock, settleUntil and the callbacks (screensChanged, refreshDock, scheduleTimers, updateStatus, endQuietStretch).
//   The safety timer, AX watcher wiring (WindowWatcher) and timerGap stay in AppController (scheduleTimers / scheduleSafety / pollTick).
// Gotchas: pollWindows is the hot path (<=30/s): no allocations added. AXObserver skips our own pid (Ajustes posts NSWindow notifications into requestPoll via AppController). Never kill Neve by name.

import AppKit
import NeveCore

@MainActor
final class WindowPoller {
    unowned let host: AppController
    init(host: AppController) { self.host = host }
    private var overlays: [Overlay] { host.overlays }
    private var polling: Bool { host.polling }
    private var userIdle: Bool { host.idle.userIdle }
    private var behind: Bool { host.behind }
    private var dock: DockWatcher { host.dock }
    private var fullscreenIdle: Bool { host.fullscreenIdle }
    private var watcher: WindowWatcher { host.watcher }
    private var timerGap: Double { host.timerGap }
    private var mouseDown = false, mouseMonitor: Any?, optionMonitor: Any?
    private(set) var missionControl = false
    private var mcTimer: Timer?, mcGate = MissionControlGate(), mcMonitor: Any?, mcIDs = WindowIDWatch(), mcStrong = false
    private func displayID(_ s: NSScreen) -> Int { host.displayID(s) }
    private func updateStatus() { host.updateStatus() }

    /// Global mouse monitors need no Accessibility permission. Installed only while snow is polling (the poll scheduler samples at ~25 Hz during a window drag).
    func syncMouseMonitor() {
        if polling, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] e in
                MainActor.assumeIsolated { self?.mouseEvent(e.type) }
            }
            optionMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in   // still mode: wake at once on Option (needs Accessibility; Overlay.update is the fallback)
                guard e.modifierFlags.contains(.option) else { return }
                MainActor.assumeIsolated { self?.overlays.forEach { $0.optionDown() } }
            }
        } else if !polling, let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
            if let o = optionMonitor { NSEvent.removeMonitor(o); optionMonitor = nil }
            mouseDown = false
        }
    }


    private let scenarioHeavy = ProcessInfo.processInfo.environment["NEVE_SCENARIO"] == "heavy"
    private var lastStage = -Double.infinity

    func pollWindows() {
        let t0 = Perf.now()
        defer { Perf.addPoll(t0) }
        guard let primary = NSScreen.screens.first else { return }
        if let k = sceneKind { pollScene(k, primary: primary); return }
        let mouse = NSEvent.mouseLocation   // read with the bounds: the drag offset is the mouse's move over the SAME interval as the window's
        guard let read = readWindowsAndMC(primaryHeight: primary.frame.height, exclude: Set(overlays.map(\.windowNumber) )) else {
            sched.didRead(ok: false, changed: false, frameMoved: false)   // CGWindowList failed: keep the last snapshot, retry shortly
            return
        }
        let raw = read.windows
        let strong = mcStrong; mcStrong = false
        let mcNow = mcGate.read(read.missionControl, now: CACurrentMediaTime(), strong: strong)   // 2 consecutive reads to suspend, 1 to release, 15 s watchdog
        setMissionControl(mcNow)
        mcTimer?.invalidate(); mcTimer = nil
        if missionControl || mcGate.pending || mcGate.holdsPiles {   // the window list is the Exposé layout: leave the piles alone and look again in 0.25 s (the only poll while it lasts)
            sched.didRead(ok: true, changed: false, frameMoved: false)
            mcTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.requestPoll() } }
            return
        }
        // Drag bookkeeping: the target is the one window whose move matches the mouse's over this same interval.
        let changed = raw != lastRead
        let moved = mouseDown && raw.contains { w in lastRead.first { $0.number == w.number }.map { $0.frame != w.frame } ?? false }
        let screenFrames = NSScreen.screens.map(\.frame)
        drag.read(down: mouseDown, moved: moved, prev: lastRead, cur: raw, mouseDelta: CGVector(dx: mouse.x - lastReadMouse.x, dy: mouse.y - lastReadMouse.y), screens: screenFrames)
        sched.didRead(ok: true, changed: changed, frameMoved: moved)
        lastRead = raw; lastReadMouse = mouse
        var windows = raw
        // Show-desktop leaves a sliver on-screen: treat as gone. A window the user dragged mostly off-screen keeps its snow.
        windows.removeAll { $0.number != drag.exempt && mostlyOffscreen($0.frame, screens: screenFrames) }
        let covering = windows.map(\.frame)
        let coverList = windows   // real windows: coverage / compaction also work in behind mode
        if behind { windows = [] }   // snow falls behind app windows: no surfaces, no Dock pile
        else if let d = dock.frame { windows.insert(WindowInfo(number: 0, frame: d, radius: d.height * 0.3), at: 0) }   // Dock draws above windows
        for o in overlays {
            let fs = covering.contains { o.covers($0) }
            if fs != o.isFullscreen { host.settleUntil[host.displayID(o.screen)] = CACurrentMediaTime() + 1 }
            o.setFullscreen(fs)
            if !o.isFullscreen { o.update(windows: windows, covering: coverList, dragTarget: drag.target, mouse: lastReadMouse) }   // under fullscreen the list is just that app: keep piles untouched
        }
        if scenarioHeavy, CACurrentMediaTime() - lastStage >= 20 { lastStage = CACurrentMediaTime(); overlays.forEach { $0.stage(.heavy) } }   // perf A/B load
        if fullscreenIdle != host.idleWatch {
            host.updateStatus()
            host.scheduleTimers()
            if !fullscreenIdle { host.refreshDock() }
        }
    }

    func mcProbeTick() {
        guard polling, !userIdle, sceneKind == nil, let ids = onScreenWindowIDs(), mcIDs.changed(ids) else { return }
        mcStrong = true
        requestPoll()
    }

    func setMissionControl(_ on: Bool) {
        guard on != missionControl else { return }
        missionControl = on
        for o in overlays { o.setSuspended(on) }
        if on, mcMonitor == nil {   // Esc closes Mission Control: release at once (needs Accessibility for global key events; without it the next negative read releases). A click may or may not close it ("+", Spaces bar): just look again now.
            mcMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
                MainActor.assumeIsolated {
                    if e.type == .leftMouseDown { self?.requestPoll(); return }
                    guard e.keyCode == 53 else { return }
                    self?.mcGate.release(); self?.setMissionControl(false); self?.requestPoll()
                }
            }
        } else if !on, let m = mcMonitor { NSEvent.removeMonitor(m); mcMonitor = nil }
    }

    // MARK: scene mode (NEVE_SCENE)
    private let launched = CACurrentMediaTime()   // NEVE_SCENE_WAIT=<secs>: the script starts that long after launch (time to start a recording)
    private var stage: SceneStage?, sceneTimer: Timer?, sceneBegun = false, scenePoll = 0

    /// Scene mode: only the scene windows count, no Dock; a 60 Hz timer moves the windows by scene time and polls them every other tick.
    func pollScene(_ k: SceneKind, primary: NSScreen) {
        if k == .demo, stage == nil {
            stage = SceneStage(screen: primary)
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let o = self.overlays.first else { return }
                    self.stage?.place(t: o.sceneTime ?? 0)
                    self.scenePoll += 1
                    if self.scenePoll % 2 == 0 { self.pollWindows() }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            sceneTimer = t
        }
        let windows = k == .demo ? (readWindows(primaryHeight: primary.frame.height, scene: stage?.numbers ?? []) ?? []) : []
        for o in overlays {
            o.update(windows: windows)
            if !sceneBegun, CACurrentMediaTime() - launched >= (Double(ProcessInfo.processInfo.environment["NEVE_SCENE_WAIT"] ?? "") ?? 0), k == .fight || windows.count == 3 {
                sceneBegun = true; o.beginScene(k)
                // NEVE_SCENE_MARK=file: unix time of scene second 0, to line a screen recording up with the script
                if let m = ProcessInfo.processInfo.environment["NEVE_SCENE_MARK"] { try? "\(Date().timeIntervalSince1970)".write(toFile: m, atomically: true, encoding: .utf8) }
            }
        }
    }


    // MARK: poll scheduling. Every window read goes through `sched`: coalesced, 30/s at most, bursts bounded (see PollScheduler).
    var sched = PollScheduler(), schedTimer: Timer?
    private var lastRead: [WindowInfo] = [], lastReadMouse = NSEvent.mouseLocation
    private var drag = DragTracker(), downOnDesktop = false, lastDragReq = 0.0

    func requestPoll(_ r: PollReasons = .windows) {
        guard polling, !userIdle else { return }
        sched.request(r)
        arm()
    }
    func transitionPoll() {
        guard polling, !userIdle else { return }
        sched.transition(now: CACurrentMediaTime())
        host.endQuietStretch()   // an event ends the quiet stretch
        arm()
    }

    /// A minimize / hide animates for a while: besides the burst, one more read ~0.6 s later catches the final state.
    func settlePoll() {
        guard polling, !userIdle else { return }
        sched.settleRead(now: CACurrentMediaTime())
        arm()
    }

    func mouseEvent(_ type: NSEvent.EventType) {
        let now = CACurrentMediaTime()
        switch type {
        case .leftMouseDown:
            mouseDown = true
            let p = NSEvent.mouseLocation
            downOnDesktop = !lastRead.contains { $0.frame.contains(p) }   // click on the wallpaper = show-desktop: no AX event
            if downOnDesktop { settlePoll() }   // windows slide away: one read after Tuning.goneGrace lets their snow fall
            drag.pressed(at: p, windows: lastRead)   // a press outside the exempt (dragged-offscreen) window ends its exemption
            if polling, !userIdle { sched.mouseDown(now: now, onDesktop: downOnDesktop, dragPlausible: dragPlausible(at: p, windows: lastRead, command: NSEvent.modifierFlags.contains(.command))) }
        case .leftMouseUp:
            mouseDown = false
            if polling, !userIdle { sched.mouseUp(now: now, onDesktop: downOnDesktop) }
        default:   // dragged: throttled; a moving window flips the scheduler into drag sampling
            guard now - lastDragReq >= 0.015, polling, !userIdle else { return }
            lastDragReq = now
            sched.mouseDragged()
        }
        arm()
    }

    func arm() {
        let now = CACurrentMediaTime()
        guard let due = sched.nextDue(now: now) else { return }
        let fire = Date(timeIntervalSinceNow: max(0, due - now))
        if let t = schedTimer, t.isValid, t.fireDate <= fire { return }
        schedTimer?.invalidate()
        let t = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.runScheduled() } }
        t.tolerance = 0.004
        RunLoop.main.add(t, forMode: .common)
        schedTimer = t
    }

    func runScheduled() {
        schedTimer = nil
        guard polling, !userIdle else { return }
        guard let r = sched.take(now: CACurrentMediaTime()) else { arm(); return }
        if r.contains(.geometry) { host.screensChanged() }
        if r.contains(.dock) { host.refreshDock() }
        if r.contains(.windows) { pollWindows() }
        arm()
    }
}
