// AGENT HEADER - Sources/Neve/PileShader.swift  (MSL source for snow piles; appended to the flake shader library)
// Role: `pileShaderSource`, one instanced quad per `PileSeg` (NeveCore/Render.swift `PileSeg`: x0/x1 in screen-local pt, top/base heights at both ends, slope, dragged flags bit0 = rides the drag offset,
//   bit1 = bank-flagged (corner fill / bridge, no skirt), n0/n1 = continuous surface normals, inset = pt hidden under a window edge). Vertex stage pads the quad (1 pt overlap in x, 8 pt below base, 4 pt above top).
// Fragment draws body, lifted band, ~6 pt crest gradient, cool AO tint for deep snow, soft downward shadow skirt + faint halo, one-light shading (Palette.light), +-1 % dither. `tone` = (increase contrast, Palette.dark blend).
// Invariants: `struct PileSeg` here MUST match the Swift one byte for byte (11 x 4-byte fields); colours come from NeveCore Palette via \(Palette.msl(...)). Used with Gpu.piles in Renderer.swift, drawn by Overlay.render BEFORE prims and flakes.
// Gotcha: edge cases (cliffs steeper than 2.5:1, overlap strips) are handled explicitly in the fragment; changing the quad padding changes overdraw cost on every pile bin (hot at 60 fps on full-screen).

