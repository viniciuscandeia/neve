import NeveCore
import AppKit
import Metal
import QuartzCore

/// Content view that hands mouse events to the overlay (only delivered while the window is interactive: ⌥ over snow).
final class InteractView: NSView {
    var onDown: ((NSEvent) -> Void)?, onDrag: ((NSEvent) -> Void)?, onUp: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDown?(event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func mouseUp(with event: NSEvent) { onUp?(event) }
}

/// Click-through snow window covering one screen (interactive only while ⌥ is held over snow or a snowball).
@MainActor
final class Overlay: NSObject, CAMetalDisplayLinkDelegate {
    private static let sharedGpu = Gpu()
    private static let forceMotion = ProcessInfo.processInfo.environment["NEVE_REDUCE_MOTION"] == "1"   // perf / tests: behave as if Reduce Motion is on

    let screen: NSScreen
    private var perf: Perf.Meter?   // NEVE_PERF=1 only
    private let field: SnowField
    private let gpu: Gpu
    private let window: NSWindow
    var windowNumber: Int { window.windowNumber }
    private let view = InteractView()
    private var held: Int?                // snowball being dragged
    private var lastDragTime: CFTimeInterval = 0
    private var dayChecked: CFTimeInterval = -1000
    private var pollMouse = NSEvent.mouseLocation
    private var lastCursor: CGPoint?
    private let metalLayer = CAMetalLayer()
    private let buffers: [MTLBuffer]
    private var primCapacity = 800   // ~700 prims / screen; grows (in update, never per frame) after a frame that dropped some
    private var primBuffers: [MTLBuffer]
    private var primWant = 0
    // MARK: pile pass
    private var pileCapacity = 8192   // grows with the surfaces' bin count when the window list changes
    private var pileBuffers: [MTLBuffer]
    private var pileForce = false     // buffers were replaced: rewrite the piles once
    static let slowmo = Float(ProcessInfo.processInfo.environment["NEVE_SLOWMO"] ?? "") ?? 1   // visual checks: the sim runs at this fraction of real time
    private var pileSlot = 0, pileCount = 0, frameDt: Float = 1.0 / 60   // 3-slot ring, rewritten only when the pile changed
    private var shiftID: Int?, shift = SIMD2<Float>.zero   // dragged window: its figures / balls ride with the drag pile layer
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var link: CAMetalDisplayLink?
    private let pass = MTLRenderPassDescriptor()   // reused every frame; only the texture changes
    private var run = false, fullscreen = false   // run: the controller's single decision (enabled, awake, not hot, user active)
    private var occluded = false
    private var lowPower = false
    private var contrast: Float = 0
    private var reduceMotion = false
    private var prefs: OverlayPrefs
    private var still = false   // Reduce Motion + "Neve parada": no flakes drawn or stepped, piles kept
    private var lastTimestamp: CFTimeInterval = 0
    // MARK: P3-C frame-rate policy
    private var stillPaused = false, dirty = true       // still snow: the link sleeps once the picture is settled; `dirty` = something changed since the last frame
    private var fastUntil: CFTimeInterval = 0, slow = false   // adaptive fps: 30 fps once nothing fast happened for 0.5 s
    private var groundY: CGFloat
    private var visibleTop: CGFloat
    private let frame: CGRect, scale: CGFloat
    // MARK: P3-0 maximized window (Coverage.swift)
    private let root = CALayer()                       // screen-local coordinates: bounds.origin = the live rect's origin while shrunk
    private var cover = CompactState()
    private var coverFraction: Float = 0, liveLocal: CGRect?   // from the last window poll
    private var coverTime: CFTimeInterval = 0, coverCheck = false
    private var coverPause = false                     // `covered`: nothing live, paused like a fullscreen app
    private var coverActive = false                    // compact mode entered (until the exit ramp ends)
    private var occStrength: Float = 0, occTarget: Float = 0   // flake occluders 0...1
    private var occ = [SIMD4<Float>](repeating: .zero, count: 9)   // 4 rects hiding every flake, 4 hiding background flakes, strength
    private var shrunk: CGRect?                        // live rect applied to panel + Metal layer (screen-local); nil = whole screen

