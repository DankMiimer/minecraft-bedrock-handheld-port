/*
 * mcpe_telemetry_abi.h — shared-memory ABI between the game process
 * (mcpelauncher-client telemetry module) and readers (bottomd,
 * telemetry_dump). Plain C, no dependencies.
 *
 * Single writer (the game process), any number of readers. Concurrency
 * via a seqlock: `seq` is incremented to an odd value before the writer
 * mutates fields and to an even value after. Readers snapshot, then
 * verify seq was even and unchanged; otherwise retry.
 *
 * Any layout change MUST bump MCPE_TELEMETRY_ABI_VERSION. Readers must
 * check both `magic` and `abi_version` and treat a mismatch as
 * "telemetry unavailable", never as an error.
 */
#ifndef MCPE_TELEMETRY_ABI_H
#define MCPE_TELEMETRY_ABI_H

#include <stdint.h>

#define MCPE_TELEMETRY_MAGIC       0x4D435054u /* "MCPT" */
#define MCPE_TELEMETRY_ABI_VERSION 1u

/* Default POSIX shm name (shm_open); override with env MCPE_TELEMETRY_SHM.
 * Appears as /dev/shm/mcpe_telemetry on Linux. */
#define MCPE_TELEMETRY_SHM_DEFAULT "/mcpe_telemetry"

/* struct McpeTelemetry.flags bits */
#define MCPE_TF_IN_GAME        (1u << 0) /* camera feed active recently */
/* A game UI screen owns the view: inventory, crafting, chest, pause,
 * chat. Fed from the client's lockCursor/unlockCursor (Bedrock releases
 * the cursor for any such screen) — deliberately BROADER than "container"
 * despite the name, because "player is in a UI, not in the world" is what
 * the bottom screen actually needs. Cursor state is the only portable
 * source: 1.20.62.02 exports no ScreenController symbols to hook. */
#define MCPE_TF_CONTAINER_OPEN (1u << 1)
#define MCPE_TF_PLAYER_DEAD    (1u << 2)
/* Recent gameplay packets are flowing to/from a private IPv4 Bedrock peer.
 * The RGDS client uses this to distinguish a remote/LAN world from a local
 * LevelDB-backed world. No addresses or packet contents are published. */
#define MCPE_TF_REMOTE_WORLD   (1u << 3)

typedef struct McpeTelemetry {
    /* -- header -- */
    uint32_t magic;        /* MCPE_TELEMETRY_MAGIC */
    uint32_t abi_version;  /* MCPE_TELEMETRY_ABI_VERSION */
    uint32_t seq;          /* seqlock; odd while writer is mid-update */
    uint32_t flags;        /* MCPE_TF_* */
    uint64_t update_ns;    /* CLOCK_MONOTONIC of last camera update */

    /* -- camera feed (FMOD listener hook; ~per frame) --
     * Position is the CAMERA/eye position, not player feet. */
    float cam_x, cam_y, cam_z;
    float yaw_deg;         /* Minecraft convention: 0 = +Z, 90 = -X */
    float pitch_deg;       /* + looks down, - looks up */
    float fwd_x, fwd_y, fwd_z; /* raw forward vector as received */

    /* -- events (per-version game hooks; optional, may stay zero) -- */
    float    death_x, death_y, death_z;
    int32_t  death_dimension;   /* -1 = no recorded death */
    uint32_t container_change_count; /* increments on every open/close */

    /* -- frame metrics (client render-loop instrumentation) -- */
    float    fps_avg_1s;        /* EMA over ~1s */
    float    frame_ms_last;
    float    frame_ms_p95_64;   /* p95 of last 64 frames */
    float    swap_ms_last;
    uint32_t long_frame_count;  /* frames >50ms since start (monotonic) */
    uint64_t frame_count;       /* total frames since start */

    /* -- reserved: dimension/health/hunger/day-time intentionally NOT
     * here — they come from the world-DB snapshot pass (bedrockmap),
     * see bottomscreen/analysis/SYMBOL_FINDINGS.md. Space reserved so
     * adding them later is an in-place ABI bump. -- */
    uint8_t reserved[64];
} McpeTelemetry;

/* ---- reader helper (header-only, C99) ---------------------------- */
#ifdef MCPE_TELEMETRY_IMPLEMENT_READER
#include <string.h>

/* Snapshot the struct. Returns 1 on success, 0 if writer was mid-update
 * too persistently (caller: just reuse the previous snapshot). */
static int mcpe_telemetry_read(const volatile McpeTelemetry *shm,
                               McpeTelemetry *out)
{
    for (int attempt = 0; attempt < 8; ++attempt) {
        uint32_t s1 = __atomic_load_n(&shm->seq, __ATOMIC_ACQUIRE);
        if (s1 & 1u) continue;
        memcpy(out, (const void *)shm, sizeof *out);
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        uint32_t s2 = __atomic_load_n(&shm->seq, __ATOMIC_ACQUIRE);
        if (s1 == s2)
            return out->magic == MCPE_TELEMETRY_MAGIC &&
                   out->abi_version == MCPE_TELEMETRY_ABI_VERSION;
    }
    return 0;
}
#endif /* MCPE_TELEMETRY_IMPLEMENT_READER */

#endif /* MCPE_TELEMETRY_ABI_H */
