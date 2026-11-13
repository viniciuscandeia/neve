// AGENT HEADER - Tests/NeveRenderTests/Legacy/LegacyRender.swift  (TEMPORARY BRIDGE: the pre-extraction render path, transcribed from Sources/Neve/Overlay.swift + Renderer.swift at main 7388854)
// Role: lets a test draw ONE deterministic frame through the OLD code path into an offscreen texture: `LegacyGpu` (= old `Gpu`, minus AppearanceWatcher), `legacyWritePrims` (= Overlay.writePrims) and `legacyRender` (= the data-writing + encoding part of Overlay.render:
//   instances, prims, soft-cut fade, piles, three passes). Only deviations from the original: state that lived in Overlay properties is a parameter (`LegacyInputs`), the shader clock `tone.z` is the explicit `time` (the original read systemUptime), buffers are
//   allocated per call, no perf meter / semaphore / present.
// REMOVAL (after phase 1 landed and the NeveRender equivalence test passed on the user's screen): delete the directory Tests/NeveRenderTests/Legacy and Tests/NeveRenderTests/LegacyEquivalenceTests.swift. Nothing in Sources/ refers to it.

import Foundation
import Metal
import NeveCore

struct LegacyGpu {
    let device: MTLDevice, queue: MTLCommandQueue
    let flakes: MTLRenderPipelineState, prims: MTLRenderPipelineState, piles: MTLRenderPipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: legacyFlakeShaderSource + legacyPrimShaderSource + legacyPileShaderSource, options: nil) }
        catch { return nil }
        guard let flakes = LegacyGpu.pipeline(device, library, "flakeVertex", "flakeFragment"),
              let prims = LegacyGpu.pipeline(device, library, "primVertex", "primFragment"),
              let piles = LegacyGpu.pipeline(device, library, "pileVertex", "pileFragment") else { return nil }
        self.device = device; self.queue = queue; self.flakes = flakes; self.prims = prims; self.piles = piles
    }

    private static func pipeline(_ device: MTLDevice, _ lib: MTLLibrary, _ v: String, _ f: String) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: v)
        d.fragmentFunction = lib.makeFunction(name: f)
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: d)
    }
}

/// What Overlay kept in its own properties and render() read.
struct LegacyInputs {
    var contrast: Float = 0
    var reduceMotion = false
    var economyOrLowPower = false
    var time: Float = 0
    var shiftID: Int?
    var shift = SIMD2<Float>.zero
    var frameDt: Float = 1.0 / 60
    var occ = [SIMD4<Float>](repeating: .zero, count: OccluderLayout.bufferLength)
    var occCount = (compact: 0, behind: 0, hard: 0)
    var occStrength: Float = 0
    var coverActive = false
    var shrunk: CGRect?
    var liveLocal: CGRect?
    var frameSize = CGSize(width: 1000, height: 800)
    var scale: CGFloat = 1
    var still = false
}

func legacyWritePrims(_ field: SnowField, _ i: LegacyInputs, _ w: inout PrimWriter) {
    let hc = i.contrast > 0
    func d(_ sid: Int?) -> SIMD2<Float> { sid != nil && sid == i.shiftID ? i.shift : .zero }
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
        if i.reduceMotion { look.pose.flutter = Flutter(); look.newest = 1 }
        Rig.snowman(look, contrast: hc, into: &w)
    }
    field.writeTreePrims(&w, contrast: hc, shift: d)
    field.writeCarrotPrims(&w, shift: d)
    field.writeGiftPrims(&w, contrast: hc, shift: d)
    field.writeShotPrims(&w, trails: !i.reduceMotion, shift: d)
    field.writeIciclePrims(&w, contrast: hc, shift: d)
    field.writeLightPrims(&w, shift: d)
}

