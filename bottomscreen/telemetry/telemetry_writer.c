/*
 * telemetry_writer.c — single-writer seqlock publisher for
 * /dev/shm/mcpe_telemetry. No launcher dependencies; links anywhere.
 *
 * Env:
 *   MCPE_TELEMETRY=0          disable entirely
 *   MCPE_TELEMETRY_SHM=/name  override shm name (must start with '/')
 */
#define _GNU_SOURCE
#include "telemetry_writer.h"
#include "mcpe_telemetry_abi.h"

#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static volatile McpeTelemetry *g_shm = NULL;
static int g_state = 0; /* 0 = uninitialized, 1 = active, -1 = disabled */
static uint64_t g_remote_peer_ns = 0;

#define REMOTE_PEER_TTL_NS (5ull * 1000ull * 1000ull * 1000ull)

/* p95 window */
#define FRAME_WIN 64
static float g_frames[FRAME_WIN];
static unsigned g_frame_idx = 0;

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void write_begin(void)
{
    __atomic_add_fetch(&g_shm->seq, 1, __ATOMIC_ACQUIRE); /* -> odd */
}

static void write_end(void)
{
    __atomic_add_fetch(&g_shm->seq, 1, __ATOMIC_RELEASE); /* -> even */
}

int mcpe_telemetry_init(void)
{
    if (g_state != 0)
        return g_state > 0;

    const char *en = getenv("MCPE_TELEMETRY");
    if (en && en[0] == '0') {
        g_state = -1;
        return 0;
    }
    const char *name = getenv("MCPE_TELEMETRY_SHM");
    if (!name || name[0] != '/')
        name = MCPE_TELEMETRY_SHM_DEFAULT;

    int fd = shm_open(name, O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        g_state = -1;
        return 0;
    }
    if (ftruncate(fd, (off_t)sizeof(McpeTelemetry)) != 0) {
        close(fd);
        g_state = -1;
        return 0;
    }
    void *p = mmap(NULL, sizeof(McpeTelemetry), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        g_state = -1;
        return 0;
    }
    g_shm = (volatile McpeTelemetry *)p;

    /* (Re)initialize in place; readers key off magic+abi. */
    McpeTelemetry init;
    memset(&init, 0, sizeof init);
    init.magic = MCPE_TELEMETRY_MAGIC;
    init.abi_version = MCPE_TELEMETRY_ABI_VERSION;
    init.death_dimension = -1;
    init.seq = 0;
    memcpy((void *)g_shm, &init, sizeof init);
    __atomic_thread_fence(__ATOMIC_RELEASE);

    g_state = 1;
    return 1;
}

void mcpe_telemetry_camera(float px, float py, float pz,
                           float fx, float fy, float fz)
{
    if (g_state == 0 && !mcpe_telemetry_init()) return;
    if (g_state < 0) return;

    /* Minecraft yaw: 0 = +Z (south), 90 = -X (west). */
    float yaw = atan2f(-fx, fz) * (180.0f / (float)M_PI);
    float cy = fy < -1.0f ? -1.0f : (fy > 1.0f ? 1.0f : fy);
    float pitch = -asinf(cy) * (180.0f / (float)M_PI);

    uint64_t now = now_ns();
    uint64_t remote = __atomic_load_n(&g_remote_peer_ns, __ATOMIC_ACQUIRE);
    write_begin();
    g_shm->cam_x = px; g_shm->cam_y = py; g_shm->cam_z = pz;
    g_shm->fwd_x = fx; g_shm->fwd_y = fy; g_shm->fwd_z = fz;
    g_shm->yaw_deg = yaw;
    g_shm->pitch_deg = pitch;
    g_shm->update_ns = now;
    g_shm->flags |= MCPE_TF_IN_GAME;
    if (remote && now >= remote && now - remote <= REMOTE_PEER_TTL_NS)
        g_shm->flags |= MCPE_TF_REMOTE_WORLD;
    else
        g_shm->flags &= ~MCPE_TF_REMOTE_WORLD;
    write_end();
}

static void remote_peer_seen(uint16_t port)
{
    if (port != 19132 && port != 19133) return;
    __atomic_store_n(&g_remote_peer_ns, now_ns(), __ATOMIC_RELEASE);
}

