#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// How a part of a life comes into focus.
//
// This replaces a CPU pipeline that pre-rendered every stage into cached bitmaps. Doing it
// on the GPU matters for three reasons beyond speed: the SOURCE can now be anything a
// SwiftUI view can draw (a bought icon, an SVG, a live animation) rather than only something
// we can generate; the arc is continuous rather than stepped through a handful of cached
// images; and a picture can keep animating WHILE it is pixellated, which a pre-rendered
// bitmap can never do.
//
// Two effects, applied together:
//
//   Blocks — sample the layer at the centre of each cell instead of at the pixel, which is
//   what makes a block a block.
//
//   Dissolve — drop whole cells at random, so an unfinished part is genuinely incomplete
//   rather than merely coarse. Coarseness alone can't hold a simple shape back: a heart at
//   five blocks across is still unmistakably a heart, so a young Heart read as finished
//   while a young Mind read as nothing. The hash is a pure function of the cell, so the
//   scatter is stable frame to frame and never crawls.

static inline float cellNoise(float2 cell, float seed) {
    return fract(sin(dot(cell + seed, float2(12.9898, 78.233))) * 43758.5453);
}

[[ stitchable ]]
half4 resolve(float2 position, SwiftUI::Layer layer, float block, float missing, float seed) {
    // Whole — no grid at all, and no cost beyond one sample.
    if (block <= 1.0) {
        return layer.sample(position);
    }

    float2 cell = floor(position / block);

    if (missing > 0.0 && cellNoise(cell, seed) < missing) {
        return half4(0.0h);
    }

    // AVERAGE the cell rather than sampling its centre. A single tap is either on the
    // picture or off it, so edge cells vanish entirely and a young form is three stray
    // squares instead of a soft mass — the CPU version got this for free by downscaling,
    // which is a box filter by another name. Sixteen taps is cheap and restores the partial
    // coverage that makes an early shape read as something rather than nothing.
    const int N = 4;
    half4 acc = half4(0.0h);
    for (int i = 0; i < N; ++i) {
        for (int j = 0; j < N; ++j) {
            float2 offset = (float2(i, j) + 0.5) / float(N);
            acc += layer.sample(cell * block + block * offset);
        }
    }
    return acc / half(N * N);
}
