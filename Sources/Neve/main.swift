import NeveCore
import AppKit
import os
import ServiceManagement

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var overlays: [Overlay] = []
    private var timer: Timer?
    private var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    private var screensAsleep = false
    private var sessionInactive = false
    private let metalItem = NSMenuItem(title: "Metal indisponível", action: nil, keyEquivalent: "")
    private var loggedMetal = false
    private var mouseDown = false
    private var userIdle = false   // no input for 5 min: rendering paused, polling kept to notice input
    private var mouseMonitor: Any?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let dock = DockWatcher()
    private var slowTimer: Timer?
    private let axItem = NSMenuItem(title: "Permitir neve no Dock…", action: #selector(askAccessibility), keyEquivalent: "")
    private let economyItem = NSMenuItem(title: "Modo econômico", action: #selector(toggleEconomy), keyEquivalent: "")
    private var economy = UserDefaults.standard.bool(forKey: "economy")
    private let loginItem = NSMenuItem(title: "Abrir no login", action: #selector(toggleLogin), keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Nevar", action: #selector(toggle), keyEquivalent: "n")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.symbol("snowflake", "Neve")
        let menu = NSMenu()
        menu.delegate = self
        let clear = NSMenuItem(title: "Limpar neve", action: #selector(clearSnow), keyEquivalent: "k")
        let quit = NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = Self.symbol("power")
        clear.image = Self.symbol("sparkles")
        toggleItem.image = Self.symbol("snowflake")
        toggleItem.target = self
        clear.target = self
        toggleItem.state = enabled ? .on : .off
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
        economyItem.target = self
        economyItem.image = Self.symbol("leaf")
        economyItem.state = economy ? .on : .off
        axItem.target = self
        axItem.image = Self.symbol("exclamationmark.triangle")
        axItem.isHidden = AXIsProcessTrusted()
        metalItem.isHidden = true
        let items: [NSMenuItem] = [statusLine, metalItem, .separator(), toggleItem, .sectionHeader(title: "QUANTIDADE")] + levels
            + [.separator(), .sectionHeader(title: "OPÇÕES"), economyItem, loginItem, axItem, .separator(), clear, quit]
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
        nc.addObserver(self, selector: #selector(thermalChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        // Global mouse monitors need no Accessibility permission; 10Hz polling only while the button is down.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouseDown = e.type == .leftMouseDown
                self.scheduleTimers()
                if !self.mouseDown && self.polling { self.pollWindows() }
            }
        }
        dock.onChange = { [weak self] in self?.refreshDock() }
        rebuildOverlays()
    }

    /// Screen set / frame / scale of the last rebuild; Dock and menu-bar (visibleFrame) changes never rebuild.
    private var builtKeys: [[CGFloat]] = []
    private func keys(_ s: [NSScreen]) -> [[CGFloat]] { s.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height, $0.backingScaleFactor] } }

    /// Leaving / entering fullscreen reshuffles the menu bar and Dock mid-Space-animation: ignore geometry until ~1s after.
    private var settleUntil = Date.distantPast
    private var settling: Bool { overlays.contains(where: \.isFullscreen) || Date() < settleUntil }

    /// Rebuild only if the screens really changed, else just move ground / menu-bar cutoffs in place.
    @objc private func screensChanged() {
        if polling && settling { return }   // the poll timer re-checks once settled
        if keys(wantedScreens) != builtKeys { rebuildOverlays() } else { overlays.forEach { $0.refreshBounds() } }
    }

    private func rebuildOverlays() {
        for o in overlays { o.teardown() }
        builtKeys = keys(wantedScreens)
        overlays = wantedScreens.compactMap { Overlay(screen: $0) }
        if overlays.count < wantedScreens.count && !loggedMetal {
            loggedMetal = true
            Logger(subsystem: "io.github.viniciuscandeia.neve", category: "overlay").error("Metal overlay could not be created for a screen")
        }
        metalItem.isHidden = !overlays.isEmpty || NSScreen.screens.isEmpty
        refreshRunState()
    }

    /// Economy mode: only the screen with the menu bar gets an overlay; the others are torn down.
    private var wantedScreens: [NSScreen] { economy ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens }

    @objc private func toggleEconomy() {
        economy.toggle()
        UserDefaults.standard.set(economy, forKey: "economy")
        economyItem.state = economy ? .on : .off
        let wanted = wantedScreens
        overlays.filter { o in !wanted.contains(o.screen) }.forEach { $0.teardown() }
        overlays.removeAll { o in !wanted.contains(o.screen) }   // main-screen piles are kept
        for o in overlays { o.setEconomy(economy) }
        builtKeys = keys(wanted)
        overlays += wanted.filter { s in !overlays.contains { $0.screen == s } }.compactMap { Overlay(screen: $0) }
        metalItem.isHidden = !overlays.isEmpty || NSScreen.screens.isEmpty
        refreshRunState()
    }

    private var running: Bool { enabled && !screensAsleep && !sessionInactive }
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
        if economy { s += " · econômico" }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { s += " · movimento reduzido" }
        return s
    }

    private func updateStatus() {
        statusLine.attributedTitle = NSAttributedString(string: "❄ Neve — " + statusText, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)])
        let paused = !enabled || !polling || userIdle || fullscreenIdle
        statusItem?.button?.appearsDisabled = paused
        axItem.isHidden = AXIsProcessTrusted()
    }

    func menuWillOpen(_ menu: NSMenu) { updateStatus() }

    private func refreshRunState() {
        updateStatus()
        for o in overlays { if running && !userIdle { o.start() } else { o.pause() } }
        scheduleTimers()
        if polling {
            refreshDock()
            pollWindows()
        }
    }

    /// 0.5s window poll (10Hz while the mouse is down) + 30s Dock refresh; just a 1Hz watch while every screen is under a fullscreen app. `.common` so menus don't stall them.
    private func scheduleTimers() {
        timer?.invalidate()
        timer = nil
        slowTimer?.invalidate()
        slowTimer = nil
        guard polling else { return }
        let idle = fullscreenIdle
        let t = Timer(timeInterval: idle ? 1 : (mouseDown ? 0.1 : 0.5), target: self, selector: #selector(pollTick), userInfo: nil, repeats: true)
        t.tolerance = idle ? 0.2 : (mouseDown ? 0.03 : 0.1)
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
        if !userIdle && since >= 300 { userIdle = true; refreshRunState() }
        else if userIdle && since < 1 { userIdle = false; refreshRunState() }
        if !userIdle { pollWindows() }
    }

    @objc private func pollWindows() {
        if !settling { screensChanged() }
        guard let primary = NSScreen.screens.first else { return }
        var windows = readWindows(primaryHeight: primary.frame.height)
        let covering = windows.map(\.frame)
        if let d = dock.frame { windows.insert(WindowInfo(number: 0, frame: d, radius: d.height * 0.3), at: 0) }   // Dock draws above windows
        for o in overlays {
            let fs = covering.contains { o.covers($0) }
            if fs != o.isFullscreen { settleUntil = Date().addingTimeInterval(1) }
            o.setFullscreen(fs)
            if !o.isFullscreen { o.update(windows: windows) }   // under fullscreen the list is just that app: keep piles untouched
        }
        if fullscreenIdle != (timer?.timeInterval == 1) {
            scheduleTimers()
            if !fullscreenIdle { refreshDock() }
        }
    }

    @objc private func toggle() {
        enabled.toggle()
        toggleItem.state = enabled ? .on : .off
        UserDefaults.standard.set(enabled, forKey: "enabled")
        refreshRunState()
    }

    @objc private func pickIntensity(_ sender: NSMenuItem) {
        guard let v = Intensity(rawValue: sender.tag) else { return }
        UserDefaults.standard.set(v.rawValue, forKey: Intensity.key)
        for m in sender.menu?.items ?? [] where Intensity(rawValue: m.tag) != nil && m.action == sender.action { m.state = m == sender ? .on : .off }
        for o in overlays { o.setIntensity(v) }
    }

    /// Dock bar frame via Accessibility; cheap no-op when untrusted. Called on Dock AX events, app launch/quit, screen changes, every 30s.
    @objc private func refreshDock() {
        axItem.isHidden = AXIsProcessTrusted()
        guard polling else { return }
        dock.refresh { [weak self] in self?.pollWindows() }
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
    @objc private func thermalChanged() {
        let h = hot
        for o in overlays { o.setHot(h) }
        refreshRunState()
    }
    @objc private func powerChanged() {
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        for o in overlays { o.setLowPower(low) }
    }
}

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
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
