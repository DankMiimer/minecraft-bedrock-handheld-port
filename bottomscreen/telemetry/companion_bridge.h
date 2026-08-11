#ifndef MCPE_COMPANION_BRIDGE_H
#define MCPE_COMPANION_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Called from the render thread after libminecraftpe has been loaded. */
void mcpe_companion_frame(void);

/* Called once immediately before buffer swap. 1 captures the current
 * gameplay frame; 2 restores the last captured gameplay frame while the
 * short-lived native inventory context is active; 0 leaves the frame alone. */
int mcpe_companion_top_frame_action(void);

#ifdef __cplusplus
}
#endif

#endif
