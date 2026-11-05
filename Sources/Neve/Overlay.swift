import AppKit
import Metal
import QuartzCore

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct Instance { float2 pos; float size; float alpha; };
struct VOut { float4 position [[position]]; float2 uv; float alpha; };
vertex VOut flakeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant Instance *inst [[buffer(0)]], constant float2 &viewSize [[buffer(1)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    Instance i = inst[iid];
    float2 p = i.pos + corner * i.size * 0.5;
    VOut o;
    o.position = float4(p / viewSize * 2.0 - 1.0, 0.0, 1.0);
    o.uv = corner;
    o.alpha = i.alpha;
    return o;
}
fragment float4 flakeFragment(VOut in [[stage_in]]) {
    float a = (1.0 - smoothstep(0.35, 1.0, length(in.uv))) * in.alpha;
    return float4(a, a, a, a);
}
"""

/// Shared Metal objects, built once.
private struct Gpu {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "flakeVertex")
        d.fragmentFunction = library.makeFunction(name: "flakeFragment")
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }
}

/// Click-through snow window covering one screen.
@MainActor
final class Overlay: NSObject {
    private static let sharedGpu = Gpu()

    private let screen: NSScreen
    private let field: SnowField
    private let gpu: Gpu
    private let window: NSWindow
    private let view = NSView()
    private let pileLayer = CAShapeLayer()
    private let metalLayer = CAMetalLayer()
    private let buffers: [MTLBuffer]
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var lastPathTime: CFTimeInterval = 0
    private let groundY: CGFloat
    private let visibleTop: CGFloat

    init?(screen: NSScreen) {
        guard let gpu = Overlay.sharedGpu else { return nil }
        let f = screen.frame, v = screen.visibleFrame
        groundY = v.minY - f.minY
        visibleTop = v.maxY - f.minY
        let areaScale = Float(f.width * f.height) / (1440 * 900)
        let field = SnowField(size: f.size, origin: f.origin, groundY: groundY, visibleTop: visibleTop,
                              flakeCount: max(120, Int(Float(Tuning.flakes) * areaScale)))
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = gpu.device.makeBuffer(length: field.capacity * MemoryLayout<Instance>.stride, options: .storageModeShared) else { return nil }
            buffers.append(b)
        }
        self.screen = screen
        self.gpu = gpu
        self.field = field
        self.buffers = buffers
        window = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(f, display: false)

        let bounds = CGRect(origin: .zero, size: f.size)
        let root = CALayer()
        view.frame = bounds
        view.layer = root
        view.wantsLayer = true
        window.contentView = view

        pileLayer.frame = bounds
        pileLayer.fillColor = CGColor(gray: 1, alpha: 0.95)
        pileLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        pileLayer.shadowOpacity = 0.35
        pileLayer.shadowRadius = 2
        pileLayer.shadowOffset = CGSize(width: 0, height: -1)
        root.addSublayer(pileLayer)

        let scale = screen.backingScaleFactor
        metalLayer.device = gpu.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2   // default 3 makes nextDrawable block the main thread and costs extra CPU
        metalLayer.isOpaque = false
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        root.addSublayer(metalLayer)

        setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
        field.setIntensity(Intensity.saved, immediate: true)
    }

    /// True when the Dock / menu bar geometry moved since creation.
    var geometryChanged: Bool {
        screen.visibleFrame.minY - screen.frame.minY != groundY || screen.visibleFrame.maxY - screen.frame.minY != visibleTop
    }

    func update(windows: [WindowInfo]) { field.update(windows: windows) }
    func clear() { field.clear() }
    func setLowPower(_ on: Bool) { field.setLowPower(on) }
    func setIntensity(_ v: Intensity) { field.setIntensity(v) }

    func start() {
        window.orderFrontRegardless()
        if link == nil {
            let l = view.displayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
        }
        lastTimestamp = 0
        link?.isPaused = false
    }

    func pause() {
        link?.isPaused = true
        window.orderOut(nil)
    }

    func teardown() {
        link?.invalidate()
        link = nil
        window.orderOut(nil)
        window.contentView = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(now - lastTimestamp, 1.0 / 30)
        lastTimestamp = now
        field.step(dt: Float(dt))
        if field.pilesDirty, now - lastPathTime >= 1.0 / 15 {
            lastPathTime = now
            field.pilesDirty = false
            let path = field.pilePath()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pileLayer.path = path
            pileLayer.shadowPath = path
            CATransaction.commit()
        }
        render()
    }

    private func render() {
        guard inFlight.wait(timeout: .now()) == .success else { return }   // never block the main thread
        guard let drawable = metalLayer.nextDrawable(), let cmd = gpu.queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let buffer = buffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % buffers.count
        let count = field.writeInstances(to: buffer.contents().assumingMemoryBound(to: Instance.self))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            var viewSize = field.size
            enc.setRenderPipelineState(gpu.pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            if count > 0 { enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count) }
            enc.endEncoding()
        }
        cmd.present(drawable)
        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.commit()
    }
}
