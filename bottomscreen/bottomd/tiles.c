#define _GNU_SOURCE
#include "tiles.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#define TILE_PX 256
#define MAX_TILES 16 /* LRU pool: 16 tiles = 4096x1024 blocks, ~3 MB */

typedef struct {
    int used;
    int32_t tx, tz;
    int dim;
    time_t mtime;
    uint64_t last_use;
    int missing; /* negative cache: file absent */
    uint8_t rgb[TILE_PX * TILE_PX * 3];
    uint8_t lum[TILE_PX * TILE_PX]; /* emission, 0 when absent */
} Tile;

static Tile g_tiles[MAX_TILES];
static char g_dir[512];
static int g_enabled = 0;
static uint64_t g_use_counter = 0;
static uint64_t g_last_check = 0;

void tiles_init(void)
{
    const char *d = getenv("BOTTOMD_TILES");
    if (!d || !d[0]) return;
    snprintf(g_dir, sizeof g_dir, "%s", d);
    g_enabled = 1;
}

int tiles_enabled(void) { return g_enabled; }

void tiles_invalidate_all(void)
{
    memset(g_tiles, 0, sizeof g_tiles);
    g_use_counter = 0;
    g_last_check = 0;
}

static void tile_path(char *out, size_t n, int dim, int32_t tx, int32_t tz)
{
    snprintf(out, n, "%s/%d/surface/r.%d.%d.raw", g_dir, dim, tx, tz);
}

static Tile *load_tile(int32_t tx, int32_t tz, int dim)
{
    /* find existing */
    for (int i = 0; i < MAX_TILES; ++i)
        if (g_tiles[i].used && g_tiles[i].tx == tx &&
            g_tiles[i].tz == tz && g_tiles[i].dim == dim) {
            g_tiles[i].last_use = ++g_use_counter;
            return g_tiles[i].missing ? NULL : &g_tiles[i];
        }
    /* evict LRU slot */
    Tile *slot = &g_tiles[0];
    for (int i = 1; i < MAX_TILES; ++i)
        if (!g_tiles[i].used || g_tiles[i].last_use < slot->last_use)
            slot = &g_tiles[i];
    slot->used = 1;
    slot->tx = tx; slot->tz = tz; slot->dim = dim;
    slot->last_use = ++g_use_counter;
    slot->missing = 1;
    slot->mtime = 0;

    char p[600];
    tile_path(p, sizeof p, dim, tx, tz);
    struct stat st;
    if (stat(p, &st) != 0) return NULL;
    FILE *f = fopen(p, "rb");
    if (!f) return NULL;
    size_t got = fread(slot->rgb, 1, sizeof slot->rgb, f);
    fclose(f);
    if (got != sizeof slot->rgb) return NULL;
    slot->missing = 0;
    slot->mtime = st.st_mtime;

    /* Parallel light plane. An absent .lum leaves it zeroed, i.e.
     * "nothing glows" — tile sets rendered before emission existed keep
     * working unchanged. */
    memset(slot->lum, 0, sizeof slot->lum);
    {
        char lp[600];
        snprintf(lp, sizeof lp, "%s/%d/surface/r.%d.%d.lum", g_dir, dim,
                 tx, tz);
        FILE *lf = fopen(lp, "rb");
        if (lf) {
            /* A short read just means less light data; the tail stays
             * zeroed, which reads as "not a light source". */
            if (fread(slot->lum, 1, sizeof slot->lum, lf) == 0)
                memset(slot->lum, 0, sizeof slot->lum);
            fclose(lf);
        }
    }
    return slot;
}

static int32_t floordiv256(int32_t a)
{
    return a >= 0 ? a / 256 : -(((-a) + 255) / 256);
}

int tiles_sample(int32_t wx, int32_t wz, int dim, uint32_t *xrgb)
{
    if (!g_enabled) return 0;
    int32_t tx = floordiv256(wx), tz = floordiv256(wz);
    /* fast path: consecutive samples almost always hit the same tile */
    static Tile *last = NULL;
    static int32_t last_tx, last_tz;
    static int last_dim;
    Tile *t;
    if (last && last->used && !last->missing && last_tx == tx &&
        last_tz == tz && last_dim == dim && last->tx == tx &&
        last->tz == tz && last->dim == dim) {
        t = last;
    } else {
        t = load_tile(tx, tz, dim);
        last = t;
        last_tx = tx; last_tz = tz; last_dim = dim;
    }
    if (!t) return 0;
    int lx = wx - tx * 256, lz = wz - tz * 256;
    const uint8_t *p = &t->rgb[((size_t)lz * TILE_PX + lx) * 3];
    if (!p[0] && !p[1] && !p[2]) return 0; /* unrendered block */
    *xrgb = 0xff000000u | ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) |
            p[2];
    return 1;
}

uint8_t tiles_sample_light(int32_t wx, int32_t wz, int dim)
{
    if (!g_enabled) return 0;
    int32_t tx = floordiv256(wx), tz = floordiv256(wz);
    Tile *t = load_tile(tx, tz, dim);
    if (!t) return 0;
    int lx = wx - tx * 256, lz = wz - tz * 256;
    return t->lum[(size_t)lz * TILE_PX + lx];
}

void tiles_tick(void)
{
    if (!g_enabled) return;
    uint64_t now = (uint64_t)time(NULL);
    if (now - g_last_check < 1) return;
    g_last_check = now;
    for (int i = 0; i < MAX_TILES; ++i) {
        if (!g_tiles[i].used) continue;
        char p[600];
        tile_path(p, sizeof p, g_tiles[i].dim, g_tiles[i].tx,
                  g_tiles[i].tz);
        struct stat st;
        int exists = stat(p, &st) == 0;
        if ((exists && st.st_mtime != g_tiles[i].mtime) ||
            (!exists && !g_tiles[i].missing) ||
            (exists && g_tiles[i].missing))
            g_tiles[i].used = 0; /* drop; reloads on next sample */
    }
}
