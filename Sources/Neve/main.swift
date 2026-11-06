import NeveCore
import AppKit
import os
import ServiceManagement
import SwiftUI

/// Dev instance name (Info.plist `NeveInstance` or env `NEVE_INSTANCE`); nil for the user's app.
let neveInstance: String? = Bundle.main.object(forInfoDictionaryKey: "NeveInstance") as? String ?? ProcessInfo.processInfo.environment["NEVE_INSTANCE"]

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var overlays: [Overlay] = []
    private var timer: Timer?
    private var idleWatch = false   // the timer is the 1 Hz fullscreen watch
    private var screensAsleep = false
    private var sessionInactive = false
    private let metalItem = NSMenuItem(title: "Metal indisponível", action: nil, keyEquivalent: "")
    private var loggedMetal = false
    private var mouseDown = false
    private var userIdle = false   // no input for 5 min: rendering paused, polling kept to notice input
    private var mouseMonitor: Any?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let dock = DockWatcher()
    private let watcher = WindowWatcher()
    private var slowTimer: Timer?
    private var lastScreensCheck = Date.distantPast
    /// The one defaults store: a per-instance suite for dev builds, so concurrent instances never share prefs.
    private let ud = neveInstance.flatMap { UserDefaults(suiteName: "io.github.viniciuscandeia.neve.dev.\($0)") } ?? .standard
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion   // read once per system change
    private let axItem = NSMenuItem(title: "Permitir neve no Dock…", action: #selector(askAccessibility), keyEquivalent: "")
    private let nevarItem = NSMenuItem(title: "Nevar", action: #selector(toggleEnabled), keyEquivalent: "n")
    private let intensityControl = NSSegmentedControl()
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var intensitySnapshot = Intensity.media
    private var prefSnapshot: [Pref: Bool] = [:]
    private var loginOn: Bool { SMAppService.mainApp.status == .enabled }

    private func flag(_ p: Pref) -> Bool { ud.object(forKey: p.rawValue) as? Bool ?? p.defaultValue }
    private var enabled: Bool { flag(.enabled) }
    private var economy: Bool { flag(.economy) }
    private var ambient: Bool { flag(.ambient) }
    private var behind: Bool { flag(.behindWindows) }
    /// Everything the overlays render from the options; the single place UserDefaults is read for them.
    private var overlayPrefs: OverlayPrefs {
        OverlayPrefs(economy: economy, behind: behind, behindLarge: flag(.behindLarge), still: flag(.stillSnow), snowman: flag(.snowman), walk: flag(.walk), visitors: flag(.visitors), sleigh: flag(.sleigh), showInCaptures: flag(.showInCaptures), intensity: Intensity.saved(ud))
    }
    private func applyPrefs() { let p = overlayPrefs; for o in overlays { o.apply(p) } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)   // global default: a hung app or the Dock must not stall AX reads
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.symbol("snowflake", "Neve")
        if let n = neveInstance { item.button?.title = " \(n)"; item.button?.imagePosition = .imageLeft }
        let menu = NSMenu()
        menu.delegate = self
        let clear = NSMenuItem(title: "Limpar neve", action: #selector(clearSnow), keyEquivalent: "k")
        let settings = NSMenuItem(title: "Ajustes…", action: #selector(showSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = Self.symbol("power")
        clear.image = Self.symbol("sparkles")
        settings.image = Self.symbol("gearshape")
        clear.target = self
        settings.target = self
        nevarItem.target = self
        nevarItem.image = Self.symbol("snowflake")
        let symbols = ["snowflake", "cloud.snow", "cloud.snow.fill", "wind.snow"]
        intensityControl.segmentCount = symbols.count
        intensityControl.trackingMode = .selectOne
        intensityControl.segmentStyle = .automatic
        for v in Intensity.allCases {
            intensityControl.setImage(Self.symbol(symbols[v.rawValue], v.title), forSegment: v.rawValue)
            intensityControl.setToolTip(v.title, forSegment: v.rawValue)
            intensityControl.setWidth(44, forSegment: v.rawValue)
        }
        intensityControl.target = self
        intensityControl.action = #selector(pickIntensity(_:))
        intensityControl.frame = NSRect(x: 0, y: 0, width: 4 * 44, height: 24)
        let intensityItem = NSMenuItem()
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 4 * 44 + 28, height: 30))
        intensityControl.frame.origin = NSPoint(x: 14, y: 3)
        holder.addSubview(intensityControl)
        intensityItem.view = holder
        axItem.target = self
        axItem.image = Self.symbol("exclamationmark.triangle")
        axItem.isHidden = AXIsProcessTrusted()
        metalItem.isHidden = true
        let items: [NSMenuItem] = [statusLine, axItem, metalItem, .separator(), nevarItem, intensityItem, .separator(), clear, settings, quit]
        for i in items { menu.addItem(i) }
        updateStatus()
        item.menu = menu
        statusItem = item

        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        prefSnapshot = prefValues()
        intensitySnapshot = Intensity.saved(ud)
        // These can be posted from any thread (thermal / power state from a system queue, defaults from anywhere): the
        // selector API would call the @MainActor methods off the main thread and trap, so deliver them on the main queue.
        nc.addObserver(forName: UserDefaults.didChangeNotification, object: ud, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.syncPrefs() } }
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.powerChanged() } }
        ws.addObserver(self, selector: #selector(powerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDock), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDock), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshRunState() } }
        ws.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        // Global mouse monitors need no Accessibility permission; without it, window polling speeds up to 10Hz while the button is down (drags).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouseDown = e.type == .leftMouseDown
                if !self.watcher.active { self.scheduleTimers() }   // only the polling rate depends on the button; events do not
                if !self.mouseDown && self.polling { self.pollWindows() }
            }
        }
        dock.onChange = { [weak self] in self?.refreshDock() }
        watcher.onChange = { [weak self] in
            guard let self, self.polling, !self.userIdle else { return }
            self.pollWindows()
        }
        syncOverlays()
    }

    private func displayID(_ s: NSScreen) -> Int { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0 }

    /// Leaving / entering fullscreen reshuffles the menu bar and Dock mid-Space-animation: per screen, ignore visibleFrame ~1s after.
    private var settleUntil: [Int: Date] = [:]
    private func settling(_ o: Overlay) -> Bool { o.isFullscreen || Date() < settleUntil[displayID(o.screen), default: .distantPast] }

    /// Real configuration changes (screens added / removed, frame or scale) apply at once, per screen;
    /// only visibleFrame-only changes (Dock, menu bar) wait for a transitioning screen to settle.
    @objc private func screensChanged() {
        lastScreensCheck = Date()
        let wanted = wantedScreens
        let ids = Set(wanted.map(displayID))
        let changed = Set(overlays.map { displayID($0.screen) }) != ids
            || wanted.contains { s in overlays.contains { displayID($0.screen) == displayID(s) && $0.screenChanged(s) } }
        if changed { syncOverlays() }
        for o in overlays where !(polling && settling(o)) { o.refreshBounds() }
    }

    /// Makes the overlays match wantedScreens: tears down unwanted / changed ones, creates missing ones; other screens keep their piles.
    private func syncOverlays() {
        let wanted = wantedScreens
        func stale(_ o: Overlay) -> Bool { !wanted.contains { displayID($0) == displayID(o.screen) && !o.screenChanged($0) } }
        overlays.filter(stale).forEach { $0.teardown() }
        overlays.removeAll(where: stale)
        applyPrefs()
        let missing = wanted.filter { s in !overlays.contains { displayID($0.screen) == displayID(s) } }
        let prefs = overlayPrefs
        let made = missing.compactMap { Overlay(screen: $0, prefs: prefs) }
        if made.count < missing.count && !loggedMetal {
            loggedMetal = true
            Logger(subsystem: "io.github.viniciuscandeia.neve", category: "overlay").error("Metal overlay could not be created for a screen")
        }
        overlays += made
        metalItem.isHidden = !overlays.isEmpty || NSScreen.screens.isEmpty
        refreshRunState()
    }

    /// "all" / "main" / a display ID. Economy forces the main screen (the one with the menu bar).
    private var target: String { ud.string(forKey: "snowOn") ?? "all" }
    private var wantedScreens: [NSScreen] {
        let all = NSScreen.screens
        if economy || target == "main" { return Array(all.prefix(1)) }
        if let id = Int(target), let s = all.first(where: { displayID($0) == id }) { return [s] }
        return all   // "all", or the chosen screen is unplugged
    }

    private func setTarget(_ t: String) {
        ud.set(t, forKey: "snowOn")
        syncOverlays()
    }

    private func prefValues() -> [Pref: Bool] { Dictionary(uniqueKeysWithValues: Pref.allCases.map { ($0, flag($0)) }) }

    /// Diffs the Bool prefs against the last snapshot and reacts to each change; called by the menu and by the defaults observer (the popover writes straight to defaults).
    @objc private func syncPrefs() {
        let new = prefValues()
        let changed = changedPrefs(old: prefSnapshot, new: new)
        prefSnapshot = new
        changed.forEach(prefChanged)
        let level = Intensity.saved(ud)   // not a Pref: set by the menu row, the popover tiles
        if level != intensitySnapshot { intensitySnapshot = level; applyPrefs(); updateStatus() }
    }

    /// The single reaction path for a pref that just changed.
    private func prefChanged(_ pref: Pref) {
        let on = flag(pref)
        switch pref {
        case .enabled:
            outroGen += 1
            if on { outroing = false; overlays.forEach { $0.intro() }; refreshRunState() }
            else { updateStatus(); runOutro { [weak self] in self?.refreshRunState() } }
        case .economy: syncOverlays()
        case .ambient: if on && userIdle { userIdle = false; refreshRunState() } else { updateStatus() }
        case .behindWindows:
            applyPrefs()
            if polling { pollWindows() }   // empties / refills the surface list
            updateStatus()
        case .behindLarge, .stillSnow, .snowman, .walk, .visitors, .sleigh, .showInCaptures: applyPrefs()
        }
    }

    @objc private func toggleEnabled() {
        ud.set(!enabled, forKey: Pref.enabled.rawValue)
        syncPrefs()
    }

    private func settingsEnv() -> SettingsEnv {
        var rows: [(title: String, id: String)] = []
        if NSScreen.screens.count > 1 { rows = NSScreen.screens.map { ($0.localizedName, String(displayID($0))) } }
        let cur = (["all", "main"] + rows.map(\.id)).contains(target) ? target : "all"
        return SettingsEnv(store: ud, screens: rows, reduceMotion: reduceMotion, isDev: neveInstance != nil,
                           target: Binding(get: { cur }, set: { [weak self] in self?.setTarget($0) }),
                           login: Binding(get: { [weak self] in self?.loginOn ?? false }, set: { [weak self] in self?.setLogin($0) }),
                           openWindow: { [weak self] in self?.showSettingsWindow() })
    }

    /// ⌘, : the quick popover; ⌥-click on the item opens the full window.
    @objc private func showSettings() {
        if NSEvent.modifierFlags.contains(.option) { return showSettingsWindow() }
        guard let button = statusItem?.button else { return }
        statusItem?.menu?.cancelTracking()
        let host = NSHostingController(rootView: QuickSettingsView(env: settingsEnv()))
        host.sizingOptions = .preferredContentSize
        let pop = popover ?? NSPopover()
        pop.behavior = .transient
        pop.contentViewController = host
        popover = pop
        // after the menu has closed
        DispatchQueue.main.async {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
        }
    }

    /// The single "Ajustes do Neve" window (rebuilt on each open so the screen list is fresh).
    private func showSettingsWindow() {
        popover?.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Ajustes do Neve"
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.contentViewController = NSHostingController(rootView: SettingsWindowView(env: settingsEnv()))
        // after the popover / menu has finished closing, or the activation is lost
        DispatchQueue.main.async { [weak self] in
            NSApp.activate()
            self?.settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private var outroing = false   // an outro is playing: the overlays stay up until it ends
    private var outroGen = 0       // bumped to cancel the previous outro's completion
    private var shuttingDown = false, replied = false

    /// Plays the outro on every overlay on screen, then `done`.
    private func runOutro(_ done: @escaping @MainActor () -> Void) {
        let shown = overlays.filter(\.showing)
        guard !shown.isEmpty else { return done() }
        outroing = true
        let gen = outroGen
        var left = shown.count
        for o in shown {
            o.outro { [weak self] in
                left -= 1
                guard left == 0, let self, self.outroGen == gen else { return }
                self.outroing = false
                done()
            }
        }
    }

    /// Quit plays the outro first (terminateLater), with a hard 1.9s limit; a second quit, or a system shutdown, skips it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !outroing, !shuttingDown, running, !hot, !userIdle, overlays.contains(where: \.showing) else { return .terminateNow }
        runOutro { [weak self] in self?.finishQuit() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in MainActor.assumeIsolated { self?.finishQuit() } }
        return .terminateLater
    }
    private func finishQuit() {
        guard !replied else { return }
        replied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private var running: Bool { (enabled || outroing) && !screensAsleep && !sessionInactive }
    /// The one source of truth for thermal throttling.
    private var hot: Bool { ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue }
    /// Polling timers only run while snow is actually shown (not disabled / asleep / locked / hot).
    private var polling: Bool { running && !hot }
    private var fullscreenIdle: Bool { !overlays.isEmpty && overlays.allSatisfy(\.isFullscreen) }

    private static func symbol(_ name: String, _ description: String? = nil) -> NSImage? {
        let i = NSImage(systemSymbolName: name, accessibilityDescription: description)
        i?.isTemplate = true
        return i
    }

    /// Read-only summary derived from the existing pause reasons; refreshed when the menu opens.
    private var statusText: String {
        let level = Intensity.saved(ud)
        if !enabled { return "Desligado" }
        if screensAsleep || sessionInactive || userIdle { return "Pausado — inativo" }
        if hot { return "Pausado — sistema quente" }
        if fullscreenIdle { return "Pausado — app em tela cheia" }
        var s = level == .nevasca ? "Nevasca · vento forte" : "Nevando · \(level.title)"
        if economy { s += " · econômico · só tela principal" }
        else if wantedScreens.count < NSScreen.screens.count { s += " · " + (wantedScreens.count == 1 && target != "main" ? wantedScreens[0].localizedName : "tela principal") }
        if ambient { s += " · ambiente" }
        if behind { s += " · atrás das janelas" }
        if reduceMotion { s += " · movimento reduzido" }
        return s
    }

    private func updateStatus() {
        statusLine.attributedTitle = NSAttributedString(string: "❄ Neve — " + statusText, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)])
        let paused = !enabled || !polling || userIdle || fullscreenIdle
        let slash = Self.symbol("snowflake.slash", "Neve — desligada")
        let (img, alpha) = !enabled
            ? (slash ?? Self.symbol("snowflake", "Neve — desligada"), slash == nil ? 0.75 : 1)
            : (Self.symbol("snowflake", paused ? "Neve — pausada" : "Neve"), paused ? 0.85 : 1)
        statusItem?.button?.image = img
        statusItem?.button?.alphaValue = alpha
        axItem.isHidden = AXIsProcessTrusted()
    }

    func menuWillOpen(_ menu: NSMenu) {
        nevarItem.state = enabled ? .on : .off
        intensityControl.selectedSegment = Intensity.saved(ud).rawValue
        updateStatus()
    }

    private func refreshRunState() {
        updateStatus()
        let run = running && !hot && !userIdle
        for o in overlays { o.setRun(run) }
        scheduleTimers()
        if polling {
            refreshDock()
            pollWindows()
        }
    }

    /// With Accessibility trust, window events drive updates and the timer is a 2s safety poll; without it, a 0.5s poll (10Hz while the mouse is down).
    /// Plus a 30s Dock refresh; just a 1Hz watch while every screen is under a fullscreen app. `.common` so menus don't stall them.
    private func scheduleTimers() {
        timer?.invalidate()
        timer = nil
        slowTimer?.invalidate()
        slowTimer = nil
        watcher.setActive(polling && AXIsProcessTrusted())   // events replace polling; the timer stays as a slow safety net
        guard polling else { return }
        let idle = fullscreenIdle
        idleWatch = idle
        let t = Timer(timeInterval: idle ? 1 : (watcher.active ? 2 : mouseDown ? 0.1 : 0.5), target: self, selector: #selector(pollTick), userInfo: nil, repeats: true)
        t.tolerance = idle ? 0.2 : (mouseDown && !watcher.active ? 0.03 : 0.1)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if !idle {
            let st = Timer(timeInterval: 30, target: self, selector: #selector(refreshDock), userInfo: nil, repeats: true)
            st.tolerance = 1
            RunLoop.main.add(st, forMode: .common)
            slowTimer = st
        }
    }

    /// No input for 5 min pauses rendering; input resumes it (checked here, so no Accessibility needed for keys).
    @objc private func pollTick() {
        let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)   // kCGAnyInputEventType
        if !userIdle && !ambient && since >= 300 { userIdle = true; refreshRunState() }
        else if userIdle && since < 2 { userIdle = false; refreshRunState() }
        if Date().timeIntervalSince(lastScreensCheck) >= 0.5 { screensChanged() }   // safety net: Dock / menu bar auto-hide changes visibleFrame without a notification
        if !userIdle { pollWindows() }
    }

    private let scenarioHeavy = ProcessInfo.processInfo.environment["NEVE_SCENARIO"] == "heavy"
    private var lastStage = Date.distantPast

    @objc private func pollWindows() {
        let t0 = Perf.now()
        defer { Perf.add(.poll, t0) }
        guard let primary = NSScreen.screens.first else { return }
        var windows = readWindows(primaryHeight: primary.frame.height)
        let covering = windows.map(\.frame)
        if behind { windows = [] }   // snow falls behind app windows: no surfaces, no Dock pile
        else if let d = dock.frame { windows.insert(WindowInfo(number: 0, frame: d, radius: d.height * 0.3), at: 0) }   // Dock draws above windows
        for o in overlays {
            let fs = covering.contains { o.covers($0) }
            if fs != o.isFullscreen { settleUntil[displayID(o.screen)] = Date().addingTimeInterval(1) }
            o.setFullscreen(fs)
            if !o.isFullscreen { o.update(windows: windows) }   // under fullscreen the list is just that app: keep piles untouched
        }
        if scenarioHeavy, Date().timeIntervalSince(lastStage) >= 20 { lastStage = Date(); overlays.forEach { $0.stage(.heavy) } }   // perf A/B load
        if fullscreenIdle != idleWatch {
            scheduleTimers()
            if !fullscreenIdle { refreshDock() }
        }
    }

    @objc private func pickIntensity(_ sender: NSSegmentedControl) {
        guard let v = Intensity(rawValue: sender.selectedSegment) else { return }
        ud.set(v.rawValue, forKey: Intensity.key)
        applyPrefs()
        updateStatus()
        statusItem?.menu?.cancelTracking()
    }

    /// Dock bar frame via Accessibility; cheap no-op when untrusted. Called on Dock AX events, app launch/quit, screen changes, every 30s.
    @objc private func refreshDock() {
        axItem.isHidden = AXIsProcessTrusted()
        if watcher.active != (polling && AXIsProcessTrusted()) { scheduleTimers() }   // trust granted / revoked
        guard polling else { return }
        dock.refresh { [weak self] in self?.screensChanged(); self?.pollWindows() }   // the Dock moving can change visibleFrame
    }

    @objc private func askAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        axPoll?.invalidate()
        axTicks = 0
        axPoll = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(axPollTick), userInfo: nil, repeats: true)
    }
    private var axTicks = 0
    @objc private func axPollTick() {
        axTicks += 1
        guard AXIsProcessTrusted() || axTicks >= 60 else { return }
        axPoll?.invalidate()
        axPoll = nil
        refreshDock()   // hides the item and starts the Dock watch
    }
    private var axPoll: Timer?

    /// Register / unregister as a login item (needs the app bundle; /Applications is most reliable).
    private func setLogin(_ on: Bool) {
        let svc = SMAppService.mainApp
        do {
            if on { try svc.register() } else { try svc.unregister() }
        } catch {
            Logger(subsystem: "io.github.viniciuscandeia.neve", category: "login").error("login item: \(error.localizedDescription)")
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Switching Spaces hides every window at once: drop piles silently instead of an avalanche.
    @objc private func spaceChanged() { for o in overlays { o.dropPiles() } }

    @objc private func clearSnow() { for o in overlays { o.clear() } }
    @objc private func powerOff() { shuttingDown = true }
    @objc private func screensSlept() { screensAsleep = true; refreshRunState() }
    @objc private func screensWoke() { screensAsleep = false; refreshRunState() }
    @objc private func sessionResigned() { sessionInactive = true; refreshRunState() }
    @objc private func sessionBecameActive() { sessionInactive = false; refreshRunState() }
    @objc private func refreshRunStateNotification() { refreshRunState() }
    @objc private func accessibilityChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        updateStatus()
    }
    @objc private func powerChanged() {
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        for o in overlays { o.setLowPower(low) }
    }
}

if neveInstance == nil, let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
    exit(0)   // already running
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
