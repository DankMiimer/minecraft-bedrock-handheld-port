/*
 * telemetry_integration.h — what the launcher integration code needs:
 * the FMOD interposer entry points and the mangled symbol name.
 * C-linkage; safe to include from C or C++.
 */
#ifndef MCPE_TELEMETRY_INTEGRATION_H
#define MCPE_TELEMETRY_INTEGRATION_H

#define MCPE_TELEMETRY_FMOD_LISTENER_SYM \
    "_ZN4FMOD6System23set3DListenerAttributesEiPK11FMOD_VECTORS3_S3_S3_"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { float x, y, z; } mcpe_fmod_vector;

/* The interposer registered in the android-linker namespace under
 * MCPE_TELEMETRY_FMOD_LISTENER_SYM. ABI-compatible with the FMOD
 * member function on aarch64/armhf (this = first arg). */
int mcpe_telemetry_fmod_listener_hook(void *self, int listener,
                                      const mcpe_fmod_vector *pos,
                                      const mcpe_fmod_vector *vel,
                                      const mcpe_fmod_vector *forward,
                                      const mcpe_fmod_vector *up);

/* Give the interposer the real host-libfmod function (dlsym result).
 * MUST be called for audio positioning to keep working. */
void mcpe_telemetry_set_real_fmod_listener(void *fn);

#ifdef __cplusplus
}
#endif

#endif
