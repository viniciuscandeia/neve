import NeveCore
import AppKit
import os
import ServiceManagement

/// UserDefaults keys of the on / off options. Defaults: Nevar and Boneco de neve on, the rest off.
enum Pref: String {
    case enabled, economy, ambient, behindWindows, stillSnow, snowman, showInCaptures
    var defaultValue: Bool { self == .enabled || self == .snowman }
}

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
    private let ud = UserDefaults.standard
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion   // read once per system change
    private let axItem = NSMenuItem(title: "Permitir neve no Dock…", action: #selector(askAccessibility), keyEquivalent: "")
    private var prefItems: [Pref: NSMenuItem] = [:]
    private let whereItem = NSMenuItem(title: "Nevar em", action: nil, keyEquivalent: "")
    private let snowballHint = NSMenuItem(title: "Segure ⌥ e arraste a neve para fazer bolas", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Abrir no login", action: #selector(toggleLogin), keyEquivalent: "")

    private func flag(_ p: Pref) -> Bool { ud.object(forKey: p.rawValue) as? Bool ?? p.defaultValue }
    private var enabled: Bool { flag(.enabled) }
    private var economy: Bool { flag(.economy) }
    private var ambient: Bool { flag(.ambient) }
    private var behind: Bool { flag(.behindWindows) }
    /// Everything the overlays render from the options; the single place UserDefaults is read for them.
    private var overlayPrefs: OverlayPrefs {
        OverlayPrefs(economy: economy, behind: behind, still: flag(.stillSnow), snowman: flag(.snowman), showInCaptures: flag(.showInCaptures), intensity: .saved)
    }
    private func applyPrefs() { let p = overlayPrefs; for o in overlays { o.apply(p) } }

    /// A check-mark menu item bound to a Pref, handled by `togglePref(_:)`.
    private func toggleItem(_ pref: Pref, _ title: String, symbol: String, key: String = "") -> NSMenuItem {
        let m = NSMenuItem(title: title, action: #selector(togglePref(_:)), keyEquivalent: key)
        m.target = self
        m.representedObject = pref.rawValue
        m.image = Self.symbol(symbol)
        m.state = flag(pref) ? .on : .off
        prefItems[pref] = m
        return m
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)   // global default: a hung app or the Dock must not stall AX reads
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.symbol("snowflake", "Neve")
        let menu = NSMenu()
        menu.delegate = self
        let clear = NSMenuItem(title: "Limpar neve", action: #selector(clearSnow), keyEquivalent: "k")
        let quit = NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = Self.symbol("power")
        clear.image = Self.symbol("sparkles")
        clear.target = self
        loginItem.target = self
        loginItem.image = Self.symbol("arrow.right.circle")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let symbols = ["snowflake", "cloud.snow", "cloud.snow.fill", "wind.snow"]
        var levels: [NSMenuItem] = []
        for v in Intensity.allCases {
            let m = NSMenuItem(title: v.title, action: #selector(pickIntensity(_:)), keyEquivalent: "")
            m.target = self
            m.tag = v.rawValue
            m.image = Self.symbol(symbols[v.rawValue])
            m.state = v == Intensity.saved ? .on : .off
            levels.append(m)
        }
        snowballHint.isEnabled = false
        snowballHint.attributedTitle = NSAttributedString(string: snowballHint.title, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        snowballHint.indentationLevel = 1
        whereItem.image = Self.symbol("display")
        whereItem.submenu = NSMenu()
        axItem.target = self
        axItem.image = Self.symbol("exclamationmark.triangle")
        axItem.isHidden = AXIsProcessTrusted()
        metalItem.isHidden = true
        let options = [toggleItem(.economy, "Modo econômico", symbol: "leaf"), toggleItem(.ambient, "Modo ambiente", symbol: "sun.max"),
                       toggleItem(.behindWindows, "Atrás das janelas", symbol: "square.stack.3d.down.right"),
                       toggleItem(.stillSnow, "Neve parada (movimento reduzido)", symbol: "pause.circle"),
                       toggleItem(.snowman, "Boneco de neve", symbol: "figure.stand")]
        let items: [NSMenuItem] = [statusLine, metalItem, .separator(), toggleItem(.enabled, "Nevar", symbol: "snowflake", key: "n"), .sectionHeader(title: "QUANTIDADE")] + levels
            + [.separator(), .sectionHeader(title: "OPÇÕES"), whereItem] + options + [snowballHint, toggleItem(.showInCaptures, "Mostrar em capturas", symbol: "camera"), loginItem, axItem, .separator(), clear, quit]
        for i in items { menu.addItem(i) }
        updateStatus()
        item.menu = menu
        statusItem = item

        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        ws.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDock), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDock), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(refreshRunStateNotification), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
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

    @objc private func pickTarget(_ sender: NSMenuItem) {
        ud.set(sender.representedObject as? String ?? "all", forKey: "snowOn")
        syncOverlays()
    }

    private func rebuildWhereMenu() {
        guard let m = whereItem.submenu else { return }
        m.removeAllItems()
        var rows: [(String, String)] = [("Todas as telas", "all"), ("Só na tela principal", "main")]
        if NSScreen.screens.count > 1 { rows += NSScreen.screens.map { ($0.localizedName, String(displayID($0))) } }
        let cur = rows.contains { $0.1 == target } ? target : "all"
        for (title, key) in rows {
            let i = NSMenuItem(title: title, action: #selector(pickTarget(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = key
            i.state = key == cur ? .on : .off
            i.isEnabled = !economy
            m.addItem(i)
        }
    }

    /// Flips the Pref a menu item is bound to (see `toggleItem`), then reacts to it.
    @objc private func togglePref(_ sender: NSMenuItem) {
        guard let pref = (sender.representedObject as? String).flatMap(Pref.init(rawValue:)) else { return }
        let on = !flag(pref)
        ud.set(on, forKey: pref.rawValue)
        sender.state = on ? .on : .off
        switch pref {
        case .enabled: refreshRunState()
        case .economy: syncOverlays()
        case .ambient: if on && userIdle { userIdle = false; refreshRunState() } else { updateStatus() }
        case .behindWindows:
            applyPrefs()
            if polling { pollWindows() }   // empties / refills the surface list
            updateStatus()
        case .stillSnow, .snowman, .showInCaptures: applyPrefs()
        }
    }

    private var running: Bool { enabled && !screensAsleep && !sessionInactive }
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
        let level = Intensity.saved
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
        statusItem?.button?.appearsDisabled = paused
        axItem.isHidden = AXIsProcessTrusted()
    }

    func menuWillOpen(_ menu: NSMenu) {
        prefItems[.stillSnow]?.isHidden = !reduceMotion
        rebuildWhereMenu()
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

    @objc private func pollWindows() {
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
        if fullscreenIdle != idleWatch {
            scheduleTimers()
            if !fullscreenIdle { refreshDock() }
        }
    }

    @objc private func pickIntensity(_ sender: NSMenuItem) {
        guard let v = Intensity(rawValue: sender.tag) else { return }
        ud.set(v.rawValue, forKey: Intensity.key)
        for m in sender.menu?.items ?? [] where Intensity(rawValue: m.tag) != nil && m.action == sender.action { m.state = m == sender ? .on : .off }
        applyPrefs()
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
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled || svc.status == .requiresApproval { try svc.unregister() } else { try svc.register() }
        } catch {
            Logger(subsystem: "io.github.viniciuscandeia.neve", category: "login").error("login item: \(error.localizedDescription)")
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        loginItem.state = svc.status == .enabled ? .on : .off
    }

    /// Switching Spaces hides every window at once: drop piles silently instead of an avalanche.
    @objc private func spaceChanged() { for o in overlays { o.dropPiles() } }

    @objc private func clearSnow() { for o in overlays { o.clear() } }
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

if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
    exit(0)   // already running
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