void mcpe_telemetry_network_peer_ipv4(uint32_t address_host, uint16_t port)
{
    /* A direct Bedrock server can be private or public. Ignore addresses that
     * can only be local/discovery traffic; retain no address either way. */
    if (port != 19132 && port != 19133) return;
    uint8_t a = (uint8_t)(address_host >> 24);
    uint8_t d = (uint8_t)address_host;
    if (address_host == 0 || address_host == 0xffffffffu ||
        a == 127 || a >= 224 || d == 255)
        return;
    remote_peer_seen(port);
}

void mcpe_telemetry_network_peer_ipv6(const uint8_t address[16], uint16_t port)
{
    if (!address || (port != 19132 && port != 19133)) return;
    int all_zero = 1;
    for (int i = 0; i < 16; ++i)
        if (address[i] != 0) { all_zero = 0; break; }
    if (all_zero || address[0] == 0xff) return; /* unspecified / multicast */

    int loopback = 1;
    for (int i = 0; i < 15; ++i)
        if (address[i] != 0) { loopback = 0; break; }
    if (loopback && address[15] == 1) return;

    /* IPv4-mapped IPv6 follows the IPv4 discovery/unicast rules. */
    int mapped = address[10] == 0xff && address[11] == 0xff;
    for (int i = 0; i < 10 && mapped; ++i)
        if (address[i] != 0) mapped = 0;
    if (mapped) {
        uint32_t v4 = ((uint32_t)address[12] << 24) |
                      ((uint32_t)address[13] << 16) |
                      ((uint32_t)address[14] << 8) |
                      (uint32_t)address[15];
        mcpe_telemetry_network_peer_ipv4(v4, port);
        return;
    }
    remote_peer_seen(port);
}

void mcpe_telemetry_frame(float frame_ms, float swap_ms)
{
    if (g_state == 0 && !mcpe_telemetry_init()) return;
    if (g_state < 0) return;
    if (frame_ms <= 0.0f) return;

    g_frames[g_frame_idx % FRAME_WIN] = frame_ms;
    g_frame_idx++;

    /* p95 of a 64 window == 4th largest: one linear pass, top-4 scan. */
    float t1 = 0, t2 = 0, t3 = 0, t4 = 0;
    unsigned n = g_frame_idx < FRAME_WIN ? g_frame_idx : FRAME_WIN;
    for (unsigned i = 0; i < n; ++i) {
        float v = g_frames[i];
        if (v > t1)      { t4 = t3; t3 = t2; t2 = t1; t1 = v; }
        else if (v > t2) { t4 = t3; t3 = t2; t2 = v; }
        else if (v > t3) { t4 = t3; t3 = v; }
        else if (v > t4) { t4 = v; }
    }
    float p95 = n >= FRAME_WIN ? t4 : t1;

    /* EMA sized so ~1s of frames dominates. */
    float inst_fps = 1000.0f / frame_ms;
    float alpha = frame_ms / 1000.0f;
    if (alpha > 0.5f) alpha = 0.5f;

    write_begin();
    float prev = g_shm->fps_avg_1s;
    g_shm->fps_avg_1s = prev <= 0.0f ? inst_fps
                                     : prev + alpha * (inst_fps - prev);
    g_shm->frame_ms_last = frame_ms;
    g_shm->frame_ms_p95_64 = p95;
    g_shm->swap_ms_last = swap_ms;
    if (frame_ms > 50.0f) g_shm->long_frame_count++;
    g_shm->frame_count++;
    write_end();
}

void mcpe_telemetry_container(int open)
{
    if (g_state == 0 && !mcpe_telemetry_init()) return;
    if (g_state < 0) return;
    write_begin();
    if (open) g_shm->flags |= MCPE_TF_CONTAINER_OPEN;
    else      g_shm->flags &= ~MCPE_TF_CONTAINER_OPEN;
    g_shm->container_change_count++;
    write_end();
}

void mcpe_telemetry_death(float x, float y, float z, int dimension)
{
    if (g_state == 0 && !mcpe_telemetry_init()) return;
    if (g_state < 0) return;
    write_begin();
    g_shm->death_x = x; g_shm->death_y = y; g_shm->death_z = z;
    g_shm->death_dimension = dimension;
    g_shm->flags |= MCPE_TF_PLAYER_DEAD;
    write_end();
}
