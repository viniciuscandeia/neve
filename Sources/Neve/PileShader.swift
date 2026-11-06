import NeveCore
/// Snow piles: one instanced quad per `PileSeg` (see NeveCore/Render.swift). Appended to the flake shader source.
/// The fragment shader draws what the CA layers used to: bluish body, a lighter band lifted 1.5pt, a white crest ~3pt deep,
/// a soft shadow skirt under the base and a faint dark halo above the top (so snow reads on white pages).
let pileShaderSource = """
struct PileSeg { float x0; float x1; float top0; float top1; float base0; float base1; float slope; uint dragged; };
struct SVOut { float4 position [[position]]; float2 p; uint id [[flat]]; };
vertex SVOut pileVertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant PileSeg *segs [[buffer(0)]],
                        constant float2 &viewSize [[buffer(1)]], constant float2 &dragOffset [[buffer(2)]]) {
    PileSeg s = segs[iid];
    float2 lo = float2(s.x0 - 1.0, min(s.base0, s.base1) - 6.0), hi = float2(s.x1 + 1.0, max(s.top0, s.top1) + 4.0);
    float2 corner = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
    float2 p = mix(lo, hi, corner);
    SVOut o;
    o.position = float4((p + (s.dragged != 0 ? dragOffset : float2(0.0))) / viewSize * 2.0 - 1.0, 0.0, 1.0);
    o.p = p;
    o.id = iid;
    return o;
}
fragment float4 pileFragment(SVOut in [[stage_in]], constant PileSeg *segs [[buffer(0)]], constant float &contrast [[buffer(1)]]) {
    PileSeg s = segs[in.id];
    float dx = max(s.x1 - s.x0, 1e-3);
    float t = (in.p.x - s.x0) / dx;   // not clamped: the quad overlaps its neighbours by 1pt and extends its own edge lines there (no x stair-steps on steep slopes)
    float bs = (s.base1 - s.base0) / dx;
    float ov = in.p.x - clamp(in.p.x, s.x0, s.x1);   // the 1pt overlap strip extends the edge lines, but never steeper than 3:1 (a bank-to-gap cliff must not spike over its neighbour)
    float top = mix(s.top0, s.top1, clamp(t, 0.0, 1.0)) + clamp(s.slope, -3.0, 3.0) * ov;
    float base = mix(s.base0, s.base1, clamp(t, 0.0, 1.0)) + clamp(bs, -3.0, 3.0) * ov;
    float dTop = (in.p.y - top) * rsqrt(1.0 + s.slope * s.slope);   // > 0 above the top edge (slope-corrected)
    float dBase = (base - in.p.y) * rsqrt(1.0 + bs * bs);           // > 0 below the base
    float w = max(fwidth(dTop) * 0.5, 0.3);
    float cover = (1.0 - smoothstep(-w, w, dTop)) * smoothstep(-w, w, -dBase);
    // Shadow skirt under the base + faint halo above the top; both fade out where the pile is flat (ends, thin snow).
    float3 shCol = mix(\(Palette.msl(Palette.shadow)), \(Palette.msl(Palette.shadowHC)), contrast);
    float hf = smoothstep(1.5, 3.5, top - base);   // no skirt / halo below ~1.5pt of snow (windows draw 1pt under the edge)
    float skirt = mix(0.45, 0.8, contrast) * smoothstep(-1.5, -0.5, dBase) * (1.0 - smoothstep(-0.5, 3.0, dBase));
    float steep = 1.0 - smoothstep(1.2, 3.0, abs(s.slope));   // a near-vertical step (bank down to the Dock gap) is a face, not a surface: no crest / halo line on it
    float halo = 0.08 * (1.0 - smoothstep(0.0, 2.5, dTop)) * steep;
    float sa = max(skirt, halo) * hf * step(s.x0, in.p.x) * step(in.p.x, s.x1);   // overlap strips draw coverage only (no doubled shadow)
    float3 rgb = mix(\(Palette.msl(Palette.snow)), \(Palette.msl(Palette.lift)), smoothstep(1.0, 2.0, -dBase));
    // Deep snow (banks): a cool ambient-occlusion tint toward the base, fading out over the lower 40pt (a fixed length, and full from ~10pt of snow:
    // the gap snow under a Dock bar then shades like the bank beside it, no break at the bar end); thin piles are untouched.
    float depth = in.p.y - base, tall = smoothstep(4.0, 10.0, top - base);
    rgb = mix(rgb, rgb * float3(0.90, 0.94, 1.0), 0.6 * tall * (1.0 - smoothstep(0.0, 40.0, depth)));
    rgb = mix(rgb, float3(1.0), \(Palette.crestAlpha) * (1.0 - smoothstep(2.0, 3.6, -dTop)) * steep);
    float a = 0.97 * cover * smoothstep(1.05, 3.0, top - base);   // thin-layer fade: a light dusting is faint, never a hard line
    return float4(rgb * a + shCol * sa * (1.0 - a), a + sa * (1.0 - a));
}
"""
