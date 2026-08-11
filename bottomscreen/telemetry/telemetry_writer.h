/*
 * telemetry_writer.h — writer API for the game-process side.
 * Compiled into mcpelauncher-client. All functions are safe to call
 * unconditionally: if init failed or MCPE_TELEMETRY=0, they no-op.
 * Single-writer design; call everything from the game/render thread
 * (the FMOD listener call and the frame-metrics site already are).
 */
#ifndef MCPE_TELEMETRY_WRITER_H
#define MCPE_TELEMETRY_WRITER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Lazily called by the other entry points; explicit call optional.
 * Returns 1 if telemetry is active, 0 if disabled/unavailable. */
int mcpe_telemetry_init(void);

/* Camera update (from the FMOD listener hook). Derives yaw/pitch. */
void mcpe_telemetry_camera(float px, float py, float pz,
                           float fx, float fy, float fz);

/* Frame metrics (from the client's existing frame instrumentation).
 * Pass swap_ms = -1 if unknown. */
void mcpe_telemetry_frame(float frame_ms, float swap_ms);

/* Network shim observation. `address_host` is an IPv4 address in host byte
 * order. Direct unicast peers on Bedrock's gameplay ports refresh the remote
 * world signal; discovery broadcast/multicast does not. Packet contents and
 * addresses are never retained or exposed. */
void mcpe_telemetry_network_peer_ipv4(uint32_t address_host, uint16_t port);
void mcpe_telemetry_network_peer_ipv6(const uint8_t address[16], uint16_t port);

/* Event hooks (per-version, optional). */
void mcpe_telemetry_container(int open);
void mcpe_telemetry_death(float x, float y, float z, int dimension);

#ifdef __cplusplus
}
#endif

#endif
