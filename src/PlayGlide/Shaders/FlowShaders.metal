#include <metal_stdlib>
using namespace metal;
constant bool nv12 [[function_constant(0)]];
constant bool selectOcclusion [[function_constant(1)]];
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
// Bit-level IEEE 754 exponent checks survive Metal's default fast-math optimization.
inline bool isFiniteHalf(half value) {
    return (as_type<ushort>(value) & 0x7C00u) != 0x7C00u;
}
inline half3 nv12Color(half luma, half2 chroma) {
    half y = fma(luma, half(255.0 / 219.0), half(-16.0 / 219.0));
    half2 cbcr = fma(chroma, half(255.0 / 224.0), half(-128.0 / 224.0));
    return saturate(half3(
        fma(half(1.5748), cbcr.y, y),
        fma(half(-0.468124), cbcr.y, fma(half(-0.187324), cbcr.x, y)),
        fma(half(1.8556), cbcr.x, y)));
}
// chromaOffset moves from chroma texel centers to the sample positions of the surface's 4:2:0 siting.
inline half3 colorAt(texture2d<half, access::sample> image, texture2d<half, access::sample> chroma, float2 uv,
                     float2 chromaOffset) {
    half3 value = image.sample(linearSampler, uv).rgb;
    if (!nv12) return value;
    return nv12Color(value.r, chroma.sample(linearSampler, uv + chromaOffset).rg);
}
inline half valid(float2 p) { return all(p >= 0.0f) && all(p <= 1.0f) ? half(1.0) : half(0.0); }
inline float2 flowAt(texture2d<half, access::sample> field, float2 uv) {
    half2 value = field.sample(linearSampler, uv).xy;
    return (isFiniteHalf(value.x) && isFiniteHalf(value.y)) ? float2(value) : float2(0.0f);
}
kernel void downscale(texture2d<half, access::sample> image [[texture(0)]],
                      texture2d<half, access::write> output [[texture(1)]],
                      texture2d<half, access::sample> chroma [[texture(2), function_constant(nv12)]],
                      constant float2 &chromaOffset [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 outSize = float2(output.get_width(), output.get_height());
    float2 base = (float2(gid) + 0.5f) / outSize;
    half3 color;
    if (image.get_width() == output.get_width() && image.get_height() == output.get_height()) {
        color = colorAt(image, chroma, base, chromaOffset);
    } else {
        float2 offset = 0.25f / outSize;
        color = (colorAt(image, chroma, base + float2(-offset.x, -offset.y), chromaOffset)
               + colorAt(image, chroma, base + float2( offset.x, -offset.y), chromaOffset)
               + colorAt(image, chroma, base + float2(-offset.x,  offset.y), chromaOffset)
               + colorAt(image, chroma, base + float2( offset.x,  offset.y), chromaOffset)) * half(0.25);
    }
    output.write(half4(saturate(color), half(1.0)), gid);
}
kernel void interpolate(texture2d<half, access::sample> a [[texture(0)]],
                        texture2d<half, access::sample> b [[texture(1)]],
                        texture2d<half, access::sample> forward [[texture(2)]],
                        texture2d<half, access::sample> backward [[texture(3)]],
                        texture2d<half, access::write> output [[texture(4)]],
                        texture2d<half, access::sample> aChroma [[texture(5), function_constant(nv12)]],
                        texture2d<half, access::sample> bChroma [[texture(6), function_constant(nv12)]],
                        constant float4 &parameters [[buffer(0)]],
                        constant float4 &chromaOffsets [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5f) / float2(output.get_width(), output.get_height());
    float2 invFlowSize = 1.0f / parameters.yz;
    float phase = parameters.x;
    float2 aOffset = chromaOffsets.xy, bOffset = chromaOffsets.zw;
    float2 originalForward = flowAt(forward, uv), originalBackward = flowAt(backward, uv);
    float motionSum = length(originalForward) + length(originalBackward);
    bool lowMotion = motionSum < 0.1f;
    if (!lowMotion && motionSum < parameters.w) {
        // An unchanged pixel under small estimated motion keeps its exact source value, so static
        // fine detail does not alternate between source and resampled images.
        half3 originalA = colorAt(a, aChroma, uv, aOffset), originalB = colorAt(b, bChroma, uv, bOffset);
        if (length(originalA - originalB) < half(0.006)) {
            output.write(half4(originalA, half(1.0)), gid);
            return;
        }
    }
    half3 fallbackColor = half3(0.0);
    if (lowMotion) {
        half3 originalA = colorAt(a, aChroma, uv, aOffset), originalB = colorAt(b, bChroma, uv, bOffset);
        if (length(originalA - originalB) < half(0.006)) {
            output.write(half4(originalA, half(1.0)), gid);
            return;
        }
        fallbackColor = phase < 0.5f ? originalA : originalB;
    }
    float2 p = mix(uv, uv - phase * originalForward * invFlowSize, 0.8f);
    float2 q = mix(uv, uv - (1.0f - phase) * originalBackward * invFlowSize, 0.8f);
    for (int i = 1; i < 4; ++i) {
        p = mix(p, uv - phase * flowAt(forward, p) * invFlowSize, 0.8f);
        q = mix(q, uv - (1.0f - phase) * flowAt(backward, q) * invFlowSize, 0.8f);
    }
    float2 f = flowAt(forward, p);
    float2 r = flowAt(backward, q);
    float2 nextP = p + f * invFlowSize, previousQ = q + r * invFlowSize;
    half3 ca = colorAt(a, aChroma, p, aOffset), cb = colorAt(b, bChroma, q, bOffset);
    half errorA = half(min(length(f + flowAt(backward, nextP)), 100.0f));
    half errorB = half(min(length(r + flowAt(forward, previousQ)), 100.0f));
    half photoA = length(ca - colorAt(b, bChroma, nextP, bOffset));
    half photoB = length(cb - colorAt(a, aChroma, previousQ, aOffset));
    half hPhase = half(phase);
    half wa = valid(p) * valid(nextP) * exp(fma(half(-8.0), photoA, half(-0.7) * errorA)) * (half(1.0) - hPhase);
    half wb = valid(q) * valid(previousQ) * exp(fma(half(-8.0), photoB, half(-0.7) * errorB)) * hPhase;
    if (!isFiniteHalf(wa)) wa = half(0.0);
    if (!isFiniteHalf(wb)) wb = half(0.0);
    half weightSum = wa + wb;
    half3 color;
    if (weightSum < half(0.05)) {
        if (lowMotion) color = fallbackColor;
        else color = phase < 0.5f ? colorAt(a, aChroma, uv, aOffset) : colorAt(b, bChroma, uv, bOffset);
    } else {
        color = (wa * ca + wb * cb) / weightSum;
        if (selectOcclusion && !lowMotion && length(ca - cb) > half(0.08)) {
            // Cancel the blend's phase bias before comparing the two directions.
            half confidenceA = wa * hPhase;
            half confidenceB = wb * (half(1.0) - hPhase);
            if (confidenceA > half(4.0) * confidenceB) color = ca;
            else if (confidenceB > half(4.0) * confidenceA) color = cb;
        }
    }
    output.write(half4(saturate(color), half(1.0)), gid);
}
