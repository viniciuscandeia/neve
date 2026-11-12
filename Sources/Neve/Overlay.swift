// AGENT HEADER - Sources/Neve/Overlay.swift  (one click-through Metal window per screen + its display-link frame loop)
// Role: `Overlay` (@MainActor, CAMetalDisplayLinkDelegate) owns, for ONE NSScreen: a borderless non-activating NSPanel (canJoinAllSpaces, level just above the Dock window, or just above
//   desktop icons in "behind windows" mode; sharingType .none unless showInCaptures), a CAMetalLayer, the `SnowField` simulation (NeveCore), 3-slot ring buffers (flake Instances, actor Prims, PileSegs;
//   inFlight semaphore = 3, never blocks main: a skipped slot just drops the frame) and the three Metal passes (piles -> prims/actors -> flakes; shaders in PileShader/PrimShader/Renderer.swift).
//   `InteractView` forwards mouse events; the panel ignores the mouse EXCEPT while Option is held over snow / a snowball (hitTest) or a drag is in progress (`pressing`, `held` snowball, `heldTree` = the overlay whose field holds the dragged Christmas tree: it moves to the neighbour screen's overlay (Overlay.all) when the cursor crosses; `dropTree()` / `hasTree` are the menu / uniqueness hooks).
// Coordinates: simulation + all buffers are screen-LOCAL AppKit points, y-up, origin = screen.frame.origin (groundY = visibleFrame.minY - frame.minY, visibleTop likewise). Metal viewport slides the whole-screen
//   coordinate space under a possibly smaller drawable (`shrunk` live rect, "maximized window" compact mode driven by Coverage.swift's CompactState; occ[26] = shader occluder rects + strength / counts).
// Frame loop (`tick`, main thread via RunLoop.main .common; the nonisolated delegate uses MainActor.assumeIsolated): dt = min(real dt, 0.06); Palette.tick; advanceCover; cursor sweep (one segment from last
//   position, only if not near another screen); pointer velocity; MusicTap.shared.read(); field.step (optionally calm interpolation: Tuning.interpolateCalm); drag shift (pile/figure offset = mouse delta since poll);
//   render(). Adaptive rate: 60 fps while anything fast (cursor near snow, held ball, field.isBusy) else 30 after FrameRate.holdDown; economy (or thermal fair+, FrameRate.economyFrames) / low power cap; still mode (Reduce Motion + stillSnow) sleeps the link
//   once piles settle (`dirty`/`wake()` restart it: ANY state change that alters the picture must call wake()).
// Controller API (called by AppController in main.swift): setRun / present (fade 0.4 s then orderOut, link paused), setSuspended (Mission Control fade 0.2 s), dip (Space change), update(windows:covering:dragTarget:mouse:)
//   (poll rate, NOT per frame: grows buffers, measureCover), adopt/screenChanged/refreshBounds/teardown (display hot-plug, Dock/menu-bar visibleFrame changes keep piles), intro/resume/melt/outro (gen counters make stale
//   completions no-ops; teardown completes pending melt/outro so the controller's Countdown ends), apply(OverlayPrefs), clear, stage, beginScene.
// Dependencies: NeveCore (SnowField, Tuning, FrameRate, Palette, Rig, PrimWriter, WindowInfo, coversScreen...), Perf.swift (NEVE_PERF meter, signposts), MusicTap, Gpu from Renderer.swift. Env: NEVE_REDUCE_MOTION=1 (force), NEVE_SLOWMO=<f>.
// Perf: tick is the per-frame hot path (~60/s per screen): no allocation, no locks; buffers grow only in update() (poll rate); writePrims/writePiles/writeInstances mirror data the shaders read.
// Gotchas: Rig/Prim/PileSeg/Instance layouts must match the Metal source strings in the shader files; Render.writePiles output is checked by GroupContourTests / StackIndependenceTests; do not re-set window.level/sharingType unless
//   changed (WindowServer recomposite hitch); screen tests/captures must be idle-gated and run under scripts/agent-run.sh --screen.

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

    private(set) var screen: NSScreen
    private var perf: Perf.Meter?   // NEVE_PERF=1 only
    private let field: SnowField
    private let gpu: Gpu
    private let window: NSWindow
    var windowNumber: Int { window.windowNumber }
    private let view = InteractView()
    private var held: Int?                // snowball being dragged
    private var heldTree: Overlay?        // overlay (self or the neighbour screen's) whose field holds the Christmas tree being dragged
    private var holding: Bool { held != nil || heldTree != nil }
    /// Every overlay of the app (set once by AppController): the tree drag looks the screen under the cursor up here.
    static var all: () -> [Overlay] = { [] }
    var screenFrame: CGRect { frame }
    var hasTree: Bool { field.hasTree }
    /// "Soltar árvore": starts the tree's gust + fall on this screen (false when there is one already, the option is off or the snow is leaving).
    func dropTree(replacing: Bool = false) -> Bool { let ok = field.dropTree(replacing: replacing); if ok { wake() }; return ok }
    /// Removes any tree / burst this screen holds (the menu replaces it); a drag in progress ends with it.
    func removeTree() { field.removeTree(); if heldTree != nil { heldTree = nil; pressing = false }; wake() }
    private var lastDragTime: CFTimeInterval = 0
    private var dayChecked: CFTimeInterval = -1000
    private var pollMouse = NSEvent.mouseLocation
    private var lastCursor: CGPoint?
    private let metalLayer = CAMetalLayer()
    private let buffers: [MTLBuffer]
    private var primCapacity = 1000   // ~700-900 prims (tree ~145, lights ~300) / screen; grows (in update, never per frame) after a frame that dropped some
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
    private var pileOcc: [SIMD4<Float>] = []   // render()'s occluder rects, reused every frame
    private var link: CAMetalDisplayLink?
    private let pass = MTLRenderPassDescriptor()   // reused every frame; only the texture changes
    private var run = false, fullscreen = false   // run: the controller's single decision (enabled, awake, not hot, user active)
    private var occluded = false
    private var suspended = false, dipGen = 0   // Mission Control hides the snow (fade 0.2 s); a Space change dips it
    private var pressing = false              // between our own mouseDown and mouseUp: stays interactive so the release is ours
    private var lowPower = false
    private var thermalWarm = false   // thermal state >= fair: economy frame rates (FrameRate.economyFrames), set by the controller
    private var econFrames: Bool { FrameRate.economyFrames(pref: prefs.economy, thermalRaw: thermalWarm ? 1 : 0) }
    private var tickTarget = 0.0   // target timestamp of the tick being drawn
    private var contrast: Float = 0
    private var reduceMotion = false
    private var prefs: OverlayPrefs
    private var still = false   // Reduce Motion + "Neve parada": no flakes drawn or stepped, piles kept
    private var lastTimestamp: CFTimeInterval = 0
    // MARK: frame-rate policy
    private var stillPaused = false, dirty = true       // still snow: the link sleeps once the picture is settled; `dirty` = something changed since the last frame
    private var fastUntil: CFTimeInterval = 0, slow = false   // adaptive fps: 30 fps once nothing fast happened for FrameRate.holdDown
    private var groundY: CGFloat
    private var visibleTop: CGFloat
    private var frame: CGRect, scale: CGFloat
    private var fps: Int
    // MARK: maximized window (Coverage.swift)
    private let root = CALayer()                       // screen-local coordinates: bounds.origin = the live rect's origin while shrunk
    private var cover = CompactState()
    private var coverFraction: Float = 0, liveLocal: CGRect?   // from the last window poll
    private var coverTime: CFTimeInterval = 0, coverCheck = false
    private var coverPause = false                     // `covered`: nothing live, paused like a fullscreen app
    private var coverActive = false                    // compact mode entered (until the exit ramp ends)
    private var occStrength: Float = 0, occTarget: Float = 0   // flake occluders 0...1
    private var occ = [SIMD4<Float>](repeating: .zero, count: 26)   // 8 compact rects (faded by strength), 8 hiding background flakes, 8 hard rects (surfaceless windows, floating panels), s, n (see Renderer `Occ`)
    private var occCount = (compact: 0, behind: 0, hard: 0)
    private var shrunk: CGRect?                        // live rect applied to panel + Metal layer (screen-local); nil = whole screen

    init?(screen: NSScreen, prefs: OverlayPrefs) {
        guard let gpu = Overlay.sharedGpu else { return nil }
        let f = screen.frame, v = screen.visibleFrame
        frame = f
        scale = screen.backingScaleFactor
        fps = screen.maximumFramesPerSecond
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
        view.onUp = { [weak self] e in MainActor.assumeIsolated { self?.pressing = false; self?.mouseUp(throwing: e.timestamp - (self?.lastDragTime ?? 0) < 0.08) } }

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
        metalLayer.maximumDrawableCount = 2   // ~24 MB less per Retina screen; a missing drawable just skips the frame (CAMetalDisplayLink only calls back with one; skipSize/skipSlot guard the rest)
        metalLayer.isOpaque = false
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.contentsGravity = .bottomLeft   // a resize never stretches the last frame
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        root.addSublayer(metalLayer)

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: AppearanceWatcher.changed, object: nil)
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

    /// The same display with the same or a new frame / scale (resolution change, arrangement change, a display that came back after a short drop):
    /// piles and figures are kept (window piles come back with their windows). The park may have outlived pref / frame-rate / bounds changes:
    /// the display link is rebuilt by present(), the window re-framed.
    func adopt(_ s: NSScreen, prefs p: OverlayPrefs) {
        screen = s
        link?.invalidate(); link = nil
        if screenChanged(s) { rebuildGeometry(s) } else { window.setFrame(s.frame, display: false) }
        apply(p)
        fps = s.maximumFramesPerSecond
        refreshBounds()
        present()
    }

    private func rebuildGeometry(_ s: NSScreen) {
        let f = s.frame, v = s.visibleFrame
        frame = f
        scale = s.backingScaleFactor
        groundY = sceneKind == nil ? v.minY - f.minY : 0
        visibleTop = v.maxY - f.minY
        shrunk = nil; liveLocal = nil; coverKey = nil
        cover = CompactState(); coverFraction = 0; coverActive = false; coverPause = false; occStrength = 0; occTarget = 0
        for i in occ.indices { occ[i] = .zero }; occCount = (0, 0, 0)
        held = nil; heldTree = nil; pressing = false; lastCursor = nil; shiftID = nil; shift = .zero
        lastWindows = []; pileSeen = -1; pileForce = true
        field.resize(size: f.size, origin: f.origin, groundY: groundY, visibleTop: visibleTop)
        field.setLive(nil)
        let bounds = CGRect(origin: .zero, size: f.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(f, display: false)
        view.frame = bounds
        root.frame = bounds; root.bounds = bounds
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
        wake()
    }

    private func fadeAlpha(_ a: CGFloat, _ duration: Double) {
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = duration; window.animator().alphaValue = a }
    }

    /// Mission Control: the snow fades out in 0.2 s and back in once it is over.
    func setSuspended(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        dipGen += 1
        if on { fadeAlpha(0, 0.2) } else if showing { fadeAlpha(1, 0.2) }   // back only if the overlay should be showing (the condition dip() uses)
        if on { pauseLink() } else { lastTimestamp = 0; wake(); if !occluded { link?.isPaused = !window.isVisible } }   // the link sleeps under Mission Control
    }

    /// Space change: the snow dips to nothing in 0.12 s and returns after ~0.5 s, so restored piles appear under the fade.
    func dip() {
        guard window.isVisible, !suspended else { return }
        dipGen += 1
        let g = dipGen
        fadeAlpha(0, 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { guard let self, self.dipGen == g, !self.suspended, self.showing else { return }; self.fadeAlpha(1, 0.4) }
        }
    }

    /// Dock / menu bar moved (visibleFrame changed, frame unchanged): updated in place, piles kept.
    func refreshBounds() {
        if screen.maximumFramesPerSecond != fps {   // refresh-rate change (ProMotion / external display mode): same frame, new frame-rate cap
            fps = screen.maximumFramesPerSecond
            link?.preferredFrameRateRange = frameRange
        }
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
        link?.isPaused = occluded || !window.isVisible || suspended
    }

    private var pileSeen = -1
    private var lastWindows: [WindowInfo] = []
    private var confirmedDrag: Int?   // the window being dragged by the mouse (main confirms it); only that one is extrapolated
    /// Space switch: no deposits on window surfaces until the next snapshot reconciles.
    func markStale() { field.markStale(now: CACurrentMediaTime()) }
    /// `covering`: the real windows for coverage / compaction when `windows` (the surfaces) is deliberately empty (behind-windows mode).
    /// `dragTarget`: the mouse-confirmed dragged window, the one source for pile segments, figures and balls. `mouse`: the pointer read at the same
    /// instant as the window bounds (the per-frame drag offset is measured from it).
    func update(windows: [WindowInfo], covering: [WindowInfo]? = nil, dragTarget: Int? = nil, mouse: CGPoint? = nil) {
        let now = CACurrentMediaTime()
        field.setDragTarget(dragTarget)
        field.update(windows: windows, now: now)   // each window's dt = its own time since its last sample
        confirmedDrag = dragTarget
        growBuffers()
        let changed = windows != lastWindows
        if changed { lastWindows = windows; fastUntil = now + FrameRate.holdDown; wake() }
        if field.pileVersion != pileSeen { pileSeen = field.pileVersion; wake() }
        pollMouse = mouse ?? NSEvent.mouseLocation   // reference for the per-frame drag offset; the poll's real bounds win
        shift = .zero; shiftID = nil
        measureCover(covering ?? windows)
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

    // MARK: maximized window: snow only in the visible strip

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
        let rects = windows.filter { $0.number != 0 && !$0.occluderOnly && $0.frame.intersects(vis) }.map(\.frame)
        let c = coverage(of: rects, in: vis)
        coverFraction = c.fraction;
        liveLocal = liveRect(frame: frame, visible: vis, uncovered: c.uncovered)?.offsetBy(dx: -o.x, dy: -o.y)
        func box(_ r: CGRect) -> SIMD4<Float> { let l = r.offsetBy(dx: -o.x, dy: -o.y); return SIMD4(Float(l.minX), Float(l.minY), Float(l.maxX), Float(l.maxY)) }
        for i in 0..<24 { occ[i] = .zero }
        let l = occluderLayout(windows: windows, vis: vis, screen: frame, behindWindows: prefs.behind, behindFar: prefs.behindLarge)
        for (i, r) in l.compact.enumerated() { occ[i] = box(r) }
        for (i, r) in l.behind.enumerated() { occ[8 + i] = box(r) }
        for (i, r) in l.hard.enumerated() { occ[16 + i] = box(r) }
        occCount = (l.compact.count, l.behind.count, l.hard.count)
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

    func clear() { field.clear(); held = nil; heldTree = nil; pressing = false; wake() }
    func stage(_ s: Scenario) { field.stage(s); wake() }
    /// Scene mode: starts the script (after the scene windows are in the field) / seconds into its loop.
    func beginScene(_ k: SceneKind) { field.beginScene(k); wake() }
    var sceneTime: Float? { field.sceneTime }

    private var outroGen = 0   // bumped by intro() / outro(): a stale outro step does nothing
    /// Snow starts gradually (no flakes pre-scattered): launch and "Nevar" turned back on. Reduce Motion keeps the plain window fade-in.
    func intro() {
        if !reduceMotion { resume() } else { outroGen += 1; outroDone = nil; field.endOutro() }
    }
    /// Back from the idle pause (or a melt): no flake on screen, new ones fall in from above the top edge (Reduce Motion too).
    func resume() {
        outroGen += 1
        meltDone = nil; outroDone = nil
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
        outroDone = done
        let gen = outroGen, fade = reduceMotion || still
        if !fade { field.collapseAll(spread: 0.3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (fade ? 0 : 1.0)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.outroGen == gen else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; self.window.animator().alphaValue = 0 }) {
                    MainActor.assumeIsolated { if self.outroGen == gen { self.finishOutro() } }
                }
            }
        }
    }
    private var outroDone: (@MainActor () -> Void)?
    private func finishOutro() { let d = outroDone; outroDone = nil; d?() }
    func dropPiles() { field.dropPiles(); wake() }
    func setThermalWarm(_ on: Bool) {
        guard on != thermalWarm else { return }
        thermalWarm = on
        link?.preferredFrameRateRange = frameRange
    }
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
        field.treeEnabled = p.tree
        field.lightsEnabled = p.lights
        refreshDay(force: true)
        field.groundOnlyActors = p.behind
        field.economy = p.economy
        field.setIntensity(p.intensity)
        if let link, link.preferredFrameRateRange != frameRange { link.preferredFrameRateRange = frameRange }
        accessibilityChanged()   // `still` follows the pref
    }
    private var simAccum = 0.0, lastStepDt: Float = 0
    /// Calm interpolation active: option on, quiet floor, and not in a mode that is capped at 30 anyway.
    private var interpolating: Bool { Tuning.interpolateCalm && slow && !econFrames && !lowPower && shrunk == nil }
    private var frameRange: CAFrameRateRange {
        let r = FrameRate.range(lowPower: lowPower, economy: econFrames, shrunk: shrunk != nil, quiet: slow && !interpolating, maxFPS: fps)
        return CAFrameRateRange(minimum: r.min, maximum: r.max, preferred: r.preferred)
    }

    /// True when `r` (a window frame, AppKit coords) covers this whole screen, menu bar included = a fullscreen app.
    func covers(_ r: CGRect) -> Bool { coversScreen(r, frame: screen.frame, notchTop: screen.safeAreaInsets.top, visible: screen.visibleFrame) }
    var isFullscreen: Bool { fullscreen }
    func setFullscreen(_ on: Bool) { if on != fullscreen { fullscreen = on; present() } }

    /// The controller's decision: enabled, awake, session active, not thermally throttled, user not idle.
    func setRun(_ on: Bool) { run = on; present() }

    /// Presents only when `run` and not under a fullscreen app. Piles are kept while paused.
    private func present() {
        guard run && !fullscreen && !coverPause else {
            guard window.isVisible else { pauseLink(); return }
            // Fade out (~0.4s), then hide; the link keeps running meanwhile. Fullscreen/thermal hides are the same path.
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; window.animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !(self.run && !self.fullscreen && !self.coverPause) else { return }
                    self.pauseLink()
                    self.window.orderOut(nil)
                }
            }
            return
        }
        if !window.isVisible { occluded = false; window.alphaValue = 0; window.orderFrontRegardless(); lastTimestamp = 0 }
        if window.alphaValue < 1, !suspended { NSAnimationContext.runAnimationGroup { $0.duration = 0.4; window.animator().alphaValue = 1 } }
        if link == nil {
            // CAMetalDisplayLink hands over a ready drawable, so the main thread never blocks in nextDrawable.
            let l = CAMetalDisplayLink(metalLayer: metalLayer)
            l.delegate = self
            l.preferredFrameLatency = 2
            l.preferredFrameRateRange = frameRange
            l.add(to: .main, forMode: .common)
            link = l
        }
        if occluded || suspended { pauseLink() } else { link?.isPaused = false }
    }

    /// Every pause path: the display link stops and the panel stops catching the mouse (a paused tick can no longer let go of it).
    private func pauseLink() {
        link?.isPaused = true
        pressing = false
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
    }

    @objc private func appearanceChanged() { wake() }

    /// Only meaningful while ordered in (orderOut also reports "not visible"); pauses the link, never the window.
    @objc private func occlusionChanged() {
        guard window.isVisible else { return }
        occluded = !window.occlusionState.contains(.visible)
        if !occluded { lastTimestamp = 0 }
        if occluded || suspended { pauseLink() } else { link?.isPaused = false }
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        link?.invalidate()
        link = nil
        window.orderOut(nil)
        window.contentView = nil
        // A pending melt / outro would never finish once this overlay is gone: complete it now so the controller's countdown still ends.
        outroGen += 1
        let m = meltDone; meltDone = nil; m?()
        finishOutro()
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
        perf?.bump(.ticks); tickTarget = time   // captured per frame at encode (the handler runs later, after newer ticks)
        guard window.isVisible else { perf?.bump(.hidden); return }
        dirty = false
        var t0 = Perf.now()
        let now = time, resumed = lastTimestamp == 0
        let realDt = lastTimestamp == 0 ? 1.0 / 60 : now - lastTimestamp   // real elapsed time: pointer speed and sweep use it, never the clamped step
        let dt = min(realDt, 0.06)   // 20 fps (economy, calm) steps 0.05
        lastTimestamp = now
        Palette.tick(now: now)   // light/dark blend (~0.5 s)
        advanceCover(now)
        frameDt = Float(dt)
        // Cursor first, simulation after: the flakes, figures and piles of this frame already see this frame's pointer.
        // One sweep per frame from the last position (polling needs no event monitor). Drags are window physics.
        let cursor = sceneKind != nil ? CGPoint(x: -1e5, y: -1e5) : FakePointer.active ? FakePointer.location(now: now) : NSEvent.mouseLocation   // NEVE_FAKE_POINTER: scripted path (FakePointer.swift)   // scenes ignore the real cursor: the same story every time
        let option = sceneKind == nil && NSEvent.modifierFlags.contains(.option)
        let o = frame.origin
        let here = CGPoint(x: cursor.x - o.x, y: cursor.y - o.y)
        if holding, !option { mouseUp() }   // ⌥ released mid-drag: let go
        // Interactive only where there is snow or a snowball (and ⌥ is down): everywhere else clicks pass through.
        let buttons = NSEvent.pressedMouseButtons
        if buttons == 0 { pressing = false }   // the release was lost (another app took it): never stay interactive
        let interactive = holding || pressing || (option && buttons == 0 && showing && !suspended && frame.contains(cursor) && field.hitTest(point: here))
        if window.ignoresMouseEvents == interactive { window.ignoresMouseEvents = !interactive }
        let prevCursor = lastCursor ?? cursor
        let sweeping = !resumed && !still && lastCursor != nil && prevCursor != cursor && NSEvent.pressedMouseButtons & 1 == 0 && !option && !holding
        let from = CGPoint(x: prevCursor.x - o.x, y: prevCursor.y - o.y)
        // Another screen's overlay: a segment that never comes within 80pt (sweep radius + the tallest pile / figure) of this frame cuts nothing here.
        let near = CGRect(origin: .zero, size: frame.size).insetBy(dx: -80, dy: -80).intersects(CGRect(x: min(from.x, here.x), y: min(from.y, here.y), width: max(abs(here.x - from.x), 1), height: max(abs(here.y - from.y), 1)))
        if sweeping, near { field.sweep(from: from, to: here, dt: Float(max(realDt * Double(Self.slowmo), 1.0 / 240))) }
        let moved = FrameRate.pointerVelocity(dx: Float(cursor.x - prevCursor.x), dy: Float(cursor.y - prevCursor.y), realDt: realDt, slowmo: Self.slowmo)
        field.optionHeld = option
        refreshDay(now: now)
        field.setPointer(frame.contains(cursor) ? SIMD2(Float(here.x), Float(here.y)) : nil, velocity: resumed ? .zero : moved)
        lastCursor = cursor
        perf?.add(.input, t0); t0 = Perf.now()
        field.music = prefs.music ? MusicTap.shared.read() : .silent
        if !still {
            // Tuning.interpolateCalm (off by default): at the calm floor the link runs at the display rate, the sim still steps at the floor rate
            // (accumulated dt) and render() draws flakes back-extrapolated to the present (alpha). Off: one step per frame, as always.
            var stepDt = dt
            if interpolating {
                simAccum += dt
                let period = 1 / Double(FrameRate.calmFloor)
                if simAccum + dt * 0.5 >= period { stepDt = min(simAccum, 0.06); simAccum = 0 } else { stepDt = 0 }
            } else { simAccum = 0 }
            if stepDt > 0 {
                let sp = Perf.signposter.beginInterval("sim"); field.step(dt: Float(stepDt) * Self.slowmo); Perf.signposter.endInterval("sim", sp)
                lastStepDt = Float(stepDt) * Self.slowmo
            }
        }
        perf?.add(.step, t0); t0 = Perf.now()
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
        // Adaptive rate (60 fps while anything fast happens, 30 otherwise) and the still-mode sleep.
        // A fast cursor needs 60 fps when something reacts to it: snow / a ball / a figure in the sweep's path (piles only with "Cursor empurra" on, which also
        // pushes the falling flakes). The cheap screen test comes first.
        let fastCursor = moved.x * moved.x + moved.y * moved.y > 60 * 60 && FrameRate.cursorNear(frame: frame, from: prevCursor, to: cursor)
            && (prefs.pointerPush || (sweeping && field.snowNear(from: from, to: here)))
        if fastCursor { perf?.bump(.fast) }
        if fastCursor || holding || field.isBusy { fastUntil = now + FrameRate.holdDown }
        let wantSlow = (prefs.adaptive || econFrames) && now > fastUntil   // economy always steps down when calm
        if wantSlow != slow { slow = wantSlow; perf?.bump(.flips); link?.preferredFrameRateRange = frameRange }
        perf?.secSlow = slow
        if let d = meltDone, field.meltDone { meltDone = nil; d() }
        if still, !dirty, field.pilesSettled, !Palette.isBlending { stillPaused = true; pauseLink() }
    }

    /// Tells the simulation today's date (sleigh frequency); re-read every 10 minutes so a Mac left on rolls over into December.
    private func refreshDay(now: CFTimeInterval = 0, force: Bool = false) {
        guard force || now - dayChecked > 600 else { return }
        dayChecked = now
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        field.calendarDay = (c.month ?? 0, c.day ?? 0)
    }

    private func mouseDown(_ e: NSEvent) {
        guard e.modifierFlags.contains(.option) else { window.ignoresMouseEvents = true; return }   // not ours (⌥ let go meanwhile): hand the click back, post nothing
        pressing = true
        let p = local(e)
        if field.openGift(at: p) { return }
        if field.pickTree(at: p) { heldTree = self; lastDragTime = e.timestamp; return }
        held = field.pickSnowball(at: p) ?? field.scoop(at: p)
        lastDragTime = e.timestamp
    }

    /// Drags the Christmas tree: follows the cursor in global coordinates and, when the cursor enters another screen, moves the tree into that screen's field (the drag continues there).
    private func dragTree(_ e: NSEvent) {
        guard var host = heldTree else { return }
        let g = NSEvent.mouseLocation
        if !host.frame.contains(g), let n = Overlay.all().first(where: { $0 !== host && $0.showing && $0.frame.contains(g) }), let t = host.field.takeTree() {
            n.field.adoptTree(t, at: n.localPoint(g))
            host.wake(); n.wake()
            heldTree = n; host = n
        }
        host.field.dragTree(to: host.localPoint(g), dt: Float(max(e.timestamp - lastDragTime, 1.0 / 240)))
        lastDragTime = e.timestamp
        host.wake()
    }

    func localPoint(_ g: CGPoint) -> CGPoint { CGPoint(x: g.x - frame.origin.x, y: g.y - frame.origin.y) }

    private func mouseDragged(_ e: NSEvent) {
        if heldTree != nil { dragTree(e); return }
        guard let id = held else { return }
        field.drag(id, to: local(e), dt: Float(max(e.timestamp - lastDragTime, 1.0 / 240)))
        lastDragTime = e.timestamp
    }

    private func mouseUp(throwing: Bool = false) {   // a pause before letting go is not a throw
        if let h = heldTree { heldTree = nil; h.field.releaseTree(throwing: throwing); h.wake(); return }
        guard let id = held else { return }
        held = nil
        field.drop(id, throwing: throwing)
    }

    /// Balls, figures and shots through `Rig`; the ones standing on the dragged window are shifted by the drag.
    private func writePrims(_ w: inout PrimWriter) {
        let hc = contrast > 0
        func d(_ sid: Int?) -> SIMD2<Float> { sid != nil && sid == shiftID ? shift : .zero }
        field.writeBallPrims(&w, contrast: hc, shift: d)
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
        field.writeTreePrims(&w, contrast: hc, shift: d)
        field.writeCarrotPrims(&w, shift: d)
        field.writeGiftPrims(&w, contrast: hc, shift: d)
        field.writeShotPrims(&w, trails: !reduceMotion, shift: d)
        field.writeIciclePrims(&w, contrast: hc, shift: d)
        field.writeLightPrims(&w, shift: d)
    }

    private func render(_ drawable: CAMetalDrawable) {
        let g = shrunk ?? CGRect(origin: .zero, size: frame.size)
        // A drawable made before a resize has the old size: skip it (the next one matches).
        perf?.bump(.renders)
        guard drawable.texture.width == Int((g.width * scale).rounded()), drawable.texture.height == Int((g.height * scale).rounded()) else { perf?.bump(.skipSize); return }
        guard inFlight.wait(timeout: .now()) == .success else { perf?.bump(.skipSlot); return }   // never block the main thread
        guard let cmd = gpu.queue.makeCommandBuffer() else {
            perf?.bump(.skipCmd)
            inFlight.signal()
            return
        }
        let sp = Perf.signposter.beginInterval("encode"); defer { Perf.signposter.endInterval("encode", sp) }
        if let m = perf { let tt = tickTarget; drawable.addPresentedHandler { m.presented($0.presentedTime, target: tt) } }
        let buffer = buffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % buffers.count
        var t0 = Perf.now()
        let count = still ? 0 : field.writeInstances(to: buffer.contents().assumingMemoryBound(to: Instance.self), lag: interpolating ? (1 - FrameRate.interpAlpha(sinceStep: simAccum, stepPeriod: 1 / Double(FrameRate.calmFloor))) * lastStepDt : 0)

        perf?.add(.write, t0); t0 = Perf.now()
        perf?.setInstances(count)
        let pbuf = primBuffers[(bufferIndex + 2) % 3]   // bufferIndex already advanced: the same ring slot as `buffer`
        var w = PrimWriter(pbuf.contents().assumingMemoryBound(to: Prim.self), capacity: primCapacity)
        t0 = Perf.now()
        writePrims(&w)
        // Soft cut: before the drawable shrinks, everything outside the live strip fades with the occluders (`Rig.a` convention: alpha only).
        var outFade: Float = 0
        var live = SIMD4<Float>.zero
        if coverActive, shrunk == nil || occStrength < 1, let r = liveLocal, r.width * r.height <= 0.5 * frame.width * frame.height {
            outFade = occStrength; live = SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY))
            w.fadeOutside(live, by: 1 - outFade)
        }
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
            let fx: Float = prefs.economy || lowPower ? 0 : 1   // visual extras (glitter, grain, crystals, window shadow) off in economy / Low Power, like the crest glints
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
                var tone = SIMD4<Float>(contrast, Palette.dark, Float(ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 1024)), fx)   // (increase contrast, dark blend, clock, effects)
                enc.setFragmentBytes(&tone, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                pileOcc.removeAll(keepingCapacity: true)   // 2 x float4 per window in front-to-back order; the dragged one rides the mouse like its pile
                for o in field.occluders {
                    var rc = o.rect
                    if o.id == shiftID { rc += SIMD4<Float>(shift.x, shift.y, shift.x, shift.y) }
                    pileOcc.append(rc); pileOcc.append(SIMD4<Float>(o.radius, 0, 0, 0))
                }
                var occN = UInt32(field.occluders.count)
                if pileOcc.isEmpty { pileOcc = [.zero, .zero] }
                enc.setFragmentBytes(&pileOcc, length: pileOcc.count * MemoryLayout<SIMD4<Float>>.stride, index: 2)
                enc.setFragmentBytes(&live, length: MemoryLayout<SIMD4<Float>>.size, index: 4)
                enc.setFragmentBytes(&outFade, length: MemoryLayout<Float>.size, index: 5)
                enc.setFragmentBytes(&occN, length: MemoryLayout<UInt32>.size, index: 3)
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
            var streakDt = frameDt * Self.slowmo   // streak length = distance per SIM frame, so it matches the (slowed) velocity
            enc.setVertexBytes(&streakDt, length: MemoryLayout<Float>.size, index: 2)
            var cf = SIMD2<Float>(contrast, fx)
            enc.setFragmentBytes(&cf, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            occ[24] = SIMD4(occStrength, occStrength > 0 ? Float(occCount.compact) : 0, Float(occCount.hard), Palette.dark)   // compact rects only mask with strength > 0; behind / hard always
            occ[25] = SIMD4(Float(occCount.behind), 0, 0, 0)
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
