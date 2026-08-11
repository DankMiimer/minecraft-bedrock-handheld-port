/*
 * test_downscale — correctness guard for mirror_writer's downscale_flip.
 *
 * The 1:1 fast path added 2026-07-27 only triggers at exactly
 * 640x480 (the RG DS game window size), so it never runs on the host
 * unless tested deliberately. It must agree with the general box-filter
 * path, and both must do the vertical flip glReadPixels forces.
 *
 * Includes the .c directly to reach the static function.
 */
#include "mirror_writer.c"

#include <assert.h>
#include <stdio.h>

static int fails = 0;

static void expect(int cond, const char *what)
{
    if (!cond) {
        printf("FAIL %s\n", what);
        fails++;
    }
}

/* Reference implementation: independent of the code under test. */
static uint32_t ref_pixel(const unsigned char *src, int sw, int sh,
                          int dx, int dy)
{
    int sy0 = (int)((int64_t)dy * sh / MCPE_MIRROR_H);
    int sy1 = (int)((int64_t)(dy + 1) * sh / MCPE_MIRROR_H);
    if (sy1 <= sy0) sy1 = sy0 + 1;
    if (sy1 > sh) sy1 = sh;
    int sx0 = (int)((int64_t)dx * sw / MCPE_MIRROR_W);
    int sx1 = (int)((int64_t)(dx + 1) * sw / MCPE_MIRROR_W);
    if (sx1 <= sx0) sx1 = sx0 + 1;
    if (sx1 > sw) sx1 = sw;
    uint32_t r = 0, g = 0, b = 0, n = 0;
    for (int sy = sy0; sy < sy1; ++sy) {
        int flipped = sh - 1 - sy;
        for (int sx = sx0; sx < sx1; ++sx) {
            const unsigned char *p = src + ((size_t)flipped * sw + sx) * 4;
            r += p[0]; g += p[1]; b += p[2];
            n++;
        }
    }
    if (!n) n = 1;
    return 0xff000000u | ((r / n) << 16) | ((g / n) << 8) | (b / n);
}

static void run_case(int sw, int sh, const char *label)
{
    unsigned char *src = malloc((size_t)sw * sh * 4);
    unsigned char *dst = malloc(MCPE_MIRROR_BUFSZ);
    assert(src && dst);
    /* deterministic, non-symmetric pattern so a missing flip shows up */
    for (int y = 0; y < sh; ++y)
        for (int x = 0; x < sw; ++x) {
            unsigned char *p = src + ((size_t)y * sw + x) * 4;
            p[0] = (unsigned char)(x * 7 + y * 3);
            p[1] = (unsigned char)(y * 5);
            p[2] = (unsigned char)(x * 11);
            p[3] = 0xff;
        }

    downscale_flip(src, sw, sh, dst);

    const uint32_t *out = (const uint32_t *)dst;
    int bad = 0;
    for (int dy = 0; dy < MCPE_MIRROR_H && bad < 5; ++dy)
        for (int dx = 0; dx < MCPE_MIRROR_W && bad < 5; ++dx) {
            uint32_t got = out[(size_t)dy * MCPE_MIRROR_W + dx];
            uint32_t want = ref_pixel(src, sw, sh, dx, dy);
            if (got != want) {
                printf("  %s mismatch at (%d,%d): got %08x want %08x\n",
                       label, dx, dy, got, want);
                bad++;
            }
        }
    expect(bad == 0, label);

    /* alpha must always be opaque — the panel has no blending */
    expect((out[0] & 0xff000000u) == 0xff000000u, "alpha opaque");

    /* top output row must come from the BOTTOM source row (the flip) */
    const unsigned char *bottom = src + (size_t)(sh - 1) * sw * 4;
    if (sw == MCPE_MIRROR_W && sh == MCPE_MIRROR_H) {
        uint32_t want = 0xff000000u | ((uint32_t)bottom[0] << 16) |
                        ((uint32_t)bottom[1] << 8) | (uint32_t)bottom[2];
        expect(out[0] == want, "flip: dst row0 == src last row");
    }
    free(src);
    free(dst);
}

int main(void)
{
    printf("1:1 fast path (640x480, the RG DS game window)\n");
    run_case(MCPE_MIRROR_W, MCPE_MIRROR_H, "1:1");
    printf("general path (1280x960, exact 2x)\n");
    run_case(1280, 960, "2x");
    printf("general path (1024x600, non-integer)\n");
    run_case(1024, 600, "non-integer");
    if (fails) {
        printf("%d FAILURES\n", fails);
        return 1;
    }
    puts("DOWNSCALE OK");
    return 0;
}
