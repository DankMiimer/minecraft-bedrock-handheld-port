/*
 * mcpe_mirror_abi.h — shared-memory ABI for the inventory MIRROR:
 * downscaled game frames published by the client, blitted by bottomd.
 *
 * Layout:
 *   [ McpeMirrorHeader ][ buffer 0 ][ buffer 1 ]
 * Each buffer is width*height*4 bytes, XRGB8888, TOP-DOWN row order
 * (the writer flips glReadPixels' bottom-up result).
 *
 * Concurrency: single writer, many readers. The writer only ever draws
 * into the INACTIVE buffer, then bumps `seq` (odd -> even) and flips
 * `active`. A reader snapshots the header, blits from `active`, then
 * re-checks `seq`; a change means the writer flipped mid-read and the
 * reader retries. Because the writer never touches the buffer a reader
 * is looking at, a torn frame requires TWO flips inside one blit —
 * impossible at the rates involved (writer <=15 Hz, blit <1 ms).
 *
 * Any layout change MUST bump MCPE_MIRROR_ABI_VERSION. Readers must
 * check magic AND abi_version and treat a mismatch as "no mirror",
 * never as an error — the bottom screen falls back to the map.
 */
#ifndef MCPE_MIRROR_ABI_H
#define MCPE_MIRROR_ABI_H

#include <stdint.h>

#define MCPE_MIRROR_MAGIC       0x4D434D52u /* "MCMR" */
#define MCPE_MIRROR_ABI_VERSION 1u

/* Default POSIX shm name; override with env MCPE_MIRROR_SHM.
 * Appears as /dev/shm/mcpe_mirror on Linux. */
#define MCPE_MIRROR_SHM_DEFAULT "/mcpe_mirror"

/* Publish resolution — the bottom panel's native size. The writer
 * downscales to this so the shm stays ~2.4 MB and bottomd blits 1:1. */
#define MCPE_MIRROR_W 640
#define MCPE_MIRROR_H 480

#define MCPE_MIRROR_BUFSZ ((size_t)MCPE_MIRROR_W * MCPE_MIRROR_H * 4u)

/* header.flags */
#define MCPE_MF_CAPTURING (1u << 0) /* writer is actively capturing */

typedef struct McpeMirrorHeader {
    uint32_t magic;
    uint32_t abi_version;
    uint32_t seq;         /* odd while the writer is flipping */
    uint32_t active;      /* which buffer holds the newest frame (0/1) */
    uint32_t width;
    uint32_t height;
    uint32_t stride;      /* bytes per row = width*4 */
    uint32_t flags;       /* MCPE_MF_* */
    uint64_t update_ns;   /* CLOCK_MONOTONIC of the last published frame */
    uint32_t frame_count;
    uint32_t src_width;   /* pre-downscale size, for diagnostics */
    uint32_t src_height;
    uint8_t  reserved[20];
} McpeMirrorHeader;

/* ---- capture REQUEST channel (bottomd -> client) ------------------ *
 * The reverse direction of everything else here. The client cannot
 * reliably tell when a UI screen is open on every version — 1.16.221.01
 * never calls lockCursor/unlockCursor at all, and 1.20.62.02 exports no
 * ScreenController symbols — so the bottom screen ASKS for capture
 * instead of the game announcing it. Tapping the ITEMS tab is the
 * trigger; no game symbols involved, works on every version.
 *
 * `update_ns` is a heartbeat: the client ignores a request older than
 * MCPE_MIRROR_REQ_STALE_NS so a crashed or killed bottomd cannot pin
 * glReadPixels on forever.
 */
#define MCPE_MIRROR_REQ_SHM_DEFAULT "/mcpe_mirror_req"
#define MCPE_MIRROR_REQ_MAGIC       0x4D435251u /* "MCRQ" */
#define MCPE_MIRROR_REQ_STALE_NS    3000000000ull

typedef struct McpeMirrorRequest {
    uint32_t magic;
    uint32_t abi_version;
    uint32_t want;       /* 1 = a reader wants frames */
    uint32_t seq;
    uint64_t update_ns;  /* CLOCK_MONOTONIC heartbeat from the reader */
    uint8_t  reserved[32];
} McpeMirrorRequest;

/* Byte offset of buffer `i` from the start of the mapping. */
#define MCPE_MIRROR_BUF_OFF(i) \
    (sizeof(McpeMirrorHeader) + (size_t)(i) * MCPE_MIRROR_BUFSZ)
#define MCPE_MIRROR_TOTAL_SZ (sizeof(McpeMirrorHeader) + 2u * MCPE_MIRROR_BUFSZ)

#endif /* MCPE_MIRROR_ABI_H */
