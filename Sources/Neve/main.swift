import NeveCore
import AppKit

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var overlays: [Overlay] = []
    private var timer: Timer?
    private var enabled = true
    private var suspended = false
    private var idleTicks = 0
    private let dock = DockWatcher()
    private var slowTimer: Timer?
    private let axItem = NSMenuItem(title: "Permitir neve no Dock…", action: #selector(askAccessibility), keyEquivalent: "")
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
        axItem.target = self
        axItem.isHidden = AXIsProcessTrusted()
        for i in [toggleItem, amount, clear, axItem, .separator(), quit] { menu.addItem(i) }
        item.menu = menu
        statusItem = item

        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(rebuildOverlays), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        ws.addObserver(self, selector: #selector(suspend), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(suspend), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(resume), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(resume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDock), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDock), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        rebuildOverlays()
    }

    @objc private func rebuildOverlays() {
        for o in overlays { o.teardown() }
        overlays = NSScreen.screens.compactMap { Overlay(screen: $0) }
        refreshRunState()
    }

    private func refreshRunState() {
        let run = enabled && !suspended
        for o in overlays { if run { o.start() } else { o.pause() } }
        timer?.invalidate()
        timer = nil
        slowTimer?.invalidate()
        slowTimer = nil
        if run {
            refreshDock()
            pollWindows()
            let st = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(refreshDock), userInfo: nil, repeats: true)
            st.tolerance = 1
            slowTimer = st
            let t = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(pollTick), userInfo: nil, repeats: true)
            t.tolerance = 0.03
            timer = t
        }
    }

    /// Windows move with the mouse (drag/resize), so poll at 10Hz while a button is down, else ~2Hz.
    @objc private func pollTick() {
        idleTicks += 1
        if NSEvent.pressedMouseButtons != 0 || idleTicks >= 5 { pollWindows() }
    }

    @objc private func pollWindows() {
        idleTicks = 0
        for o in overlays where o.geometryChanged { return rebuildOverlays() }
        guard let primary = NSScreen.screens.first else { return }
        var windows = readWindows(primaryHeight: primary.frame.height)
        if let d = dock.frame { windows.insert(WindowInfo(number: 0, frame: d, radius: d.height * 0.3), at: 0) }   // Dock draws above windows
        for o in overlays { o.update(windows: windows) }
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

    /// Dock bar frame via Accessibility; cheap no-op when untrusted. Called on app launch/quit, screen changes, every 3s.
    @objc private func refreshDock() {
        axItem.isHidden = AXIsProcessTrusted()
        guard let primary = NSScreen.screens.first else { return }
        dock.refresh(primaryHeight: primary.frame.height) { [weak self] in self?.pollWindows() }
    }

    @objc private func askAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Switching Spaces hides every window at once: drop piles silently instead of an avalanche.
    @objc private func spaceChanged() { for o in overlays { o.dropPiles() } }

    @objc private func clearSnow() { for o in overlays { o.clear() } }
    @objc private func suspend() { suspended = true; refreshRunState() }
    @objc private func resume() { suspended = false; refreshRunState() }
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
