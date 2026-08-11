/*
 * test_daynight — the day/night shading curve.
 *
 * Eyeballing this is unreliable: on a map with no terrain loaded the
 * tint lands on an already-near-black background and looks like nothing
 * happened. So assert the curve numerically instead.
 */
#include "worldinfo.c"

#include <stdio.h>
#include <stdlib.h>

static int fails;

static void expect(int cond, const char *what, float got)
{
    if (!cond) {
        printf("FAIL %-42s got %.3f\n", what, (double)got);
        fails++;
    } else {
        printf("ok   %-42s %.3f\n", what, (double)got);
    }
}

/* reach into the module's state without needing a player.json on disk */
static float at(long long tick)
{
    g_have = 1;
    g_day_time = tick;
    return worldinfo_daylight();
}

int main(void)
{
    printf("-- unknown clock must NEVER dim the map --\n");
    g_have = 0;
    expect(worldinfo_daylight() == 1.0f, "no world info -> full daylight",
           worldinfo_daylight());

    printf("-- daytime is undimmed --\n");
    expect(at(0) == 1.0f, "dawn edge (0)", at(0));
    expect(at(6000) == 1.0f, "noon (6000)", at(6000));
    expect(at(11999) == 1.0f, "just before dusk (11999)", at(11999));

    printf("-- night is dark but never black --\n");
    float night = at(18000);
    expect(night > 0.25f && night < 0.40f, "midnight in range", night);
    expect(at(14000) == night, "night is flat (14000)", at(14000));
    expect(at(22000) == night, "night is flat (22000)", at(22000));

    printf("-- dusk and dawn ramp, monotonically --\n");
    float prev = 1.0f;
    for (long long t = 12000; t <= 13800; t += 200) {
        float v = at(t);
        if (v > prev + 1e-6f) {
            printf("FAIL dusk not monotonic at %lld (%.3f > %.3f)\n", t,
                   (double)v, (double)prev);
            fails++;
            break;
        }
        prev = v;
    }
    printf("ok   dusk descends 1.000 -> %.3f\n", (double)at(13800));
    prev = night;
    for (long long t = 22200; t <= 24000; t += 200) {
        float v = at(t);
        if (v < prev - 1e-6f) {
            printf("FAIL dawn not monotonic at %lld (%.3f < %.3f)\n", t,
                   (double)v, (double)prev);
            fails++;
            break;
        }
        prev = v;
    }
    printf("ok   dawn ascends %.3f -> %.3f\n", (double)night,
           (double)at(24000));

    printf("-- wrapping: ticks are cumulative, not modulo, in level.dat --\n");
    expect(at(24000 * 7 + 18000) == night, "day 7 midnight == midnight",
           at(24000 * 7 + 18000));
    expect(at(24000 * 3 + 6000) == 1.0f, "day 3 noon == noon",
           at(24000 * 3 + 6000));
    /* a negative or corrupt tick must not produce a negative factor */
    float neg = at(-5000);
    expect(neg >= 0.0f && neg <= 1.0f, "negative tick stays in range", neg);

    if (fails) {
        printf("\n%d FAILURES\n", fails);
        return 1;
    }
    puts("\nDAYNIGHT OK");
    return 0;
}
