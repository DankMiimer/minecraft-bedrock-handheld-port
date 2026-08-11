/*
 * telemetry_dump — read /dev/shm/mcpe_telemetry and print it.
 *   telemetry_dump            follow mode, 5 Hz
 *   telemetry_dump --once     single line, exit 0 if valid data, 3 if none
 *   MCPE_TELEMETRY_SHM=/name  same override as the writer
 */
#define _GNU_SOURCE
#define MCPE_TELEMETRY_IMPLEMENT_READER
#include "mcpe_telemetry_abi.h"

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
    int once = argc > 1 && strcmp(argv[1], "--once") == 0;
    const char *name = getenv("MCPE_TELEMETRY_SHM");
    if (!name || name[0] != '/')
        name = MCPE_TELEMETRY_SHM_DEFAULT;

    int fd = shm_open(name, O_RDONLY, 0);
    if (fd < 0) {
        fprintf(stderr, "telemetry_dump: shm_open(%s) failed "
                        "(game not running with telemetry?)\n", name);
        return 2;
    }
    const volatile McpeTelemetry *shm =
        mmap(NULL, sizeof(McpeTelemetry), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (shm == MAP_FAILED) {
        perror("telemetry_dump: mmap");
        return 2;
    }

    for (;;) {
        McpeTelemetry t;
        if (!mcpe_telemetry_read(shm, &t)) {
            if (once) {
                fprintf(stderr, "telemetry_dump: no valid data\n");
                return 3;
            }
            usleep(200 * 1000);
            continue;
        }
        double age_ms = (double)(now_ns() - t.update_ns) / 1e6;
        printf("pos=(%.2f, %.2f, %.2f) yaw=%.1f pitch=%.1f "
               "flags=[%s%s%s%s] age=%.0fms | fps=%.1f last=%.1fms "
               "p95=%.1fms long=%u frames=%llu deaths@(%.0f,%.0f,%.0f dim %d)\n",
               t.cam_x, t.cam_y, t.cam_z, t.yaw_deg, t.pitch_deg,
               (t.flags & MCPE_TF_IN_GAME) ? "game " : "",
               (t.flags & MCPE_TF_CONTAINER_OPEN) ? "container " : "",
               (t.flags & MCPE_TF_PLAYER_DEAD) ? "dead " : "",
               (t.flags & MCPE_TF_REMOTE_WORLD) ? "remote " : "",
               age_ms, t.fps_avg_1s, t.frame_ms_last, t.frame_ms_p95_64,
               t.long_frame_count, (unsigned long long)t.frame_count,
               t.death_x, t.death_y, t.death_z, t.death_dimension);
        fflush(stdout);
        if (once)
            return 0;
        usleep(200 * 1000);
    }
}
