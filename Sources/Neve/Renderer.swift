import Metal

/// Shared Metal objects, built once: one library (runtime-compiled from the shader strings), the flake and the prim pipelines.
struct Gpu {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let flakes: MTLRenderPipelineState
    let prims: MTLRenderPipelineState
    let piles: MTLRenderPipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: flakeShaderSource + primShaderSource + pileShaderSource, options: nil),
              let flakes = Gpu.pipeline(device, library, "flakeVertex", "flakeFragment"),
              let prims = Gpu.pipeline(device, library, "primVertex", "primFragment"),
              let piles = Gpu.pipeline(device, library, "pileVertex", "pileFragment") else { return nil }
        self.device = device
        self.queue = queue
        self.flakes = flakes
        self.prims = prims
        self.piles = piles
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
struct VOut { float4 position [[position]]; float2 uv; float alpha; float size; float seed; };
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
    return o;
}
// White core, cool blue-gray rim: reads on white pages, still looks like snow on dark ones.
// `contrast` (Increase Contrast) = 1 darkens the rim and keeps it opaque.
fragment float4 flakeFragment(VOut in [[stage_in]], constant float &contrast [[buffer(0)]]) {
    float d = length(in.uv);
    // Flakes >= ~5pt: faint 6-fold crystal hint + a little per-flake irregularity. Small ones stay round dots.
    float big = smoothstep(3.5, 5.5, in.size);
    if (big > 0.0) {
        float th = atan2(in.uv.y, in.uv.x) + in.seed * 6.2832;
        float wob = cos(6.0 * th) * 0.13 + cos(3.0 * th + in.seed * 17.0) * 0.07 * fract(in.seed * 7.0);
        d *= 1.0 - big * (wob + 0.04);
    }
    float core = 1.0 - smoothstep(0.1, 0.45, d);
    float3 rim = mix(float3(0.56, 0.65, 0.80), float3(0.40, 0.50, 0.70), contrast);
    float a = (1.0 - smoothstep(0.55, 1.0, d)) * in.alpha;
    return float4(mix(rim, float3(1.0), core) * a, a);
}
"""