/// Draws the frame into a new bgra8 texture of the drawable size (shrunk rect or whole screen) and returns its bytes (premultiplied BGRA, row-major).
func legacyRender(_ gpu: LegacyGpu, _ field: SnowField, _ inp: LegacyInputs) -> [UInt8]? {
    var occ = inp.occ
    var live = SIMD4<Float>.zero
    let g = inp.shrunk ?? CGRect(origin: .zero, size: inp.frameSize)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int((g.width * inp.scale).rounded()), height: Int((g.height * inp.scale).rounded()), mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]
    td.storageMode = .shared
    guard let tex = gpu.device.makeTexture(descriptor: td), let cmd = gpu.queue.makeCommandBuffer() else { return nil }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].texture = tex

    let primCapacity = 1000
    guard let buffer = gpu.device.makeBuffer(length: field.capacity * MemoryLayout<Instance>.stride, options: .storageModeShared),
          let pbuf = gpu.device.makeBuffer(length: primCapacity * MemoryLayout<Prim>.stride, options: .storageModeShared) else { return nil }
    let pileCapacity = max(8192, field.pileSegDemand)
    guard let pileBuf = gpu.device.makeBuffer(length: pileCapacity * MemoryLayout<PileSeg>.stride, options: .storageModeShared) else { return nil }
    memset(buffer.contents(), 0, buffer.length); memset(pbuf.contents(), 0, pbuf.length); memset(pileBuf.contents(), 0, pileBuf.length)

    let count = inp.still ? 0 : field.writeInstances(to: buffer.contents().assumingMemoryBound(to: Instance.self))
    var w = PrimWriter(pbuf.contents().assumingMemoryBound(to: Prim.self), capacity: primCapacity)
    legacyWritePrims(field, inp, &w)
    var outFade: Float = 0
    if inp.coverActive, inp.shrunk == nil || inp.occStrength < 1, let r = inp.liveLocal, r.width * r.height <= 0.5 * inp.frameSize.width * inp.frameSize.height {
        outFade = inp.occStrength; live = SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY))
        w.fadeOutside(live, by: 1 - outFade)
    }
    var pileDropped = 0
    let pileCount = field.writePiles(to: pileBuf.contents().assumingMemoryBound(to: PileSeg.self), capacity: pileCapacity, dt: inp.frameDt, force: true, dropped: &pileDropped) ?? 0
    var pileOcc: [SIMD4<Float>] = []
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    var viewSize = field.size
    let fx: Float = inp.economyOrLowPower ? 0 : 1
    enc.setViewport(MTLViewport(originX: Double(-g.minX * inp.scale), originY: Double(-(CGFloat(field.size.y) - g.maxY) * inp.scale),
                                width: Double(CGFloat(field.size.x) * inp.scale), height: Double(CGFloat(field.size.y) * inp.scale), znear: 0, zfar: 1))
    if pileCount > 0 {
        var dragOffset = inp.shiftID == nil ? SIMD2<Float>.zero : inp.shift
        enc.setRenderPipelineState(gpu.piles)
        enc.setVertexBuffer(pileBuf, offset: 0, index: 0)
        enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        enc.setVertexBytes(&dragOffset, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
        enc.setFragmentBuffer(pileBuf, offset: 0, index: 0)
        var tone = SIMD4<Float>(inp.contrast, Palette.dark, inp.time, fx)
        enc.setFragmentBytes(&tone, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        for o in field.occluders {
            var rc = o.rect
            if o.id == inp.shiftID { rc += SIMD4<Float>(inp.shift.x, inp.shift.y, inp.shift.x, inp.shift.y) }
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
    if w.n > 0 {
        enc.setRenderPipelineState(gpu.prims)
        enc.setVertexBuffer(pbuf, offset: 0, index: 0)
        enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        enc.setFragmentBuffer(pbuf, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: w.n)
    }
    enc.setRenderPipelineState(gpu.flakes)
    enc.setVertexBuffer(buffer, offset: 0, index: 0)
    enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
    var streakDt = inp.frameDt
    enc.setVertexBytes(&streakDt, length: MemoryLayout<Float>.size, index: 2)
    var cf = SIMD2<Float>(inp.contrast, fx)
    enc.setFragmentBytes(&cf, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
    occ[3 * OccluderLayout.slots] = SIMD4(inp.occStrength, inp.occStrength > 0 ? Float(inp.occCount.compact) : 0, Float(inp.occCount.hard), Palette.dark)
    occ[3 * OccluderLayout.slots + 1] = SIMD4(Float(inp.occCount.behind), 0, 0, 0)
    occ.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
    if count > 0 { enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count) }
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    guard cmd.status == .completed else { return nil }
    var bytes = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
    tex.getBytes(&bytes, bytesPerRow: tex.width * 4, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
    return bytes
}