import NeveCore
/// Snow piles: one instanced quad per `PileSeg` (see NeveCore/Render.swift). Appended to the flake shader source.
/// The fragment shader draws: near-white body, a lighter band lifted 1.5pt, a ~6pt smooth crest gradient, a cool tint only in the lower part of deep snow,
/// a neutral soft shadow straight down under the base and a faint neutral (darkening only) halo above the top. `tone` = (increase contrast, dark blend 0...1).
let pileShaderSource = """
struct PileSeg { float x0; float x1; float top0; float top1; float base0; float base1; float slope; uint dragged; float n0; float n1; float inset; };
struct SVOut { float4 position [[position]]; float2 p; uint id [[flat]]; };
vertex SVOut pileVertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant PileSeg *segs [[buffer(0)]],
                        constant float2 &viewSize [[buffer(1)]], constant float2 &dragOffset [[buffer(2)]]) {
    PileSeg s = segs[iid];
    float2 lo = float2(s.x0 - 1.0, min(s.base0, s.base1) - 8.0), hi = float2(s.x1 + 1.0, max(s.top0, s.top1) + 4.0);
    float2 corner = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
    float2 p = mix(lo, hi, corner);
    SVOut o;
    o.position = float4((p + ((s.dragged & 1) != 0 ? dragOffset : float2(0.0))) / viewSize * 2.0 - 1.0, 0.0, 1.0);
    o.p = p;
    o.id = iid;
    return o;
}
fragment float4 pileFragment(SVOut in [[stage_in]], constant PileSeg *segs [[buffer(0)]], constant float2 &tone [[buffer(1)]]) {
    float contrast = tone.x, dark = tone.y;
    PileSeg s = segs[in.id];
    float dx = max(s.x1 - s.x0, 1e-3);
    float t = (in.p.x - s.x0) / dx;   // not clamped: the quad overlaps its neighbours by 1pt and extends its own edge lines there (no x stair-steps on steep slopes)
    float bs = (s.base1 - s.base0) / dx;
    float ov = in.p.x - clamp(in.p.x, s.x0, s.x1);   // the 1pt overlap strip extends the edge lines, but a cliff (steeper than 2.5:1, e.g. bank down to the gap under the Dock) extends flat: it must not spike over its neighbour
    float sl = (ov != 0.0 && abs(s.slope) > 2.5) ? 0.0 : s.slope;   // in the strip a cliff's edge is flat, and so is its distance metric (else it reaches ~10pt above the flat edge: a hairline)
    float bsl = (ov != 0.0 && abs(bs) > 2.5) ? 0.0 : bs;
    float top = mix(s.top0, s.top1, clamp(t, 0.0, 1.0)) + sl * ov;
    float base = mix(s.base0, s.base1, clamp(t, 0.0, 1.0)) + bsl * ov;
    float dTop = (in.p.y - top) * rsqrt(1.0 + sl * sl);   // > 0 above the top edge (slope-corrected)
    float dBase = (base - in.p.y) * rsqrt(1.0 + bsl * bsl);           // > 0 below the base
    float w = max(fwidth(dTop) * 0.5, 0.3);
    float cover = (1.0 - smoothstep(-w, w, dTop)) * smoothstep(-w, w, -dBase);
    // Shadow skirt under the base + faint halo above the top; both fade out where the pile is flat (ends, thin snow).
    float3 shCol = mix(\(Palette.msl(Palette.shadow)), \(Palette.msl(Palette.shadowHC)), contrast);
    float snow = top - base - s.inset;   // real snow depth: windows draw `inset` pt under their edge to hide the seam, which must not count as snow
    float hf = smoothstep(1.5, 3.5, snow);   // no skirt / halo below ~1.5pt of snow
    float steepBase = (1.0 - smoothstep(1.2, 3.0, abs(bs))) * ((s.dragged & 2) != 0 ? 0.0 : 1.0);   // bank-flagged pieces (corner fill, bridge) are part of the bank body: no skirt on it   // the skirt follows a base edge, never a near-vertical one (it would be a dark stroke across the bank)
    float shA = \(Palette.msl(Palette.shadowAlpha));
    float skirt = shA * mix(1.0, 1.8, contrast) * smoothstep(-1.5, -0.5, dBase) * (1.0 - smoothstep(-0.5, 6.0, dBase)) * steepBase;   // neutral black, ~6pt soft falloff straight down
    float steep = 1.0 - smoothstep(1.2, 3.0, abs(sl));   // a near-vertical step (bank down to the Dock gap) is a face, not a surface: no crest / halo line on it
    float halo = 0.3 * shA * (1.0 - smoothstep(0.0, 2.5, dTop)) * steep;
    float sa = max(skirt, halo) * hf * step(s.x0, in.p.x) * step(in.p.x, s.x1);   // overlap strips draw coverage only (no doubled shadow)
    // Light from the upper left on a continuous normal (n0 -> n1, no facets): only close to the surface, subtle; Increase Contrast weakens it.
    float nl = mix(s.n0, s.n1, clamp(t, 0.0, 1.0));
    float ndl = dot(float2(-nl, 1.0), \(Palette.mslLight)) * rsqrt(1.0 + nl * nl) - \(Palette.light.y);   // 0 on flat ground, > 0 facing the one light (Palette.light)
    float lk = clamp(ndl * 3.0, -1.0, 1.0) * (1.0 - 0.6 * contrast) * steep * (1.0 - smoothstep(0.0, 6.0, -dTop));
    float3 rgb = mix(\(Palette.msl(Palette.snow)), \(Palette.msl(Palette.lift)), smoothstep(1.0, 2.0, -dBase));
    // Deep snow (banks): a cool ambient-occlusion tint in the lower ~40% of the snow (at most 40pt, at least 4pt), full from ~10pt of snow; thin piles are untouched.
    float depth = in.p.y - ((s.dragged & 2) != 0 ? 0.0 : base), tall = smoothstep(4.0, 10.0, snow);
    float tintLen = clamp(0.4 * max(top - ((s.dragged & 2) != 0 ? 0.0 : base), 1.0), 4.0, 40.0);
    rgb = mix(rgb, rgb * \(Palette.msl(Palette.deep)), 0.6 * tall * (1.0 - smoothstep(0.0, tintLen, depth)));
    rgb = lk < 0.0 ? mix(rgb, rgb * \(Palette.msl(Palette.shade)), -lk * 0.7) : rgb + 0.04 * lk;
    rgb = mix(rgb, \(Palette.msl(Palette.flake)), \(Palette.crestAlpha) * (1.0 - smoothstep(0.0, 6.0, -dTop)) * steep);   // smooth ~6pt gradient, no hard band
    rgb *= 1.0 + (fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715)))) - 0.5) * 0.02;   // +-1% dither against banding
    float a = 0.97 * cover * smoothstep(0.3, 1.8, snow);   // thin-layer fade: a speck is faint but visible, never a hard line (specks are 1-2 bins wide, so no full-width film)
    return float4(rgb * a + shCol * sa * (1.0 - a), a + sa * (1.0 - a));
}
"""
