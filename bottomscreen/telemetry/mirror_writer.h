/*
 * mirror_writer.h — inventory MIRROR capture, client side.
 *
 * Call mcpe_mirror_capture() from the swap hook, BEFORE the actual
 * buffer swap, once per frame. It is cheap and returns immediately
 * unless a capture is actually due:
 *   - MCPE_MIRROR=0 disables it outright;
 *   - it only captures while mcpe_mirror_set_active(1) is in force
 *     (driven by the same container/UI-screen signal as
 *     MCPE_TF_CONTAINER_OPEN — no container, no readback cost);
 *   - it rate-limits to MCPE_MIRROR_FPS (default 10).
 *
 * This keeps glReadPixels off the normal gameplay path entirely, which
 * is the mitigation for the stall risk flagged in RGDS_DUALSCREEN_PLAN.md.
 */
#ifndef MCPE_MIRROR_WRITER_H
#define MCPE_MIRROR_WRITER_H

#ifdef __cplusplus
extern "C" {
#endif

/* Enable/disable capture. Idempotent; safe to call every frame. */
void mcpe_mirror_set_active(int active);

/* Capture the current back buffer if one is due. w/h are the drawing
 * surface dimensions. No-op when inactive, disabled, or rate-limited. */
void mcpe_mirror_capture(int w, int h);

/* Release the shm mapping (optional; process exit does it too). */
void mcpe_mirror_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
