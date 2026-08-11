#ifndef MCPE_FRAME_FREEZER_H
#define MCPE_FRAME_FREEZER_H

#ifdef __cplusplus
extern "C" {
#endif

/* action: 0 no-op, 1 cache the rendered gameplay frame, 2 replace the
 * rendered frame with the cache before swap. */
void mcpe_frame_freezer_apply(int action, int width, int height);

#ifdef __cplusplus
}
#endif

#endif
