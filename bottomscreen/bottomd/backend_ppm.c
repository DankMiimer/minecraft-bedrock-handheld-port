/* PPM file backend — headless testing. Writes frame_%04u.ppm. */
#include "backend.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char dir[512];
    unsigned n;
} PpmPriv;

static int ppm_init(Backend *self)
{
    (void)self;
    return 0;
}

static void ppm_present(Backend *self, const uint32_t *px)
{
    PpmPriv *p = self->priv;
    char path[600];
    snprintf(path, sizeof path, "%s/frame_%04u.ppm", p->dir, p->n++);
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", BOTTOMD_W, BOTTOMD_H);
    for (int i = 0; i < BOTTOMD_W * BOTTOMD_H; ++i) {
        unsigned char rgb[3] = { (px[i] >> 16) & 0xff, (px[i] >> 8) & 0xff,
                                 px[i] & 0xff };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
}

static void ppm_shutdown(Backend *self)
{
    free(self->priv);
    free(self);
}

Backend *backend_ppm_create(const char *out_dir)
{
    Backend *b = calloc(1, sizeof *b);
    PpmPriv *p = calloc(1, sizeof *p);
    if (!b || !p) { free(b); free(p); return NULL; }
    snprintf(p->dir, sizeof p->dir, "%s", out_dir ? out_dir : ".");
    b->name = "ppm";
    b->init = ppm_init;
    b->present = ppm_present;
    b->shutdown = ppm_shutdown;
    b->priv = p;
    return b;
}
