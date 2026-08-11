#define _POSIX_C_SOURCE 200809L
#include "worldinfo.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int near(float actual, float expected)
{
    return fabsf(actual - expected) < 0.001f;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s player.json\n", argv[0]);
        return 2;
    }
    if (setenv("BOTTOMD_PLAYER_JSON", argv[1], 1) != 0) {
        perror("setenv");
        return 2;
    }

    worldinfo_init();
    worldinfo_poll();

    int sx = 0, sy = 0, sz = 0;
    if (!worldinfo_have() || worldinfo_dimension() != 1 ||
        worldinfo_day_time() != 18000 ||
        !near(worldinfo_health(), 17.5f) ||
        !near(worldinfo_hunger(), 13.0f) ||
        !near(worldinfo_daylight(), 0.32f) ||
        !worldinfo_spawn(&sx, &sy, &sz) ||
        sx != 120 || sy != 65 || sz != -40) {
        fprintf(stderr,
                "worldinfo mismatch: have=%d dim=%d day=%lld health=%.2f "
                "hunger=%.2f daylight=%.3f spawn=%d,%d,%d\n",
                worldinfo_have(), worldinfo_dimension(),
                (long long)worldinfo_day_time(), worldinfo_health(),
                worldinfo_hunger(), worldinfo_daylight(), sx, sy, sz);
        return 1;
    }

    puts("worldinfo OK: health, hunger, dimension, time and spawn parsed");
    return 0;
}
