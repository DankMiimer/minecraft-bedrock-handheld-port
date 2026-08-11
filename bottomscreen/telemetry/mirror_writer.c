/*
 * mirror_writer.c — glReadPixels capture -> /dev/shm/mcpe_mirror.
 *
 * Env:
 *   MCPE_MIRROR=0        disable entirely
 *   MCPE_MIRROR_SHM=/n   override shm name (must start with '/')
 *   MCPE_MIRROR_FPS=N    capture rate cap (default 10, max 30)
 *
 * GL entry points are resolved lazily by dlsym on the already-loaded
 * host GLES library — NOT by linking against it. The client must keep
 * running unchanged on a host without GLES headers/libs, and the mirror
 * must degrade to "no mirror" rather than failing to load.
 */
#define _GNU_SOURCE
#include "mirror_writer.h"
#include "mcpe_mirror_abi.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifndef GL_RGBA
#define GL_RGBA           0x1908
#define GL_UNSIGNED_BYTE  0x1401
#define GL_PACK_ALIGNMENT 0x0D05
#endif

typedef void (*pfn_readpixels)(int x, int y, int w, int h,
                               unsigned fmt, unsigned type, void *px);
typedef void (*pfn_pixelstorei)(unsigned pname, int param);

static pfn_readpixels  gl_read_pixels = NULL;
static pfn_pixelstorei gl_pixel_storei = NULL;

static unsigned char *g_shm = NULL;   /* whole mapping */
static McpeMirrorHeader *g_hdr = NULL;
static unsigned char *g_scratch = NULL; /* full-res RGBA readback */
static size_t g_scratch_sz = 0;
static int g_state = 0;   /* 0 uninit, 1 active, -1 disabled */
static int g_capturing = 0;
static uint64_t g_last_ns = 0;
static uint64_t g_min_interval_ns = 100000000ull; /* 10 fps */

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void *resolve_gl(const char *name)
{
    /* The host GLES lib is already loaded by the window backend; look it
     * up without pulling in a new copy. RTLD_DEFAULT covers the common
     * case where it is in the global scope. */
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    static void *h = NULL;
    if (!h) h = dlopen("libGLESv2.so.2", RTLD_LAZY | RTLD_NOLOAD);
    if (!h) h = dlopen("libGLESv2.so", RTLD_LAZY | RTLD_NOLOAD);
    if (!h) h = dlopen("libGLESv2.so.2", RTLD_LAZY);
    if (!h) h = dlopen("libGLESv2.so", RTLD_LAZY);
    return h ? dlsym(h, name) : NULL;
}

static int mirror_init(void)
{
    if (g_state != 0) return g_state > 0;

    const char *en = getenv("MCPE_MIRROR");
    if (en && en[0] == '0') { g_state = -1; return 0; }

    gl_read_pixels = (pfn_readpixels)resolve_gl("glReadPixels");
    gl_pixel_storei = (pfn_pixelstorei)resolve_gl("glPixelStorei");
    if (!gl_read_pixels) {
        fprintf(stderr, "mcpe_mirror: glReadPixels unavailable, "
                        "mirror disabled\n");
        g_state = -1;
        return 0;
    }

    /* 15 default: the capture is a 640x480 row-flip (no scaling on this
     * device), and the panel runs at 20 fps, so 15 reads smoothly
     * without competing hard with the game for memory bandwidth. */
    const char *fps = getenv("MCPE_MIRROR_FPS");
    if (fps && fps[0]) {
        int v = atoi(fps);
        if (v < 1) v = 1;
        if (v > 60) v = 60;
        g_min_interval_ns = 1000000000ull / (uint64_t)v;
    } else {
        g_min_interval_ns = 1000000000ull / 15ull;
    }

    const char *name = getenv("MCPE_MIRROR_SHM");
    if (!name || name[0] != '/') name = MCPE_MIRROR_SHM_DEFAULT;

    int fd = shm_open(name, O_CREAT | O_RDWR, 0644);
    if (fd < 0) { g_state = -1; return 0; }
    if (ftruncate(fd, (off_t)MCPE_MIRROR_TOTAL_SZ) != 0) {
        close(fd);
        g_state = -1;
        return 0;
    }
    void *p = mmap(NULL, MCPE_MIRROR_TOTAL_SZ, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) { g_state = -1; return 0; }

    g_shm = (unsigned char *)p;
    g_hdr = (McpeMirrorHeader *)p;
    memset(g_hdr, 0, sizeof *g_hdr);
    g_hdr->magic = MCPE_MIRROR_MAGIC;
    g_hdr->abi_version = MCPE_MIRROR_ABI_VERSION;
    g_hdr->width = MCPE_MIRROR_W;
    g_hdr->height = MCPE_MIRROR_H;
    g_hdr->stride = MCPE_MIRROR_W * 4u;
    __atomic_thread_fence(__ATOMIC_RELEASE);

    fprintf(stderr, "mcpe_mirror: publishing %ux%u to %s at <=%llu fps\n",
            MCPE_MIRROR_W, MCPE_MIRROR_H, name,
            (unsigned long long)(1000000000ull / g_min_interval_ns));
    g_state = 1;
    return 1;
}

