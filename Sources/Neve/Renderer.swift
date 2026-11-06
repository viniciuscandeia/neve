import Metal

/// Shared Metal objects, built once: one library (runtime-compiled from the shader strings), the flake and the prim pipelines.
struct Gpu {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let flakes: MTLRenderPipelineState
    let prims: MTLRenderPipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: flakeShaderSource + primShaderSource, options: nil),
              let flakes = Gpu.pipeline(device, library, "flakeVertex", "flakeFragment"),
              let prims = Gpu.pipeline(device, library, "primVertex", "primFragment") else { return nil }
        self.device = device
        self.queue = queue
        self.flakes = flakes
        self.prims = prims
    }

    /// Premultiplied-alpha blending into a bgra8 drawable.
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

let flakeShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct Instance { float2 pos; float size; float alpha; float seed; };
struct VOut { float4 position [[position]]; float2 uv; float alpha; float size; float seed; float2 wpos; };
struct Occ { float4 r[8]; float4 s; };   // r[0..3] hide every flake, r[4..7] only background ones (seed >= 2); s.x = strength of the first four
vertex VOut flakeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant Instance *inst [[buffer(0)]], constant float2 &viewSize [[buffer(1)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    Instance i = inst[iid];
    float2 p = i.pos + corner * i.size * 0.5;
    VOut o;
    o.position = float4(p / viewSize * 2.0 - 1.0, 0.0, 1.0);
    o.uv = corner;
    o.alpha = i.alpha;
    o.size = i.size;
    o.seed = i.seed;
    o.wpos = p;
    return o;
}
// White core, cool blue-gray rim: reads on white pages, still looks like snow on dark ones.
// `contrast` (Increase Contrast) = 1 darkens the rim and keeps it opaque.
// 1 inside the rect (minx, miny, maxx, maxy; screen coordinates) with a soft ~8pt edge; empty rects hide nothing.
static float occMask(float2 p, float4 r) {
    if (r.z <= r.x) return 0.0;
    float d = min(min(p.x - r.x, r.z - p.x), min(p.y - r.y, r.w - p.y));
    return smoothstep(-4.0, 4.0, d);
}
fragment float4 flakeFragment(VOut in [[stage_in]], constant float &contrast [[buffer(0)]], constant Occ &occ [[buffer(1)]]) {
    float seed = fract(in.seed);
    float hide = 0.0;
    for (int k = 0; k < 4; k++) hide = max(hide, max(occMask(in.wpos, occ.r[k]) * occ.s.x, in.seed >= 2.0 ? occMask(in.wpos, occ.r[4 + k]) : 0.0));
    if (hide >= 1.0) discard_fragment();
    float d = length(in.uv);
    // Flakes >= ~5pt: faint 6-fold crystal hint + a little per-flake irregularity. Small ones stay round dots.
    float big = smoothstep(3.5, 5.5, in.size);
    if (big > 0.0) {
        float th = atan2(in.uv.y, in.uv.x) + seed * 6.2832;
        float wob = cos(6.0 * th) * 0.13 + cos(3.0 * th + seed * 17.0) * 0.07 * fract(seed * 7.0);
        d *= 1.0 - big * (wob + 0.04);
    }
    float core = 1.0 - smoothstep(0.1, 0.45, d);
    float3 rim = mix(float3(0.56, 0.65, 0.80), float3(0.40, 0.50, 0.70), contrast);
    float a = (1.0 - smoothstep(0.55, 1.0, d)) * in.alpha * (1.0 - hide);
    return float4(mix(rim, float3(1.0), core) * a, a);
}
"""

