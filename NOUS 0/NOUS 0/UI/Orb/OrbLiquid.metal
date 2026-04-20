#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Hash / noise — lightweight, no lookup table.
static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

static inline float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        v += vnoise(p) * amp;
        p *= 2.02;
        amp *= 0.5;
    }
    return v;
}

// SwiftUI colorEffect: position (pixel coords), existing color -> new color.
// args: time (s), amp (0..1), touch (normalized 0..1), phos (RGBA premultiplied).
[[ stitchable ]] half4 orbLiquid(
    float2 position,
    half4 color,
    float time,
    float amp,
    float2 touch,
    half4 phos
) {
    // Diameter is the caller's view size. Use position directly assuming Canvas passes raw pixels;
    // we normalize against an assumed 88pt max frame (shader should self-scale).
    float2 uv = position / 88.0 - 0.5;
    float r = length(uv);

    // Idle flow
    float t = time;
    float flow = fbm(uv * 2.2 + float2(sin(t * 0.25), cos(t * 0.18)));

    // Voice boil: amp drives turbulence freq + magnitude.
    float boilFreq = 4.0 + amp * 7.0;
    float boilSpd = 0.6 + amp * 2.5;
    float boil = fbm(uv * boilFreq + float2(t * boilSpd, -t * boilSpd * 0.7));

    float turb = mix(flow * 0.14, boil * (0.25 + amp * 0.55), amp);

    // Touch attractor bulge
    float2 tc = touch - 0.5;
    float pull = exp(-length(uv - tc) * 6.0) * 0.18 * max(amp, 0.35);

    // Inner glow falloff
    float falloff = smoothstep(0.5, 0.0, r + turb * 0.4 + pull);

    // Phosphor tint
    half3 rgb = mix(color.rgb, phos.rgb, (half)falloff * half(0.78));

    // Alpha: transparent outside, denser toward core; respect source alpha.
    float edge = smoothstep(0.52, 0.42, r);
    half a = color.a * (half)edge + (half)falloff * half(0.45) * (half)edge;

    // Specular rim near top-left — meniscus
    float spec = smoothstep(0.44, 0.30, length(uv - float2(-0.12, -0.18))) * 0.20 * (1.0 - amp * 0.6);
    rgb += half3(spec);

    return half4(rgb, clamp(a, half(0.0), half(1.0)));
}
