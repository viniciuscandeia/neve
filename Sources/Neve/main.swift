import NeveCore
import AppKit
import os

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var overlays: [Overlay] = []
    private var timer: Timer?
    private var enabled = true
    private var screensAsleep = false
    private var sessionInactive = false
    private let metalItem = NSMenuItem(title: "Metal indisponível", action: nil, keyEquivalent: "")
    private var loggedMetal = false
    private var idleTicks = 0
    private let dock = DockWatcher()
    private var slowTimer: Timer?
    private let axItem = NSMenuItem(title: "Permitir neve no Dock…", action: #selector(askAccessibility), keyEquivalent: "")
    private let economyItem = NSMenuItem(title: "Modo econômico", action: #selector(toggleEconomy), keyEquivalent: "")
    private var economy = UserDefaults.standard.bool(forKey: "economy")
    private let toggleItem = NSMenuItem(title: "Nevar", action: #selector(toggle), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Neve")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        let clear = NSMenuItem(title: "Limpar neve", action: #selector(clearSnow), keyEquivalent: "")
        let quit = NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        toggleItem.target = self
        clear.target = self
        toggleItem.state = .on
        let amount = NSMenuItem(title: "Quantidade", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in Intensity.allCases {
            let m = NSMenuItem(title: v.title, action: #selector(pickIntensity(_:)), keyEquivalent: "")
            m.target = self
            m.tag = v.rawValue
            m.state = v == Intensity.saved ? .on : .off
            sub.addItem(m)
        }
        amount.submenu = sub
        economyItem.target = self
        economyItem.state = economy ? .on : .off
        axItem.target = self
        axItem.isHidden = AXIsProcessTrusted()
        metalItem.isHidden = true
        for i in [metalItem, toggleItem, amount, economyItem, clear, axItem, .separator(), quit] { menu.addItem(i) }
        item.menu = menu
        statusItem = item

        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(rebuildOverlays), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        ws.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDock), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDock), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(thermalChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        dock.onChange = { [weak self] in self?.refreshDock() }
        rebuildOverlays()
    }

    @objc private func rebuildOverlays() {
        for o in overlays { o.teardown() }
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
        overlays += wanted.filter { s in !overlays.contains { $0.screen == s } }.compactMap { Overlay(screen: $0) }
        metalItem.isHidden = !overlays.isEmpty || NSScreen.screens.isEmpty
        refreshRunState()
    }

    private var running: Bool { enabled && !screensAsleep && !sessionInactive }
    private var hot: Bool { ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue }
    /// Polling timers only run while snow is actually shown (not disabled / asleep / locked / hot).
    private var polling: Bool { running && !hot }
    private var fullscreenIdle: Bool { !overlays.isEmpty && overlays.allSatisfy(\.isFullscreen) }

    private func refreshRunState() {
        for o in overlays { if running { o.start() } else { o.pause() } }
        scheduleTimers()
        if polling {
            refreshDock()
            pollWindows()
        }
    }

    /// 10Hz window tick (drag/resize) + 30s Dock refresh; just a 1Hz watch while every screen is under a fullscreen app. `.common` so menus don't stall them.
    private func scheduleTimers() {
        timer?.invalidate()
        timer = nil
        slowTimer?.invalidate()
        slowTimer = nil
        guard polling else { return }
        let idle = fullscreenIdle
        let t = Timer(timeInterval: idle ? 1 : 0.1, target: self, selector: #selector(pollTick), userInfo: nil, repeats: true)
        t.tolerance = idle ? 0.2 : 0.03
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if !idle {
            let st = Timer(timeInterval: 30, target: self, selector: #selector(refreshDock), userInfo: nil, repeats: true)
            st.tolerance = 1
            RunLoop.main.add(st, forMode: .common)
            slowTimer = st
        }
    }

    /// Windows move with the mouse (drag/resize), so poll at 10Hz while a button is down, else ~2Hz.
    @objc private func pollTick() {
        idleTicks += 1
        if fullscreenIdle || NSEvent.pressedMouseButtons != 0 || idleTicks >= 5 { pollWindows() }
    }

    @objc private func pollWindows() {
        idleTicks = 0
        for o in overlays where o.geometryChanged { return rebuildOverlays() }
        guard let primary = NSScreen.screens.first else { return }
        var windows = readWindows(primaryHeight: primary.frame.height)
        let covering = windows.map(\.frame)
        if let d = dock.frame { windows.insert(WindowInfo(number: 0, frame: d, radius: d.height * 0.3), at: 0) }   // Dock draws above windows
        for o in overlays {
            o.setFullscreen(covering.contains { o.covers($0) })
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
        refreshRunState()
    }

    @objc private func pickIntensity(_ sender: NSMenuItem) {
        guard let v = Intensity(rawValue: sender.tag) else { return }
        UserDefaults.standard.set(v.rawValue, forKey: Intensity.key)
        for m in sender.menu?.items ?? [] { m.state = m == sender ? .on : .off }
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

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
