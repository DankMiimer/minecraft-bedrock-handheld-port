/*
 * test_mirror — fake mirror producer for developing/testing bottomd's
 * blit path without the game (the real producer needs a live GL
 * context). Publishes through the same header/seqlock/double-buffer
 * protocol as mirror_writer.c.
 *
 * Frames are solid magenta with a moving dark bar, so a reader test can
 * assert "these pixels came from the mirror" — nothing bottomd renders
 * itself is anywhere near magenta.
 *
 *   test_mirror [seconds] [fps]     (default 3, 10)
 * Env: MCPE_MIRROR_SHM (default /mcpe_mirror)
 */
#define _GNU_SOURCE
#include "mcpe_mirror_abi.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

int main(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 3;
    int fps = argc > 2 ? atoi(argv[2]) : 10;
    if (fps < 1) fps = 1;

    const char *name = getenv("MCPE_MIRROR_SHM");
    if (!name || name[0] != '/') name = MCPE_MIRROR_SHM_DEFAULT;

    int fd = shm_open(name, O_CREAT | O_RDWR, 0644);
    if (fd < 0) { perror("shm_open"); return 1; }
    if (ftruncate(fd, (off_t)MCPE_MIRROR_TOTAL_SZ) != 0) {
        perror("ftruncate");
        return 1;
    }
    void *p = mmap(NULL, MCPE_MIRROR_TOTAL_SZ, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }

    unsigned char *base = (unsigned char *)p;
    McpeMirrorHeader *h = (McpeMirrorHeader *)p;
    memset(h, 0, sizeof *h);
    h->magic = MCPE_MIRROR_MAGIC;
    h->abi_version = MCPE_MIRROR_ABI_VERSION;
    h->width = MCPE_MIRROR_W;
    h->height = MCPE_MIRROR_H;
    h->stride = MCPE_MIRROR_W * 4u;
    h->src_width = 1280;
    h->src_height = 720;
    h->flags = MCPE_MF_CAPTURING;
    __atomic_thread_fence(__ATOMIC_RELEASE);

    int frames = secs * fps;
    for (int f = 0; f < frames; ++f) {
        uint32_t next = h->active ? 0u : 1u;
        uint32_t *buf = (uint32_t *)(base + MCPE_MIRROR_BUF_OFF(next));
        int bar = (f * 7) % MCPE_MIRROR_H;
        for (int y = 0; y < MCPE_MIRROR_H; ++y) {
            uint32_t col = (y >= bar && y < bar + 24) ? 0xff101010u
                                                      : 0xffff00ffu;
            for (int x = 0; x < MCPE_MIRROR_W; ++x)
                buf[(size_t)y * MCPE_MIRROR_W + x] = col;
        }
        __atomic_add_fetch(&h->seq, 1, __ATOMIC_ACQUIRE);
        h->active = next;
        h->update_ns = now_ns();
        h->frame_count++;
        __atomic_add_fetch(&h->seq, 1, __ATOMIC_RELEASE);
        usleep(1000000 / fps);
    }
    puts("test_mirror: done");
    return 0;
}
