/*
 * fbdev backend — blits to a Linux framebuffer ($BOTTOMD_FB, default
 * /dev/fb1). Handles 32bpp directly and 16bpp RGB565 by conversion.
 * Centers the 640x480 canvas if the panel is larger.
 */
#define _GNU_SOURCE
#include "backend.h"

#include <fcntl.h>
#include <linux/fb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

typedef struct {
    int fd;
    uint8_t *fbmem;
    size_t fbsize;
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
} FbPriv;

static int fb_init(Backend *self)
{
    FbPriv *p = self->priv;
    const char *dev = getenv("BOTTOMD_FB");
    if (!dev) dev = "/dev/fb1";
    p->fd = open(dev, O_RDWR | O_CLOEXEC);
    if (p->fd < 0) {
        fprintf(stderr, "bottomd: open(%s) failed\n", dev);
        return -1;
    }
    if (ioctl(p->fd, FBIOGET_VSCREENINFO, &p->vinfo) ||
        ioctl(p->fd, FBIOGET_FSCREENINFO, &p->finfo)) {
        close(p->fd);
        return -1;
    }
    if (p->vinfo.bits_per_pixel != 32 && p->vinfo.bits_per_pixel != 16) {
        fprintf(stderr, "bottomd: unsupported fb depth %u\n",
                p->vinfo.bits_per_pixel);
        close(p->fd);
        return -1;
    }
    p->fbsize = p->finfo.line_length * p->vinfo.yres;
    p->fbmem = mmap(NULL, p->fbsize, PROT_READ | PROT_WRITE, MAP_SHARED,
                    p->fd, 0);
    if (p->fbmem == MAP_FAILED) {
        close(p->fd);
        return -1;
    }
    fprintf(stderr, "bottomd: fbdev %s %ux%u@%u\n", dev, p->vinfo.xres,
            p->vinfo.yres, p->vinfo.bits_per_pixel);
    return 0;
}

static void fb_present(Backend *self, const uint32_t *px)
{
    FbPriv *p = self->priv;
    unsigned w = p->vinfo.xres < BOTTOMD_W ? p->vinfo.xres : BOTTOMD_W;
    unsigned h = p->vinfo.yres < BOTTOMD_H ? p->vinfo.yres : BOTTOMD_H;
    unsigned ox = (p->vinfo.xres - w) / 2, oy = (p->vinfo.yres - h) / 2;

    for (unsigned y = 0; y < h; ++y) {
        const uint32_t *src = px + y * BOTTOMD_W;
        uint8_t *dst = p->fbmem + (oy + y) * p->finfo.line_length;
        if (p->vinfo.bits_per_pixel == 32) {
            memcpy(dst + ox * 4, src, w * 4);
        } else { /* RGB565 */
            uint16_t *d16 = (uint16_t *)dst + ox;
            for (unsigned x = 0; x < w; ++x) {
                uint32_t c = src[x];
                d16[x] = (uint16_t)(((c >> 8) & 0xf800) |
                                    ((c >> 5) & 0x07e0) |
                                    ((c >> 3) & 0x001f));
            }
        }
    }
}

static void fb_shutdown(Backend *self)
{
    FbPriv *p = self->priv;
    if (p->fbmem && p->fbmem != MAP_FAILED) munmap(p->fbmem, p->fbsize);
    if (p->fd >= 0) close(p->fd);
    free(p);
    free(self);
}

Backend *backend_fbdev_create(void)
{
    Backend *b = calloc(1, sizeof *b);
    FbPriv *p = calloc(1, sizeof *p);
    if (!b || !p) { free(b); free(p); return NULL; }
    p->fd = -1;
    b->name = "fbdev";
    b->init = fb_init;
    b->present = fb_present;
    b->shutdown = fb_shutdown;
    b->priv = p;
    return b;
}
