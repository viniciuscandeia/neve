// AGENT HEADER - Tests/NeveRenderTests/OffscreenRender.swift  (renders one NeveRender frame into an offscreen texture and returns its bytes)
// Role: `offscreenRender(field, variant)` = the headless path the lab will use: Gpu -> FrameData(inputs from a RenderVariant) -> prepare -> encode into a new bgra8 shared texture -> premultiplied BGRA bytes, row-major.
// Used by: NeveRenderTests (permanent) and LegacyEquivalenceTests (bridge).

import Foundation
import Metal
import NeveCore
import NeveRender

func offscreenRender(_ gpu: Gpu, _ field: SnowField, _ v: RenderVariant) -> [UInt8]? {
    guard let fd = FrameData(gpu: gpu, field: field) else { return nil }
    fd.inputs.contrast = v.contrast; fd.inputs.reduceMotion = v.reduceMotion; fd.inputs.effects = !v.economy; fd.inputs.time = v.time
    fd.inputs.dragID = v.shiftID; fd.inputs.dragShift = v.shift
    for (k, r) in v.occRects.compact.enumerated() { fd.inputs.occ[k] = r }
    for (k, r) in v.occRects.behind.enumerated() { fd.inputs.occ[8 + k] = r }
    for (k, r) in v.occRects.hard.enumerated() { fd.inputs.occ[16 + k] = r }
    fd.inputs.occCount = (v.occRects.compact.count, v.occRects.behind.count, v.occRects.hard.count)
    fd.inputs.occStrength = v.occStrength; fd.inputs.coverActive = v.coverActive; fd.inputs.viewRect = v.shrunk; fd.inputs.liveLocal = v.liveLocal
    fd.inputs.screenSize = CGSize(width: 1000, height: 800)
    fd.forcePiles()
    fd.prepare(field)
    let g = v.shrunk ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int((g.width * v.scale).rounded()), height: Int((g.height * v.scale).rounded()), mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]
    td.storageMode = .shared
    guard let tex = gpu.device.makeTexture(descriptor: td), let cmd = gpu.queue.makeCommandBuffer() else { return nil }
    fd.encode(into: tex, commandBuffer: cmd, field: field, scale: v.scale)
    cmd.commit()
    cmd.waitUntilCompleted()
    guard cmd.status == .completed else { return nil }
    var bytes = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
    tex.getBytes(&bytes, bytesPerRow: tex.width * 4, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
    return bytes
}
