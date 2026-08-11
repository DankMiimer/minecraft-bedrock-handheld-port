/*
 * fmod_listener_hook.c — interposer for
 *   FMOD::System::set3DListenerAttributes(int, const FMOD_VECTOR*,
 *       const FMOD_VECTOR*, const FMOD_VECTOR*, const FMOD_VECTOR*)
 *   mangled: _ZN4FMOD6System23set3DListenerAttributesEiPK11FMOD_VECTORS3_S3_S3_
 *
 * The game calls this every frame with the camera position/orientation;
 * verified imported by both 1.16.221.01 and 1.20.62.02 arm64
 * (bottomscreen/analysis/SYMBOL_FINDINGS.md). Member function, so the
 * first argument is the FMOD::System `this` pointer — identical machine
 * ABI to this plain C function on aarch64 and armhf.
 *
 * Integration (in mcpelauncher-client, either mechanism):
 *   A. Pre-load symbol override: register mcpe_telemetry_fmod_listener_hook
 *      under the mangled name in the linker's symbol table before
 *      libminecraftpe.so is loaded, and set the real pointer:
 *        mcpe_telemetry_set_real_fmod_listener(
 *            dlsym(fmod_lib_handle, MCPE_TELEMETRY_FMOD_LISTENER_SYM));
 *   B. Post-load GOT patch: swap libminecraftpe's GOT entry for the
 *      symbol to mcpe_telemetry_fmod_listener_hook, stashing the old
 *      pointer via mcpe_telemetry_set_real_fmod_listener().
 *
 * If the real pointer was never set, the hook still records telemetry
 * and returns FMOD_OK (0) — audio positioning would break, so the
 * integration MUST set the real pointer; the fallback only guards
 * against a partial install crashing the game.
 */
#include "telemetry_writer.h"
#include "telemetry_integration.h"
#include <stddef.h>

typedef int (*mcpe_fmod_listener_fn)(void *self, int listener,
                                     const mcpe_fmod_vector *pos,
                                     const mcpe_fmod_vector *vel,
                                     const mcpe_fmod_vector *forward,
                                     const mcpe_fmod_vector *up);

static mcpe_fmod_listener_fn g_real = NULL;

void mcpe_telemetry_set_real_fmod_listener(void *fn)
{
    g_real = (mcpe_fmod_listener_fn)fn;
}

int mcpe_telemetry_fmod_listener_hook(void *self, int listener,
                                      const mcpe_fmod_vector *pos,
                                      const mcpe_fmod_vector *vel,
                                      const mcpe_fmod_vector *forward,
                                      const mcpe_fmod_vector *up)
{
    if (listener == 0 && pos && forward)
        mcpe_telemetry_camera(pos->x, pos->y, pos->z,
                              forward->x, forward->y, forward->z);
    if (g_real)
        return g_real(self, listener, pos, vel, forward, up);
    return 0; /* FMOD_OK */
}
