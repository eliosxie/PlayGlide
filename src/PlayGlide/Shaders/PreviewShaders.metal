#include <metal_stdlib>
using namespace metal;
struct SourceUniforms {
    float4 fitRect;
    float4 fitMax;
    float4 uvRect;
    float4 clampRect;
    float4 flags;
};
struct PreviewUniforms {
    SourceUniforms primary;
    SourceUniforms original;
    float4 split;
    float4 post;
};
struct HybridPreviewUniforms {
    SourceUniforms primary;
    float4 split;
    float4 offsets;
    float4 weights;
    float4 post;
};
constant bool previewHasMotion [[function_constant(0)]];
constant bool previewHasForwardMotion [[function_constant(1)]];
constant bool previewSampleMid [[function_constant(2)]];
struct PreviewVertex {
    float4 position [[position]];
};
constexpr sampler previewSampler(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler previewNearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
vertex PreviewVertex previewVertex(uint vid [[vertex_id]]) {
    constexpr float2 positions[3] = {
        float2(-1.0f, -1.0f),
        float2(3.0f, -1.0f),
        float2(-1.0f, 3.0f)
    };
    PreviewVertex out;
    out.position = float4(positions[vid], 0.0f, 1.0f);
    return out;
}
inline half3 rec709ToSRGB(half3 value) {
    float3 v = clamp(float3(value), 0.0f, 1.0f);
    // Match macOS CGColorSpace.itur_709 (BT.1886 gamma 2.4) -> sRGB to <= 1/255 across 0..255.
    float3 low = 12.92f * pow(v, 2.4f);
    float3 high = fma(1.055f, v, -0.055f);
    return half3(saturate(select(high, low, v <= 0.0906066f)));
}
inline half3 encodeSDRToBT2020PQ(half3 rgb, bool fromRec709) {
    float3 v = clamp(float3(rgb), 0.0f, 1.0f);
    float3 lin709;
    if (fromRec709) {
        lin709 = pow(v, float3(2.4f));
    } else {
        float3 low = v * (1.0f / 12.92f);
        float3 high = pow((v + 0.055f) * (1.0f / 1.055f), float3(2.4f));
        lin709 = select(high, low, v <= 0.04045f);
    }
    // ITU-R BT.2087 Rec.709 -> BT.2020 linear primaries scaled to 100-nit reference white / 10000 nits.
    float3 lin2020 = float3(
        dot(lin709, float3(0.6274039f, 0.3292830f, 0.0433131f)),
        dot(lin709, float3(0.0690973f, 0.9195404f, 0.0113623f)),
        dot(lin709, float3(0.0163914f, 0.0880133f, 0.8955953f)));
    float3 y = max(lin2020, 0.0f) * 0.01f;
    constexpr float m1 = 0.1593017578125f;
    constexpr float m2 = 78.84375f;
    constexpr float c1 = 0.8359375f;
    constexpr float c2 = 18.8515625f;
    constexpr float c3 = 18.6875f;
    float3 ym1 = pow(y, float3(m1));
    float3 pq = pow((c1 + c2 * ym1) / (1.0f + c3 * ym1), float3(m2));
    return half3(saturate(select(pq, float3(0.0f), y <= 0.0f)));
}
inline half3 finalizePreviewColor(half3 rgb, float colorMode) {
    if (colorMode > 2.5f) {
        return encodeSDRToBT2020PQ(rgb, true);
    }
    if (colorMode > 1.5f) {
        return encodeSDRToBT2020PQ(rgb, false);
    }
    if (colorMode > 0.5f) {
        return rec709ToSRGB(rgb);
    }
    return rgb;
}
inline half3 decodeYCbCr(half y, half2 cbcr, uint hdrMode) {
    if (hdrMode == 3u) {
        // ITU-R BT.2100 / BT.2020 reference PQ decode: exact non-constant-luminance matrix,
        // no chroma boost, and no shadow gamma crush (PLAYGLIDE_HDR10_REFERENCE_PQ=1 / Reference style).
        half yClamped = saturate(y);
        return saturate(half3(
            fma(half(1.4746), cbcr.y, yClamped),
            fma(half(-0.5713531), cbcr.y, fma(half(-0.1645531), cbcr.x, yClamped)),
            fma(half(1.8814), cbcr.x, yClamped)));
    }
    if (hdrMode >= 1u) {
        half yPos = max(half(0.0), y);
        half yAnchored;
        half2 cBoost;
        if (hdrMode == 2u) {
            // C1-smooth near-black toe: Y=16 maps to strict 0.0 OLED black while keeping Y=17..33 shadow steps.
            half t = saturate(yPos * half(1.0 / 0.08));
            yAnchored = yPos * mix(half(0.25), half(1.0), t);
            cBoost = cbcr * mix(half(0.75), half(1.12), t);
        } else {
            // Legacy hard black-floor clamp (PLAYGLIDE_HDR10_SOFT_TOE=0).
            yAnchored = max(half(0.0), (yPos - half(0.042)) * half(1.0 / 0.958));
            cBoost = cbcr * half(1.12);
        }
        half3 rgb = saturate(half3(
            fma(half(1.4746), cBoost.y, yAnchored),
            fma(half(-0.57135), cBoost.y, fma(half(-0.16455), cBoost.x, yAnchored)),
            fma(half(1.8814), cBoost.x, yAnchored)));
        // Subtle S-curve in PQ domain deepens shadow contrast while preserving 100..1000 nit highlights.
        return saturate(pow(rgb, half3(1.10)));
    }
    return saturate(half3(
        fma(half(1.5748), cbcr.y, y),
        fma(half(-0.468124), cbcr.y, fma(half(-0.187324), cbcr.x, y)),
        fma(half(1.8556), cbcr.x, y)));
}
inline half2 sampleBilateralChroma(
    texture2d<half, access::sample> lumaTex,
    texture2d<half, access::sample> chromaTex,
    float2 uv, float2 chromaOffset, half centerRawY
) {
    float2 cSize = float2(chromaTex.get_width(), chromaTex.get_height());
    float2 invCSize = 1.0f / cSize;
    float2 cPos = (uv + chromaOffset) * cSize - 0.5f;
    float2 cBase = floor(cPos);
    float2 f = saturate(cPos - cBase);
    float2 c00 = (cBase + 0.5f) * invCSize;
    float2 c10 = c00 + float2(invCSize.x, 0.0f);
    float2 c01 = c00 + float2(0.0f, invCSize.y);
    float2 c11 = c00 + invCSize;

    half sw00 = half((1.0f - f.x) * (1.0f - f.y));
    half sw10 = half(f.x * (1.0f - f.y));
    half sw01 = half((1.0f - f.x) * f.y);
    half sw11 = half(f.x * f.y);

    half y00 = lumaTex.sample(previewSampler, c00 - chromaOffset).r;
    half y10 = lumaTex.sample(previewSampler, c10 - chromaOffset).r;
    half y01 = lumaTex.sample(previewSampler, c01 - chromaOffset).r;
    half y11 = lumaTex.sample(previewSampler, c11 - chromaOffset).r;

    half d00 = centerRawY - y00;
    half d10 = centerRawY - y10;
    half d01 = centerRawY - y01;
    half d11 = centerRawY - y11;
    half w00 = sw00 / fma(d00 * d00, half(1200.0), half(1.0));
    half w10 = sw10 / fma(d10 * d10, half(1200.0), half(1.0));
    half w01 = sw01 / fma(d01 * d01, half(1200.0), half(1.0));
    half w11 = sw11 / fma(d11 * d11, half(1200.0), half(1.0));
    half wSum = w00 + w10 + w01 + w11;

    half2 uv00 = chromaTex.sample(previewNearestSampler, c00).rg;
    half2 uv10 = chromaTex.sample(previewNearestSampler, c10).rg;
    half2 uv01 = chromaTex.sample(previewNearestSampler, c01).rg;
    half2 uv11 = chromaTex.sample(previewNearestSampler, c11).rg;
    return (uv00 * w00 + uv10 * w10 + uv01 * w01 + uv11 * w11) / max(wSum, half(1e-4));
}
// Gradient-preserving 2-tap symmetric integer-offset luma debanding for 8-bit UVC HDR10 PQ inputs.
// Uses two L1-coherent nearest texel taps (zero bilinear edge bleed, zero trig, branchless ALU) so
// 1..2 LSB PQ quantization bands blend continuously into 10-bit output while fine text/edges (>3 LSB)
// strictly bypass.
inline half debandHDR10Luma(
    texture2d<half, access::sample> lumaTex,
    float2 uv, float2 px, float4 clampRect, half rawY
) {
    float h0 = fract(52.9829189f * fract(dot(px, float2(0.06711056f, 0.00583715f))));
    float h1 = fract(h0 * 1.6180339f + 0.37f);
    float2 texStep = 1.0f / float2(lumaTex.get_width(), lumaTex.get_height());
    float dx = floor(1.0f + 9.0f * h0);
    float sy = fract(h1 * 2.0f);
    float dy = floor(1.0f + 9.0f * sy) * ((h1 >= 0.5f) ? 1.0f : -1.0f);
    float2 dir = float2(dx, dy) * texStep;

    half y0 = lumaTex.sample(previewNearestSampler, clamp(uv + dir, clampRect.xy, clampRect.zw)).r;
    half y1 = lumaTex.sample(previewNearestSampler, clamp(uv - dir, clampRect.xy, clampRect.zw)).r;
    half maxDiffY = max(abs(y0 - rawY), abs(y1 - rawY));
    half wY = half(1.0) - smoothstep(half(1.8 / 255.0), half(3.2 / 255.0), maxDiffY);
    return mix(rawY, (y0 + y1) * half(0.5), wY);
}
inline half3 sampleSource(
    texture2d<half, access::sample> primaryTex,
    texture2d<half, access::sample> chromaTex,
    SourceUniforms src,
    float2 px,
    bool bilateralChroma = false,
    bool hdr10Deband = false
) {
    if (px.x < src.fitRect.x || px.x >= src.fitMax.x || px.y < src.fitRect.y || px.y >= src.fitMax.y) {
        return half3(0.0h);
    }
    float2 normalized = (px - src.fitRect.xy) * src.fitRect.zw;
    float2 uv = clamp(fma(normalized, src.uvRect.zw, src.uvRect.xy), src.clampRect.xy, src.clampRect.zw);
    half3 rgb;
    uint hdrMode = src.flags.x > 1.5f ? uint(src.flags.x - 0.5f) : 0u;
    if (src.fitMax.z > 0.0f) {
        float2 d = src.fitMax.zw;
        float2 uv0 = clamp(uv + float2(-d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
        float2 uv1 = clamp(uv + float2( d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
        float2 uv2 = clamp(uv + float2(-d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
        float2 uv3 = clamp(uv + float2( d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
        if (src.flags.x > 0.5f) {
            half luma = (primaryTex.sample(previewSampler, uv0).r
                       + primaryTex.sample(previewSampler, uv1).r
                       + primaryTex.sample(previewSampler, uv2).r
                       + primaryTex.sample(previewSampler, uv3).r) * half(0.25);
            half2 chroma = (chromaTex.sample(previewSampler, uv0 + src.flags.zw).rg
                          + chromaTex.sample(previewSampler, uv1 + src.flags.zw).rg
                          + chromaTex.sample(previewSampler, uv2 + src.flags.zw).rg
                          + chromaTex.sample(previewSampler, uv3 + src.flags.zw).rg) * half(0.25);
            half y = fma(luma, half(255.0 / 219.0), half(-16.0 / 219.0));
            half2 cbcr = fma(chroma, half(255.0 / 224.0), half(-128.0 / 224.0));
            rgb = decodeYCbCr(y, cbcr, hdrMode);
        } else {
            rgb = (primaryTex.sample(previewSampler, uv0).rgb
                 + primaryTex.sample(previewSampler, uv1).rgb
                 + primaryTex.sample(previewSampler, uv2).rgb
                 + primaryTex.sample(previewSampler, uv3).rgb) * half(0.25);
        }
    } else if (src.flags.x > 0.5f) {
        half rawY = primaryTex.sample(previewSampler, uv).r;
        // flags.zw moves from chroma texel centers to the surface's 4:2:0 sample positions.
        half2 chroma = bilateralChroma
            ? sampleBilateralChroma(primaryTex, chromaTex, uv, src.flags.zw, rawY)
            : chromaTex.sample(previewSampler, uv + src.flags.zw).rg;
        if (hdr10Deband && hdrMode >= 1u) {
            rawY = debandHDR10Luma(primaryTex, uv, px, src.clampRect, rawY);
        }
        half y = fma(rawY, half(255.0 / 219.0), half(-16.0 / 219.0));
        half2 cbcr = fma(chroma, half(255.0 / 224.0), half(-128.0 / 224.0));
        rgb = decodeYCbCr(y, cbcr, hdrMode);
    } else {
        rgb = primaryTex.sample(previewSampler, uv).rgb;
    }
    return finalizePreviewColor(rgb, src.flags.y);
}
inline half triangularDither(float2 px) {
    float n0 = fract(52.9829189f * fract(dot(px, float2(0.06711056f, 0.00583715f))));
    float n1 = fract(52.9829189f * fract(dot(px + float2(17.0f, 31.0f), float2(0.06711056f, 0.00583715f))));
    return half((n0 - n1) * 0.5f);
}
// 5-tap overshoot-clamped RCAS with high-contrast static-text guard (zero ringing, zero white halos).
inline half previewRCASLuma(half3 rgb, bool bt2020) {
    return bt2020 ? dot(rgb, half3(0.2627, 0.6780, 0.0593))
                  : dot(rgb, half3(0.2126, 0.7152, 0.0722));
}
inline half3 previewApplyRCAS(half3 c, half3 n, half3 s, half3 e, half3 w, half strength, bool bt2020) {
    half lC = previewRCASLuma(c, bt2020);
    half lN = previewRCASLuma(n, bt2020);
    half lS = previewRCASLuma(s, bt2020);
    half lE = previewRCASLuma(e, bt2020);
    half lW = previewRCASLuma(w, bt2020);
    half lMin = min(lC, min(min(lN, lS), min(lE, lW)));
    half lMax = max(lC, max(max(lN, lS), max(lE, lW)));
    half contrast = lMax - lMin;
    half textGuard = half(1.0) - smoothstep(half(0.55), half(0.75), contrast);
    half amp = clamp(min(lMin, half(1.0) - lMax) / max(lMax, half(1e-4)), half(0.0), half(1.0));
    half lobe = -half(0.1875) * strength * sqrt(amp) * textGuard;
    half3 out = (c + lobe * (n + s + e + w)) / (half(1.0) + half(4.0) * lobe);
    half3 rgbMin = min(c, min(min(n, s), min(e, w)));
    half3 rgbMax = max(c, max(max(n, s), max(e, w)));
    return clamp(out, rgbMin, rgbMax);
}
inline half previewApplyLumaRCAS(half c, half n, half s, half e, half w, half strength) {
    half lMin = min(c, min(min(n, s), min(e, w)));
    half lMax = max(c, max(max(n, s), max(e, w)));
    half contrast = lMax - lMin;
    half textGuard = half(1.0) - smoothstep(half(0.55), half(0.75), contrast);
    half amp = clamp(min(lMin, half(1.0) - lMax) / max(lMax, half(1e-4)), half(0.0), half(1.0));
    half lobe = -half(0.1875) * strength * sqrt(amp) * textGuard;
    return clamp((c + lobe * (n + s + e + w)) / (half(1.0) + half(4.0) * lobe), lMin, lMax);
}
fragment half4 previewFragment(
    PreviewVertex in [[stage_in]],
    texture2d<half, access::sample> primaryTex [[texture(0)]],
    texture2d<half, access::sample> primaryChroma [[texture(1)]],
    texture2d<half, access::sample> originalTex [[texture(2)]],
    texture2d<half, access::sample> originalChroma [[texture(3)]],
    constant PreviewUniforms &uniforms [[buffer(0)]]
) {
    float2 px = in.position.xy;
    uint postFlags = uint(uniforms.post.y + 0.5f);
    bool bilateralChroma = (postFlags & 1u) != 0u;
    bool hdr10Deband = (postFlags & 2u) != 0u;
    bool useOriginal = uniforms.split.x > 0.5f && px.x < uniforms.split.y;
    SourceUniforms activeSrc = useOriginal ? uniforms.original : uniforms.primary;
    half3 rgb = useOriginal
        ? sampleSource(originalTex, originalChroma, activeSrc, px, bilateralChroma, hdr10Deband)
        : sampleSource(primaryTex, primaryChroma, activeSrc, px, bilateralChroma, hdr10Deband);
    if (uniforms.post.x > 0.001f
        && px.x >= activeSrc.fitRect.x && px.x < activeSrc.fitMax.x
        && px.y >= activeSrc.fitRect.y && px.y < activeSrc.fitMax.y) {
        half3 n = useOriginal
            ? sampleSource(originalTex, originalChroma, activeSrc, px + float2(0.0f, -1.0f), bilateralChroma, hdr10Deband)
            : sampleSource(primaryTex, primaryChroma, activeSrc, px + float2(0.0f, -1.0f), bilateralChroma, hdr10Deband);
        half3 s = useOriginal
            ? sampleSource(originalTex, originalChroma, activeSrc, px + float2(0.0f, 1.0f), bilateralChroma, hdr10Deband)
            : sampleSource(primaryTex, primaryChroma, activeSrc, px + float2(0.0f, 1.0f), bilateralChroma, hdr10Deband);
        half3 e = useOriginal
            ? sampleSource(originalTex, originalChroma, activeSrc, px + float2(1.0f, 0.0f), bilateralChroma, hdr10Deband)
            : sampleSource(primaryTex, primaryChroma, activeSrc, px + float2(1.0f, 0.0f), bilateralChroma, hdr10Deband);
        half3 w = useOriginal
            ? sampleSource(originalTex, originalChroma, activeSrc, px + float2(-1.0f, 0.0f), bilateralChroma, hdr10Deband)
            : sampleSource(primaryTex, primaryChroma, activeSrc, px + float2(-1.0f, 0.0f), bilateralChroma, hdr10Deband);
        bool bt2020 = activeSrc.flags.x > 1.5f;
        rgb = previewApplyRCAS(rgb, n, s, e, w, half(uniforms.post.x), bt2020);
    }
    if (uniforms.split.z > 0.0f) {
        rgb = saturate(rgb + half3(triangularDither(px) * half(uniforms.split.z)));
    }
    return half4(rgb, half(1.0));
}
// Bit-level IEEE 754 exponent checks survive Metal's default fast-math optimization.
inline bool previewIsFiniteHalf2(half2 value) {
    return (as_type<ushort>(value.x) & 0x7C00u) != 0x7C00u
        && (as_type<ushort>(value.y) & 0x7C00u) != 0x7C00u;
}
inline bool previewIsFiniteMotion(half2 raw, float2 value, bool safeFinite) {
    if (safeFinite) return previewIsFiniteHalf2(raw);
    return isfinite(value.x) && isfinite(value.y);
}
inline half previewNv12Luma(half luma) {
    return fma(luma, half(255.0 / 219.0), half(-16.0 / 219.0));
}
inline void sampleStaticPlane(
    texture2d<half, access::sample> lumaTex,
    texture2d<half, access::sample> chromaTex,
    float2 uv, float2 chromaOffset, SourceUniforms src, bool windowAA, bool bilateralChroma,
    thread half &outY, thread half2 &outUV
) {
    if (windowAA) {
        float2 d = src.fitMax.zw;
        float2 uv0 = clamp(uv + float2(-d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
        float2 uv1 = clamp(uv + float2( d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
        float2 uv2 = clamp(uv + float2(-d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
        float2 uv3 = clamp(uv + float2( d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
        outY = (lumaTex.sample(previewSampler, uv0).r
              + lumaTex.sample(previewSampler, uv1).r
              + lumaTex.sample(previewSampler, uv2).r
              + lumaTex.sample(previewSampler, uv3).r) * half(0.25);
        outUV = (chromaTex.sample(previewSampler, uv0 + chromaOffset).rg
               + chromaTex.sample(previewSampler, uv1 + chromaOffset).rg
               + chromaTex.sample(previewSampler, uv2 + chromaOffset).rg
               + chromaTex.sample(previewSampler, uv3 + chromaOffset).rg) * half(0.25);
    } else {
        outY = lumaTex.sample(previewSampler, uv).r;
        outUV = bilateralChroma
            ? sampleBilateralChroma(lumaTex, chromaTex, uv, chromaOffset, outY)
            : chromaTex.sample(previewSampler, uv + chromaOffset).rg;
    }
}
inline half3 previewLowBlur(
    texture2d<half, access::sample> luma, texture2d<half, access::sample> chroma,
    float2 uv, uint hdrMode
) {
    float2 step = 1.0f / float2(luma.get_width(), luma.get_height());
    half y = (luma.sample(previewSampler, uv + float2(-step.x, -step.y)).r
            + luma.sample(previewSampler, uv + float2(step.x, -step.y)).r
            + luma.sample(previewSampler, uv + float2(-step.x, step.y)).r
            + luma.sample(previewSampler, uv + float2(step.x, step.y)).r) * half(0.25);
    half2 cbcr = fma(chroma.sample(previewSampler, uv).rg, half(255.0 / 224.0), half(-128.0 / 224.0));
    return decodeYCbCr(previewNv12Luma(y), cbcr, hdrMode);
}
// Local 3x3 envelope breakout with low-contrast background gating: keeps static fine text at staticW == 1.0
// while preserving fast-moving midpoint icons gliding over smooth static backgrounds.
inline half previewIconEnvelopeRelease(
    texture2d<half, access::sample> lowA, texture2d<half, access::sample> lowAChroma,
    texture2d<half, access::sample> lowB, texture2d<half, access::sample> lowBChroma,
    texture2d<half, access::sample> lowMid, texture2d<half, access::sample> lowMidChroma,
    float2 uv
) {
    // Exact center early-out: neighbor extrema can only widen [min, max], so if the center
    // midpoint sample already lies within the breakout thresholds of lowA/lowB at uv, the full
    // 3x3 + +/-2 envelope is mathematically guaranteed to return 0.0.
    half midY = saturate(previewNv12Luma(lowMid.sample(previewSampler, uv).r));
    half a0 = saturate(previewNv12Luma(lowA.sample(previewSampler, uv).r));
    half b0 = saturate(previewNv12Luma(lowB.sample(previewSampler, uv).r));
    half minY = min(a0, b0);
    half maxY = max(a0, b0);
    half2 midC = lowMidChroma.sample(previewSampler, uv).rg;
    half2 ca0 = lowAChroma.sample(previewSampler, uv).rg;
    half2 cb0 = lowBChroma.sample(previewSampler, uv).rg;
    half2 minC = min(ca0, cb0);
    half2 maxC = max(ca0, cb0);
    half centerLumaBreak = max(half(0.0), max(minY - midY, midY - maxY));
    half2 centerChromaOver = max(half2(0.0), max(minC - midC, midC - maxC)) * half(255.0 / 224.0);
    if (centerLumaBreak <= half(0.065) && length(centerChromaOver) <= half(0.055)) {
        return half(0.0);
    }
    float2 lStep = 1.0f / float2(lowA.get_width(), lowA.get_height());
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            if (dx == 0 && dy == 0) continue;
            float2 p = uv + float2(float(dx), float(dy)) * lStep;
            half ya = saturate(previewNv12Luma(lowA.sample(previewSampler, p).r));
            half yb = saturate(previewNv12Luma(lowB.sample(previewSampler, p).r));
            minY = min(minY, min(ya, yb));
            maxY = max(maxY, max(ya, yb));
        }
    }
    // Include +/-2 cardinal neighbors to cover VT's 2-texel blur footprint around static fine text.
    const float2 haloOffsets[4] = {
        float2(-2.0f, 0.0f), float2(2.0f, 0.0f), float2(0.0f, -2.0f), float2(0.0f, 2.0f)
    };
    for (int i = 0; i < 4; ++i) {
        float2 p = uv + haloOffsets[i] * lStep;
        half ya = saturate(previewNv12Luma(lowA.sample(previewSampler, p).r));
        half yb = saturate(previewNv12Luma(lowB.sample(previewSampler, p).r));
        minY = min(minY, min(ya, yb));
        maxY = max(maxY, max(ya, yb));
    }
    half rangeY = maxY - minY;
    if (rangeY >= half(0.08)) return half(0.0);
    float2 cStep = 1.0f / float2(lowAChroma.get_width(), lowAChroma.get_height());
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            if (dx == 0 && dy == 0) continue;
            float2 p = uv + float2(float(dx), float(dy)) * cStep;
            half2 ca = lowAChroma.sample(previewSampler, p).rg;
            half2 cb = lowBChroma.sample(previewSampler, p).rg;
            minC = min(minC, min(ca, cb));
            maxC = max(maxC, max(ca, cb));
        }
    }
    half2 rangeC = (maxC - minC) * half(255.0 / 224.0);
    half maxRangeC = max(rangeC.x, rangeC.y);
    if (maxRangeC >= half(0.07)) return half(0.0);
    half lumaBreak = max(half(0.0), max(minY - midY, midY - maxY));
    half2 chromaOver = max(half2(0.0), max(minC - midC, midC - maxC)) * half(255.0 / 224.0);
    half chromaBreak = length(chromaOver);
    half bgSmooth = (half(1.0) - smoothstep(half(0.03), half(0.08), rangeY))
        * (half(1.0) - smoothstep(half(0.03), half(0.07), maxRangeC));
    half breakout = max(
        smoothstep(half(0.065), half(0.14), lumaBreak),
        smoothstep(half(0.055), half(0.12), chromaBreak));
    return bgSmooth * breakout;
}
inline float4 previewCatmullRom(texture2d<half, access::sample> image, float2 uv, bool antiRing) {
    float2 size = float2(image.get_width(), image.get_height());
    float2 position = uv * size;
    float2 center = floor(position - 0.5f) + 0.5f;
    float2 f = position - center;
    float2 w0 = f * (-0.5f + f * (1.0f - 0.5f * f));
    float2 w1 = 1.0f + f * f * (-2.5f + 1.5f * f);
    float2 w2 = f * (0.5f + f * (2.0f - 1.5f * f));
    float2 w3 = f * f * (-0.5f + 0.5f * f);
    float2 w12 = w1 + w2;
    float2 p0 = (center - 1.0f) / size, p12 = (center + w2 / w12) / size, p3 = (center + 2.0f) / size;
    float4 result = float4(image.sample(previewSampler, float2(p0.x, p0.y))) * w0.x * w0.y;
    result += float4(image.sample(previewSampler, float2(p12.x, p0.y))) * w12.x * w0.y;
    result += float4(image.sample(previewSampler, float2(p3.x, p0.y))) * w3.x * w0.y;
    result += float4(image.sample(previewSampler, float2(p0.x, p12.y))) * w0.x * w12.y;
    result += float4(image.sample(previewSampler, float2(p12.x, p12.y))) * w12.x * w12.y;
    result += float4(image.sample(previewSampler, float2(p3.x, p12.y))) * w3.x * w12.y;
    result += float4(image.sample(previewSampler, float2(p0.x, p3.y))) * w0.x * w3.y;
    result += float4(image.sample(previewSampler, float2(p12.x, p3.y))) * w12.x * w3.y;
    result += float4(image.sample(previewSampler, float2(p3.x, p3.y))) * w3.x * w3.y;
    if (antiRing) {
        float2 c00 = center / size;
        float2 c11 = (center + 1.0f) / size;
        float s00 = float(image.sample(previewNearestSampler, float2(c00.x, c00.y)).r);
        float s10 = float(image.sample(previewNearestSampler, float2(c11.x, c00.y)).r);
        float s01 = float(image.sample(previewNearestSampler, float2(c00.x, c11.y)).r);
        float s11 = float(image.sample(previewNearestSampler, float2(c11.x, c11.y)).r);
        float lo = min(min(s00, s10), min(s01, s11));
        float hi = max(max(s00, s10), max(s01, s11));
        result.r = clamp(result.r, lo, hi);
    }
    return result;
}
inline half previewPatchDiff(texture2d<half, access::sample> img, float2 uv, float2 step,
                             half m0, half m1, half m2, half m3, half m4,
                             half wg1, half wg2, half wg3, half wg4, half invW) {
    half d = abs(img.sample(previewSampler, uv).r - m0);
    d += wg1 * abs(img.sample(previewSampler, uv + float2(step.x, 0.0f)).r - m1);
    d += wg2 * abs(img.sample(previewSampler, uv - float2(step.x, 0.0f)).r - m2);
    d += wg3 * abs(img.sample(previewSampler, uv + float2(0.0f, step.y)).r - m3);
    d += wg4 * abs(img.sample(previewSampler, uv - float2(0.0f, step.y)).r - m4);
    return d * invW;
}
kernel void previewSelectMotion(
    texture2d<half, access::sample> lowA [[texture(0)]],
    texture2d<half, access::sample> lowAChroma [[texture(1)]],
    texture2d<half, access::sample> lowB [[texture(2)]],
    texture2d<half, access::sample> lowBChroma [[texture(3)]],
    texture2d<half, access::sample> lowMid [[texture(4)]],
    texture2d<half, access::sample> motion [[texture(5)]],
    texture2d<half, access::write> detailOut [[texture(6)]],
    texture2d<half, access::sample> forwardMotion [[texture(7), function_constant(previewHasForwardMotion)]],
    constant float4 &weights [[buffer(0)]],
    constant float4 &motionScale [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = detailOut.get_width(), h = detailOut.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 lowSize = float2(lowA.get_width(), lowA.get_height());
    float2 lowStep = 1.0f / lowSize;
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    uint motionFlags = uint(motionScale.w + 0.5f);
    uint hdrMode = motionFlags & 3u;
    bool hudDehalo = (motionFlags & 8u) != 0u;
    bool safeFinite = (motionFlags & 16u) != 0u;
    bool lowStatic = false;
    if (weights.y > 0.5f) {
        half3 la = previewLowBlur(lowA, lowAChroma, uv, hdrMode);
        half3 lb = previewLowBlur(lowB, lowBChroma, uv, hdrMode);
        lowStatic = length(la - lb) < half(0.012);
    }
    half2 centerRaw = motion.sample(previewNearestSampler, uv).rg;
    float2 centerV = float2(centerRaw);
    bool centerFinite = previewIsFiniteMotion(centerRaw, centerV, safeFinite);
    bool centerSmall = !centerFinite || (abs(centerV.x) < 0.25f && abs(centerV.y) < 0.25f);
    if (lowStatic && centerSmall) {
        detailOut.write(half4(half(0.0), half(0.0), half(2.0), half(0.0)), gid);
        return;
    }
    float fwdScale = motionScale.z;
    half2 centerFwdRaw = previewHasForwardMotion
        ? forwardMotion.sample(previewNearestSampler, uv).rg : half2(half(0.0));
    float2 centerFwdV = previewHasForwardMotion ? -float2(centerFwdRaw) * fwdScale : float2(0.0f);
    float2 gridSize = float2(motion.get_width(), motion.get_height());
    float2 gridStep = 1.0f / gridSize;
    float2 gridFrac = fract(uv * gridSize);
    float sx = gridFrac.x < 0.5f ? -1.0f : 1.0f;
    float sy = gridFrac.y < 0.5f ? -1.0f : 1.0f;
    float t = weights.x;
    half m0, m1, m2, m3, m4;
    if (previewSampleMid) {
        m0 = lowMid.sample(previewSampler, uv).r;
        m1 = lowMid.sample(previewSampler, uv + float2(lowStep.x, 0.0f)).r;
        m2 = lowMid.sample(previewSampler, uv - float2(lowStep.x, 0.0f)).r;
        m3 = lowMid.sample(previewSampler, uv + float2(0.0f, lowStep.y)).r;
        m4 = lowMid.sample(previewSampler, uv - float2(0.0f, lowStep.y)).r;
    } else {
        uint x0 = gid.x, y0 = gid.y;
        uint xm = x0 > 0 ? x0 - 1 : 0;
        uint xp = x0 + 1 < w ? x0 + 1 : w - 1;
        uint ym = y0 > 0 ? y0 - 1 : 0;
        uint yp = y0 + 1 < h ? y0 + 1 : h - 1;
        m0 = lowMid.read(uint2(x0, y0)).r;
        m1 = lowMid.read(uint2(xp, y0)).r;
        m2 = lowMid.read(uint2(xm, y0)).r;
        m3 = lowMid.read(uint2(x0, yp)).r;
        m4 = lowMid.read(uint2(x0, ym)).r;
    }
    half wg1 = half(1.0) / (half(1.0) + half(16.0) * abs(m1 - m0));
    half wg2 = half(1.0) / (half(1.0) + half(16.0) * abs(m2 - m0));
    half wg3 = half(1.0) / (half(1.0) + half(16.0) * abs(m3 - m0));
    half wg4 = half(1.0) / (half(1.0) + half(16.0) * abs(m4 - m0));
    half invW = half(1.0) / (half(1.0) + wg1 + wg2 + wg3 + wg4);
    const float2 probeOffsets[6] = {
        float2(0.0f, 0.0f), float2(sx, 0.0f), float2(0.0f, sy), float2(sx, sy),
        float2(-sx, 0.0f), float2(0.0f, -sy)
    };
    float2 bestDUV = float2(0.0f);
    float2 bestV = float2(0.0f);
    half bestScore = half(1.0);
    half bestErrA = half(1.0);
    half bestErrB = half(1.0);
    float2 lastV = float2(1e6f);
    int totalCandidates = previewHasForwardMotion ? 7 : 6;
    for (int i = 0; i < totalCandidates; ++i) {
        if (i == 4 && bestScore < half(0.015)) break;
        if (i == 5 && bestScore < half(0.022)) break;
        half2 rawV;
        float2 v;
        if (i == 0) {
            rawV = centerRaw;
            v = centerV;
        } else if (i < 4) {
            rawV = motion.sample(previewNearestSampler, uv + probeOffsets[i] * gridStep).rg;
            v = float2(rawV);
        } else if (previewHasForwardMotion && i == 4) {
            rawV = centerFwdRaw;
            v = centerFwdV;
        } else {
            int idx = previewHasForwardMotion ? (i - 1) : i;
            rawV = motion.sample(previewNearestSampler, uv + probeOffsets[idx] * gridStep).rg;
            v = float2(rawV);
        }
        if (!previewIsFiniteMotion(rawV, v, safeFinite) || (abs(v.x) < 0.25f && abs(v.y) < 0.25f)) continue;
        if (i > 0 && ((centerFinite && abs(v.x - centerV.x) < 0.25f && abs(v.y - centerV.y) < 0.25f)
                   || (abs(v.x - lastV.x) < 0.25f && abs(v.y - lastV.y) < 0.25f)
                   || (abs(v.x - bestV.x) < 0.25f && abs(v.y - bestV.y) < 0.25f))) continue;
        lastV = v;
        float2 dUV = v * motionScale.xy;
        float2 uvA = uv + t * dUV;
        float2 uvB = uv - (1.0f - t) * dUV;
        half eA = previewPatchDiff(lowA, uvA, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
        half eB = previewPatchDiff(lowB, uvB, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
        half score = min(eA, eB) + half(0.5) * max(eA, eB);
        if (score < bestScore) {
            bestScore = score;
            bestDUV = dUV;
            bestV = v;
            bestErrA = eA;
            bestErrB = eB;
            if (score < half(0.010)) break;
        }
    }
    if (hudDehalo && bestScore >= half(0.015) && (abs(bestV.x) >= 0.25f || abs(bestV.y) >= 0.25f)) {
        float2 uvA = uv + t * bestDUV;
        float2 uvB = uv - (1.0f - t) * bestDUV;
        if (bestErrB < half(0.018) && bestErrA > bestErrB + half(0.025)) {
            half occA = abs(lowA.sample(previewSampler, uvA).r - lowB.sample(previewSampler, uvA).r)
                * half(255.0 / 219.0);
            if (occA < half(0.025)) { bestScore = min(bestScore, bestErrB + half(0.006)); }
        } else if (bestErrA < half(0.018) && bestErrB > bestErrA + half(0.025)) {
            half occB = abs(lowA.sample(previewSampler, uvB).r - lowB.sample(previewSampler, uvB).r)
                * half(255.0 / 219.0);
            if (occB < half(0.025)) { bestScore = min(bestScore, bestErrA + half(0.006)); }
        }
    }
    if (hudDehalo && centerSmall && !lowStatic && bestScore >= half(0.015)) {
        // Gate far-distance (+/-2..3 macroblock) background probes on local spatial contrast plus a nearby
        // static stroke anchor so dark or subtly moving MV=0 backgrounds never pay 80 extra texture fetches.
        const float2 gateOffsets[9] = {
            float2(0.0f, 0.0f),
            float2(0.25f, 0.0f), float2(-0.25f, 0.0f), float2(0.0f, 0.25f), float2(0.0f, -0.25f),
            float2(0.50f, 0.0f), float2(-0.50f, 0.0f), float2(0.0f, 0.50f), float2(0.0f, -0.50f)
        };
        half minA = half(1.0), maxA = half(0.0);
        half minB = half(1.0), maxB = half(0.0);
        half minStaticDiff = half(1.0);
        for (int g = 0; g < 9; ++g) {
            float2 gp = uv + gateOffsets[g] * gridStep;
            half ga = lowA.sample(previewSampler, gp).r;
            half gb = lowB.sample(previewSampler, gp).r;
            minA = min(minA, ga);
            maxA = max(maxA, ga);
            minB = min(minB, gb);
            maxB = max(maxB, gb);
            minStaticDiff = min(minStaticDiff, abs(ga - gb));
        }
        half spatialContrast = max(maxA - minA, maxB - minB) * half(255.0 / 219.0);
        bool nearHighContrastHUD = spatialContrast >= half(0.18)
            && (minStaticDiff * half(255.0 / 219.0)) < half(0.045);
        // Static high-contrast HUD text locks its 16x16 macroblock (32x32 at 4K) to MV=0.
        // Step 2-3 macroblocks past text rows to borrow background MV and allow unoccluded
        // single-sided matches when the opposite endpoint lands on static HUD text.
        const float2 hudOffsets[8] = {
            float2(0.0f, 2.0f), float2(0.0f, -2.0f), float2(0.0f, 3.0f), float2(0.0f, -3.0f),
            float2(2.0f, 0.0f), float2(-2.0f, 0.0f), float2(3.0f, 0.0f), float2(-3.0f, 0.0f)
        };
        float2 hudLastV = float2(1e6f);
        for (int k = 0; nearHighContrastHUD && k < 8; ++k) {
            half2 rawV = motion.sample(previewNearestSampler, uv + hudOffsets[k] * gridStep).rg;
            float2 v = float2(rawV);
            if (!previewIsFiniteMotion(rawV, v, safeFinite) || (abs(v.x) < 0.25f && abs(v.y) < 0.25f)) continue;
            if ((abs(v.x - hudLastV.x) < 0.25f && abs(v.y - hudLastV.y) < 0.25f)
                || (abs(v.x - bestV.x) < 0.25f && abs(v.y - bestV.y) < 0.25f)) continue;
            hudLastV = v;
            float2 dUV = v * motionScale.xy;
            float2 uvA = uv + t * dUV;
            float2 uvB = uv - (1.0f - t) * dUV;
            half eA = previewPatchDiff(lowA, uvA, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
            half eB = previewPatchDiff(lowB, uvB, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
            half score = min(eA, eB) + half(0.5) * max(eA, eB);
            if (eB < half(0.018) && eA > eB + half(0.025)) {
                half occA = abs(lowA.sample(previewSampler, uvA).r - lowB.sample(previewSampler, uvA).r)
                    * half(255.0 / 219.0);
                if (occA < half(0.025)) { score = min(score, eB + half(0.006)); }
            } else if (eA < half(0.018) && eB > eA + half(0.025)) {
                half occB = abs(lowA.sample(previewSampler, uvB).r - lowB.sample(previewSampler, uvB).r)
                    * half(255.0 / 219.0);
                if (occB < half(0.025)) { score = min(score, eA + half(0.006)); }
            }
            if (score < bestScore) {
                bestScore = score;
                bestDUV = dUV;
                bestV = v;
                bestErrA = eA;
                bestErrB = eB;
                if (score < half(0.010)) break;
            }
        }
    }
    half wA = smoothstep(half(0.045), half(0.010), bestErrA);
    half wB = smoothstep(half(0.045), half(0.010), bestErrB);
    if (previewHasForwardMotion && (wA + wB > half(0.02))) {
        float2 uvA = uv + t * bestDUV;
        float2 uvB = uv - (1.0f - t) * bestDUV;
        half2 rawAB = forwardMotion.sample(previewNearestSampler, uvA).rg;
        half2 rawBA = motion.sample(previewNearestSampler, uvB).rg;
        float2 vABatA = float2(rawAB) * fwdScale;
        float2 vBAatB = float2(rawBA);
        float fbThresh = max(2.5f, 0.25f * length(bestV));
        if (previewIsFiniteMotion(rawAB, vABatA, safeFinite) && bestErrA > bestErrB + half(0.005)) {
            float fbA = length(vABatA + bestV);
            if (fbA > fbThresh) {
                wA *= smoothstep(half(fbThresh * 2.0f), half(fbThresh), half(fbA));
            }
        }
        if (previewIsFiniteMotion(rawBA, vBAatB, safeFinite) && bestErrB > bestErrA + half(0.005)) {
            float fbB = length(vBAatB - bestV);
            if (fbB > fbThresh) {
                wB *= smoothstep(half(fbThresh * 2.0f), half(fbThresh), half(fbB));
            }
        }
    }
    detailOut.write(half4(half(bestDUV.x), half(bestDUV.y), lowStatic ? (wA + half(2.0)) : wA, wB), gid);
}
// Fused single-pass hybrid midpoint decode directly to 10-bit/8-bit preview drawable,
// eliminating the 12.4 MB 4K 420v intermediate round-trip and its 8-bit quantization loss.
fragment half4 previewHybridFragment(
    PreviewVertex in [[stage_in]],
    texture2d<half, access::sample> aTex [[texture(0)]],
    texture2d<half, access::sample> aChroma [[texture(1)]],
    texture2d<half, access::sample> bTex [[texture(2)]],
    texture2d<half, access::sample> bChroma [[texture(3)]],
    texture2d<half, access::sample> lowATex [[texture(4)]],
    texture2d<half, access::sample> lowAChroma [[texture(5)]],
    texture2d<half, access::sample> lowBTex [[texture(6)]],
    texture2d<half, access::sample> lowBChroma [[texture(7)]],
    texture2d<half, access::sample> lowMidTex [[texture(8)]],
    texture2d<half, access::sample> lowMidChroma [[texture(9)]],
    texture2d<half, access::sample> motionDetail [[texture(10), function_constant(previewHasMotion)]],
    constant HybridPreviewUniforms &u [[buffer(0)]]
) {
    float2 px = in.position.xy;
    SourceUniforms src = u.primary;
    if (px.x < src.fitRect.x || px.x >= src.fitMax.x || px.y < src.fitRect.y || px.y >= src.fitMax.y) {
        return half4(half3(0.0h), half(1.0));
    }
    uint postFlags = uint(u.post.y + 0.5f);
    bool bilateralChroma = (postFlags & 1u) != 0u;
    bool hdr10Deband = (postFlags & 2u) != 0u;
    if (u.split.x > 0.5f && px.x < u.split.y) {
        half3 orig = sampleSource(aTex, aChroma, src, px, bilateralChroma, hdr10Deband);
        if (u.post.x > 0.001f) {
            half3 n = sampleSource(aTex, aChroma, src, px + float2(0.0f, -1.0f), bilateralChroma, hdr10Deband);
            half3 s = sampleSource(aTex, aChroma, src, px + float2(0.0f, 1.0f), bilateralChroma, hdr10Deband);
            half3 e = sampleSource(aTex, aChroma, src, px + float2(1.0f, 0.0f), bilateralChroma, hdr10Deband);
            half3 w = sampleSource(aTex, aChroma, src, px + float2(-1.0f, 0.0f), bilateralChroma, hdr10Deband);
            orig = previewApplyRCAS(orig, n, s, e, w, half(u.post.x), src.flags.x > 1.5f);
        }
        if (u.split.z > 0.0f) {
            orig = saturate(orig + half3(triangularDither(px) * half(u.split.z)));
        }
        return half4(orig, half(1.0));
    }
    float2 normalized = (px - src.fitRect.xy) * src.fitRect.zw;
    float2 uv = clamp(fma(normalized, src.uvRect.zw, src.uvRect.xy), src.clampRect.xy, src.clampRect.zw);
    uint hdrMode = src.flags.x > 1.5f ? uint(src.flags.x - 0.5f) : 0u;
    float colorMode = src.flags.y;
    half4 md = half4(0.0);
    bool lowStatic = false;
    if (previewHasMotion) {
        md = motionDetail.sample(previewNearestSampler, uv);
        lowStatic = md.z >= half(1.5);
        if (lowStatic) md.z -= half(2.0);
    } else if (u.weights.y > 0.5f) {
        half3 la = previewLowBlur(lowATex, lowAChroma, uv, hdrMode);
        half3 lb = previewLowBlur(lowBTex, lowBChroma, uv, hdrMode);
        lowStatic = length(la - lb) < half(0.012);
    }
    float t = u.weights.x;
    half tHalf = half(t);
    uint qualityFlags = uint(u.weights.w + 0.5f);
    bool edgeRefine = (qualityFlags & 1u) != 0u;
    bool hudDehalo = (qualityFlags & 4u) != 0u;
    bool spatialMovingDetail = (qualityFlags & 8u) != 0u && previewHasMotion;
    bool iconEnvelope = (qualityFlags & 16u) != 0u;
    bool adaptiveCAS = (qualityFlags & 32u) != 0u;
    half rcasStrength = half(u.post.x);
    float2 pxUVStep = src.fitRect.zw * src.uvRect.zw;
    half pairedConfidence = spatialMovingDetail
        ? smoothstep(half(0.05), half(0.45), min(md.z, md.w)) : half(0.0);
    bool windowAA = u.split.w > 0.5f && src.fitMax.z > 0.0f;
    float srcPixelsPerOutPixel = windowAA ? (float(aTex.get_width()) * src.fitMax.z * 4.0f) : 1.0f;
    half detailScale = windowAA ? half(smoothstep(2.0f, 1.0f, srcPixelsPerOutPixel)) : half(1.0);
    half staticW = half(0.0);
    half yA = half(0.0), yB = half(0.0);
    half2 caUV = half2(0.0), cbUV = half2(0.0);
    if (lowStatic) {
        sampleStaticPlane(aTex, aChroma, uv, u.offsets.xy, src, windowAA, bilateralChroma, yA, caUV);
        sampleStaticPlane(bTex, bChroma, uv, u.offsets.zw, src, windowAA, bilateralChroma, yB, cbUV);
        half dY = (yA - yB) * half(255.0 / 219.0);
        half2 dCbCr = (caUV - cbUV) * half(255.0 / 224.0);
        half dR, dG, dB;
        if (hdrMode >= 2u) {
            dR = dY + half(1.4746) * dCbCr.y;
            dG = dY + fma(half(-0.57135), dCbCr.y, half(-0.16455) * dCbCr.x);
            dB = dY + half(1.8814) * dCbCr.x;
        } else {
            dR = dY + half(1.5748) * dCbCr.y;
            dG = dY + fma(half(-0.468124), dCbCr.y, half(-0.187324) * dCbCr.x);
            dB = dY + half(1.8556) * dCbCr.x;
        }
        staticW = smoothstep(half(0.022), half(0.011), sqrt(dR * dR + dG * dG + dB * dB));
        if (iconEnvelope && staticW > half(0.001)) {
            staticW *= half(1.0) - previewIconEnvelopeRelease(
                lowATex, lowAChroma, lowBTex, lowBChroma, lowMidTex, lowMidChroma, uv);
        }
        if (staticW >= half(0.999) && pairedConfidence == half(0.0)) {
            half rawStaticY = mix(yA, yB, tHalf);
            half2 rawStaticUV = mix(caUV, cbUV, tHalf);
            if (hdr10Deband && hdrMode >= 1u && !windowAA) {
                rawStaticY = debandHDR10Luma(aTex, uv, px, src.clampRect, rawStaticY);
            }
            half yStatic = saturate(previewNv12Luma(rawStaticY));
            if (rcasStrength > half(0.001)) {
                half yN = saturate(previewNv12Luma(mix(
                    aTex.sample(previewSampler, clamp(uv + float2(0.0f, -pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                    bTex.sample(previewSampler, clamp(uv + float2(0.0f, -pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                    tHalf)));
                half yS = saturate(previewNv12Luma(mix(
                    aTex.sample(previewSampler, clamp(uv + float2(0.0f, pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                    bTex.sample(previewSampler, clamp(uv + float2(0.0f, pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                    tHalf)));
                half yE = saturate(previewNv12Luma(mix(
                    aTex.sample(previewSampler, clamp(uv + float2(pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                    bTex.sample(previewSampler, clamp(uv + float2(pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                    tHalf)));
                half yW = saturate(previewNv12Luma(mix(
                    aTex.sample(previewSampler, clamp(uv + float2(-pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                    bTex.sample(previewSampler, clamp(uv + float2(-pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                    tHalf)));
                yStatic = previewApplyLumaRCAS(yStatic, yN, yS, yE, yW, rcasStrength);
            }
            half2 cbcrStatic = fma(rawStaticUV, half(255.0 / 224.0), half(-128.0 / 224.0));
            half3 rgb = finalizePreviewColor(decodeYCbCr(yStatic, cbcrStatic, hdrMode), colorMode);
            if (u.split.z > 0.0f) rgb = saturate(rgb + half3(triangularDither(px) * half(u.split.z)));
            return half4(rgb, half(1.0));
        }
    }
    half midY;
    if (windowAA && srcPixelsPerOutPixel > 2.0f) {
        float2 d = src.fitMax.zw;
        float2 uv0 = clamp(uv + float2(-d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
        float2 uv1 = clamp(uv + float2( d.x, -d.y), src.clampRect.xy, src.clampRect.zw);
        float2 uv2 = clamp(uv + float2(-d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
        float2 uv3 = clamp(uv + float2( d.x,  d.y), src.clampRect.xy, src.clampRect.zw);
        half mLuma = (lowMidTex.sample(previewSampler, uv0).r
                    + lowMidTex.sample(previewSampler, uv1).r
                    + lowMidTex.sample(previewSampler, uv2).r
                    + lowMidTex.sample(previewSampler, uv3).r) * half(0.25);
        midY = saturate(previewNv12Luma(mLuma));
    } else {
        midY = saturate(previewNv12Luma(half(previewCatmullRom(lowMidTex, uv, edgeRefine).r)));
    }
    half midRawY = clamp(fma(midY, half(219.0 / 255.0), half(16.0 / 255.0)), half(16.0 / 255.0), half(235.0 / 255.0));
    half2 midUV = bilateralChroma
        ? sampleBilateralChroma(lowMidTex, lowMidChroma, uv, float2(0.0f), midRawY)
        : lowMidChroma.sample(previewSampler, uv).rg;
    half y = midY;
    half alignedY = midY;
    half alignedWeight = half(0.0);
    half2 outChroma = midUV;
    bool appliedMotion = false;
    half motionConf = half(0.0);
    float2 motionUV = uv;
    bool motionRefIsB = false;
    if (previewHasMotion && detailScale > half(0.01)) {
        if (edgeRefine && (!spatialMovingDetail || pairedConfidence == half(0.0))) {
            float2 mdSize = float2(motionDetail.get_width(), motionDetail.get_height());
            float2 mdPos = uv * mdSize;
            float2 mdCenter = floor(mdPos - 0.5f) + 0.5f;
            float2 mdFrac = mdPos - mdCenter;
            float2 p00 = mdCenter / mdSize;
            float2 p10 = (mdCenter + float2(1.0f, 0.0f)) / mdSize;
            float2 p01 = (mdCenter + float2(0.0f, 1.0f)) / mdSize;
            float2 p11 = (mdCenter + float2(1.0f, 1.0f)) / mdSize;
            half l00 = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, p00).r));
            half l10 = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, p10).r));
            half l01 = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, p01).r));
            half l11 = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, p11).r));
            half lRange = max(max(l00, l10), max(l01, l11)) - min(min(l00, l10), min(l01, l11));
            if (lRange > half(0.02)) {
                float d00 = abs(float(midY - l00)) + 0.015f * length(mdFrac);
                float d10 = abs(float(midY - l10)) + 0.015f * length(mdFrac - float2(1.0f, 0.0f));
                float d01 = abs(float(midY - l01)) + 0.015f * length(mdFrac - float2(0.0f, 1.0f));
                float d11 = abs(float(midY - l11)) + 0.015f * length(mdFrac - float2(1.0f, 1.0f));
                float2 bestUV = p00;
                float bestD = d00;
                if (d10 < bestD) { bestD = d10; bestUV = p10; }
                if (d01 < bestD) { bestD = d01; bestUV = p01; }
                if (d11 < bestD) { bestUV = p11; }
                md = motionDetail.sample(previewNearestSampler, bestUV);
                if (md.z >= half(1.5)) md.z -= half(2.0);
            }
        }
        if (spatialMovingDetail) {
            pairedConfidence = smoothstep(half(0.05), half(0.45), min(md.z, md.w));
        }
        half wA = md.z;
        half wB = md.w;
        if (wA + wB > half(0.02)) {
            appliedMotion = true;
            float2 bestDUV = float2(md.xy);
            float2 uvA = uv + t * bestDUV;
            float2 uvB = uv - (1.0f - t) * bestDUV;
            half wa = half(1.0 - t) * wA;
            half wb = half(t) * wB;
            half invWAB = half(1.0) / max(wa + wb, half(1e-4));
            half conf = max(wA, wB) * detailScale;
            motionConf = conf;
            motionRefIsB = wb > wa;
            motionUV = motionRefIsB ? uvB : uvA;
            half srcAY = midY, srcBY = midY;
            half baseAY = midY, baseBY = midY;
            half hiAY = half(0.0), hiBY = half(0.0);
            half2 srcAUV = midUV, srcBUV = midUV;
            half2 hiAUV = half2(0.0), hiBUV = half2(0.0);
            if (wA > half(0.01)) {
                srcAY = saturate(previewNv12Luma(aTex.sample(previewSampler, uvA).r));
                baseAY = saturate(previewNv12Luma(lowATex.sample(previewSampler, uvA).r));
                hiAY = srcAY - baseAY;
                srcAUV = aChroma.sample(previewSampler, uvA + u.offsets.xy).rg;
                hiAUV = srcAUV - lowAChroma.sample(previewSampler, uvA).rg;
            }
            if (wB > half(0.01)) {
                srcBY = saturate(previewNv12Luma(bTex.sample(previewSampler, uvB).r));
                baseBY = saturate(previewNv12Luma(lowBTex.sample(previewSampler, uvB).r));
                hiBY = srcBY - baseBY;
                srcBUV = bChroma.sample(previewSampler, uvB + u.offsets.zw).rg;
                hiBUV = srcBUV - lowBChroma.sample(previewSampler, uvB).rg;
            }
            half baseY = midY;
            if (hudDehalo) {
                if (wB > half(0.70) && wA < half(0.05)) {
                    half haloGate = half(1.0) - smoothstep(half(0.04), half(0.12), abs(midY - baseBY));
                    baseY = mix(midY, baseBY, wB * haloGate * half(0.45));
                } else if (wA > half(0.70) && wB < half(0.05)) {
                    half haloGate = half(1.0) - smoothstep(half(0.04), half(0.12), abs(midY - baseAY));
                    baseY = mix(midY, baseAY, wA * haloGate * half(0.45));
                }
            }
            half detailY = (hiAY * wa + hiBY * wb) * invWAB;
            half envMinY = min(midY, min(wA > half(0.1) ? srcAY : midY, wB > half(0.1) ? srcBY : midY));
            half envMaxY = max(midY, max(wA > half(0.1) ? srcAY : midY, wB > half(0.1) ? srcBY : midY));
            y = clamp(baseY + conf * detailY, envMinY, envMaxY);
            if (pairedConfidence > half(0.0)) {
                half agrees = half(1.0) - smoothstep(half(0.012), half(0.045), abs(srcAY - srcBY));
                alignedWeight = pairedConfidence * agrees * detailScale;
                alignedY = mix(srcAY, srcBY, tHalf);
                if (staticW > half(0.0)) {
                    half originalY = saturate(previewNv12Luma(mix(yA, yB, tHalf)));
                    half movement = clamp(sign(alignedY - originalY) * (midY - originalY), half(0.0), half(1.0));
                    staticW *= half(1.0) - alignedWeight * smoothstep(half(0.025), half(0.10), movement);
                }
            }
            half2 detailUV = (hiAUV * wa + hiBUV * wb) * invWAB;
            half2 uvMin = min(midUV, min(wA > half(0.1) ? srcAUV : midUV, wB > half(0.1) ? srcBUV : midUV));
            half2 uvMax = max(midUV, max(wA > half(0.1) ? srcAUV : midUV, wB > half(0.1) ? srcBUV : midUV));
            outChroma = clamp(midUV + conf * detailUV, uvMin, uvMax);
        }
    }
    if (hudDehalo && !lowStatic && !appliedMotion && u.weights.y > 0.5f) {
        half syA = aTex.sample(previewSampler, uv).r;
        half syB = bTex.sample(previewSampler, uv).r;
        half dSY = abs(syA - syB) * half(255.0 / 219.0);
        if (dSY < half(0.012)) {
            half lowAY = saturate(previewNv12Luma(lowATex.sample(previewSampler, uv).r));
            half lowBY = saturate(previewNv12Luma(lowBTex.sample(previewSampler, uv).r));
            half midDev = max(half(0.0), max(min(lowAY, lowBY) - midY, midY - max(lowAY, lowBY)));
            half stYA = half(0.0), stYB = half(0.0);
            half2 stCA = half2(0.0), stCB = half2(0.0);
            sampleStaticPlane(aTex, aChroma, uv, u.offsets.xy, src, windowAA, bilateralChroma, stYA, stCA);
            sampleStaticPlane(bTex, bChroma, uv, u.offsets.zw, src, windowAA, bilateralChroma, stYB, stCB);
            half dSC = length((stCA - stCB) * half(255.0 / 224.0));
            half strokeW = (half(1.0) - smoothstep(half(0.005), half(0.012), dSY))
                * (half(1.0) - smoothstep(half(0.012), half(0.024), dSC))
                * (half(1.0) - smoothstep(half(0.025), half(0.065), midDev));
            if (strokeW > half(0.01)) {
                yA = stYA;
                yB = stYB;
                caUV = stCA;
                cbUV = stCB;
                staticW = max(staticW, strokeW);
            }
        }
    }
    half casGain = adaptiveCAS ? half(1.45) * (half(1.0) - half(0.65) * motionConf) : half(1.0);
    half casStrength = half(u.weights.z) * casGain * detailScale;
    if (casStrength > half(0.001)) {
        float2 casStep = 0.75f / float2(lowMidTex.get_width(), lowMidTex.get_height());
        half n = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(0.0f, -casStep.y)).r));
        half so = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(0.0f, casStep.y)).r));
        half e = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(casStep.x, 0.0f)).r));
        half w = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(-casStep.x, 0.0f)).r));
        half mn = min(y, min(min(n, so), min(e, w)));
        half mx = max(y, max(max(n, so), max(e, w)));
        half amp = clamp(min(mn, half(1.0) - mx) / max(mx, half(1e-4)), half(0.0), half(1.0));
        half kCas = -casStrength * sqrt(amp);
        y = clamp((y + kCas * (n + so + e + w)) / (half(1.0) + half(4.0) * kCas), mn, mx);
    }
    if (alignedWeight > half(0.001)) {
        y = mix(y, alignedY, alignedWeight);
    }
    if (staticW > half(0.001)) {
        y = mix(y, saturate(previewNv12Luma(mix(yA, yB, tHalf))), staticW);
        outChroma = mix(outChroma, mix(caUV, cbUV, tHalf), staticW);
    }
    if (rcasStrength > half(0.001)) {
        half rC, rN, rS, rE, rW;
        if (staticW > half(0.5)) {
            rC = saturate(previewNv12Luma(mix(yA, yB, tHalf)));
            rN = saturate(previewNv12Luma(mix(
                aTex.sample(previewSampler, clamp(uv + float2(0.0f, -pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                bTex.sample(previewSampler, clamp(uv + float2(0.0f, -pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                tHalf)));
            rS = saturate(previewNv12Luma(mix(
                aTex.sample(previewSampler, clamp(uv + float2(0.0f, pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                bTex.sample(previewSampler, clamp(uv + float2(0.0f, pxUVStep.y), src.clampRect.xy, src.clampRect.zw)).r,
                tHalf)));
            rE = saturate(previewNv12Luma(mix(
                aTex.sample(previewSampler, clamp(uv + float2(pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                bTex.sample(previewSampler, clamp(uv + float2(pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                tHalf)));
            rW = saturate(previewNv12Luma(mix(
                aTex.sample(previewSampler, clamp(uv + float2(-pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                bTex.sample(previewSampler, clamp(uv + float2(-pxUVStep.x, 0.0f), src.clampRect.xy, src.clampRect.zw)).r,
                tHalf)));
        } else if (appliedMotion && motionConf > half(0.25)) {
            texture2d<half, access::sample> refTex = motionRefIsB ? bTex : aTex;
            rC = saturate(previewNv12Luma(refTex.sample(previewSampler, motionUV).r));
            rN = saturate(previewNv12Luma(refTex.sample(previewSampler, motionUV + float2(0.0f, -pxUVStep.y)).r));
            rS = saturate(previewNv12Luma(refTex.sample(previewSampler, motionUV + float2(0.0f, pxUVStep.y)).r));
            rE = saturate(previewNv12Luma(refTex.sample(previewSampler, motionUV + float2(pxUVStep.x, 0.0f)).r));
            rW = saturate(previewNv12Luma(refTex.sample(previewSampler, motionUV + float2(-pxUVStep.x, 0.0f)).r));
        } else {
            rC = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv).r));
            rN = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(0.0f, -pxUVStep.y)).r));
            rS = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(0.0f, pxUVStep.y)).r));
            rE = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(pxUVStep.x, 0.0f)).r));
            rW = saturate(previewNv12Luma(lowMidTex.sample(previewSampler, uv + float2(-pxUVStep.x, 0.0f)).r));
        }
        y = previewApplyLumaRCAS(
            y, saturate(y + (rN - rC)), saturate(y + (rS - rC)),
            saturate(y + (rE - rC)), saturate(y + (rW - rC)), rcasStrength);
    }
    if (hdr10Deband && hdrMode >= 1u && !windowAA) {
        half rawOutY = clamp(fma(y, half(219.0 / 255.0), half(16.0 / 255.0)), half(16.0 / 255.0), half(235.0 / 255.0));
        rawOutY = debandHDR10Luma(lowMidTex, uv, px, src.clampRect, rawOutY);
        y = saturate(previewNv12Luma(rawOutY));
    }
    half2 cbcr = fma(outChroma, half(255.0 / 224.0), half(-128.0 / 224.0));
    half3 rgb = finalizePreviewColor(decodeYCbCr(y, cbcr, hdrMode), colorMode);
    if (u.split.z > 0.0f) rgb = saturate(rgb + half3(triangularDither(px) * half(u.split.z)));
    return half4(rgb, half(1.0));
}
