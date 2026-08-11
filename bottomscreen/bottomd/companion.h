#ifndef BOTTOMD_COMPANION_H
#define BOTTOMD_COMPANION_H

#include "../telemetry/mcpe_companion_abi.h"

void companion_init(void);
int companion_read(McpeCompanionState *out);
uint64_t companion_send(uint32_t type, uint32_t source_kind,
                        int source_slot, uint32_t destination_kind,
                        int destination_slot, uint32_t amount,
                        uint32_t recipe_network_id, const char *text);
void companion_close(void);

#endif
