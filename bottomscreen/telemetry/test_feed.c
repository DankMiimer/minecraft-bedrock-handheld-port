/*
 * test_feed — fake game process for developing/testing readers (and
 * later bottomd) without the game. Simulates a player walking a circle
 * at 60 fps through the REAL writer + FMOD hook path.
 *
 *   test_feed [seconds] [center_x center_z]   (default 5, 100 -40)
 */
#define _GNU_SOURCE
#include "telemetry_writer.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* from fmod_listener_hook.c */
typedef struct { float x, y, z; } mcpe_fmod_vector;
int mcpe_telemetry_fmod_listener_hook(void *self, int listener,
                                      const mcpe_fmod_vector *pos,
                                      const mcpe_fmod_vector *vel,
                                      const mcpe_fmod_vector *forward,
                                      const mcpe_fmod_vector *up);

int main(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 5;
    float ctr_x = argc > 3 ? (float)atof(argv[2]) : 100.0f;
    float ctr_z = argc > 3 ? (float)atof(argv[3]) : -40.0f;
    if (!mcpe_telemetry_init()) {
        fprintf(stderr, "test_feed: telemetry init failed\n");
        return 1;
    }
    const mcpe_fmod_vector up = {0, 1, 0};
    const char *remote = getenv("MCPE_TEST_REMOTE_WORLD");
    const uint8_t remote_v6[16] = {
        0xfd, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0, 0,
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0
    };
    for (int frame = 0; frame < secs * 60; ++frame) {
        float t = (float)frame / 60.0f;
        float ang = t * 0.5f;
        mcpe_fmod_vector pos = {ctr_x + 30.0f * cosf(ang), 70.0f,
                                ctr_z + 30.0f * sinf(ang)};
        mcpe_fmod_vector fwd = {-sinf(ang), 0.0f, cosf(ang)};
        mcpe_fmod_vector vel = {0, 0, 0};
        if (remote && !strcmp(remote, "ipv6"))
            mcpe_telemetry_network_peer_ipv6(remote_v6, 19133);
        else if (remote)
            mcpe_telemetry_network_peer_ipv4(0xc0a8010cu, 19132);
        mcpe_telemetry_fmod_listener_hook(NULL, 0, &pos, &vel, &fwd, &up);
        /* fake frame time: mostly 16.7ms, a spike every 4s */
        float fms = (frame % 240 == 239) ? 80.0f : 16.7f;
        mcpe_telemetry_frame(fms, 0.4f);
        if (frame == 90) mcpe_telemetry_container(1);
        if (frame == 150) mcpe_telemetry_container(0);
        if (frame == 200)
            mcpe_telemetry_death(pos.x, pos.y, pos.z, 0);
        usleep(16700);
    }
    puts("test_feed: done");
    return 0;
}
