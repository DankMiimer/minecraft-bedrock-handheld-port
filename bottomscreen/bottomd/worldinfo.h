/* worldinfo.h — the slow half of the telemetry.
 *
 * Position/heading come per-frame from the FMOD hook. Everything that
 * lives in the world database — day time, dimension, health, spawn —
 * comes from bedrockmap's snapshot pass, which writes <tiles>/player.json
 * every few seconds (see bedrockmap README). bedrockmap has been writing
 * day_time since the beginning; bottomd simply never read it.
 *
 * Polled on mtime like the waypoints file: the path only exists once the
 * active world is known, and it is rewritten atomically via rename.
 */
#ifndef BOTTOMD_WORLDINFO_H
#define BOTTOMD_WORLDINFO_H

#include <stdint.h>

/* $BOTTOMD_TILES/player.json unless $BOTTOMD_PLAYER_JSON overrides. */
void worldinfo_init(void);

/* Cheap; re-reads at most once a second and only when mtime moved. */
void worldinfo_poll(void);

/* 1 once a player.json has ever been read successfully. */
int worldinfo_have(void);

/* Bedrock world time in ticks. 0 = dawn, 6000 noon, 12000 dusk,
 * 18000 midnight; wraps at 24000. */
int64_t worldinfo_day_time(void);

/* Daylight factor for map shading: 1.0 full day, ~0.32 deep night, with
 * smooth dusk/dawn ramps. Returns 1.0 when no world info is available —
 * an unknown clock must not dim the map. */
float worldinfo_daylight(void);

/* Overworld 0 / Nether 1 / End 2, or -1 when unknown. */
int worldinfo_dimension(void);

/* Snapshot values from ~local_player. Negative means unavailable. They update
 * whenever Bedrock flushes its LevelDB and the terrain worker publishes a new
 * player.json; callers must present them as snapshot data, not per-frame data. */
float worldinfo_health(void);
float worldinfo_hunger(void);

/* Last bed spawn recorded in player.json. Returns 1 when all coordinates were
 * parsed, otherwise 0. */
int worldinfo_spawn(int *x, int *y, int *z);

#endif