/* ---- capture request channel (bottomd asks for frames) ------------ */
static McpeMirrorRequest *g_req = NULL;
static int g_req_state = 0; /* 0 uninit, 1 mapped, -1 unavailable */

static int request_wanted(void)
{
    if (g_req_state < 0) return 0;
    if (g_req_state == 0) {
        const char *n = getenv("MCPE_MIRROR_REQ_SHM");
        if (!n || n[0] != '/') n = MCPE_MIRROR_REQ_SHM_DEFAULT;
        /* O_RDWR|O_CREAT: either side may get here first. */
        int fd = shm_open(n, O_CREAT | O_RDWR, 0644);
        if (fd < 0) { g_req_state = -1; return 0; }
        if (ftruncate(fd, (off_t)sizeof(McpeMirrorRequest)) != 0) {
            close(fd);
            g_req_state = -1;
            return 0;
        }
        void *p = mmap(NULL, sizeof(McpeMirrorRequest),
                       PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) { g_req_state = -1; return 0; }
        g_req = (McpeMirrorRequest *)p;
        g_req_state = 1;
    }
    if (g_req->magic != MCPE_MIRROR_REQ_MAGIC) return 0;
    if (!g_req->want) return 0;
    /* Heartbeat: a dead reader must not pin glReadPixels on forever. */
    uint64_t u = g_req->update_ns;
    if (u == 0) return 0;
    uint64_t now = now_ns();
    return (now > u ? now - u : 0) < MCPE_MIRROR_REQ_STALE_NS;
}

void mcpe_mirror_set_active(int active)
{
    active = !!active;
    if (active == g_capturing) return;
    g_capturing = active;
    if (g_state > 0) {
        if (active) g_hdr->flags |= MCPE_MF_CAPTURING;
        else        g_hdr->flags &= ~MCPE_MF_CAPTURING;
        __atomic_thread_fence(__ATOMIC_RELEASE);
    }
    /* Force the next capture to happen immediately rather than waiting
     * out the rate limiter — the first frame after opening a container
     * is the one the player is waiting to see. */
    if (active) g_last_ns = 0;
}

/* Box-downscale src (RGBA, bottom-up) into dst (XRGB8888, top-down).
 * Integer-averaged over each destination cell's source footprint; at the
 * ratios involved (~2x) that is visibly better than point sampling and
 * still cheap. Also does the vertical flip glReadPixels requires. */