    init?(screen: NSScreen, prefs: OverlayPrefs) {
        guard let gpu = Overlay.sharedGpu else { return nil }
        let f = screen.frame, v = screen.visibleFrame
        frame = f
        scale = screen.backingScaleFactor
        groundY = sceneKind == nil ? v.minY - f.minY : 0   // scenes have no Dock: the ground is the screen bottom
        visibleTop = v.maxY - f.minY
        let areaScale = Float(f.width * f.height) / (1440 * 900)
        let field = SnowField(size: f.size, origin: f.origin, groundY: groundY, visibleTop: visibleTop,
                              flakeCount: max(120, Int(Float(Tuning.flakes) * areaScale)), config: simConfig,
                              seed: sceneSeed ?? .random(in: 0...UInt64.max))
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = gpu.device.makeBuffer(length: field.capacity * MemoryLayout<Instance>.stride, options: .storageModeShared) else { return nil }
            buffers.append(b)
        }
        var primBuffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = gpu.device.makeBuffer(length: primCapacity * MemoryLayout<Prim>.stride, options: .storageModeShared) else { return nil }
            primBuffers.append(b)
        }
        self.primBuffers = primBuffers
        var pileBuffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = gpu.device.makeBuffer(length: pileCapacity * MemoryLayout<PileSeg>.stride, options: .storageModeShared) else { return nil }
            pileBuffers.append(b)
        }
        self.pileBuffers = pileBuffers
        self.screen = screen
        self.prefs = prefs
        self.gpu = gpu
        self.field = field
        self.buffers = buffers
        // A non-activating panel: clicking a snowball must not pull Neve (and its menu bar) in front of the user's app.
        let panel = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        window = panel
        super.init()
        view.onDown = { [weak self] e in MainActor.assumeIsolated { self?.mouseDown(e) } }
        view.onDrag = { [weak self] e in MainActor.assumeIsolated { self?.mouseDragged(e) } }
        view.onUp = { [weak self] e in MainActor.assumeIsolated { self?.mouseUp(throwing: e.timestamp - (self?.lastDragTime ?? 0) < 0.08) } }

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(f, display: false)

        let bounds = CGRect(origin: .zero, size: f.size)
        let host = CALayer()   // layer-hosting view: its layer geometry is ours (root moves with the live rect)
        root.frame = bounds
        host.addSublayer(root)
        view.frame = bounds
        view.layer = host
        view.wantsLayer = true
        window.contentView = view

        let scale = screen.backingScaleFactor
        metalLayer.device = gpu.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.contentsGravity = .bottomLeft   // a resize never stretches the last frame
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        root.addSublayer(metalLayer)

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)

        window.setAccessibilityElement(false)   // decoration: VoiceOver must not announce it
        window.setAccessibilityHidden(true)
        view.setAccessibilityElement(false)
        view.setAccessibilityHidden(true)
        window.isExcludedFromWindowsMenu = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        apply(prefs)
        setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
        field.setIntensity(prefs.intensity, immediate: true)
        if Perf.on {
            field.timer = Perf.seconds
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
            perf = Perf.Meter(label: "screen\(id) \(Int(frame.width))x\(Int(frame.height))")
        }
        intro()
    }

    /// True when the screen's frame or scale differs from creation: needs a full rebuild.
    func screenChanged(_ s: NSScreen) -> Bool { s.frame != frame || s.backingScaleFactor != scale }

    /// Dock / menu bar moved (visibleFrame changed, frame unchanged): updated in place, piles kept.
    func refreshBounds() {
        let g: CGFloat = sceneKind == nil ? screen.visibleFrame.minY - frame.minY : 0, t = screen.visibleFrame.maxY - frame.minY
        guard g != groundY || t != visibleTop else { return }
        groundY = g
        visibleTop = t
        field.setBounds(groundY: g, visibleTop: t)
    }

    /// Reduce Motion: calmer snow. Increase Contrast: stronger flake rim and pile bottom edge. (Reduce Transparency: nothing to change, the overlay has no blur.)
    @objc private func accessibilityChanged() {
        let ws = NSWorkspace.shared
        let motion = ws.accessibilityDisplayShouldReduceMotion || Self.forceMotion, hc = ws.accessibilityDisplayShouldIncreaseContrast
        field.setCalm(motion)
        reduceMotion = motion
        still = prefs.still && motion
        field.frozen = still
        contrast = hc ? 1 : 0
        wake()
    }

    /// Still mode renders only on change: anything that changes the picture calls this to restart the link for (at least) one frame.
    private func wake() {
        dirty = true
        guard stillPaused else { return }
        stillPaused = false
        lastTimestamp = 0
        link?.isPaused = occluded || !window.isVisible
    }

    private var pileSeen = -1
    private var lastWindows: [WindowInfo] = []
    private var confirmedDrag: Int?   // the window being dragged by the mouse (main confirms it); only that one is extrapolated
    /// Space switch: no deposits on window surfaces until the next snapshot reconciles.
    func markStale() { field.markStale() }
    /// `covering`: the real windows for coverage / compaction when `windows` (the surfaces) is deliberately empty (behind-windows mode).
    func update(windows: [WindowInfo], covering: [WindowInfo]? = nil, dragTarget: Int? = nil) {
        let now = CACurrentMediaTime()
        field.update(windows: windows, now: now)   // each window's dt = its own time since its last sample
        confirmedDrag = dragTarget
        growBuffers()
        let changed = windows != lastWindows
        if changed { lastWindows = windows; fastUntil = now + 0.5; wake() }
        if field.pileVersion != pileSeen { pileSeen = field.pileVersion; wake() }
        pollMouse = NSEvent.mouseLocation   // reference for the per-frame drag offset; the poll's real bounds win
        shift = .zero; shiftID = nil
        measureCover(covering ?? windows)   // MARK: P3-0
    }
    /// Poll rate, outside the frame path: size the prim / pile buffers from the demand (old ones stay alive in any in-flight command buffer).
    private func growBuffers() {
        func make<T>(_ n: Int, _: T.Type) -> [MTLBuffer]? {
            let bs = (0..<3).compactMap { _ in gpu.device.makeBuffer(length: n * MemoryLayout<T>.stride, options: .storageModeShared) }
            return bs.count == 3 ? bs : nil
        }
        let pd = field.pileSegDemand
        if pd > pileCapacity, let b = make((pd * 5 / 4 + 1023) & ~1023, PileSeg.self) {
            pileBuffers = b; pileCapacity = b[0].length / MemoryLayout<PileSeg>.stride; pileForce = true; wake()
        }
        if primWant > primCapacity, let b = make((primWant * 3 / 2 + 255) & ~255, Prim.self) {
            primBuffers = b; primCapacity = b[0].length / MemoryLayout<Prim>.stride; wake()
        }
    }

    // MARK: P3-0 maximized window: snow only in the visible strip

    /// Windows -> coverage of the usable area, the live rect and the shader occluders (poll rate; cheap).
    private var coverKey: (windows: [WindowInfo], vis: CGRect, behindLarge: Bool)?
    private func measureCover(_ windows: [WindowInfo]) {
        let vis = screen.visibleFrame
        if coverKey == nil || coverKey! != (windows, vis, prefs.behindLarge) {   // identical snapshots (bursts, other screens' polls) reuse the last coverage / occluders
            coverKey = (windows, vis, prefs.behindLarge)
            computeCover(windows, vis)
        }
        advanceWhileIdle()
    }

    private func computeCover(_ windows: [WindowInfo], _ vis: CGRect) {
        let o = frame.origin
        let rects = windows.filter { $0.number != 0 && $0.frame.intersects(vis) }.map(\.frame).sorted { $0.width * $0.height > $1.width * $1.height }
        let c = coverage(of: rects, in: vis)
        coverFraction = c.fraction; 
        liveLocal = liveRect(frame: frame, visible: vis, uncovered: c.uncovered)?.offsetBy(dx: -o.x, dy: -o.y)
        func box(_ r: CGRect) -> SIMD4<Float> { let l = r.offsetBy(dx: -o.x, dy: -o.y); return SIMD4(Float(l.minX), Float(l.minY), Float(l.maxX), Float(l.maxY)) }
        for i in 0..<8 { occ[i] = .zero }
        for (i, r) in rects.prefix(4).enumerated() { occ[i] = box(r) }
        if prefs.behindLarge {
            let big = rects.filter { $0.width * $0.height >= 0.35 * vis.width * vis.height }
            for (i, r) in big.prefix(4).enumerated() { occ[4 + i] = box(r) }
        }
    }

    /// Hysteresis timers keep running on every poll, changed snapshot or not.
    private func advanceWhileIdle() {
        if !(window.isVisible && link?.isPaused == false) {   // not ticking (covered / paused): the poll drives the state machine
            advanceCover(CACurrentMediaTime())
            if cover.pending, !coverCheck {   // look again shortly: nobody else will
                coverCheck = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    MainActor.assumeIsolated { self?.coverCheck = false; self?.advanceCover(CACurrentMediaTime()) }
                }
            }
        }
    }

    /// Hysteresis step (per frame, or per poll while paused), then act on the state.
    private func advanceCover(_ now: CFTimeInterval) {
        let dt = Float(min(max(now - coverTime, 0), 0.25))
        coverTime = now
        let s = cover.update(fraction: coverFraction, liveHeight: liveLocal?.height ?? 0, mouseDown: NSEvent.pressedMouseButtons != 0, dt: dt)
        if s != .normal, !coverActive { coverActive = true; occTarget = 1 }
        if s == .normal, coverActive, occTarget != 0 {   // leaving: expand first, wake half the flakes anywhere, then fade the occluders out
            setLiveRect(nil)
            field.wake(fraction: 0.5)
            occTarget = 0
        }
        let pause = s == .covered
        if pause != coverPause { coverPause = pause; present() }
        guard coverActive else { return }
        if occStrength != occTarget {
            occStrength = reduceMotion ? occTarget : occStrength + (occTarget > occStrength ? 1 : -1) * min(Float(dt) / 0.6, abs(occTarget - occStrength))
            if reduceMotion { crossfade() }
        }
        if occTarget == 0 { if occStrength == 0 { coverActive = false }; return }
        // Shrink once the occluders are fully in, and only when the live area is at most half the screen.
        if occStrength >= 1, s == .compact {
            if let r = liveLocal, r.width * r.height <= 0.5 * frame.width * frame.height { if shrunk != r { setLiveRect(r) } }
            else if shrunk != nil { setLiveRect(nil) }
        }
    }

    /// Reduce Motion: a quick fade instead of the 0.6s occluder ramp.
    private func crossfade() {
        guard window.isVisible else { return }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; window.animator().alphaValue = 1 }
    }

    /// Panel, Metal layer and layer coordinates change together in one transaction; piles and the sim stay in screen-local coordinates.
    private func setLiveRect(_ r: CGRect?) {
        guard shrunk != r else { return }
        shrunk = r
        let g = r ?? CGRect(origin: .zero, size: frame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(CGRect(x: frame.minX + g.minX, y: frame.minY + g.minY, width: g.width, height: g.height), display: false)
        root.frame = CGRect(origin: .zero, size: g.size)
        root.bounds = g
        metalLayer.frame = g
        metalLayer.drawableSize = CGSize(width: g.width * scale, height: g.height * scale)
        CATransaction.commit()
        field.setLive(r)
        // The display link keeps vending drawables of the size it was made with: make a new one.
        if let l = link { l.invalidate(); link = nil; _ = l; present() }
        if reduceMotion { crossfade() }
    }

    /// Window-local mouse position -> screen-local simulation coordinates.
    private func local(_ e: NSEvent) -> CGPoint {
        let p = view.convert(e.locationInWindow, from: nil), o = shrunk?.origin ?? .zero
        return CGPoint(x: p.x + o.x, y: p.y + o.y)
    }

    func clear() { field.clear(); wake() }
    func stage(_ s: Scenario) { field.stage(s); wake() }
    /// Scene mode: starts the script (after the scene windows are in the field) / seconds into its loop.
    func beginScene(_ k: SceneKind) { field.beginScene(k); wake() }
    var sceneTime: Float? { field.sceneTime }

    private var outroGen = 0   // bumped by intro() / outro(): a stale outro step does nothing
    /// Snow starts gradually (no flakes pre-scattered): launch and "Nevar" turned back on. Reduce Motion keeps the plain window fade-in.
    func intro() {
        if !reduceMotion { resume() } else { outroGen += 1; field.endOutro() }
    }
    /// Back from the idle pause (or a melt): no flake on screen, new ones fall in from above the top edge (Reduce Motion too).
    func resume() {
        outroGen += 1
        meltDone = nil
        field.beginIntro(duration: 2.5)
    }
    private var meltDone: (@MainActor () -> Void)?
    /// Idle melt: snow thaws away over ~12 s (0.6 s with Reduce Motion), then `done` (the controller pauses rendering). Not on screen / still snow: cleared at once.
    func melt(_ done: @escaping @MainActor () -> Void) {
        guard showing, !still else { field.clear(); return done() }
        outroGen += 1
        meltDone = done
        field.beginMelt(duration: 12)
        wake()
    }
    /// Being shown right now (the only state an outro makes sense in).
    var showing: Bool { run && !fullscreen && window.isVisible }
    /// Piles, balls and the snowman collapse into falling snow, then the window fades; `done` runs ~1.4s later.
    /// Reduce Motion / still snow: just a 0.4s fade.
    func outro(_ done: @escaping @MainActor () -> Void) {
        outroGen += 1
        let gen = outroGen, fade = reduceMotion || still
        if !fade { field.collapseAll(spread: 0.3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (fade ? 0 : 1.0)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.outroGen == gen else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; self.window.animator().alphaValue = 0 }) {
                    MainActor.assumeIsolated { if self.outroGen == gen { done() } }
                }
            }
        }
    }
    func dropPiles() { field.dropPiles(); wake() }
    func setLowPower(_ on: Bool) {
        lowPower = on
        field.setLowPower(on)
        link?.preferredFrameRateRange = frameRange
    }
    /// Applies the user options (idempotent; the controller calls it on every change).
    func apply(_ p: OverlayPrefs) {
        prefs = p
        // Behind windows: just above the desktop icons (snow over the wallpaper only); else one above the Dock:
        // over the Dock (piles) but under menu bar, status-bar popovers and menus (all .statusBar+).
        // Only touch the window when these change: re-setting level/sharingType makes WindowServer recomposite (a visible hitch on every pref change).
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(p.behind ? .desktopIconWindow : .dockWindow)) + 1)
        if window.level != level { window.level = level }
        let sharing: NSWindow.SharingType = p.showInCaptures ? .readOnly : .none   // hidden from screenshots / recordings / sharing by default
        if window.sharingType != sharing { window.sharingType = sharing }
        field.snowmanEnabled = p.snowman
        field.walkEnabled = p.walk
        field.pointerPush = p.pointerPush
        field.visitorsEnabled = p.visitors
        field.sleighEnabled = p.sleigh
        refreshDay(force: true)
        field.groundOnlyActors = p.behind
        field.economy = p.economy
        field.setIntensity(p.intensity)
        if let link, link.preferredFrameRateRange != frameRange { link.preferredFrameRateRange = frameRange }
        accessibilityChanged()   // `still` follows the pref
    }
    private var frameRange: CAFrameRateRange {
        let r = FrameRate.range(lowPower: lowPower, economy: prefs.economy, shrunk: shrunk != nil, calm: slow)
        return CAFrameRateRange(minimum: r.min, maximum: r.max, preferred: r.preferred)
    }

    /// True when `r` (a window frame, AppKit coords) covers this whole screen, menu bar included = a fullscreen app.
    func covers(_ r: CGRect) -> Bool { r.insetBy(dx: -1, dy: -1).contains(screen.frame) }
    var isFullscreen: Bool { fullscreen }
    func setFullscreen(_ on: Bool) { if on != fullscreen { fullscreen = on; present() } }

    /// The controller's decision: enabled, awake, session active, not thermally throttled, user not idle.
    func setRun(_ on: Bool) { run = on; present() }

    /// Presents only when `run` and not under a fullscreen app. Piles are kept while paused.
    private func present() {
        guard run && !fullscreen && !coverPause else {
            guard window.isVisible else { link?.isPaused = true; return }
            // Fade out (~0.4s), then hide; the link keeps running meanwhile. Fullscreen/thermal hides are the same path.
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; window.animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !(self.run && !self.fullscreen && !self.coverPause) else { return }
                    self.link?.isPaused = true
                    self.window.orderOut(nil)
                }
            }
            return
        }
        if !window.isVisible { occluded = false; window.alphaValue = 0; window.orderFrontRegardless(); lastTimestamp = 0 }
        if window.alphaValue < 1 { NSAnimationContext.runAnimationGroup { $0.duration = 0.4; window.animator().alphaValue = 1 } }
        if link == nil {
            // CAMetalDisplayLink hands over a ready drawable, so the main thread never blocks in nextDrawable.
            let l = CAMetalDisplayLink(metalLayer: metalLayer)
            l.delegate = self
            l.preferredFrameLatency = 2
            l.preferredFrameRateRange = frameRange
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = occluded
    }

    /// Only meaningful while ordered in (orderOut also reports "not visible"); pauses the link, never the window.
    @objc private func occlusionChanged() {
        guard window.isVisible else { return }
        occluded = !window.occlusionState.contains(.visible)
        if !occluded { lastTimestamp = 0 }
        link?.isPaused = occluded
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        link?.invalidate()
        link = nil
        window.orderOut(nil)
        window.contentView = nil
    }

    /// The SDK declares this nonisolated. The link is added to RunLoop.main, so it always fires on the main thread:
    /// assumeIsolated is therefore sound (and traps if that ever changes).
    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // Update/drawable are not Sendable, but never leave the main thread here.
        nonisolated(unsafe) let drawable = update.drawable
        let time = update.targetTimestamp
        MainActor.assumeIsolated { tick(drawable, time) }
    }

    private func tick(_ drawable: CAMetalDrawable, _ time: CFTimeInterval) {
        perf?.bump(.ticks)
        guard window.isVisible else { perf?.bump(.hidden); return }
        dirty = false
        var t0 = Perf.now()
        let now = time, resumed = lastTimestamp == 0
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(now - lastTimestamp, 0.06)   // 20 fps (economy, calm) steps 0.05
        lastTimestamp = now
        advanceCover(now)   // MARK: P3-0
        frameDt = Float(dt)
        field.music = prefs.music ? MusicTap.shared.read() : .silent
        if !still { field.step(dt: Float(dt) * Self.slowmo) }
        perf?.add(.step, t0); t0 = Perf.now()
        // Cursor wipe: one sweep per frame from the last position (polling needs no event monitor). Drags are window physics.
        let cursor = sceneKind == nil ? NSEvent.mouseLocation : CGPoint(x: -1e5, y: -1e5)   // scenes ignore the real cursor: the same story every time
        let option = sceneKind == nil && NSEvent.modifierFlags.contains(.option)
        let o = frame.origin
        let here = CGPoint(x: cursor.x - o.x, y: cursor.y - o.y)
        if held != nil, !option { mouseUp() }   // ⌥ released mid-drag: let go
        // Interactive only where there is snow or a snowball (and ⌥ is down): everywhere else clicks pass through.
        let interactive = held != nil || (option && frame.contains(cursor) && field.hitTest(point: here))
        if window.ignoresMouseEvents == interactive { window.ignoresMouseEvents = !interactive }
        if !resumed, !still, let prev = lastCursor, prev != cursor, NSEvent.pressedMouseButtons & 1 == 0, !option, held == nil {
            field.sweep(from: CGPoint(x: prev.x - o.x, y: prev.y - o.y), to: CGPoint(x: cursor.x - o.x, y: cursor.y - o.y), dt: Float(dt))
        }
        let local = SIMD2(Float(cursor.x - frame.origin.x), Float(cursor.y - frame.origin.y))
        let moved = lastCursor.map { SIMD2(Float(cursor.x - $0.x), Float(cursor.y - $0.y)) / Float(max(dt, 1.0 / 240)) } ?? .zero   // dt can be 0 (same timestamp twice): 0/0 would put NaN in every flake near the pointer
        field.optionHeld = option
        refreshDay(now: now)
        field.setPointer(frame.contains(cursor) ? local : nil, velocity: resumed ? .zero : moved)
        let lastCursorPrev = lastCursor ?? cursor
        lastCursor = cursor
        perf?.add(.input, t0); t0 = Perf.now()
        let drag = confirmedDrag   // only the confirmed drag target (its delta matched the mouse's, same size, unique), never any window that merely moved
        // A dragged window follows the mouse 1:1: its pile segments, figures and balls shift by the mouse delta since the last poll (a shader uniform).
        // After release the last offset is held until the next poll reconciles with the real bounds.
        if drag != nil, NSEvent.pressedMouseButtons != 0 {
            let m = NSEvent.mouseLocation
            shiftID = drag
            shift = SIMD2(Float(m.x - pollMouse.x), Float(m.y - pollMouse.y))
        }
        perf?.add(.drag, t0)
        render(drawable)
        perf?.busyNow(field.busyReasons)
        perf?.frame(field, "paused=\(link?.isPaused ?? true) occluded=\(occluded) slow=\(slow)")
        // P3-C: adaptive rate (60 fps while anything fast happens, 30 otherwise) and the still-mode sleep.
        // A fast cursor only needs 60 fps when something reacts to it (flake push / pile groove); with the toggle off nothing does.
        if (prefs.pointerPush && moved.x * moved.x + moved.y * moved.y > 60 * 60 && FrameRate.cursorNear(frame: frame, from: lastCursorPrev, to: cursor)) || held != nil || field.isBusy { fastUntil = now + 0.5 }
        let wantSlow = (prefs.adaptive || prefs.economy) && now > fastUntil   // economy always steps down when calm
        if wantSlow != slow { slow = wantSlow; link?.preferredFrameRateRange = frameRange }
        if let d = meltDone, field.meltDone { meltDone = nil; d() }
        if still, !dirty, field.pilesSettled { stillPaused = true; link?.isPaused = true }
    }

    /// Tells the simulation today's date (sleigh frequency); re-read every 10 minutes so a Mac left on rolls over into December.
    private func refreshDay(now: CFTimeInterval = 0, force: Bool = false) {
        guard force || now - dayChecked > 600 else { return }
        dayChecked = now
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        field.calendarDay = (c.month ?? 0, c.day ?? 0)
    }

    private func mouseDown(_ e: NSEvent) {
        guard e.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.option) else { return }
        let p = local(e)
        if field.openGift(at: p) { return }
        held = field.pickSnowball(at: p) ?? field.scoop(at: p)
        lastDragTime = e.timestamp
    }

    private func mouseDragged(_ e: NSEvent) {
        guard let id = held else { return }
        field.drag(id, to: local(e), dt: Float(max(e.timestamp - lastDragTime, 1.0 / 240)))
        lastDragTime = e.timestamp
    }

    private func mouseUp(throwing: Bool = false) {   // a pause before letting go is not a throw
        guard let id = held else { return }
        held = nil
        field.drop(id, throwing: throwing)
    }

    /// Balls, figures and shots through `Rig`; the ones standing on the dragged window are shifted by the drag.
    private func writePrims(_ w: inout PrimWriter) {
        let hc = contrast > 0
        func d(_ sid: Int?) -> SIMD2<Float> { sid != nil && sid == shiftID ? shift : .zero }
        for b in field.balls {
            Rig.ball(center: b.pos + d(b.surfaceID), radius: b.radius, rotation: b.rotation, fade: b.fade, squash: 0, contrast: hc,
                     face: b.face != 0, facing: b.face == 0 ? 1 : b.face, into: &w)
        }
        for f in field.figures where f.phase != .hidden {
            if f.kind == .sleigh { Rig.sleigh(field.sleighLook(of: f), contrast: hc, into: &w); continue }
            if f.kind == .rabbit {
                var l = field.rabbitLook(of: f)
                let o = d(f.surfaceID)
                l.foot += o
                if let fl = l.flight { l.flight = fl + SIMD3(o.x, o.y, 0) }
                Rig.rabbit(l, contrast: hc, into: &w)
                continue
            }
            if f.kind == .penguin {
                var l = field.penguinLook(of: f)
                l.foot += d(f.surfaceID)
                Rig.penguin(l, contrast: hc, into: &w)
                continue
            }
            if f.kind == .robin {
                var l = field.robinLook(of: f)
                l.foot += d(f.surfaceID)
                Rig.robin(l, contrast: hc, into: &w)
                continue
            }
            var look = field.look(of: f)
            look.foot += d(f.surfaceID)
            if reduceMotion { look.pose.flutter = Flutter(); look.newest = 1 }
            Rig.snowman(look, contrast: hc, into: &w)
        }
        field.writeCarrotPrims(&w, shift: d)
        field.writeGiftPrims(&w, contrast: hc, shift: d)
        field.writeShotPrims(&w, trails: !reduceMotion, shift: d)
        field.writeIciclePrims(&w, contrast: hc, shift: d)
    }

    private func render(_ drawable: CAMetalDrawable) {
        let g = shrunk ?? CGRect(origin: .zero, size: frame.size)   // MARK: P3-0
        // A drawable made before a resize has the old size: skip it (the next one matches).
        perf?.bump(.renders)
        guard drawable.texture.width == Int((g.width * scale).rounded()), drawable.texture.height == Int((g.height * scale).rounded()) else { perf?.bump(.skipSize); return }
        guard inFlight.wait(timeout: .now()) == .success else { perf?.bump(.skipSlot); return }   // never block the main thread
        guard let cmd = gpu.queue.makeCommandBuffer() else {
            perf?.bump(.skipCmd)
            inFlight.signal()
            return
        }
        let buffer = buffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % buffers.count
        var t0 = Perf.now()
        let count = still ? 0 : field.writeInstances(to: buffer.contents().assumingMemoryBound(to: Instance.self))

        perf?.add(.write, t0); t0 = Perf.now()
        perf?.setInstances(count)
        let pbuf = primBuffers[(bufferIndex + 2) % 3]   // bufferIndex already advanced: the same ring slot as `buffer`
        var w = PrimWriter(pbuf.contents().assumingMemoryBound(to: Prim.self), capacity: primCapacity)
        t0 = Perf.now()
        writePrims(&w)
        if w.dropped > 0 { primWant = max(primWant, primCapacity + w.dropped) }
        perf?.truncated(prims: w.dropped)
        perf?.add(.actors, t0); t0 = Perf.now()
        pass.colorAttachments[0].texture = drawable.texture
        let slot = (pileSlot + 1) % pileBuffers.count
        t0 = Perf.now()
        var pileDropped = 0
        defer { pileForce = false }
        if let n = field.writePiles(to: pileBuffers[slot].contents().assumingMemoryBound(to: PileSeg.self), capacity: pileCapacity, dt: frameDt, force: pileForce, dropped: &pileDropped) {
            pileSlot = slot
            pileCount = n
            perf?.add(.pile, t0); perf?.bump(.pileWrites); perf?.setSegs(n)
        } else { perf?.bump(.pileHits) }
        perf?.truncated(piles: pileDropped)
        t0 = Perf.now()
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            var viewSize = field.size
            // Shaders always work in whole-screen coordinates; the viewport slides the screen under the (smaller) drawable.
            enc.setViewport(MTLViewport(originX: Double(-g.minX * scale), originY: Double(-(CGFloat(field.size.y) - g.maxY) * scale),
                                        width: Double(CGFloat(field.size.x) * scale), height: Double(CGFloat(field.size.y) * scale), znear: 0, zfar: 1))
            if pileCount > 0 {   // piles under the actors
                var dragOffset = shiftID == nil ? SIMD2<Float>.zero : shift
                enc.setRenderPipelineState(gpu.piles)
                enc.setVertexBuffer(pileBuffers[pileSlot], offset: 0, index: 0)
                enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
                enc.setVertexBytes(&dragOffset, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
                enc.setFragmentBuffer(pileBuffers[pileSlot], offset: 0, index: 0)
                enc.setFragmentBytes(&contrast, length: MemoryLayout<Float>.size, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: pileCount)
            }
            if w.n > 0 {   // actors under the flakes
                enc.setRenderPipelineState(gpu.prims)
                enc.setVertexBuffer(pbuf, offset: 0, index: 0)
                enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
                enc.setFragmentBuffer(pbuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: w.n)
            }
            enc.setRenderPipelineState(gpu.flakes)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setFragmentBytes(&contrast, length: MemoryLayout<Float>.size, index: 0)
            occ[8] = SIMD4(occStrength, 0, 0, 0)
            occ.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            if count > 0 { enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count) }
            enc.endEncoding()
        }
        cmd.present(drawable)
        let sem = inFlight, meter = perf
        cmd.addCompletedHandler { c in meter?.gpuDone(c); sem.signal() }
        cmd.commit()
        perf?.bump(.commits)
        perf?.add(.encode, t0)
    }
}
