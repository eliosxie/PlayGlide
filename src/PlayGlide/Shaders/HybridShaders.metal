#include <metal_stdlib>
using namespace metal;
constant bool nv12 [[function_constant(0)]];
constant bool hasMotion [[function_constant(1)]];
constant bool hasForwardMotion [[function_constant(2)]];
constant bool exactTwoX [[function_constant(3)]];
constant bool sampleMid [[function_constant(4)]];
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
inline half nv12Luma(half luma) {
    return fma(luma, half(255.0 / 219.0), half(-16.0 / 219.0));
}
inline half3 nv12FromY(half y, half2 chroma) {
    half2 cbcr = fma(chroma, half(255.0 / 224.0), half(-128.0 / 224.0));
    return saturate(half3(
        fma(half(1.5748), cbcr.y, y),
        fma(half(-0.468124), cbcr.y, fma(half(-0.187324), cbcr.x, y)),
        fma(half(1.8556), cbcr.x, y)));
}
inline half3 nv12Color(half luma, half2 chroma) {
    return nv12FromY(nv12Luma(luma), chroma);
}
inline half3 sourceColor(texture2d<half, access::sample> image, texture2d<half, access::sample> chroma,
                         float2 uv, float2 offset) {
    half3 value = image.sample(linearSampler, uv).rgb;
    if (!nv12) return value;
    return nv12Color(value.r, chroma.sample(linearSampler, uv + offset).rg);
}
inline half3 decodeLowYCbCr(half y, half2 cbcr, bool bt2020, bool softToe) {
    if (bt2020) {
        half yPos = max(half(0.0), y);
        half yAnchored;
        half2 cBoost;
        if (softToe) {
            half t = saturate(yPos * half(1.0 / 0.08));
            yAnchored = yPos * mix(half(0.25), half(1.0), t);
            cBoost = cbcr * mix(half(0.75), half(1.12), t);
        } else {
            yAnchored = max(half(0.0), (yPos - half(0.042)) * half(1.0 / 0.958));
            cBoost = cbcr * half(1.12);
        }
        half3 rgb = saturate(half3(
            fma(half(1.4746), cBoost.y, yAnchored),
            fma(half(-0.57135), cBoost.y, fma(half(-0.16455), cBoost.x, yAnchored)),
            fma(half(1.8814), cBoost.x, yAnchored)));
        return saturate(pow(rgb, half3(1.10)));
    }
    return saturate(half3(
        fma(half(1.5748), cbcr.y, y),
        fma(half(-0.468124), cbcr.y, fma(half(-0.187324), cbcr.x, y)),
        fma(half(1.8556), cbcr.x, y)));
}
// Low-frequency color over about three downscaled pixels; ignores moire that VT adds to fine detail.
inline half3 lowBlur(texture2d<half, access::sample> luma, texture2d<half, access::sample> chroma,
                     float2 uv, bool bt2020 = false, bool softToe = false) {
    float2 step = 1.0f / float2(luma.get_width(), luma.get_height());
    half y = (luma.sample(linearSampler, uv + float2(-step.x, -step.y)).r
            + luma.sample(linearSampler, uv + float2(step.x, -step.y)).r
            + luma.sample(linearSampler, uv + float2(-step.x, step.y)).r
            + luma.sample(linearSampler, uv + float2(step.x, step.y)).r) * half(0.25);
    if (!bt2020) return nv12Color(y, chroma.sample(linearSampler, uv).rg);
    half2 cbcr = fma(chroma.sample(linearSampler, uv).rg, half(255.0 / 224.0), half(-128.0 / 224.0));
    return decodeLowYCbCr(nv12Luma(y), cbcr, true, softToe);
}
// Local 3x3 envelope breakout with low-contrast background gating: VT blur on static fine text stays
// inside or adjacent to high-contrast 3x3 extrema (rangeY/rangeC large -> 0 release), while a fast-moving
// icon gliding across a smooth static background breaks out of the local [min3x3, max3x3] envelope.
inline half iconEnvelopeRelease(
    texture2d<half, access::sample> lowA, texture2d<half, access::sample> lowAChroma,
    texture2d<half, access::sample> lowB, texture2d<half, access::sample> lowBChroma,
    texture2d<half, access::sample> lowMid, texture2d<half, access::sample> lowMidChroma,
    float2 uv
) {
    float2 lStep = 1.0f / float2(lowA.get_width(), lowA.get_height());
    half minY = half(1.0);
    half maxY = half(0.0);
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float2 p = uv + float2(float(dx), float(dy)) * lStep;
            half ya = saturate(nv12Luma(lowA.sample(linearSampler, p).r));
            half yb = saturate(nv12Luma(lowB.sample(linearSampler, p).r));
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
        half ya = saturate(nv12Luma(lowA.sample(linearSampler, p).r));
        half yb = saturate(nv12Luma(lowB.sample(linearSampler, p).r));
        minY = min(minY, min(ya, yb));
        maxY = max(maxY, max(ya, yb));
    }
    half rangeY = maxY - minY;
    if (rangeY >= half(0.08)) return half(0.0);
    float2 cStep = 1.0f / float2(lowAChroma.get_width(), lowAChroma.get_height());
    half2 minC = half2(1.0);
    half2 maxC = half2(0.0);
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float2 p = uv + float2(float(dx), float(dy)) * cStep;
            half2 ca = lowAChroma.sample(linearSampler, p).rg;
            half2 cb = lowBChroma.sample(linearSampler, p).rg;
            minC = min(minC, min(ca, cb));
            maxC = max(maxC, max(ca, cb));
        }
    }
    half2 rangeC = (maxC - minC) * half(255.0 / 224.0);
    half maxRangeC = max(rangeC.x, rangeC.y);
    if (maxRangeC >= half(0.07)) return half(0.0);
    half midY = saturate(nv12Luma(lowMid.sample(linearSampler, uv).r));
    half2 midC = lowMidChroma.sample(linearSampler, uv).rg;
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
// Four bilinear taps per output texel; covers both the 0.5 (4K) and 0.75 (1440p) scales.
kernel void shrinkLuma(texture2d<half, access::sample> source [[texture(0)]],
                       texture2d<half, access::write> output [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 size = float2(output.get_width(), output.get_height());
    float2 uv = (float2(gid) + 0.5f) / size;
    float2 o = 0.25f / size;
    half value = (source.sample(linearSampler, uv + float2(-o.x, -o.y)).r
                + source.sample(linearSampler, uv + float2(o.x, -o.y)).r
                + source.sample(linearSampler, uv + float2(-o.x, o.y)).r
                + source.sample(linearSampler, uv + float2(o.x, o.y)).r) * half(0.25);
    output.write(half4(value), gid);
}
kernel void shrinkChroma(texture2d<half, access::sample> source [[texture(0)]],
                         texture2d<half, access::write> output [[texture(1)]],
                         constant float2 &offset [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 size = float2(output.get_width(), output.get_height());
    float2 uv = (float2(gid) + 0.5f) / size + offset;
    float2 o = 0.25f / size;
    half2 value = (source.sample(linearSampler, uv + float2(-o.x, -o.y)).rg
                 + source.sample(linearSampler, uv + float2(o.x, -o.y)).rg
                 + source.sample(linearSampler, uv + float2(-o.x, o.y)).rg
                 + source.sample(linearSampler, uv + float2(o.x, o.y)).rg) * half(0.5) * half(0.5);
    output.write(half4(value, half(0.0), half(0.0)), gid);
}
// Catmull-Rom from nine bilinear taps.
inline float4 catmullRom(texture2d<half, access::sample> image, float2 uv) {
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
    float4 result = float4(image.sample(linearSampler, float2(p0.x, p0.y))) * w0.x * w0.y;
    result += float4(image.sample(linearSampler, float2(p12.x, p0.y))) * w12.x * w0.y;
    result += float4(image.sample(linearSampler, float2(p3.x, p0.y))) * w3.x * w0.y;
    result += float4(image.sample(linearSampler, float2(p0.x, p12.y))) * w0.x * w12.y;
    result += float4(image.sample(linearSampler, float2(p12.x, p12.y))) * w12.x * w12.y;
    result += float4(image.sample(linearSampler, float2(p3.x, p12.y))) * w3.x * w12.y;
    result += float4(image.sample(linearSampler, float2(p0.x, p3.y))) * w0.x * w3.y;
    result += float4(image.sample(linearSampler, float2(p12.x, p3.y))) * w12.x * w3.y;
    result += float4(image.sample(linearSampler, float2(p3.x, p3.y))) * w3.x * w3.y;
    return result;
}
// Edge-aware weighted 5-tap patch mismatch so cross taps across a sharp object silhouette
// do not corrupt motion-vector selection at the 1-pixel boundary.
inline half patchDiff(texture2d<half, access::sample> img, float2 uv, float2 step,
                      half m0, half m1, half m2, half m3, half m4,
                      half wg1, half wg2, half wg3, half wg4, half invW) {
    half d = abs(img.sample(linearSampler, uv).r - m0);
    d += wg1 * abs(img.sample(linearSampler, uv + float2(step.x, 0.0f)).r - m1);
    d += wg2 * abs(img.sample(linearSampler, uv - float2(step.x, 0.0f)).r - m2);
    d += wg3 * abs(img.sample(linearSampler, uv + float2(0.0f, step.y)).r - m3);
    d += wg4 * abs(img.sample(linearSampler, uv - float2(0.0f, step.y)).r - m4);
    return d * invW;
}
// Bit-level IEEE 754 exponent checks survive Metal's default fast-math optimization.
inline bool isFiniteHalf2(half2 value) {
    return (as_type<ushort>(value.x) & 0x7C00u) != 0x7C00u
        && (as_type<ushort>(value.y) & 0x7C00u) != 0x7C00u;
}
inline bool isFiniteMotion(half2 raw, float2 value, bool safeFinite) {
    if (safeFinite) return isFiniteHalf2(raw);
    return isfinite(value.x) && isfinite(value.y);
}
// Evaluates bidirectional motion-vector candidates, edge-aware patch mismatch, forward-backward
// occlusion consistency, and low-frequency static candidacy once per downscaled pixel (1/4 the
// threads of 4K), packing (bestDUV.x, bestDUV.y, lowStatic ? wA + 2 : wA, wB) for full-res merge.
kernel void selectMotion(texture2d<half, access::sample> lowA [[texture(0)]],
                         texture2d<half, access::sample> lowAChroma [[texture(1)]],
                         texture2d<half, access::sample> lowB [[texture(2)]],
                         texture2d<half, access::sample> lowBChroma [[texture(3)]],
                         texture2d<half, access::sample> lowMid [[texture(4)]],
                         texture2d<half, access::sample> motion [[texture(5)]],
                         texture2d<half, access::write> detailOut [[texture(6)]],
                         texture2d<half, access::sample> forwardMotion [[texture(7), function_constant(hasForwardMotion)]],
                         constant float4 &weights [[buffer(0)]],
                         constant float4 &motionScale [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint w = detailOut.get_width(), h = detailOut.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 lowSize = float2(lowA.get_width(), lowA.get_height());
    float2 lowStep = 1.0f / lowSize;
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    uint motionFlags = uint(motionScale.w + 0.5f);
    bool bt2020 = (motionFlags & 3u) >= 1u;
    bool softToe = (motionFlags & 3u) >= 2u;
    bool hudDehalo = (motionFlags & 8u) != 0u;
    bool safeFinite = (motionFlags & 16u) != 0u;
    bool lowStatic = false;
    if (weights.y > 0.5f) {
        half3 la = lowBlur(lowA, lowAChroma, uv, bt2020, softToe);
        half3 lb = lowBlur(lowB, lowBChroma, uv, bt2020, softToe);
        lowStatic = length(la - lb) < half(0.012);
    }
    half2 centerRaw = motion.sample(nearestSampler, uv).rg;
    float2 centerV = float2(centerRaw);
    bool centerFinite = isFiniteMotion(centerRaw, centerV, safeFinite);
    bool centerSmall = !centerFinite || (abs(centerV.x) < 0.25f && abs(centerV.y) < 0.25f);
    if (lowStatic && centerSmall) {
        detailOut.write(half4(half(0.0), half(0.0), half(2.0), half(0.0)), gid);
        return;
    }
    float fwdScale = motionScale.z;
    half2 centerFwdRaw = hasForwardMotion
        ? forwardMotion.sample(nearestSampler, uv).rg : half2(half(0.0));
    float2 centerFwdV = hasForwardMotion ? -float2(centerFwdRaw) * fwdScale : float2(0.0f);
    float2 gridSize = float2(motion.get_width(), motion.get_height());
    float2 gridStep = 1.0f / gridSize;
    float2 gridFrac = fract(uv * gridSize);
    float sx = gridFrac.x < 0.5f ? -1.0f : 1.0f;
    float sy = gridFrac.y < 0.5f ? -1.0f : 1.0f;
    float t = weights.x;
    half m0, m1, m2, m3, m4;
    if (sampleMid) {
        m0 = lowMid.sample(linearSampler, uv).r;
        m1 = lowMid.sample(linearSampler, uv + float2(lowStep.x, 0.0f)).r;
        m2 = lowMid.sample(linearSampler, uv - float2(lowStep.x, 0.0f)).r;
        m3 = lowMid.sample(linearSampler, uv + float2(0.0f, lowStep.y)).r;
        m4 = lowMid.sample(linearSampler, uv - float2(0.0f, lowStep.y)).r;
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
    // Quadrant-nearest 2x2 macroblocks cover horizontal, vertical and diagonal object silhouettes
    // in 4 probes; only residual thin-object edges fall through to forward and opposite cardinals.
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
    int totalCandidates = hasForwardMotion ? 7 : 6;
    for (int i = 0; i < totalCandidates; ++i) {
        if (i == 4 && bestScore < half(0.015)) break;
        if (i == 5 && bestScore < half(0.022)) break;
        half2 rawV;
        float2 v;
        if (i == 0) {
            rawV = centerRaw;
            v = centerV;
        } else if (i < 4) {
            rawV = motion.sample(nearestSampler, uv + probeOffsets[i] * gridStep).rg;
            v = float2(rawV);
        } else if (hasForwardMotion && i == 4) {
            rawV = centerFwdRaw;
            v = centerFwdV;
        } else {
            int idx = hasForwardMotion ? (i - 1) : i;
            rawV = motion.sample(nearestSampler, uv + probeOffsets[idx] * gridStep).rg;
            v = float2(rawV);
        }
        if (!isFiniteMotion(rawV, v, safeFinite) || (abs(v.x) < 0.25f && abs(v.y) < 0.25f)) continue;
        if (i > 0 && ((centerFinite && abs(v.x - centerV.x) < 0.25f && abs(v.y - centerV.y) < 0.25f)
                   || (abs(v.x - lastV.x) < 0.25f && abs(v.y - lastV.y) < 0.25f)
                   || (abs(v.x - bestV.x) < 0.25f && abs(v.y - bestV.y) < 0.25f))) continue;
        lastV = v;
        float2 dUV = v * motionScale.xy;
        float2 uvA = uv + t * dUV;
        float2 uvB = uv - (1.0f - t) * dUV;
        half eA = patchDiff(lowA, uvA, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
        half eB = patchDiff(lowB, uvB, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
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
            half occA = abs(lowA.sample(linearSampler, uvA).r - lowB.sample(linearSampler, uvA).r)
                * half(255.0 / 219.0);
            if (occA < half(0.025)) { bestScore = min(bestScore, bestErrB + half(0.006)); }
        } else if (bestErrA < half(0.018) && bestErrB > bestErrA + half(0.025)) {
            half occB = abs(lowA.sample(linearSampler, uvB).r - lowB.sample(linearSampler, uvB).r)
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
            half ga = lowA.sample(linearSampler, gp).r;
            half gb = lowB.sample(linearSampler, gp).r;
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
            half2 rawV = motion.sample(nearestSampler, uv + hudOffsets[k] * gridStep).rg;
            float2 v = float2(rawV);
            if (!isFiniteMotion(rawV, v, safeFinite) || (abs(v.x) < 0.25f && abs(v.y) < 0.25f)) continue;
            if ((abs(v.x - hudLastV.x) < 0.25f && abs(v.y - hudLastV.y) < 0.25f)
                || (abs(v.x - bestV.x) < 0.25f && abs(v.y - bestV.y) < 0.25f)) continue;
            hudLastV = v;
            float2 dUV = v * motionScale.xy;
            float2 uvA = uv + t * dUV;
            float2 uvB = uv - (1.0f - t) * dUV;
            half eA = patchDiff(lowA, uvA, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
            half eB = patchDiff(lowB, uvB, lowStep, m0, m1, m2, m3, m4, wg1, wg2, wg3, wg4, invW);
            half score = min(eA, eB) + half(0.5) * max(eA, eB);
            if (eB < half(0.018) && eA > eB + half(0.025)) {
                half occA = abs(lowA.sample(linearSampler, uvA).r - lowB.sample(linearSampler, uvA).r)
                    * half(255.0 / 219.0);
                if (occA < half(0.025)) { score = min(score, eB + half(0.006)); }
            } else if (eA < half(0.018) && eB > eA + half(0.025)) {
                half occB = abs(lowA.sample(linearSampler, uvB).r - lowB.sample(linearSampler, uvB).r)
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
    if (hasForwardMotion && (wA + wB > half(0.02))) {
        float2 uvA = uv + t * bestDUV;
        float2 uvB = uv - (1.0f - t) * bestDUV;
        half2 rawAB = forwardMotion.sample(nearestSampler, uvA).rg;
        half2 rawBA = motion.sample(nearestSampler, uvB).rg;
        float2 vABatA = float2(rawAB) * fwdScale;
        float2 vBAatB = float2(rawBA);
        float fbThresh = max(2.5f, 0.25f * length(bestV));
        if (isFiniteMotion(rawAB, vABatA, safeFinite) && bestErrA > bestErrB + half(0.005)) {
            float fbA = length(vABatA + bestV);
            if (fbA > fbThresh) {
                wA *= smoothstep(half(fbThresh * 2.0f), half(fbThresh), half(fbA));
            }
        }
        if (isFiniteMotion(rawBA, vBAatB, safeFinite) && bestErrB > bestErrA + half(0.005)) {
            float fbB = length(vBAatB - bestV);
            if (fbB > fbThresh) {
                wB *= smoothstep(half(fbThresh * 2.0f), half(fbThresh), half(fbB));
            }
        }
    }
    detailOut.write(half4(half(bestDUV.x), half(bestDUV.y), lowStatic ? (wA + half(2.0)) : wA, wB), gid);
}
// A pixel that is unchanged in both native sources and in their blurred downscaled copies keeps the
// native value; elsewhere VT's midpoint is upscaled with Catmull-Rom, with optional motion-guided
// native high-frequency detail transfer and overshoot-clamped adaptive sharpening.
kernel void merge(texture2d<half, access::sample> a [[texture(0)]],
                  texture2d<half, access::sample> b [[texture(1)]],
                  texture2d<half, access::sample> aChroma [[texture(2), function_constant(nv12)]],
                  texture2d<half, access::sample> bChroma [[texture(3), function_constant(nv12)]],
                  texture2d<half, access::sample> lowA [[texture(4)]],
                  texture2d<half, access::sample> lowAChroma [[texture(5)]],
                  texture2d<half, access::sample> lowB [[texture(6)]],
                  texture2d<half, access::sample> lowBChroma [[texture(7)]],
                  texture2d<half, access::sample> lowMid [[texture(8)]],
                  texture2d<half, access::sample> lowMidChroma [[texture(9)]],
                  texture2d<half, access::write> output [[texture(10)]],
                  texture2d<half, access::sample> motionDetail [[texture(11), function_constant(hasMotion)]],
                  constant float4 &offsets [[buffer(0)]],
                  constant float4 &weights [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5f) / float2(output.get_width(), output.get_height());
    uint qualityFlags = uint(weights.w + 0.5f);
    bool bt2020 = (qualityFlags & 3u) >= 1u;
    bool softToe = (qualityFlags & 3u) >= 2u;
    bool iconEnvelope = (qualityFlags & 16u) != 0u;
    half4 md = half4(0.0);
    bool lowStatic = false;
    if (hasMotion) {
        md = motionDetail.sample(nearestSampler, uv);
        lowStatic = md.z >= half(1.5);
        if (lowStatic) md.z -= half(2.0);
    } else if (weights.y > 0.5f) {
        half3 la = lowBlur(lowA, lowAChroma, uv, bt2020, softToe), lb = lowBlur(lowB, lowBChroma, uv, bt2020, softToe);
        lowStatic = length(la - lb) < half(0.012);
    }
    half staticW = half(0.0);
    half3 staticColor = half3(0.0);
    if (lowStatic) {
        half3 ca = sourceColor(a, aChroma, uv, offsets.xy), cb = sourceColor(b, bChroma, uv, offsets.zw);
        if (length(ca - cb) < half(0.014)) {
            half release = iconEnvelope
                ? iconEnvelopeRelease(lowA, lowAChroma, lowB, lowBChroma, lowMid, lowMidChroma, uv)
                : half(0.0);
            staticW = half(1.0) - release;
            staticColor = mix(ca, cb, half(weights.x));
            if (staticW >= half(0.999)) {
                output.write(half4(staticColor, half(1.0)), gid);
                return;
            }
        }
    }
    half midRawY = half(catmullRom(lowMid, uv).r);
    half2 midUV = lowMidChroma.sample(linearSampler, uv).rg;
    half3 midpoint = nv12Color(midRawY, midUV);
    half3 color = midpoint;
    if (hasMotion) {
        half wA = md.z;
        half wB = md.w;
        if (wA + wB > half(0.02)) {
            float t = weights.x;
            float2 bestDUV = float2(md.xy);
            float2 uvA = uv + t * bestDUV;
            float2 uvB = uv - (1.0f - t) * bestDUV;
            half3 srcA = midpoint, srcB = midpoint;
            half3 hiA = half3(0.0), hiB = half3(0.0);
            if (wA > half(0.01)) {
                srcA = sourceColor(a, aChroma, uvA, offsets.xy);
                half3 baseA = nv12Color(
                    lowA.sample(linearSampler, uvA).r, lowAChroma.sample(linearSampler, uvA).rg);
                hiA = srcA - baseA;
            }
            if (wB > half(0.01)) {
                srcB = sourceColor(b, bChroma, uvB, offsets.zw);
                half3 baseB = nv12Color(
                    lowB.sample(linearSampler, uvB).r, lowBChroma.sample(linearSampler, uvB).rg);
                hiB = srcB - baseB;
            }
            half wa = half(1.0 - t) * wA;
            half wb = half(t) * wB;
            half3 detail = (hiA * wa + hiB * wb) / max(wa + wb, half(1e-4));
            half conf = max(wA, wB);
            half3 envMin = min(midpoint, min(wA > half(0.1) ? srcA : midpoint, wB > half(0.1) ? srcB : midpoint));
            half3 envMax = max(midpoint, max(wA > half(0.1) ? srcA : midpoint, wB > half(0.1) ? srcB : midpoint));
            color = clamp(midpoint + conf * detail, envMin, envMax);
        }
    }
    if (weights.z > 0.001f) {
        float2 s = 0.75f / float2(lowMid.get_width(), lowMid.get_height());
        half y = dot(color, half3(0.2126, 0.7152, 0.0722));
        half n = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(0.0f, -s.y)).r));
        half so = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(0.0f, s.y)).r));
        half e = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(s.x, 0.0f)).r));
        half w = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(-s.x, 0.0f)).r));
        half mn = min(y, min(min(n, so), min(e, w)));
        half mx = max(y, max(max(n, so), max(e, w)));
        half amp = clamp(min(mn, half(1.0) - mx) / max(mx, half(1e-4)), half(0.0), half(1.0));
        half k = -half(weights.z) * sqrt(amp);
        half sharpY = clamp((y + k * (n + so + e + w)) / (half(1.0) + half(4.0) * k), mn, mx);
        color = saturate(color + half3(sharpY - y));
    }
    if (staticW > half(0.001)) {
        color = mix(color, staticColor, staticW);
    }
    output.write(half4(color, half(1.0)), gid);
}
inline half lumaToNV12Y(half y) {
    return clamp(fma(y, half(219.0 / 255.0), half(16.0 / 255.0)), half(16.0 / 255.0), half(235.0 / 255.0));
}
// Emits native Rec.709 420v (12.4 MB vs 33.2 MB BGRA at 4K), running 1 thread per 2x2 luma block.
// At exact 2:1 (4K from 1080p), a 20x20 threadgroup tile computes exact separable Catmull-Rom and
// 4-tap CAS directly from SRAM (replacing 80 lowMid texture fetches/block), while operating purely
// in YCbCr with smooth static/dynamic feathering to eliminate RGB round-trips and HUD edge shimmer.
kernel void mergeNV12Out(texture2d<half, access::sample> a [[texture(0)]],
                         texture2d<half, access::sample> b [[texture(1)]],
                         texture2d<half, access::sample> aChroma [[texture(2)]],
                         texture2d<half, access::sample> bChroma [[texture(3)]],
                         texture2d<half, access::sample> lowA [[texture(4)]],
                         texture2d<half, access::sample> lowAChroma [[texture(5)]],
                         texture2d<half, access::sample> lowB [[texture(6)]],
                         texture2d<half, access::sample> lowBChroma [[texture(7)]],
                         texture2d<half, access::sample> lowMid [[texture(8)]],
                         texture2d<half, access::sample> lowMidChroma [[texture(9)]],
                         texture2d<half, access::write> outY [[texture(10)]],
                         texture2d<half, access::write> outUV [[texture(11)]],
                         texture2d<half, access::sample> motionDetail [[texture(12), function_constant(hasMotion)]],
                         constant float4 &offsets [[buffer(0)]],
                         constant float4 &weights [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]],
                         uint2 tid [[thread_position_in_threadgroup]],
                         uint2 tgSize [[threads_per_threadgroup]]) {
    threadgroup half midTile[20][20];
    if (exactTwoX) {
        int2 groupBase = int2(gid) - int2(tid);
        int lowW = int(lowMid.get_width());
        int lowH = int(lowMid.get_height());
        uint tgCount = tgSize.x * tgSize.y;
        uint linearTid = tid.y * tgSize.x + tid.x;
        for (uint idx = linearTid; idx < 400; idx += tgCount) {
            uint ty = idx / 20;
            uint tx = idx - ty * 20;
            int sx = clamp(groupBase.x + int(tx) - 2, 0, lowW - 1);
            int sy = clamp(groupBase.y + int(ty) - 2, 0, lowH - 1);
            midTile[ty][tx] = nv12Luma(lowMid.read(uint2(sx, sy)).r);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    uint halfW = outUV.get_width(), halfH = outUV.get_height();
    if (gid.x >= halfW || gid.y >= halfH) return;
    uint2 base = gid * 2;
    float2 invFull = 1.0f / float2(outY.get_width(), outY.get_height());
    float2 uvCenter = (float2(base) + 1.0f) * invFull;
    uint qualityFlags = uint(weights.w + 0.5f);
    bool bt2020 = (qualityFlags & 3u) >= 1u;
    bool softToe = (qualityFlags & 3u) >= 2u;
    half4 md = half4(0.0);
    bool lowStatic = false;
    if (hasMotion) {
        md = motionDetail.sample(nearestSampler, uvCenter);
        lowStatic = md.z >= half(1.5);
        if (lowStatic) md.z -= half(2.0);
    } else if (weights.y > 0.5f) {
        half3 la = lowBlur(lowA, lowAChroma, uvCenter, bt2020, softToe);
        half3 lb = lowBlur(lowB, lowBChroma, uvCenter, bt2020, softToe);
        lowStatic = length(la - lb) < half(0.012);
    }
    half tHalf = half(weights.x);
    bool hudDehalo = (qualityFlags & 4u) != 0u;
    bool iconEnvelope = (qualityFlags & 16u) != 0u;
    half iconRelease = (iconEnvelope && lowStatic)
        ? iconEnvelopeRelease(lowA, lowAChroma, lowB, lowBChroma, lowMid, lowMidChroma, uvCenter)
        : half(0.0);
    half pairedConfidence = (qualityFlags & 8u) != 0u && hasMotion
        ? smoothstep(half(0.25), half(0.80), min(md.z, md.w)) : half(0.0);
    half2 caUV = half2(0.0), cbUV = half2(0.0);
    half yA[4] = { half(0.0), half(0.0), half(0.0), half(0.0) };
    half yB[4] = { half(0.0), half(0.0), half(0.0), half(0.0) };
    half diff2[4] = { half(1.0), half(1.0), half(1.0), half(1.0) };
    if (lowStatic) {
        caUV = aChroma.sample(linearSampler, uvCenter + offsets.xy).rg;
        cbUV = bChroma.sample(linearSampler, uvCenter + offsets.zw).rg;
        yA[0] = a.sample(nearestSampler, (float2(base) + float2(0.5f, 0.5f)) * invFull).r;
        yB[0] = b.sample(nearestSampler, (float2(base) + float2(0.5f, 0.5f)) * invFull).r;
        yA[1] = a.sample(nearestSampler, (float2(base) + float2(1.5f, 0.5f)) * invFull).r;
        yB[1] = b.sample(nearestSampler, (float2(base) + float2(1.5f, 0.5f)) * invFull).r;
        yA[2] = a.sample(nearestSampler, (float2(base) + float2(0.5f, 1.5f)) * invFull).r;
        yB[2] = b.sample(nearestSampler, (float2(base) + float2(0.5f, 1.5f)) * invFull).r;
        yA[3] = a.sample(nearestSampler, (float2(base) + float2(1.5f, 1.5f)) * invFull).r;
        yB[3] = b.sample(nearestSampler, (float2(base) + float2(1.5f, 1.5f)) * invFull).r;
        half2 dCbCr = (caUV - cbUV) * half(255.0 / 224.0);
        half dR = bt2020 ? (half(1.4746) * dCbCr.y) : (half(1.5748) * dCbCr.y);
        half dG = bt2020
            ? fma(half(-0.57135), dCbCr.y, half(-0.16455) * dCbCr.x)
            : fma(half(-0.468124), dCbCr.y, half(-0.187324) * dCbCr.x);
        half dB = bt2020 ? (half(1.8814) * dCbCr.x) : (half(1.8556) * dCbCr.x);
        for (uint k = 0; k < 4; ++k) {
            half dY = (yA[k] - yB[k]) * half(255.0 / 219.0);
            half r = dY + dR;
            half g = dY + dG;
            half bl = dY + dB;
            diff2[k] = r * r + g * g + bl * bl;
        }
        if (pairedConfidence == half(0.0) && iconRelease < half(0.001)
            && max(max(diff2[0], diff2[1]), max(diff2[2], diff2[3])) < half(0.014 * 0.014)) {
            outY.write(half4(mix(yA[0], yB[0], tHalf)), base);
            outY.write(half4(mix(yA[1], yB[1], tHalf)), base + uint2(1, 0));
            outY.write(half4(mix(yA[2], yB[2], tHalf)), base + uint2(0, 1));
            outY.write(half4(mix(yA[3], yB[3], tHalf)), base + uint2(1, 1));
            outUV.write(half4(mix(caUV, cbUV, tHalf), half(0.0), half(0.0)), gid);
            return;
        }
    }
    half2 midUV = lowMidChroma.sample(linearSampler, uvCenter).rg;
    float t = weights.x;
    float2 bestDUV = float2(md.xy);
    half wA = md.z;
    half wB = md.w;
    bool applyMotion = hasMotion && (wA + wB > half(0.02));
    half wa = half(1.0 - t) * wA;
    half wb = half(t) * wB;
    half invWAB = half(1.0) / max(wa + wb, half(1e-4));
    half conf = max(wA, wB);
    half2 outChroma = midUV;
    if (applyMotion) {
        float2 uvAC = uvCenter + t * bestDUV;
        float2 uvBC = uvCenter - (1.0f - t) * bestDUV;
        half2 srcAUV = midUV, srcBUV = midUV;
        half2 hiAUV = half2(0.0), hiBUV = half2(0.0);
        if (wA > half(0.01)) {
            srcAUV = aChroma.sample(linearSampler, uvAC + offsets.xy).rg;
            hiAUV = srcAUV - lowAChroma.sample(linearSampler, uvAC).rg;
        }
        if (wB > half(0.01)) {
            srcBUV = bChroma.sample(linearSampler, uvBC + offsets.zw).rg;
            hiBUV = srcBUV - lowBChroma.sample(linearSampler, uvBC).rg;
        }
        half2 detailUV = (hiAUV * wa + hiBUV * wb) * invWAB;
        half2 uvMin = min(midUV, min(wA > half(0.1) ? srcAUV : midUV, wB > half(0.1) ? srcBUV : midUV));
        half2 uvMax = max(midUV, max(wA > half(0.1) ? srcAUV : midUV, wB > half(0.1) ? srcBUV : midUV));
        outChroma = clamp(midUV + conf * detailUV, uvMin, uvMax);
    }
    half catY[4];
    half t00 = half(0.0), t01 = half(0.0), t02 = half(0.0);
    half t10 = half(0.0), t11 = half(0.0), t12 = half(0.0);
    half t20 = half(0.0), t21 = half(0.0), t22 = half(0.0);
    if (exactTwoX) {
        uint lx = tid.x + 2;
        uint ly = tid.y + 2;
        const half c0 = half(-3.0 / 128.0);
        const half c1 = half(29.0 / 128.0);
        const half c2 = half(111.0 / 128.0);
        const half c3 = half(-9.0 / 128.0);
        half rowL[5];
        half rowR[5];
        for (uint r = 0; r < 5; ++r) {
            uint ry = ly - 2 + r;
            half s0 = midTile[ry][lx - 2];
            half s1 = midTile[ry][lx - 1];
            half s2 = midTile[ry][lx];
            half s3 = midTile[ry][lx + 1];
            half s4 = midTile[ry][lx + 2];
            rowL[r] = fma(c0, s0, fma(c1, s1, fma(c2, s2, c3 * s3)));
            rowR[r] = fma(c3, s1, fma(c2, s2, fma(c1, s3, c0 * s4)));
        }
        catY[0] = saturate(fma(c0, rowL[0], fma(c1, rowL[1], fma(c2, rowL[2], c3 * rowL[3]))));
        catY[1] = saturate(fma(c0, rowR[0], fma(c1, rowR[1], fma(c2, rowR[2], c3 * rowR[3]))));
        catY[2] = saturate(fma(c3, rowL[1], fma(c2, rowL[2], fma(c1, rowL[3], c0 * rowL[4]))));
        catY[3] = saturate(fma(c3, rowR[1], fma(c2, rowR[2], fma(c1, rowR[3], c0 * rowR[4]))));
        if (weights.z > 0.001f) {
            t00 = saturate(midTile[ly - 1][lx - 1]);
            t01 = saturate(midTile[ly - 1][lx]);
            t02 = saturate(midTile[ly - 1][lx + 1]);
            t10 = saturate(midTile[ly][lx - 1]);
            t11 = saturate(midTile[ly][lx]);
            t12 = saturate(midTile[ly][lx + 1]);
            t20 = saturate(midTile[ly + 1][lx - 1]);
            t21 = saturate(midTile[ly + 1][lx]);
            t22 = saturate(midTile[ly + 1][lx + 1]);
        }
    }
    float2 casStep = 0.75f / float2(lowMid.get_width(), lowMid.get_height());
    half staticWeightSum = half(0.0);
    for (uint dy = 0; dy < 2; ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            uint k = dy * 2 + dx;
            uint2 px = base + uint2(dx, dy);
            half staticW = lowStatic
                ? smoothstep(half(0.022), half(0.011), sqrt(diff2[k])) * (half(1.0) - iconRelease)
                : half(0.0);
            if (staticW >= half(0.999) && pairedConfidence == half(0.0)) {
                staticWeightSum += staticW;
                outY.write(half4(mix(yA[k], yB[k], tHalf)), px);
                continue;
            }
            float2 uv = (float2(px) + 0.5f) * invFull;
            half midY = exactTwoX ? catY[k] : saturate(nv12Luma(half(catmullRom(lowMid, uv).r)));
            half y = midY;
            half alignedY = midY;
            half alignedWeight = half(0.0);
            if (applyMotion) {
                float2 uvA = uv + t * bestDUV;
                float2 uvB = uv - (1.0f - t) * bestDUV;
                half srcAY = midY, srcBY = midY;
                half baseAY = midY, baseBY = midY;
                half hiAY = half(0.0), hiBY = half(0.0);
                if (wA > half(0.01)) {
                    srcAY = saturate(nv12Luma(a.sample(linearSampler, uvA).r));
                    baseAY = saturate(nv12Luma(lowA.sample(linearSampler, uvA).r));
                    hiAY = srcAY - baseAY;
                }
                if (wB > half(0.01)) {
                    srcBY = saturate(nv12Luma(b.sample(linearSampler, uvB).r));
                    baseBY = saturate(nv12Luma(lowB.sample(linearSampler, uvB).r));
                    hiBY = srcBY - baseBY;
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
                    half agrees = half(1.0) - smoothstep(half(0.012), half(0.04), abs(srcAY - srcBY));
                    alignedWeight = pairedConfidence * agrees;
                    alignedY = mix(srcAY, srcBY, tHalf);
                    if (staticW > half(0.0)) {
                        // A thin moving stroke can lie between its two original positions.
                        // Require its direction of contrast change to agree with the VT midpoint.
                        half originalY = nv12Luma(mix(yA[k], yB[k], tHalf));
                        half movement = clamp(sign(alignedY - originalY) * (midY - originalY),
                                              half(0.0), half(1.0));
                        staticW *= half(1.0)
                            - alignedWeight * smoothstep(half(0.025), half(0.10), movement);
                    }
                }
            } else if (hudDehalo && !lowStatic && weights.y > 0.5f) {
                half syA = a.sample(nearestSampler, uv).r;
                half syB = b.sample(nearestSampler, uv).r;
                half dSY = abs(syA - syB) * half(255.0 / 219.0);
                if (dSY < half(0.012)) {
                    half lowAY = saturate(nv12Luma(lowA.sample(linearSampler, uv).r));
                    half lowBY = saturate(nv12Luma(lowB.sample(linearSampler, uv).r));
                    half midDev = max(half(0.0), max(min(lowAY, lowBY) - midY, midY - max(lowAY, lowBY)));
                    half2 scA = aChroma.sample(linearSampler, uvCenter + offsets.xy).rg;
                    half2 scB = bChroma.sample(linearSampler, uvCenter + offsets.zw).rg;
                    half dSC = length((scA - scB) * half(255.0 / 224.0));
                    half strokeW = (half(1.0) - smoothstep(half(0.005), half(0.012), dSY))
                        * (half(1.0) - smoothstep(half(0.012), half(0.024), dSC))
                        * (half(1.0) - smoothstep(half(0.025), half(0.065), midDev));
                    if (strokeW > half(0.01)) {
                        yA[k] = syA;
                        yB[k] = syB;
                        caUV = scA;
                        cbUV = scB;
                        staticW = max(staticW, strokeW);
                    }
                }
            }
            if (weights.z > 0.001f) {
                half n, so, e, w;
                if (exactTwoX) {
                    if (dx == 0) {
                        half xm0 = fma(half(0.25), t00, half(0.75) * t01);
                        half xm1 = fma(half(0.25), t10, half(0.75) * t11);
                        half xm2 = fma(half(0.25), t20, half(0.75) * t21);
                        if (dy == 0) {
                            n = xm0;
                            so = (xm1 + xm2) * half(0.5);
                            w = fma(half(0.25), t00, half(0.75) * t10);
                            e = fma(half(0.125), t01 + t02, half(0.375) * (t11 + t12));
                        } else {
                            n = (xm0 + xm1) * half(0.5);
                            so = xm2;
                            w = fma(half(0.75), t10, half(0.25) * t20);
                            e = fma(half(0.375), t11 + t12, half(0.125) * (t21 + t22));
                        }
                    } else {
                        half xp0 = fma(half(0.75), t01, half(0.25) * t02);
                        half xp1 = fma(half(0.75), t11, half(0.25) * t12);
                        half xp2 = fma(half(0.75), t21, half(0.25) * t22);
                        if (dy == 0) {
                            n = xp0;
                            so = (xp1 + xp2) * half(0.5);
                            w = fma(half(0.125), t00 + t01, half(0.375) * (t10 + t11));
                            e = fma(half(0.25), t02, half(0.75) * t12);
                        } else {
                            n = (xp0 + xp1) * half(0.5);
                            so = xp2;
                            w = fma(half(0.375), t10 + t11, half(0.125) * (t20 + t21));
                            e = fma(half(0.75), t12, half(0.25) * t22);
                        }
                    }
                } else {
                    n = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(0.0f, -casStep.y)).r));
                    so = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(0.0f, casStep.y)).r));
                    e = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(casStep.x, 0.0f)).r));
                    w = saturate(nv12Luma(lowMid.sample(linearSampler, uv + float2(-casStep.x, 0.0f)).r));
                }
                half mn = min(y, min(min(n, so), min(e, w)));
                half mx = max(y, max(max(n, so), max(e, w)));
                half amp = clamp(min(mn, half(1.0) - mx) / max(mx, half(1e-4)), half(0.0), half(1.0));
                half kCas = -half(weights.z) * sqrt(amp);
                y = clamp((y + kCas * (n + so + e + w)) / (half(1.0) + half(4.0) * kCas), mn, mx);
            }
            half yRaw = lumaToNV12Y(mix(y, alignedY, alignedWeight));
            staticWeightSum += staticW;
            if (staticW > half(0.001)) {
                yRaw = mix(yRaw, mix(yA[k], yB[k], tHalf), staticW);
            }
            outY.write(half4(yRaw), px);
        }
    }
    if (staticWeightSum > half(0.001)) {
        outChroma = mix(outChroma, mix(caUV, cbUV, tHalf), min(half(1.0), staticWeightSum * half(0.25)));
    }
    outUV.write(half4(outChroma, half(0.0), half(0.0)), gid);
}
