#define _GNU_SOURCE
#include "worldinfo.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

static char g_path[512];
static time_t g_mtime = 0;
static time_t g_last_check = 0;
static int g_have = 0;
static int64_t g_day_time = 0;
static int g_dimension = -1;
static float g_health = -1.0f;
static float g_hunger = -1.0f;
static int g_spawn[3];
static int g_have_spawn = 0;

void worldinfo_init(void)
{
    const char *p = getenv("BOTTOMD_PLAYER_JSON");
    if (p && p[0]) {
        snprintf(g_path, sizeof g_path, "%s", p);
        return;
    }
    const char *tiles = getenv("BOTTOMD_TILES");
    if (tiles && tiles[0])
        snprintf(g_path, sizeof g_path, "%s/player.json", tiles);
}

/* Minimal scanner for the flat, machine-written player.json bedrockmap
 * emits — no general JSON parser needed, and a malformed file simply
 * leaves the previous values in place. */
static int find_i64(const char *buf, const char *key, int64_t *out)
{
    const char *p = strstr(buf, key);
    if (!p) return 0;
    p += strlen(key);
    while (*p == ' ' || *p == ':' || *p == '"') p++;
    char *end = NULL;
    long long v = strtoll(p, &end, 10);
    if (end == p) return 0;
    *out = (int64_t)v;
    return 1;
}

static int find_float(const char *buf, const char *key, float *out)
{
    const char *p = strstr(buf, key);
    if (!p) return 0;
    p += strlen(key);
    while (*p == ' ' || *p == ':' || *p == '"') p++;
    char *end = NULL;
    float value = strtof(p, &end);
    if (end == p) return 0;
    *out = value;
    return 1;
}

static int find_triplet(const char *buf, const char *key, int out[3])
{
    const char *p = strstr(buf, key);
    if (!p) return 0;
    p += strlen(key);
    while (*p && *p != '[') p++;
    if (*p++ != '[') return 0;
    for (int i = 0; i < 3; ++i) {
        while (*p == ' ' || *p == ',') p++;
        char *end = NULL;
        long value = strtol(p, &end, 10);
        if (end == p) return 0;
        out[i] = (int)value;
        p = end;
    }
    return 1;
}

void worldinfo_poll(void)
{
    if (!g_path[0]) return;
    time_t now = time(NULL);
    if (now == g_last_check) return;
    g_last_check = now;

    struct stat st;
    if (stat(g_path, &st) != 0) return;
    if (st.st_mtime == g_mtime) return;
    g_mtime = st.st_mtime;

    FILE *f = fopen(g_path, "r");
    if (!f) return;
    char buf[1024];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;

    int64_t v;
    int parsed = 0;
    if (find_i64(buf, "\"day_time\"", &v)) {
        g_day_time = v;
        parsed = 1;
    }
    if (find_i64(buf, "\"dimension\"", &v)) {
        g_dimension = (int)v;
        parsed = 1;
    }
    if (find_float(buf, "\"health\"", &g_health)) parsed = 1;
    if (find_float(buf, "\"hunger\"", &g_hunger)) parsed = 1;
    g_have_spawn = find_triplet(buf, "\"spawn\"", g_spawn);
    if (g_have_spawn) parsed = 1;
    if (parsed && !g_have)
        fprintf(stderr,
                "bottomd: world info from %s (health=%.1f hunger=%.1f "
                "day_time=%lld)\n",
                g_path, g_health, g_hunger, (long long)g_day_time);
    if (parsed) g_have = 1;
}

int worldinfo_have(void) { return g_have; }
int64_t worldinfo_day_time(void) { return g_day_time; }
int worldinfo_dimension(void) { return g_dimension; }
float worldinfo_health(void) { return g_health; }
float worldinfo_hunger(void) { return g_hunger; }

int worldinfo_spawn(int *x, int *y, int *z)
{
    if (!g_have_spawn) return 0;
    if (x) *x = g_spawn[0];
    if (y) *y = g_spawn[1];
    if (z) *z = g_spawn[2];
    return 1;
}

/* Minecraft's day is 24000 ticks: 0 dawn, 6000 noon, 12000 dusk,
 * 18000 midnight. Dusk and dawn each take about 1800 ticks, so ramp
 * across those rather than snapping — a hard cut would look like the
 * map glitching. */
static float ramp(float t, float a, float b)
{
    if (t <= a) return 0.0f;
    if (t >= b) return 1.0f;
    float x = (t - a) / (b - a);
    return x * x * (3.0f - 2.0f * x); /* smoothstep */
}

#define NIGHT_LEVEL 0.32f

float worldinfo_daylight(void)
{
    if (!g_have) return 1.0f; /* unknown clock must never dim the map */
    float t = (float)(((g_day_time % 24000) + 24000) % 24000);
    float dark;
    if (t < 12000.0f) dark = 0.0f;                    /* day */
    else if (t < 13800.0f) dark = ramp(t, 12000.0f, 13800.0f);  /* dusk */
    else if (t < 22200.0f) dark = 1.0f;               /* night */
    else dark = 1.0f - ramp(t, 22200.0f, 24000.0f);   /* dawn */
    return 1.0f - dark * (1.0f - NIGHT_LEVEL);
}
