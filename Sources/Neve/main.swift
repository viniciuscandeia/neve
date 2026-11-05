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

func runSelfTest() {
    // CG -> AppKit
    let r = appKitFrame(fromCG: CGRect(x: 100, y: 50, width: 300, height: 200), primaryHeight: 900)
    precondition(r == CGRect(x: 100, y: 650, width: 300, height: 200), "coord conversion")

    // Pile
    var p = Pile(columns: 50, inset: 12)
    p.deposit(bin: 25, volume: 5)
    precondition(p.heights[25] > 0, "deposit increases height")
    for _ in 0..<5 { p.deposit(bin: 25, volume: 8) }
    precondition(p.heights[24] > 0 && p.heights[26] > 0, "relaxation spreads")
    for _ in 0..<300 { p.deposit(bin: 25, volume: 5) }
    precondition(p.heights.max()! <= Tuning.maxPileHeight + 0.001, "max height")

    // Surface map + knock-off
    let field = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 10)
    let dock = WindowInfo(number: 0, frame: CGRect(x: 500, y: 20, width: 400, height: 60), radius: 18)
    let back = WindowInfo(number: 1, frame: CGRect(x: 100, y: 200, width: 300, height: 200))
    let front = WindowInfo(number: 2, frame: CGRect(x: 200, y: 300, width: 300, height: 300))
    field.update(windows: [dock, front, back])
    precondition(!field.edgeVisible(id: 1, x: 300), "back edge hidden under front window")
    precondition(field.edgeVisible(id: 1, x: 150), "back edge visible elsewhere")
    precondition(field.edgeVisible(id: 2, x: 300), "front edge visible")
    precondition(field.edgeVisible(id: 0, x: 700), "dock visible")
    precondition(!field.edgeVisible(id: 0, x: 200), "no snow surface outside the dock bar")

    let idx = field.surfaces.firstIndex { $0.id == 1 }!
    let c0 = field.surfaces[idx].c0
    for _ in 0..<20 { field.deposit(surface: idx, bin: 150 / 2 - c0, volume: 4) }
    precondition(field.pile(id: 1)!.heights.max()! > 1, "pile built")
    let n = field.update(windows: [dock, front, WindowInfo(number: 1, frame: back.frame.offsetBy(dx: 40, dy: 0))])
    precondition(n > 0 && field.debris.count == n, "knock-off spawns debris")
    precondition(field.pile(id: 1)!.heights.max()! == 0, "knock-off clears pile")

    // Window disappears (minimize / close / hide): all its snow falls.
    field.clear()
    let idx2 = field.surfaces.firstIndex { $0.id == 1 }!
    for _ in 0..<20 { field.deposit(surface: idx2, bin: 10, volume: 4) }
    let m = field.update(windows: [dock, front])
    precondition(m > 0 && field.debris.count == m && field.pile(id: 1) == nil, "vanished window drops snow as debris")

    // Space switch: piles dropped silently.
    let idx3 = field.surfaces.firstIndex { $0.id == 2 }!
    field.clear()
    for _ in 0..<20 { field.deposit(surface: idx3, bin: 40, volume: 4) }
    field.dropPiles()
    precondition(field.update(windows: []) == 0 && field.debris.isEmpty, "space switch makes no avalanche")

    // Rounded corner: baseline drops at the ends and snow slides off as debris.
    var p2 = Pile(columns: 100, inset: Tuning.cornerInset)
    p2.round(radius: 20, c0: 0, minX: 0, maxX: 200)
    precondition(p2.base[0] < -10 && p2.base[50] == 0, "baseline follows corner arc")
    for _ in 0..<200 { p2.deposit(bin: 1, volume: 5) }
    precondition(p2.spillL > 0, "snow slides off the corner")
    print("selftest ok")
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
