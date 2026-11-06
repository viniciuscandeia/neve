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

    let screen: NSScreen
    private let field: SnowField
    private let gpu: Gpu
    private let window: NSWindow
    private let view = InteractView()
    private var held: Int?                // snowball being dragged
    private var lastDragTime: CFTimeInterval = 0
    private var pollMouse = NSEvent.mouseLocation
    private var lastCursor: CGPoint?
    private let metalLayer = CAMetalLayer()
    private let buffers: [MTLBuffer]
    private static let primCapacity = 640   // ~600 prims / screen
    private let primBuffers: [MTLBuffer]
    // MARK: pile pass
    private static let pileCapacity = 8192
    private let pileBuffers: [MTLBuffer]
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
    private var groundY: CGFloat
    private var visibleTop: CGFloat
    private let frame: CGRect, scale: CGFloat

    init?(screen: NSScreen, prefs: OverlayPrefs) {
        guard let gpu = Overlay.sharedGpu else { return nil }
        let f = screen.frame, v = screen.visibleFrame
        frame = f
        scale = screen.backingScaleFactor
        groundY = v.minY - f.minY
        visibleTop = v.maxY - f.minY
        let areaScale = Float(f.width * f.height) / (1440 * 900)
        let field = SnowField(size: f.size, origin: f.origin, groundY: groundY, visibleTop: visibleTop,
                              flakeCount: max(120, Int(Float(Tuning.flakes) * areaScale)), config: simConfig)
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = gpu.device.makeBuffer(length: field.capacity * MemoryLayout<Instance>.stride, options: .storageModeShared) else { return nil }
            buffers.append(b)
        }
        var primBuffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = gpu.device.makeBuffer(length: Overlay.primCapacity * MemoryLayout<Prim>.stride, options: .storageModeShared) else { return nil }
            primBuffers.append(b)
        }
        self.primBuffers = primBuffers
        var pileBuffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = gpu.device.makeBuffer(length: Overlay.pileCapacity * MemoryLayout<PileSeg>.stride, options: .storageModeShared) else { return nil }
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
        let root = CALayer()
        view.frame = bounds
        view.layer = root
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
        intro()
    }

    /// True when the screen's frame or scale differs from creation: needs a full rebuild.
    func screenChanged(_ s: NSScreen) -> Bool { s.frame != frame || s.backingScaleFactor != scale }

    /// Dock / menu bar moved (visibleFrame changed, frame unchanged): updated in place, piles kept.
    func refreshBounds() {
        let g = screen.visibleFrame.minY - frame.minY, t = screen.visibleFrame.maxY - frame.minY
        guard g != groundY || t != visibleTop else { return }
        groundY = g
        visibleTop = t
        field.setBounds(groundY: g, visibleTop: t)
    }

    /// Reduce Motion: calmer snow. Increase Contrast: stronger flake rim and pile bottom edge. (Reduce Transparency: nothing to change, the overlay has no blur.)
    @objc private func accessibilityChanged() {
        let ws = NSWorkspace.shared
        let motion = ws.accessibilityDisplayShouldReduceMotion, hc = ws.accessibilityDisplayShouldIncreaseContrast
        field.setCalm(motion)
        reduceMotion = motion
        still = prefs.still && motion
        contrast = hc ? 1 : 0
    }

    private var lastWindows: [WindowInfo] = [], lastChange: CFTimeInterval = 0
    func update(windows: [WindowInfo]) {
        // Time since the last *changed* list (identical polls must not shrink it), clamped like the old wall-clock path.
        let now = CACurrentMediaTime()
        field.update(windows: windows, dt: Float(min(max(now - lastChange, 1.0 / 240), 0.5)))
        if windows != lastWindows { lastWindows = windows; lastChange = now }
        pollMouse = NSEvent.mouseLocation   // reference for the per-frame drag offset; the poll's real bounds win
        shift = .zero; shiftID = nil
    }
    func clear() { field.clear() }
    func stage(_ s: Scenario) { field.stage(s) }

    private var outroGen = 0   // bumped by intro() / outro(): a stale outro step does nothing
    /// Snow starts gradually (no flakes pre-scattered): launch and "Nevar" turned back on. Reduce Motion keeps the plain window fade-in.
    func intro() {
        outroGen += 1
        if !reduceMotion { field.beginIntro(duration: 2.5) }
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
    func dropPiles() { field.dropPiles() }
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
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(p.behind ? .desktopIconWindow : .dockWindow)) + 1)
        window.sharingType = p.showInCaptures ? .readOnly : .none   // hidden from screenshots / recordings / sharing by default
        field.snowmanEnabled = p.snowman
        field.walkEnabled = p.walk
        field.setIntensity(p.intensity)
        link?.preferredFrameRateRange = frameRange
        accessibilityChanged()   // `still` follows the pref
    }
    private var frameRange: CAFrameRateRange {
        lowPower || prefs.economy ? CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30) : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    /// True when `r` (a window frame, AppKit coords) covers this whole screen, menu bar included = a fullscreen app.
    func covers(_ r: CGRect) -> Bool { r.insetBy(dx: -1, dy: -1).contains(screen.frame) }
    var isFullscreen: Bool { fullscreen }
    func setFullscreen(_ on: Bool) { if on != fullscreen { fullscreen = on; present() } }

    /// The controller's decision: enabled, awake, session active, not thermally throttled, user not idle.
    func setRun(_ on: Bool) { run = on; present() }

    /// Presents only when `run` and not under a fullscreen app. Piles are kept while paused.
    private func present() {
        guard run && !fullscreen else {
            guard window.isVisible else { link?.isPaused = true; return }
            // Fade out (~0.4s), then hide; the link keeps running meanwhile. Fullscreen/thermal hides are the same path.
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; window.animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !(self.run && !self.fullscreen) else { return }
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
        guard window.isVisible else { return }
        var t0 = Perf.now()
        let now = time, resumed = lastTimestamp == 0
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(now - lastTimestamp, 1.0 / 30)
        lastTimestamp = now
        frameDt = Float(dt)
        if !still { field.step(dt: Float(dt)) }
        Perf.add(.step, t0); t0 = Perf.now()
        // Cursor wipe: one sweep per frame from the last position (polling needs no event monitor). Drags are window physics.
        let cursor = NSEvent.mouseLocation
        let option = NSEvent.modifierFlags.contains(.option)
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
        let moved = lastCursor.map { SIMD2(Float(cursor.x - $0.x), Float(cursor.y - $0.y)) / Float(dt) } ?? .zero
        field.setPointer(frame.contains(cursor) ? local : nil, velocity: resumed ? .zero : moved)
        lastCursor = cursor
        Perf.add(.input, t0); t0 = Perf.now()
        let drag = field.draggingID
        // A dragged window follows the mouse 1:1: its pile segments, figures and balls shift by the mouse delta since the last poll (a shader uniform).
        // After release the last offset is held until the next poll reconciles with the real bounds.
        if drag != nil, NSEvent.pressedMouseButtons != 0 {
            let m = NSEvent.mouseLocation
            shiftID = drag
            shift = SIMD2(Float(m.x - pollMouse.x), Float(m.y - pollMouse.y))
        }
        Perf.add(.pile, t0)
        render(drawable)
        Perf.frame(field)
    }

    private func mouseDown(_ e: NSEvent) {
        guard e.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.option) else { return }
        held = field.pickSnowball(at: e.locationInWindow) ?? field.scoop(at: e.locationInWindow)
        lastDragTime = e.timestamp
    }

    private func mouseDragged(_ e: NSEvent) {
        guard let id = held else { return }
        field.drag(id, to: e.locationInWindow, dt: Float(max(e.timestamp - lastDragTime, 1.0 / 240)))
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
            var look = field.look(of: f)
            look.foot += d(f.surfaceID)
            if reduceMotion { look.pose.flutter = Flutter(); look.newest = 1 }
            Rig.snowman(look, contrast: hc, into: &w)
        }
        for s in field.shots { Rig.shot(pos: s.pos, radius: 3.6, alpha: 1, into: &w) }
    }

    private func render(_ drawable: CAMetalDrawable) {
        guard inFlight.wait(timeout: .now()) == .success else { return }   // never block the main thread
        guard let cmd = gpu.queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let buffer = buffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % buffers.count
        var t0 = Perf.now()
        let count = still ? 0 : field.writeInstances(to: buffer.contents().assumingMemoryBound(to: Instance.self))

        Perf.add(.write, t0); t0 = Perf.now()
        Perf.setInstances(count)
        let pbuf = primBuffers[(bufferIndex + 2) % 3]   // bufferIndex already advanced: the same ring slot as `buffer`
        var w = PrimWriter(pbuf.contents().assumingMemoryBound(to: Prim.self), capacity: Overlay.primCapacity)
        t0 = Perf.now()
        writePrims(&w)
        Perf.add(.actors, t0); t0 = Perf.now()
        pass.colorAttachments[0].texture = drawable.texture
        let slot = (pileSlot + 1) % pileBuffers.count
        t0 = Perf.now()
        if let n = field.writePiles(to: pileBuffers[slot].contents().assumingMemoryBound(to: PileSeg.self), capacity: Overlay.pileCapacity, dt: frameDt) {
            pileSlot = slot
            pileCount = n
        }
        Perf.add(.pile, t0); t0 = Perf.now()
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            var viewSize = field.size
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
            if count > 0 { enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count) }
            enc.endEncoding()
        }
        cmd.present(drawable)
        let sem = inFlight
        cmd.addCompletedHandler { c in Perf.gpuDone(c); sem.signal() }
        cmd.commit()
        Perf.add(.encode, t0)
    }
}
