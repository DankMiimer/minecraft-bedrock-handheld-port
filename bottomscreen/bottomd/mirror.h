/* mirror.h — reader for the inventory MIRROR shm published by the
 * client (see ../telemetry/mcpe_mirror_abi.h).
 *
 * Readiness is a first-class question here: MODE_MIRROR must be
 * unreachable unless there are real frames to show, or we are back to
 * presenting a black rectangle and calling it a feature (P7). */
#ifndef BOTTOMD_MIRROR_H
#define BOTTOMD_MIRROR_H

#include "draw.h"
#include <stdint.h>

/* $BOTTOMD_MIRROR_SHM (default /mcpe_mirror). Safe to call repeatedly;
 * (re)attaches lazily since the game may start after bottomd. */
void mirror_init(void);

/* 1 when a valid mirror is mapped AND its newest frame is younger than
 * max_age_ms. Cheap: attaches at most every 500 ms while absent. */
int mirror_ready(uint64_t max_age_ms);

/* Blit the newest frame. Returns 1 on success, 0 if it could not read a
 * coherent frame (caller should fall back rather than present garbage).
 * Fills age_ms with the frame's age when non-NULL. */
int mirror_blit(Canvas *c, uint64_t *age_ms);

/* Ask the client to capture (want=1) or stop (want=0), and refresh the
 * heartbeat. Call every frame: the client ignores requests older than
 * ~3 s, so a bottomd that dies cannot leave glReadPixels running.
 *
 * This is how MIRROR is triggered in practice. The client cannot detect
 * an open UI screen on every version (1.16.221.01 never calls
 * lockCursor/unlockCursor; 1.20.62.02 exports no ScreenControllers), so
 * the bottom screen asks instead — tapping ITEMS is the trigger. */
void mirror_request(int want);

#endif