static void downscale_flip(const unsigned char *src, int sw, int sh,
                           unsigned char *dst)
{
    if (sw <= 0 || sh <= 0) return;

    /* FAST PATH — measured on the RG DS 2026-07-27: the game window is
     * 640x480 (run_bedrock passes -ww 640 -wh 480), exactly the panel
     * size, so the common case is a pure vertical flip with NO scaling.
     * The general path below would still run its per-destination-pixel
     * box loop with a 1x1 footprint, which is ~300k iterations of
     * pointless averaging per frame. Row-wise conversion instead. */
    if (sw == MCPE_MIRROR_W && sh == MCPE_MIRROR_H) {
        for (int dy = 0; dy < MCPE_MIRROR_H; ++dy) {
            const unsigned char *srow =
                src + (size_t)(sh - 1 - dy) * sw * 4;
            uint32_t *drow =
                (uint32_t *)(dst + (size_t)dy * MCPE_MIRROR_W * 4);
            for (int dx = 0; dx < MCPE_MIRROR_W; ++dx) {
                drow[dx] = 0xff000000u | ((uint32_t)srow[0] << 16) |
                           ((uint32_t)srow[1] << 8) | (uint32_t)srow[2];
                srow += 4;
            }
        }
        return;
    }

    for (int dy = 0; dy < MCPE_MIRROR_H; ++dy) {
        /* destination row dy maps to source rows [sy0, sy1) counted from
         * the TOP; glReadPixels gave us bottom-up, so flip here. */
        int sy0 = (int)((int64_t)dy * sh / MCPE_MIRROR_H);
        int sy1 = (int)((int64_t)(dy + 1) * sh / MCPE_MIRROR_H);
        if (sy1 <= sy0) sy1 = sy0 + 1;
        if (sy1 > sh) sy1 = sh;
        uint32_t *drow = (uint32_t *)(dst + (size_t)dy * MCPE_MIRROR_W * 4);
        for (int dx = 0; dx < MCPE_MIRROR_W; ++dx) {
            int sx0 = (int)((int64_t)dx * sw / MCPE_MIRROR_W);
            int sx1 = (int)((int64_t)(dx + 1) * sw / MCPE_MIRROR_W);
            if (sx1 <= sx0) sx1 = sx0 + 1;
            if (sx1 > sw) sx1 = sw;
            uint32_t r = 0, g = 0, b = 0, n = 0;
            for (int sy = sy0; sy < sy1; ++sy) {
                int flipped = sh - 1 - sy;
                const unsigned char *srow =
                    src + ((size_t)flipped * sw + sx0) * 4;
                for (int sx = sx0; sx < sx1; ++sx) {
                    r += srow[0]; g += srow[1]; b += srow[2];
                    srow += 4;
                    n++;
                }
            }
            if (!n) n = 1;
            drow[dx] = 0xff000000u | ((r / n) << 16) | ((g / n) << 8) |
                       (b / n);
        }
    }
}

void mcpe_mirror_capture(int w, int h)
{
    if (w <= 0 || h <= 0) return;
    if (g_state < 0) return;

    /* Two independent ways to be asked for frames:
     *   - the game told us a UI screen is open (mcpe_mirror_set_active),
     *   - or a reader asked via the request shm (the ITEMS tab).
     * The request path is checked at most every 250 ms so the normal
     * gameplay frame pays one timestamp compare, not an shm poll. */
    uint64_t now = now_ns();
    if (!g_capturing) {
        static uint64_t last_req_check = 0;
        static int req_cached = 0;
        if (!last_req_check || now - last_req_check > 250000000ull) {
            last_req_check = now;
            req_cached = request_wanted();
        }
        if (!req_cached) return;
    }

    if (g_state == 0 && !mirror_init()) return;
    if (g_state < 0) return;

    if (g_last_ns && now - g_last_ns < g_min_interval_ns) return;
    g_last_ns = now;

    size_t need = (size_t)w * (size_t)h * 4u;
    if (need > g_scratch_sz) {
        unsigned char *p = (unsigned char *)realloc(g_scratch, need);
        if (!p) return;
        g_scratch = p;
        g_scratch_sz = need;
    }

    if (gl_pixel_storei) gl_pixel_storei(GL_PACK_ALIGNMENT, 1);
    gl_read_pixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, g_scratch);

    /* Draw into the buffer nobody is reading, then flip. */
    uint32_t next = g_hdr->active ? 0u : 1u;
    downscale_flip(g_scratch, w, h, g_shm + MCPE_MIRROR_BUF_OFF(next));

    __atomic_add_fetch(&g_hdr->seq, 1, __ATOMIC_ACQUIRE);   /* -> odd */
    g_hdr->active = next;
    g_hdr->src_width = (uint32_t)w;
    g_hdr->src_height = (uint32_t)h;
    g_hdr->update_ns = now;
    g_hdr->frame_count++;
    __atomic_add_fetch(&g_hdr->seq, 1, __ATOMIC_RELEASE);   /* -> even */
}

void mcpe_mirror_shutdown(void)
{
    if (g_shm) {
        munmap(g_shm, MCPE_MIRROR_TOTAL_SZ);
        g_shm = NULL;
        g_hdr = NULL;
    }
    free(g_scratch);
    g_scratch = NULL;
    g_scratch_sz = 0;
    g_state = 0;
    g_capturing = 0;
}
