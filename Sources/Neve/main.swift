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
    private var screensaver = false   // the screen saver covers the displays: nothing to draw under it
    private var missionControl = false, mcTimer: Timer?
    private let panel = PanelState()
    private var loggedMetal = false
    private var mouseDown = false
    private var userIdle = false   // no input for 5 min (after the melt): rendering paused, polling kept to notice input
    private var idleMelting = false   // the 5 min fired: snow is melting away, then userIdle
    private var meltGen = 0
    /// Idle timeout in seconds; NEVE_IDLE_SECS shortens it for dev / recordings.
    private let idleSecs = Double(ProcessInfo.processInfo.environment["NEVE_IDLE_SECS"] ?? "") ?? 300
    private var mouseMonitor: Any?
    private let dock = DockWatcher()
    private let watcher = WindowWatcher()
    private var slowTimer: Timer?
    private var lastScreensCheck = -Double.infinity   // monotonic (CACurrentMediaTime): a wall-clock jump must not stall the checks
    /// The one defaults store: a per-instance suite for dev builds, so concurrent instances never share prefs.
    private let ud = neveInstance.flatMap { UserDefaults(suiteName: "io.github.viniciuscandeia.neve.dev.\($0)") } ?? .standard
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion   // read once per system change
    private var menuViews: [NSView] = []   // the custom-view items, re-fitted each time the menu opens
    private var ajustesItem: NSMenuItem?
    private var tabsObservation: NSKeyValueObservation?
    private static let ajustesOpenedKey = "ajustesOpened"   // the Accessibility dot on Ajustes… shows until the window was opened once
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
        // Scene mode: fixed options (Mostrar em capturas ON, everything alive), whatever the user saved; nothing is written back.
        if let k = sceneKind { var p = OverlayPrefs(); p.showInCaptures = true; p.adaptive = false; p.intensity = k == .demo ? .forte : .media; return p }
        var p = OverlayPrefs(flag); p.intensity = Intensity.saved(ud); return p
    }
    private func applyPrefs() { let p = overlayPrefs; for o in overlays { o.apply(p) } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)   // global default: a hung app or the Dock must not stall AX reads
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.symbol("snowflake", "Neve")
        if let n = neveInstance { item.button?.title = " \(n)"; item.button?.imagePosition = .imageLeft }
        item.menu = buildMenu()   // a real menu for left and right click alike (HIG: a menu, not a popover)
        statusItem = item
        updateStatus()
        installMainMenu()

        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        prefSnapshot = prefValues()
        syncMusic()
        intensitySnapshot = Intensity.saved(ud)
        // These can be posted from any thread (thermal / power state from a system queue, defaults from anywhere): the
        // selector API would call the @MainActor methods off the main thread and trap, so deliver them on the main queue.
        nc.addObserver(forName: UserDefaults.didChangeNotification, object: ud, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.syncPrefs() } }
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.powerChanged() } }
        ws.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        let dn = DistributedNotificationCenter.default()   // a screen lock keeps the displays awake and the session active
        dn.addObserver(self, selector: #selector(sessionResigned), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dn.addObserver(self, selector: #selector(sessionBecameActive), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        dn.addObserver(self, selector: #selector(screensaverStarted), name: NSNotification.Name("com.apple.screensaver.didstart"), object: nil)
        dn.addObserver(self, selector: #selector(screensaverStopped), name: NSNotification.Name("com.apple.screensaver.didstop"), object: nil)
        ws.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDock), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDock), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshRunState() } }
        ws.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        dock.onChange = { [weak self] in self?.refreshDock() }
        for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                  NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            ws.addObserver(self, selector: #selector(transitionPollNotification), name: n, object: nil)
        }
        ws.addObserver(self, selector: #selector(settlePollNotification), name: NSWorkspace.didHideApplicationNotification, object: nil)
        watcher.onChange = { [weak self] in self?.transitionPoll() }   // an AX event is a transition: the window may still be animating
        watcher.onSettle = { [weak self] in self?.settlePoll() }       // minimize / hide animations outlast the burst: one more read afterwards
        syncOverlays()
        // First launch only: open the menu once so the icon is found (no dialog).
        if neveInstance == nil, sceneKind == nil, takeOnce("firstLaunchMenuShown", in: ud) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.statusItem?.button?.performClick(nil) }
        }
    }

    /// Double-click in Finder while running: the menu-bar extra may be hidden or crowded out, so show Ajustes and make sure the item is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        showSettingsWindow()
        return true
    }

    /// Global mouse monitors need no Accessibility permission. Installed only while snow is polling (the poll scheduler samples at ~25 Hz during a window drag).
    private func syncMouseMonitor() {
        if polling, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] e in
                MainActor.assumeIsolated { self?.mouseEvent(e.type) }
            }
        } else if !polling, let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
            mouseDown = false
        }
    }

    private func displayID(_ s: NSScreen) -> Int { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0 }

    /// Leaving / entering fullscreen reshuffles the menu bar and Dock mid-Space-animation: per screen, ignore visibleFrame ~1s after.
    private var settleUntil: [Int: Double] = [:]   // CACurrentMediaTime
    private func settling(_ o: Overlay) -> Bool { o.isFullscreen || CACurrentMediaTime() < settleUntil[displayID(o.screen), default: -.infinity] }

    /// Real configuration changes (screens added / removed, frame or scale) apply at once, per screen;
    /// only visibleFrame-only changes (Dock, menu bar) wait for a transitioning screen to settle.
    @objc private func screensChanged() {
        lastScreensCheck = CACurrentMediaTime()
        syncPanelInfo()
        let wanted = wantedScreens
        let ids = Set(wanted.map(displayID))
        let changed = Set(overlays.map { displayID($0.screen) }) != ids
            || wanted.contains { s in overlays.contains { displayID($0.screen) == displayID(s) && $0.screenChanged(s) } }
        if changed { syncOverlays() }
        var recheck = 0.0
        for o in overlays {
            if polling && settling(o) { recheck = max(recheck, settleUntil[displayID(o.screen), default: 0] - CACurrentMediaTime()) }
            else { o.refreshBounds() }
        }
        if recheck > 0 {   // skipped while settling: look again once the settle window ends
            settleTimer?.invalidate()
            settleTimer = Timer.scheduledTimer(withTimeInterval: recheck + 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestPoll([.geometry]) }
            }
        }
    }
    private var settleTimer: Timer?

    /// A display that vanished (wake, KVM, cable): its overlay is hidden and kept this long in case the same display returns.
    private var parked: [Int: Overlay] = [:]
    private var parkTimer: Timer?

    /// Makes the overlays match wantedScreens: tears down unwanted / changed ones, creates missing ones; other screens keep their piles.
    private func syncOverlays() {
        let wanted = wantedScreens
        let present = Set(NSScreen.screens.map(displayID))
        func stale(_ o: Overlay) -> Bool { !wanted.contains { displayID($0) == displayID(o.screen) } }   // a new frame / scale is adopted in place (piles kept)
        for o in overlays.filter(stale) {
            let id = displayID(o.screen)
            if present.contains(id) { o.teardown() }   // a pref / frame change: as before
            else { o.setRun(false); parked[id]?.teardown(); parked[id] = o }   // unplugged: wait before throwing the piles away
        }
        overlays.removeAll(where: stale)
        for o in overlays { if let s = wanted.first(where: { displayID($0) == displayID(o.screen) }), o.screenChanged(s) { o.adopt(s, prefs: overlayPrefs) } }
        applyPrefs()
        var missing = wanted.filter { s in !overlays.contains { displayID($0.screen) == displayID(s) } }
        for s in missing {
            guard let p = parked.removeValue(forKey: displayID(s)) else { continue }
            p.adopt(s, prefs: overlayPrefs); overlays.append(p)
        }
        missing.removeAll { s in overlays.contains { displayID($0.screen) == displayID(s) } }
        for (id, p) in parked where present.contains(id) { p.teardown(); parked[id] = nil }   // back but unwanted
        parkTimer?.invalidate()
        parkTimer = nil
        if !parked.isEmpty {
            parkTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.parked.values.forEach { $0.teardown() }; self?.parked = [:] }
            }
        }
        let prefs = overlayPrefs
        let made = missing.compactMap { Overlay(screen: $0, prefs: prefs) }
        if made.count < missing.count && !loggedMetal {
            loggedMetal = true
            Logger(subsystem: "io.github.viniciuscandeia.neve", category: "overlay").error("Metal overlay could not be created for a screen")
        }
        overlays += made
        panel.metalMissing = overlays.isEmpty && !NSScreen.screens.isEmpty
        refreshRunState()
    }

    /// "all" / "main" / a display ID. Economy forces the main screen (the one with the menu bar).
    private var target: String { ud.string(forKey: "snowOn") ?? "all" }
    private var wantedScreens: [NSScreen] {
        let all = NSScreen.screens
        if sceneKind != nil { return Array(all.prefix(1)) }
        if economy || target == "main" { return Array(all.prefix(1)) }
        if let id = Int(target), let s = all.first(where: { displayID($0) == id }) { return [s] }
        return all   // "all", or the chosen screen is unplugged
    }

    private func setTarget(_ t: String) {
        ud.set(t, forKey: "snowOn")
        syncOverlays()
    }

    private func prefValues() -> [Pref: Bool] { Dictionary(uniqueKeysWithValues: Pref.allCases.map { ($0, flag($0)) }) }

    /// Diffs the Bool prefs against the last snapshot and reacts to each change; called by the defaults observer (the panel writes straight to defaults).
    @objc private func syncPrefs() {
        let new = prefValues()
        let changed = changedPrefs(old: prefSnapshot, new: new)
        prefSnapshot = new
        changed.forEach(prefChanged)
        let level = Intensity.saved(ud)   // not a Pref: set by the Quantidade row
        if level != intensitySnapshot { intensitySnapshot = level; applyPrefs(); updateStatus() }
    }

    /// The single reaction path for a pref that just changed.
    private func prefChanged(_ pref: Pref) {
        let on = flag(pref)
        switch pref {
        case .enabled:
            outroGen += 1; meltGen += 1; idleMelting = false
            if on { outroing = false; overlays.forEach { $0.intro() }; refreshRunState() }
            else { updateStatus(); runOutro { [weak self] in self?.refreshRunState() } }
        case .economy: syncOverlays(); syncMusic()
        case .music: applyPrefs(); syncMusic()
        case .ambient: if on && (userIdle || idleMelting) { wakeFromIdle() } else { updateStatus() }
        case .behindWindows:
            applyPrefs()
            requestPoll()   // empties / refills the surface list
            updateStatus()
        case .behindLarge:
            applyPrefs()
            requestPoll()   // the occluders / coverage follow the option now, not at the next window change
        case .stillSnow, .snowman, .walk, .visitors, .sleigh, .showInCaptures, .adaptiveFps, .pointerPush: applyPrefs()
        }
    }

    /// The tap runs only while the option is on and nothing asks for calm: Reduce Motion, economy, Low Power. Off = tap destroyed.
    private func syncMusic() {
        let calm = economy || ProcessInfo.processInfo.isLowPowerModeEnabled
        let want = flag(.music) && !reduceMotion && !calm && sceneKind == nil
        if want, !MusicTap.shared.running {
            // The cause is unknown (permission, output device or aggregate creation can all fail): say so neutrally.
            panel.musicNote = MusicTap.shared.start() ? "" : (MusicTap.supported ? tr("Sem acesso ao áudio. Veja Privacidade e Segurança e a saída de som.") : tr("Precisa do macOS 14.2 ou mais novo."))
        } else if !want {
            MusicTap.shared.stop()
            if MusicTap.supported { panel.musicNote = flag(.music) && calm && !reduceMotion && sceneKind == nil ? (economy ? tr("Pausada: modo econômico ligado.") : tr("Pausada: Modo de Baixo Consumo ligado.")) : "" }
        }
    }

    /// Screen list, Reduce Motion and the login state shown live in Ajustes.
    private func syncPanelInfo() {
        let all = NSScreen.screens
        let labels = screenLabels(names: all.map(\.localizedName), sizes: all.map { $0.frame.size })
        panel.screens = all.count > 1 ? zip(all, labels).map { (title: $1, id: String(displayID($0))) } : []
        panel.reduceMotion = reduceMotion
        panel.loginOn = loginOn
    }

    private func settingsEnv() -> SettingsEnv {
        syncPanelInfo()
        return SettingsEnv(store: ud, isDev: neveInstance != nil,
                           target: Binding(get: { [weak self] in self.map { s in (["all", "main"] + s.panel.screens.map(\.id)).contains(s.target) ? s.target : "all" } ?? "all" }, set: { [weak self] in self?.setTarget($0) }),
                           login: Binding(get: { [weak self] in self?.panel.loginOn ?? false }, set: { [weak self] in self?.setLogin($0) }),
                           openWindow: { [weak self] in self?.showSettingsWindow() },
                           panel: panel, askAccessibility: { [weak self] in self?.askAccessibility() },
                           restoreDefaults: { [weak self] in if let ud = self?.ud { restoreDefaults(in: ud) } })
    }

    // MARK: menu (NSMenu on the status item; custom-view items for Nevar and Quantidade, the rest plain items)

    private func buildMenu() -> NSMenu {
        let env = settingsEnv()
        let m = NSMenu()
        m.delegate = self
        m.autoenablesItems = false
        func custom<V: View>(_ v: V) -> NSMenuItem {
            let h = NSHostingView(rootView: v)
            h.frame.size = h.fittingSize
            menuViews.append(h)
            let i = NSMenuItem()
            i.view = h
            return i
        }
        func item(_ title: String, _ symbol: String, _ sel: Selector, _ key: String, _ target: AnyObject) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = target
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return i
        }
        m.addItem(custom(MenuHeader(panel: panel, env: env)))
        m.addItem(custom(IntensityTile(store: ud)))
        m.addItem(.separator())
        m.addItem(item(tr("Limpar neve"), "eraser", #selector(clearSnow), "k", self))
        let a = item(tr("Ajustes…"), "gearshape", #selector(showSettingsWindow), ",", self)
        ajustesItem = a
        m.addItem(a)
        m.addItem(.separator())
        m.addItem(item(tr("Sair"), "power", #selector(NSApplication.terminate(_:)), "q", NSApp))
        return m
    }

    /// Refresh before it shows: live status, item heights (the status text may wrap), the Accessibility dot. ⌥-click skips the menu for Ajustes.
    func menuWillOpen(_ menu: NSMenu) {
        if NSEvent.modifierFlags.contains(.option) {
            menu.cancelTracking()
            DispatchQueue.main.async { [weak self] in self?.showSettingsWindow() }
            return
        }
        updateStatus()
        menuViews.forEach { $0.frame.size = $0.fittingSize }
        let dot = panel.axMissing && !ud.bool(forKey: Self.ajustesOpenedKey)
        if dot {
            let t = NSMutableAttributedString(string: tr("Ajustes…") + " ")
            t.append(NSAttributedString(string: "●", attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 8)]))
            ajustesItem?.attributedTitle = t
        } else { ajustesItem?.attributedTitle = nil }
        ajustesItem?.setAccessibilityHelp(dot ? tr("Falta a permissão de Acessibilidade, opcional.") : nil)
    }

    /// Just enough of a main menu for the Ajustes window (and any key window): ⌘, ⌘W ⌘Q and the Edit commands. An accessory app shows it only while active.
    private func installMainMenu() {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let i = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
        }
        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let m = NSMenu(title: title)
            build(m)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
        }
        submenu("Neve") { m in
            add(m, tr("Ajustes…"), #selector(showSettingsWindow), ",", target: self)
            m.addItem(.separator())
            add(m, tr("Sair"), #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        }
        submenu(tr("Editar")) { m in
            add(m, tr("Desfazer"), Selector(("undo:")), "z")
            add(m, tr("Refazer"), Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            add(m, tr("Recortar"), #selector(NSText.cut(_:)), "x")
            add(m, tr("Copiar"), #selector(NSText.copy(_:)), "c")
            add(m, tr("Colar"), #selector(NSText.paste(_:)), "v")
            add(m, tr("Selecionar Tudo"), #selector(NSText.selectAll(_:)), "a")
        }
        submenu(tr("Janela")) { m in add(m, tr("Fechar"), #selector(NSWindow.performClose(_:)), "w") }
        NSApp.mainMenu = main
    }

    /// The single "Ajustes" window: toolbar tabs (System Settings style, title = selected tab), not resizable, last tab remembered.
    @objc private func showSettingsWindow() {
        ud.set(true, forKey: Self.ajustesOpenedKey)
        syncPanelInfo()
        if settingsWindow == nil {
            let env = settingsEnv()
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for t in SettingsTab.allCases {
                let host = NSHostingController(rootView: SettingsPane(env: env, tab: t))
                host.sizingOptions = .preferredContentSize
                let ti = NSTabViewItem(viewController: host)
                ti.label = t.title
                ti.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
                tabs.addTabViewItem(ti)
            }
            tabs.selectedTabViewItemIndex = min(max(0, ud.integer(forKey: SettingsTab.key)), SettingsTab.allCases.count - 1)
            tabsObservation = tabs.observe(\.selectedTabViewItemIndex) { [weak self] t, _ in
                MainActor.assumeIsolated { self?.ud.set(t.selectedTabViewItemIndex, forKey: SettingsTab.key) }
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
            // In-process window: AXObserver skips our own pid, so refresh the snow surfaces from NSWindow events.
            for n in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification,
                      NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(settingsWindowChanged), name: n, object: w)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(syncLoginState), name: NSWindow.didBecomeKeyNotification, object: w)   // the user may have changed it in System Settings
        }
        // after the menu has finished closing, or the activation is lost
        DispatchQueue.main.async { [weak self] in
            NSApp.activate()
            self?.settingsWindow?.makeKeyAndOrderFront(nil)
            self?.settingsWindowChanged()
        }
    }

    @objc private func syncLoginState() { panel.loginOn = loginOn }

    /// Coalesced through the window watcher's rate limit; the async hop lets a closing window leave the on-screen list first.
    @objc private func settingsWindowChanged() {
        DispatchQueue.main.async { [weak self] in self?.requestPoll() }
    }

    private var outroing = false   // an outro is playing: the overlays stay up until it ends
    private var outroGen = 0       // bumped to cancel the previous outro's completion

    /// Plays the outro on every overlay on screen, then `done`.
    private func runOutro(_ done: @escaping @MainActor () -> Void) {
        let shown = overlays.filter(\.showing)
        guard !shown.isEmpty else { return done() }
        outroing = true
        let gen = outroGen
        var left = Countdown(shown.count)
        for o in shown {
            o.outro { [weak self] in
                guard left.hit(), let self, self.outroGen == gen else { return }
                self.outroing = false
                done()
            }
        }
    }

    private var running: Bool { (enabled || outroing) && !screensAsleep && !sessionInactive && !screensaver }
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

    /// Read-only summary derived from the existing pause reasons; refreshed live while the panel is open.
    private var statusText: String {
        let level = Intensity.saved(ud)
        if !enabled { return tr("Desligado") }
        if screensAsleep || sessionInactive || userIdle { return tr("Pausado: sem atividade") }
        if hot { return tr("Pausado: Mac esquentou") }
        if fullscreenIdle { return tr("Pausado: app em tela cheia") }
        if NSScreen.screens.isEmpty { return tr("Pausado: sem tela") }
        if overlays.isEmpty { return panel.metalMissing ? tr("Sem neve: este Mac não consegue desenhá-la") : tr("Pausado") }
        var s = tr("Nevando · \(level.title)")
        // At most one modifier; the other modes are already visible as tiles.
        if wantedScreens.count < NSScreen.screens.count { s += " · " + (wantedScreens.count == 1 && target != "main" && !economy ? wantedScreens[0].localizedName : tr("tela principal")) }
        else if reduceMotion { s += " · " + tr("movimento reduzido") }
        return s
    }

    private func updateStatus() {
        panel.status = statusText
        statusItem?.button?.setAccessibilityLabel("Neve")
        statusItem?.button?.setAccessibilityValue(panel.status)
        let paused = !enabled || !polling || userIdle || fullscreenIdle
        // Off: slashed flake; paused: the flake in a circle (a distinct template symbol instead of dimming); else the plain flake.
        let img = !enabled ? (Self.symbol("snowflake.slash", tr("Neve — desligada")) ?? Self.symbol("snowflake", tr("Neve — desligada")))
            : paused ? (Self.symbol("snowflake.circle", tr("Neve — pausada")) ?? Self.symbol("snowflake", tr("Neve — pausada")))
            : Self.symbol("snowflake", "Neve")
        statusItem?.button?.image = img
        panel.axMissing = !AXIsProcessTrusted()
    }

    private func refreshRunState() {
        updateStatus()
        let run = running && !hot && !userIdle
        for o in overlays { o.setRun(run) }
        scheduleTimers()
        if polling {
            refreshDock()
            requestPoll()
        }
    }

    /// With Accessibility trust, window events drive updates and the timer is a 2s safety poll; without it, a 0.5s poll (drags are sampled by the scheduler).
    /// Plus a 30s Dock refresh; just a 1Hz watch while every screen is under a fullscreen app. `.common` so menus don't stall them.
    private func scheduleTimers() {
        syncMouseMonitor()
        slowTimer?.invalidate()
        slowTimer = nil
        scheduleSafety(slow: true)
    }

    /// Rebuilds the poll timer; `slow` also rebuilds the 30 s Dock timer (leave it alone when only the safety period changes).
    private func scheduleSafety(slow: Bool) {
        timer?.invalidate()
        timer = nil
        watcher.setActive(polling && AXIsProcessTrusted())   // events replace polling; the timer stays as a slow safety net
        guard polling else { return }
        let idle = fullscreenIdle
        idleWatch = idle
        timerGap = safetyGap()
        let t = Timer(timeInterval: idle ? 1 : (watcher.active ? timerGap : 0.5), target: self, selector: #selector(pollTick), userInfo: nil, repeats: true)
        t.tolerance = idle ? 0.2 : 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if slow && !idle {
            let st = Timer(timeInterval: 30, target: self, selector: #selector(refreshDock), userInfo: nil, repeats: true)
            st.tolerance = 1
            RunLoop.main.add(st, forMode: .common)
            slowTimer = st
        }
    }

    /// Safety period; never stretched while idle/melting, so a single input always lands in the wake window of `pollTick`.
    private func safetyGap() -> Double { sched.safetyInterval(now: CACurrentMediaTime(), ax: watcher.active && !userIdle && !idleMelting) }

    /// No input for 5 min pauses rendering; input resumes it (checked here, so no Accessibility needed for keys).
    @objc private func pollTick() {
        let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)   // kCGAnyInputEventType
        if !userIdle && !idleMelting && !ambient && sceneKind == nil && since >= idleSecs { startIdleMelt() }
        else if (userIdle || idleMelting) && since < max(2, timerGap + 0.5) { wakeFromIdle() }
        if CACurrentMediaTime() - lastScreensCheck >= 0.5 { requestPoll([.geometry]) }   // safety net: Dock / menu bar auto-hide changes visibleFrame without a notification
        requestPoll()   // the safety poll
        if watcher.active, !idleWatch, safetyGap() != timerGap { scheduleSafety(slow: false) }   // quiet for 10 s: 2 s -> 5 s
    }

    /// The idle timeout: the snow melts away on every overlay, then rendering pauses (userIdle).
    private func startIdleMelt() {
        idleMelting = true
        meltGen += 1
        let gen = meltGen
        var left = Countdown(overlays.count)
        guard !left.isDone else { idleMelting = false; userIdle = true; return refreshRunState() }
        for o in overlays {
            o.melt { [weak self] in
                guard left.hit(), let self, self.meltGen == gen, self.idleMelting else { return }
                self.idleMelting = false
                self.userIdle = true
                self.refreshRunState()
            }
        }
    }

    /// Input is back (or Modo ambiente turned on): cancels a running melt and restarts the snow from the top edge, like the intro.
    private func wakeFromIdle() {
        meltGen += 1
        idleMelting = false
        userIdle = false
        overlays.forEach { $0.resume() }
        refreshRunState()
    }

    private let scenarioHeavy = ProcessInfo.processInfo.environment["NEVE_SCENARIO"] == "heavy"
    private var lastStage = -Double.infinity

    @objc private func pollWindows() {
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
        if read.missionControl != missionControl { missionControl = read.missionControl; for o in overlays { o.setSuspended(missionControl) } }
        mcTimer?.invalidate(); mcTimer = nil
        if missionControl {   // the window list is the Exposé layout: leave the piles alone and look again in 0.25 s (the only poll while it lasts)
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
            if fs != o.isFullscreen { settleUntil[displayID(o.screen)] = CACurrentMediaTime() + 1 }
            o.setFullscreen(fs)
            if !o.isFullscreen { o.update(windows: windows, covering: coverList, dragTarget: drag.target, mouse: lastReadMouse) }   // under fullscreen the list is just that app: keep piles untouched
        }
        if scenarioHeavy, CACurrentMediaTime() - lastStage >= 20 { lastStage = CACurrentMediaTime(); overlays.forEach { $0.stage(.heavy) } }   // perf A/B load
        if fullscreenIdle != idleWatch {
            updateStatus()
            scheduleTimers()
            if !fullscreenIdle { refreshDock() }
        }
    }

    // MARK: scene mode (NEVE_SCENE)
    private let launched = CACurrentMediaTime()   // NEVE_SCENE_WAIT=<secs>: the script starts that long after launch (time to start a recording)
    private var stage: SceneStage?, sceneTimer: Timer?, sceneBegun = false, scenePoll = 0

    /// Scene mode: only the scene windows count, no Dock; a 60 Hz timer moves the windows by scene time and polls them every other tick.
    private func pollScene(_ k: SceneKind, primary: NSScreen) {
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

    /// Dock bar frame via Accessibility; cheap no-op when untrusted. Called on Dock AX events, app launch/quit, screen changes, every 30s.
    @objc private func refreshDock() {
        panel.axMissing = !AXIsProcessTrusted()
        if watcher.active != (polling && AXIsProcessTrusted()) { scheduleTimers() }   // trust granted / revoked
        guard polling else { return }
        dock.refresh { [weak self] in self?.requestPoll([.geometry, .windows]) }   // the Dock moving can change visibleFrame (Dock.refresh is itself single-flight)
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
        var failed = false
        do {
            if on { try svc.register() } else { try svc.unregister() }
        } catch {
            failed = true
            Logger(subsystem: "io.github.viniciuscandeia.neve", category: "login").error("login item: \(error.localizedDescription)")
        }
        let approval = svc.status == .requiresApproval
        panel.loginOn = loginOn   // the real state, not what was asked
        panel.loginNote = loginNote(requiresApproval: approval, failed: failed || (on && !approval && !loginOn))
        if approval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Switching Spaces hides every window at once: drop piles silently instead of an avalanche.
    @objc private func spaceChanged() {
        for o in overlays { o.dropPiles(); o.markStale(); o.dip() }   // keep the ground pile; window surfaces take no snow until the next snapshot
        transitionPoll()
    }

    @objc private func transitionPollNotification() { transitionPoll() }
    @objc private func settlePollNotification() { settlePoll() }

    // MARK: poll scheduling. Every window read goes through `sched`: coalesced, 30/s at most, bursts bounded (see PollScheduler).
    private var sched = PollScheduler(), schedTimer: Timer?, timerGap = PollScheduler.safetyGap
    private var lastRead: [WindowInfo] = [], lastReadMouse = NSEvent.mouseLocation
    private var drag = DragTracker(), downOnDesktop = false, lastDragReq = 0.0

    private func requestPoll(_ r: PollReasons = .windows) {
        guard polling, !userIdle else { return }
        sched.request(r)
        arm()
    }
    private func transitionPoll() {
        guard polling, !userIdle else { return }
        sched.transition(now: CACurrentMediaTime())
        if watcher.active, !idleWatch, timerGap != PollScheduler.safetyGap { scheduleSafety(slow: false) }   // an event ends the quiet stretch
        arm()
    }

    /// A minimize / hide animates for a while: besides the burst, one more read ~0.6 s later catches the final state.
    private func settlePoll() {
        guard polling, !userIdle else { return }
        sched.settleRead(now: CACurrentMediaTime())
        arm()
    }

    private func mouseEvent(_ type: NSEvent.EventType) {
        let now = CACurrentMediaTime()
        switch type {
        case .leftMouseDown:
            mouseDown = true
            let p = NSEvent.mouseLocation
            downOnDesktop = !lastRead.contains { $0.frame.contains(p) }   // click on the wallpaper = show-desktop: no AX event
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

    private func arm() {
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

    private func runScheduled() {
        schedTimer = nil
        guard polling, !userIdle else { return }
        guard let r = sched.take(now: CACurrentMediaTime()) else { arm(); return }
        if r.contains(.geometry) { screensChanged() }
        if r.contains(.dock) { refreshDock() }
        if r.contains(.windows) { pollWindows() }
        arm()
    }

    @objc private func clearSnow() { for o in overlays { o.clear() } }
    @objc private func screensaverStarted() { screensaver = true; refreshRunState() }
    /// Back from the screen saver: the snow starts gently again (like after the idle pause), piles kept.
    @objc private func screensaverStopped() {
        screensaver = false
        for o in overlays { o.resume() }
        refreshRunState()
    }
    @objc private func screensSlept() { screensAsleep = true; refreshRunState() }
    @objc private func screensWoke() { screensAsleep = false; refreshRunState() }
    @objc private func sessionResigned() { sessionInactive = true; refreshRunState() }
    @objc private func sessionBecameActive() { sessionInactive = false; refreshRunState() }
    @objc private func accessibilityChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.reduceMotion = reduceMotion
        syncMusic()
        updateStatus()
    }
    @objc private func powerChanged() {
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        for o in overlays { o.setLowPower(low) }
        syncMusic()
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
