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
    // Tap count follows the block: a big cell needs several samples to know what is in it,
    // a small one does not, and a fixed sixteen everywhere is most of this shader's cost on
    // a screen holding seven of them.
    int N = clamp(int(block / 4.0), 2, 4);
    half4 acc = half4(0.0h);
    for (int i = 0; i < N; ++i) {
        for (int j = 0; j < N; ++j) {
            float2 offset = (float2(i, j) + 0.5) / float(N);
            acc += layer.sample(cell * block + block * offset);
        }
    }
    return acc / half(N * N);
}

// A life coming back a patch at a time, and each axis owning its own patches.
//
// The first arrangement drew the body as four layers — head, chest, hips, shoulders — each
// masked to an anatomical region. Around the torso all four masks reach at once, so four
// partly-opaque copies of one person stacked up and the middle sat there dense and dark. The
// second drew ONE layer at one maturity, which fixed the torso and meant a single new link
// nudged the whole figure very slightly: nothing you could ever see happen.
//
// Neither is how a life actually fills in. It fills in unevenly and in patches, and a single
// connection ought to light up a few squares SOMEWHERE rather than move everything a hair.
//
// So every cell is dealt an owner — by the same hash that scatters the dissolve, so the
// ownership is arbitrary, fixed, and spread over the whole body rather than pooled in a
// region — and a cell appears once its own axis has grown past the lot it was dealt. Mind
// filling lights Mind's scattered squares wherever they happen to fall; nothing overlaps,
// because a cell has exactly one owner; and one link is a handful of squares, which is a thing
// you can watch happen.
[[ stitchable ]]
half4 resolveByAxis(float2 position, SwiftUI::Layer layer, float block, float seed,
                    float a0, float a1, float a2, float a3, float a4) {
    if (block <= 1.0) {
        return layer.sample(position);
    }

    float2 cell = floor(position / block);

    // Which axis this cell belongs to. A second, differently-salted hash, so ownership is
    // uncorrelated with the threshold below — otherwise an axis's cells would all carry
    // similar thresholds and it would come back in a band rather than in a scatter.
    float owner = cellNoise(cell, seed + 41.7);
    float maturity = owner < 0.2 ? a0
                   : owner < 0.4 ? a1
                   : owner < 0.6 ? a2
                   : owner < 0.8 ? a3
                   : a4;

    // The lot this cell was dealt. It appears when its axis passes it, so an axis at a third
    // has filled roughly a third of its own cells — scattered over the whole figure.
    if (cellNoise(cell, seed) > maturity) {
        return half4(0.0h);
    }

    int N = clamp(int(block / 4.0), 2, 4);
    half4 acc = half4(0.0h);
    for (int i = 0; i < N; ++i) {
        for (int j = 0; j < N; ++j) {
            float2 offset = (float2(i, j) + 0.5) / float(N);
            acc += layer.sample(cell * block + block * offset);
        }
    }
    return acc / half(N * N);
}
