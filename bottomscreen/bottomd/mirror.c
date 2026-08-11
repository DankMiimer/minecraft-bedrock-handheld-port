#define _GNU_SOURCE
#include "mirror.h"
#include "../telemetry/mcpe_mirror_abi.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static char g_name[256];
static unsigned char *g_map = NULL;
static const McpeMirrorHeader *g_hdr = NULL;
static uint64_t g_last_try_ns = 0;
static int g_logged = 0;

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

void mirror_init(void)
{
    const char *n = getenv("BOTTOMD_MIRROR_SHM");
    if (n && n[0]) snprintf(g_name, sizeof g_name, "%s", n);
    else snprintf(g_name, sizeof g_name, "%s", MCPE_MIRROR_SHM_DEFAULT);
}

/* The game may start long after bottomd, and may restart under it, so
 * attaching is a retry loop rather than a one-shot. */
static void attach(void)
{
    if (g_map) return;
    uint64_t now = now_ns();
    if (g_last_try_ns && now - g_last_try_ns < 500000000ull) return;
    g_last_try_ns = now;

    /* shm_open wants a leading-slash NAME; allow a plain path too so the
     * test harness can point at a regular file. */
    int fd = (g_name[0] == '/' && !strchr(g_name + 1, '/'))
                 ? shm_open(g_name, O_RDONLY, 0)
                 : open(g_name, O_RDONLY);
    if (fd < 0) return;
    void *p = mmap(NULL, MCPE_MIRROR_TOTAL_SZ, PROT_READ, MAP_SHARED, fd,
                   0);
    close(fd);
    if (p == MAP_FAILED) return;

    const McpeMirrorHeader *h = (const McpeMirrorHeader *)p;
    if (h->magic != MCPE_MIRROR_MAGIC ||
        h->abi_version != MCPE_MIRROR_ABI_VERSION) {
        /* Never treat a mismatch as an error — just stay unmirrored. */
        if (!g_logged) {
            fprintf(stderr, "bottomd: mirror %s magic/abi mismatch "
                            "(0x%x v%u) — ignoring\n",
                    g_name, h->magic, h->abi_version);
            g_logged = 1;
        }
        munmap(p, MCPE_MIRROR_TOTAL_SZ);
        return;
    }
    g_map = (unsigned char *)p;
    g_hdr = h;
    fprintf(stderr, "bottomd: mirror attached %s %ux%u\n", g_name,
            h->width, h->height);
}

static McpeMirrorRequest *g_req = NULL;
static int g_req_state = 0; /* 0 uninit, 1 mapped, -1 unavailable */
static char g_req_name[256];

void mirror_request(int want)
{
    if (g_req_state < 0) return;
    if (g_req_state == 0) {
        const char *n = getenv("BOTTOMD_MIRROR_REQ_SHM");
        snprintf(g_req_name, sizeof g_req_name, "%s",
                 (n && n[0]) ? n : MCPE_MIRROR_REQ_SHM_DEFAULT);
        int fd = (g_req_name[0] == '/' && !strchr(g_req_name + 1, '/'))
                     ? shm_open(g_req_name, O_CREAT | O_RDWR, 0644)
                     : open(g_req_name, O_CREAT | O_RDWR, 0644);
        if (fd < 0) { g_req_state = -1; return; }
        if (ftruncate(fd, (off_t)sizeof(McpeMirrorRequest)) != 0) {
            close(fd);
            g_req_state = -1;
            return;
        }
        void *p = mmap(NULL, sizeof(McpeMirrorRequest),
                       PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) { g_req_state = -1; return; }
        g_req = (McpeMirrorRequest *)p;
        g_req->magic = MCPE_MIRROR_REQ_MAGIC;
        g_req->abi_version = MCPE_MIRROR_ABI_VERSION;
        g_req_state = 1;
        fprintf(stderr, "bottomd: mirror request channel %s\n", g_req_name);
    }
    want = !!want;
    if ((int)g_req->want != want)
        fprintf(stderr, "bottomd: mirror capture %s\n",
                want ? "REQUESTED" : "released");
    g_req->want = (uint32_t)want;
    g_req->update_ns = now_ns();
    __atomic_add_fetch(&g_req->seq, 1, __ATOMIC_RELEASE);
}

int mirror_ready(uint64_t max_age_ms)
{
    attach();
    if (!g_hdr) return 0;
    if (g_hdr->frame_count == 0) return 0;
    uint64_t u = g_hdr->update_ns;
    if (u == 0) return 0;
    uint64_t now = now_ns();
    uint64_t age_ms = (now > u ? now - u : 0) / 1000000ull;
    return age_ms <= max_age_ms;
}

int mirror_blit(Canvas *c, uint64_t *age_ms)
{
    attach();
    if (!g_hdr) return 0;

    for (int attempt = 0; attempt < 4; ++attempt) {
        uint32_t s1 = __atomic_load_n(&g_hdr->seq, __ATOMIC_ACQUIRE);
        if (s1 & 1u) continue;          /* writer is mid-flip */
        uint32_t act = g_hdr->active;
        uint32_t w = g_hdr->width, h = g_hdr->height;
        uint64_t upd = g_hdr->update_ns;
        if (act > 1 || w == 0 || h == 0) return 0;

        const uint32_t *src =
            (const uint32_t *)(g_map + MCPE_MIRROR_BUF_OFF(act));

        /* Publish size is the panel size, so this is normally a straight
         * copy; the clamp keeps a mismatched producer from writing off
         * the end of the canvas. */
        uint32_t cw = w < (uint32_t)BOTTOMD_W ? w : (uint32_t)BOTTOMD_W;
        uint32_t ch = h < (uint32_t)BOTTOMD_H ? h : (uint32_t)BOTTOMD_H;
        if (cw != (uint32_t)BOTTOMD_W || ch != (uint32_t)BOTTOMD_H)
            draw_clear(c, 0xff000000);
        for (uint32_t y = 0; y < ch; ++y)
            memcpy(c->px + (size_t)y * BOTTOMD_W,
                   src + (size_t)y * w, (size_t)cw * 4);

        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        uint32_t s2 = __atomic_load_n(&g_hdr->seq, __ATOMIC_ACQUIRE);
        if (s1 == s2) {
            if (age_ms) {
                uint64_t now = now_ns();
                *age_ms = (now > upd ? now - upd : 0) / 1000000ull;
            }
            return 1;
        }
        /* writer flipped under us — retry */
    }
    return 0;
}
