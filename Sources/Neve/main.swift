// AGENT HEADER - Sources/Neve/main.swift  (app entry point + AppController; the app's "brain", MainActor)
// Role: top-level code (single-instance check, NSApplication .accessory = menu-bar agent, no Dock icon) and `AppController`, which owns ALL app-level policy:
//   status item + NSMenu (MenuHeader/IntensityTile from SettingsView.swift), the "Ajustes" NSWindow (toolbar tabs), overlays (one `Overlay` per wanted NSScreen, Overlay.swift),
//   pause/run state, timers, window polling, idle melt, Mission Control / screen saver / lock / sleep handling, login item (SMAppService), Accessibility prompt.
// Globals: `neveInstance` = Info.plist `NeveInstance` or env NEVE_INSTANCE (dev bundle; no single-instance lock, no login item, prefs in suite io.github.viniciuscandeia.neve.dev.<name>); `ud` = the only UserDefaults store.
// Threading: everything is @MainActor; notifications that may arrive off-main are delivered with queue:.main + MainActor.assumeIsolated. Timers are added to RunLoop .common so menus do not stall them.
// Run state: `run` (RunState, NeveCore/RunState.swift: outroing/screensAsleep/sessionInactive/screensaver): running = (enabled||outroing) && !asleep && !inactive && !screensaver; polling = running && !hot (thermal >= serious); overlays run only if !idle.userIdle.
//   userIdle = no input for NEVE_IDLE_SECS (default 300 s) unless Modo ambiente: first the melt (IdleMonitor.swift: snow melts, meltGen guards stale completions) then rendering pauses; input -> IdleMonitor.wake.
//   refreshRunState() is the single re-evaluation point (status icon, overlay setRun, timers, Dock + poll kick). Christmas tree: `dropTreeNow` ("Soltar árvore" menu item and a one-shot 15 s timer after the snow starts, `armTree`) picks the cursor's screen and refuses while any overlay `hasTree`. Prefs: syncPrefs diffs Pref snapshot (NeveCore/Prefs.swift) -> prefChanged(pref) is the only reaction path.
// Split (behavior-neutral): RunState (NeveCore/RunState.swift) = pause flags; IdleMonitor.swift = idle melt / wake; WindowPoller.swift = scheduler, mouse monitor, pollWindows, Mission Control gate, scene mode (everything described under "Window polling" below except the safety timer / AX watcher / Dock refresh, which stay here).
// Window polling: every read goes through `sched` (PollScheduler, NeveCore/WindowInfo.swift: coalesced, <=30/s, bursts bounded). Sources: WindowWatcher AX events (transitionPoll / settlePoll),
//   safety timer (2 s -> 5 s after 10 s quiet with AX; 0.5 s without Accessibility; 1 Hz while every screen is under a fullscreen app), 30 s Dock refresh, 0.3 s Mission Control probe (WindowList.swift onScreenWindowIDs),
//   global mouse monitors (installed only while polling; drag sampling ~25 Hz), screen geometry (screensChanged, 0.5 s safety re-check). pollWindows() reads CGWindowList (CG top-left coords ->
//   filterWindows converts to AppKit y-up), runs DragTracker + MissionControlGate, drops mostly-offscreen windows, inserts the Dock rect (WindowInfo number 0), then Overlay.update(windows:covering:dragTarget:mouse:).
//   "behind windows" mode passes no surfaces. Fullscreen app on a screen => that overlay keeps its piles untouched (settleUntil: 1 s of ignored visibleFrame changes).
// Screens: syncOverlays reconciles wantedScreens ("snowOn" default key: all|main|<displayID>; economy forces main) with overlays; unplugged displays are parked 1.5 s (`parked`) so piles survive KVM/wake flaps.
// Side effects: UserDefaults keys via Pref raw values + snowOn, ajustesOpened, firstLaunchMenuShown (takeOnce), SettingsTab.key, intensity (Intensity.saved); NSWorkspace / DistributedNotificationCenter observers (screen lock,
//   screensaver didstart/didstop with a 5 s fallback timer on the engine process); AXUIElementSetMessagingTimeout 0.25 s globally; MusicTap start/stop (syncMusic: off under Reduce Motion, economy, Low Power, scenes).
// Env vars: NEVE_INSTANCE, NEVE_IDLE_SECS, NEVE_SCENARIO=heavy (re-stages a heavy load every 20 s), NEVE_SCENE=demo|fight (+ NEVE_SCENE_WAIT, NEVE_SCENE_MARK; `sceneKind` is defined in NeveCore/Scenario.swift;
//   scene mode fixes the options, ignores the real cursor, SceneStage.swift supplies the demo windows, polled via a 60 Hz timer). NEVE_REDUCE_MOTION / NEVE_PERF are read elsewhere.
// Gotchas: all user-visible strings go through tr() with keys in BOTH pt-BR and en Localizable.strings (NeveCore/Resources). Never kill Neve by name. AXObserver skips our own pid, so the Ajustes window posts its own NSWindow
//   notifications into requestPoll. Hot path: pollWindows (<=30/s) and pollTick; keep allocations out of them.

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
    var overlays: [Overlay] = []
    private var timer: Timer?
    var idleWatch = false   // the timer is the 1 Hz fullscreen watch
    private var run = RunState()   // pause flags: run.outroing, run.screensAsleep, run.sessionInactive, run.screensaver (the screen saver covers the displays: nothing to draw under it)
    var timerGap = PollScheduler.safetyGap   // current safety-timer period (read by WindowPoller / IdleMonitor.check)
    private var mcProbe: Timer?   // the 0.3 s Mission Control probe timer (ticks into poller.mcProbeTick)
    private var ssTimer: Timer?   // screen saver on: polling is off, so this slow timer notices it ended without a didstop
    private let panel = PanelState()
    private var loggedMetal = false
    let idle = IdleMonitor()   // idle melt / wake (IdleMonitor.swift); idle.userIdle = rendering paused, polling kept to notice input
    let dock = DockWatcher()
    private(set) lazy var poller = WindowPoller(host: self)
    let watcher = WindowWatcher()
    private var slowTimer: Timer?
    private var lastScreensCheck = -Double.infinity   // monotonic (CACurrentMediaTime): a wall-clock jump must not stall the checks
    /// The one defaults store: a per-instance suite for dev builds, so concurrent instances never share prefs.
    private let ud = neveInstance.flatMap { UserDefaults(suiteName: "io.github.viniciuscandeia.neve.dev.\($0)") } ?? .standard
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion   // read once per system change
    private var menuViews: [NSView] = []   // the custom-view items, re-fitted each time the menu opens
    private var ajustesItem: NSMenuItem?
    private var treeItem: NSMenuItem?      // "Soltar árvore": enabled only while there is no tree anywhere
    private var treeAutoPending = true     // the tree falls by itself once, shortly after the snow starts (Pref.christmasTree on)
    private var treeTimer: Timer?
    private var tabsObservation: NSKeyValueObservation?
    private static let ajustesOpenedKey = "ajustesOpened"   // the Accessibility dot on Ajustes… shows until the window was opened once
    private var settingsWindow: NSWindow?
    private var intensitySnapshot = Intensity.media
    private var prefSnapshot: [Pref: Bool] = [:]
    private var loginOn: Bool { SMAppService.mainApp.status == .enabled }

    private func flag(_ p: Pref) -> Bool { ud.object(forKey: p.rawValue) as? Bool ?? p.defaultValue }
    var enabled: Bool { flag(.enabled) }
    private var economy: Bool { flag(.economy) }
    private var ambient: Bool { flag(.ambient) }
    var behind: Bool { flag(.behindWindows) }
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
        idle.overlays = { [weak self] in self?.overlays ?? [] }
        idle.changed = { [weak self] in self?.refreshRunState() }
        Overlay.all = { [weak self] in self?.overlays ?? [] }

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
        watcher.onChange = { [weak self] in self?.poller.transitionPoll() }   // an AX event is a transition: the window may still be animating
        watcher.onSettle = { [weak self] in self?.poller.settlePoll() }       // minimize / hide animations outlast the burst: one more read afterwards
        syncOverlays()
        // First launch only: open the menu once so the icon is found (no dialog).
        if neveInstance == nil, sceneKind == nil, !ud.bool(forKey: "firstLaunchMenuShown") { firstRunMenu(triesLeft: 20) }
    }

    /// The status button's window may not be placed yet at launch: look every 0.1 s for up to ~2 s; the once-flag is consumed only when the click fires.
    private func firstRunMenu(triesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let b = self.statusItem?.button, let w = b.window, w.frame.width > 0, w.frame.height > 0 {
                    if takeOnce("firstLaunchMenuShown", in: self.ud) { b.performClick(nil) }
                } else if triesLeft > 1 { self.firstRunMenu(triesLeft: triesLeft - 1) }
            }
        }
    }

    /// Double-click in Finder while running: the menu-bar extra may be hidden or crowded out, so show Ajustes and make sure the item is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        showSettingsWindow()
        return true
    }

    func displayID(_ s: NSScreen) -> Int { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0 }

    /// Leaving / entering fullscreen reshuffles the menu bar and Dock mid-Space-animation: per screen, ignore visibleFrame ~1s after.
    var settleUntil: [Int: Double] = [:]   // CACurrentMediaTime
    private func settling(_ o: Overlay) -> Bool { o.isFullscreen || CACurrentMediaTime() < settleUntil[displayID(o.screen), default: -.infinity] }

    /// Real configuration changes (screens added / removed, frame or scale) apply at once, per screen;
    /// only visibleFrame-only changes (Dock, menu bar) wait for a transitioning screen to settle.
    @objc func screensChanged() {
        invalidateScreenCache()   // the cache's own observer registers lazily and may run after this
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
                MainActor.assumeIsolated { self?.poller.requestPoll([.geometry]) }
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
        if poller.missionControl { made.forEach { $0.setSuspended(true) } }   // created during Mission Control: stay hidden
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
            outroGen += 1; idle.cancel()
            if on { run.outroing = false; overlays.forEach { $0.intro() }; refreshRunState() }
            else { updateStatus(); runOutro { [weak self] in self?.refreshRunState() } }
        case .economy: syncOverlays(); syncMusic()
        case .music: applyPrefs(); syncMusic()
        case .ambient: if on && (idle.userIdle || idle.melting) { idle.wake() } else { updateStatus() }
        case .behindWindows:
            applyPrefs()
            poller.requestPoll()   // empties / refills the surface list
            updateStatus()
        case .behindLarge:
            applyPrefs()
            poller.requestPoll()   // the occluders / coverage follow the option now, not at the next window change
        case .christmasTree: applyPrefs(); if on { armTree() }
        case .stillSnow, .snowman, .walk, .visitors, .sleigh, .lights, .showInCaptures, .adaptiveFps, .pointerPush: applyPrefs()
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
        let t = item(tr("Soltar árvore"), "tree", #selector(dropTreeAction), "", self)
        treeItem = t
        m.addItem(t)
        let a = item(tr("Ajustes…"), "gearshape", #selector(showSettingsWindow), ",", self)
        ajustesItem = a
        m.addItem(a)
        m.addItem(.separator())
        m.addItem(item(tr("Sair"), "power", #selector(NSApplication.terminate(_:)), "q", NSApp))
        return m
    }

    /// Refresh before it shows: live status, item heights (the status text may wrap), the Accessibility dot. ⌥-click skips the menu for Ajustes.
    func menuWillOpen(_ menu: NSMenu) {
        let mods = NSEvent.modifierFlags, evType = NSApp.currentEvent?.type
        let mouse = evType == .leftMouseDown || evType == .leftMouseUp || evType == .rightMouseDown || evType == .rightMouseUp || evType == .otherMouseDown || evType == .otherMouseUp
        if optionClickOpensSettings(option: mods.contains(.option), control: mods.contains(.control), mouse: mouse) {   // ⌃⌥ is VoiceOver's modifier pair
            menu.cancelTracking()
            DispatchQueue.main.async { [weak self] in self?.showSettingsWindow() }
            return
        }
        updateStatus()
        treeItem?.isEnabled = flag(.christmasTree) && !overlays.contains(where: \.hasTree) && overlays.contains(where: \.showing)
        menuViews.forEach { $0.frame.size = $0.fittingSize }
        ajustesItem?.attributedTitle = nil
        let plainTitle = ajustesItem?.title
        let dot = panel.axMissing && !ud.bool(forKey: Self.ajustesOpenedKey)
        if dot {
            let t = NSMutableAttributedString(string: tr("Ajustes…") + " ")
            t.append(NSAttributedString(string: "●", attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 8)]))
            ajustesItem?.attributedTitle = t
        } else { ajustesItem?.attributedTitle = nil }
        ajustesItem?.setAccessibilityLabel(dot ? plainTitle : nil)   // VoiceOver must not read the "●"
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
                host.title = t.title   // the tab controller propagates the selected tab's title to the window (System Settings style)
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
        DispatchQueue.main.async { [weak self] in self?.poller.requestPoll() }
    }

    private var outroGen = 0       // bumped to cancel the previous outro's completion

    /// Plays the outro on every overlay on screen, then `done`.
    private func runOutro(_ done: @escaping @MainActor () -> Void) {
        let shown = overlays.filter(\.showing)
        guard !shown.isEmpty else { return done() }
        run.outroing = true
        let gen = outroGen
        var left = Countdown(shown.count)
        for o in shown {
            o.outro { [weak self] in
                guard left.hit(), let self, self.outroGen == gen else { return }
                self.run.outroing = false
                done()
            }
        }
    }

    private var running: Bool { run.running(enabled: enabled) }
    /// The one source of truth for thermal throttling.
    private var hot: Bool { ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue }
    /// Polling timers only run while snow is actually shown (not disabled / asleep / locked / hot).
    var polling: Bool { run.polling(enabled: enabled, hot: hot) }
    var fullscreenIdle: Bool { !overlays.isEmpty && overlays.allSatisfy(\.isFullscreen) }

    private static func symbol(_ name: String, _ description: String? = nil) -> NSImage? {
        let i = NSImage(systemSymbolName: name, accessibilityDescription: description)
        i?.isTemplate = true
        return i
    }

    /// Read-only summary derived from the existing pause reasons; refreshed live while the panel is open.
    private var statusText: String {
        let level = Intensity.saved(ud)
        if !enabled { return tr("Desligado") }
        if run.screensAsleep || run.sessionInactive || idle.userIdle { return tr("Pausado: sem atividade") }
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

    func updateStatus() {
        panel.status = statusText
        statusItem?.button?.setAccessibilityLabel("Neve")
        statusItem?.button?.setAccessibilityValue(panel.status)
        let paused = !enabled || !polling || idle.userIdle || fullscreenIdle
        // Off: slashed flake; paused: the flake in a circle (a distinct template symbol instead of dimming); else the plain flake.
        let img = !enabled ? (Self.symbol("snowflake.slash", tr("Neve — desligada")) ?? Self.symbol("snowflake", tr("Neve — desligada")))
            : paused ? (Self.symbol("snowflake.circle", tr("Neve — pausada")) ?? Self.symbol("snowflake", tr("Neve — pausada")))
            : Self.symbol("snowflake", "Neve")
        statusItem?.button?.image = img
        panel.axMissing = !AXIsProcessTrusted()
    }

    private func refreshRunState() {
        updateStatus()
        let go = run.rendering(enabled: enabled, hot: hot, userIdle: idle.userIdle)
        for o in overlays { o.setRun(go); o.setThermalWarm(ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.fair.rawValue) }
        if go { armTree() }
        scheduleTimers()
        if polling {
            refreshDock()
            poller.requestPoll()
        }
    }

    /// With Accessibility trust, window events drive updates and the timer is a 2s safety poll; without it, a 0.5s poll (drags are sampled by the scheduler).
    /// Plus a 30s Dock refresh; just a 1Hz watch while every screen is under a fullscreen app. `.common` so menus don't stall them.
    func scheduleTimers() {
        poller.syncMouseMonitor()
        slowTimer?.invalidate()
        slowTimer = nil
        mcProbe?.invalidate()
        mcProbe = nil
        scheduleSafety(slow: true)
    }

    /// Rebuilds the poll timer; `slow` also rebuilds the 30 s Dock timer (leave it alone when only the safety period changes).
    func scheduleSafety(slow: Bool) {
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
            // Nothing notifies us when Mission Control opens: a 0.3 s probe of the on-screen window IDs (~65 us, ~0.02% CPU) requests a read when the list changes.
            let pr = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poller.mcProbeTick() }
            }
            pr.tolerance = 0.15
            RunLoop.main.add(pr, forMode: .common)
            mcProbe = pr
        }
    }

    /// Safety period; never stretched while idle/melting, so a single input always lands in the wake window of `pollTick`.
    private func safetyGap() -> Double { poller.sched.safetyInterval(now: CACurrentMediaTime(), ax: watcher.active && !idle.userIdle && !idle.melting) }

    @objc private func pollTick() {
        idle.check(ambient: ambient, scene: sceneKind != nil, timerGap: timerGap)
        if CACurrentMediaTime() - lastScreensCheck >= 0.5 { poller.requestPoll([.geometry]) }   // safety net: Dock / menu bar auto-hide changes visibleFrame without a notification
        poller.requestPoll()   // the safety poll
        if watcher.active, !idleWatch, safetyGap() != timerGap { scheduleSafety(slow: false) }   // quiet for 10 s: 2 s -> 5 s
    }

    /// Dock bar frame via Accessibility; cheap no-op when untrusted. Called on Dock AX events, app launch/quit, screen changes, every 30s.
    @objc func refreshDock() {
        panel.axMissing = !AXIsProcessTrusted()
        if watcher.active != (polling && AXIsProcessTrusted()) { scheduleTimers() }   // trust granted / revoked
        guard polling else { return }
        dock.refresh { [weak self] in self?.poller.requestPoll([.geometry, .windows]) }   // the Dock moving can change visibleFrame (Dock.refresh is itself single-flight)
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
        poller.transitionPoll()
    }

    /// An AX event ends the quiet stretch of the safety timer (5 s back to 2 s).
    func endQuietStretch() { if watcher.active, !idleWatch, timerGap != PollScheduler.safetyGap { scheduleSafety(slow: false) } }

    @objc private func transitionPollNotification() { poller.transitionPoll() }
    @objc private func settlePollNotification() { poller.settlePoll() }

    @objc private func clearSnow() { for o in overlays { o.clear() } }

    /// The Christmas tree falls on the cursor's screen (else the first shown one); never a second one anywhere (also counts a tree carried by a drag onto another screen).
    @discardableResult private func dropTreeNow() -> Bool {
        guard flag(.christmasTree), !overlays.contains(where: \.hasTree) else { return false }
        let m = NSEvent.mouseLocation, shown = overlays.filter(\.showing)
        guard let o = shown.first(where: { $0.screenFrame.contains(m) }) ?? shown.first else { return false }
        return o.dropTree()
    }
    @objc private func dropTreeAction() { dropTreeNow() }
    /// Once per launch the tree falls by itself ~15 s after the snow starts; retried every 15 s while nothing can show it (paused, idle melt, option off).
    private func armTree() {
        guard treeAutoPending, treeTimer == nil, flag(.christmasTree), sceneKind == nil else { return }
        treeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.treeTimer = nil
                if self.dropTreeNow() { self.treeAutoPending = false } else { self.armTree() }
            }
        }
    }
    @objc private func screensaverStarted() {
        run.screensaver = true
        ssTimer?.invalidate()
        ssTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in   // didstop can be missed; the engine process is the truth
            MainActor.assumeIsolated {
                if self?.saverRunning == false { self?.screensaverStopped() }
            }
        }
        refreshRunState()
    }
    /// Back from the screen saver: the snow starts gently again (like after the idle pause), piles kept.
    private var saverRunning: Bool { NSWorkspace.shared.runningApplications.contains { isScreensaverEngine($0.bundleIdentifier) } }
    @objc private func screensaverStopped() {
        ssTimer?.invalidate(); ssTimer = nil
        guard run.screensaver else { return }
        run.screensaver = false
        for o in overlays { o.resume() }
        refreshRunState()
    }
    @objc private func screensSlept() { run.screensAsleep = true; refreshRunState() }
    @objc private func screensWoke() { run.screensAsleep = false; if !saverRunning { screensaverStopped() }; refreshRunState() }
    @objc private func sessionResigned() { run.sessionInactive = true; refreshRunState() }
    @objc private func sessionBecameActive() { run.sessionInactive = false; if !saverRunning { screensaverStopped() }; refreshRunState() }
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

if ProcessInfo.processInfo.environment["NEVE_SHADER_CHECK"] == "1" {   // compile every shader + pipeline, report on stderr, exit before any UI
    exit(Gpu() == nil ? 1 : 0)
}
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
