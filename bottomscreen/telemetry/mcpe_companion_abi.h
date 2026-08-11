/* Versioned Bedrock <-> independent RGDS companion protocol.
 *
 * This ABI contains values only: no process pointers and no Mojang assets.
 * The game is the sole state writer. bottomd is the sole command writer.
 * Commands describe intent; the game-side bridge must route them through
 * Bedrock's normal container/transaction APIs and may reject any command.
 */
#ifndef MCPE_COMPANION_ABI_H
#define MCPE_COMPANION_ABI_H

#include <stdint.h>

#define MCPE_COMPANION_ABI_VERSION 1u
#define MCPE_COMPANION_STATE_MAGIC 0x4d434353u /* MCCS */
#define MCPE_COMPANION_CMD_MAGIC   0x4d434351u /* MCCQ */
#define MCPE_COMPANION_STATE_SHM_DEFAULT "/mcpe_companion_state"
#define MCPE_COMPANION_CMD_SHM_DEFAULT   "/mcpe_companion_cmd"

#define MCPE_COMPANION_MAX_SLOTS   46
#define MCPE_COMPANION_MAX_CHAT    16
#define MCPE_COMPANION_MAX_RECIPES 20

enum McpeCompanionCapabilities {
    MCPE_CC_HOOK_VALIDATED = 1u << 0,
    MCPE_CC_INVENTORY_READ = 1u << 1,
    MCPE_CC_INVENTORY_MOVE = 1u << 2,
    MCPE_CC_CRAFTING_READ  = 1u << 3,
    MCPE_CC_CRAFTING_DO    = 1u << 4,
    MCPE_CC_CHAT_READ      = 1u << 5,
    MCPE_CC_CHAT_SEND      = 1u << 6,
};

enum McpeCompanionStateFlags {
    MCPE_CS_IN_GAME       = 1u << 0,
    MCPE_CS_CREATIVE      = 1u << 1,
    MCPE_CS_RECIPE_BOOK   = 1u << 2,
    MCPE_CS_COMMAND_BUSY  = 1u << 3,
    MCPE_CS_COMMAND_ERROR = 1u << 4,
};

enum McpeCompanionSlotKind {
    MCPE_SLOT_INVENTORY = 0,
    MCPE_SLOT_HOTBAR    = 1,
    MCPE_SLOT_ARMOR     = 2,
    MCPE_SLOT_OFFHAND   = 3,
    MCPE_SLOT_CURSOR    = 4,
    MCPE_SLOT_CRAFTING  = 5,
    MCPE_SLOT_RESULT    = 6,
};

typedef struct McpeCompanionSlot {
    uint8_t kind;
    uint8_t index;
    uint8_t count;
    uint8_t flags;
    uint16_t aux;
    uint16_t damage;
    uint16_t max_damage;
    uint16_t texture_variant;
    char identifier[64];
    char display_name[64];
    /* Atlas-relative path supplied by Bedrock where available.  bottomd may
     * instead resolve identifier through its user-install item index. */
    char texture_path[96];
} McpeCompanionSlot;

typedef struct McpeCompanionChatLine {
    uint64_t received_ns;
    char sender[48];
    char message[208];
} McpeCompanionChatLine;

typedef struct McpeCompanionRecipe {
    uint32_t network_id;
    uint16_t craftable_count;
    uint8_t ingredient_count;
    uint8_t flags;
    char identifier[64];
    char display_name[64];
    char texture_path[96];
} McpeCompanionRecipe;

typedef struct McpeCompanionState {
    uint32_t magic;
    uint16_t abi_version;
    uint16_t struct_size;
    volatile uint32_t seq;
    uint32_t capabilities;
    uint32_t flags;
    uint64_t update_ns;
    uint64_t command_ack;
    uint32_t command_result;
    uint16_t slot_count;
    uint16_t chat_count;
    uint16_t recipe_count;
    int16_t selected_slot;
    uint8_t crafting_width;
    uint8_t crafting_height;
    char bedrock_version[32];
    char bridge_status[96];
    McpeCompanionSlot slots[MCPE_COMPANION_MAX_SLOTS];
    McpeCompanionChatLine chat[MCPE_COMPANION_MAX_CHAT];
    McpeCompanionRecipe recipes[MCPE_COMPANION_MAX_RECIPES];
} McpeCompanionState;

enum McpeCompanionCommandType {
    MCPE_CMD_NONE = 0,
    MCPE_CMD_SELECT_SLOT,
    MCPE_CMD_MOVE_STACK,
    MCPE_CMD_MOVE_ONE,
    MCPE_CMD_TAKE_HALF,
    MCPE_CMD_CRAFT_RECIPE,
    MCPE_CMD_SEND_CHAT,
    MCPE_CMD_REFRESH,
};

enum McpeCompanionCommandResult {
    MCPE_CMD_RESULT_NONE = 0,
    MCPE_CMD_RESULT_OK = 1,
    MCPE_CMD_RESULT_UNSUPPORTED = 2,
    MCPE_CMD_RESULT_INVALID = 3,
    MCPE_CMD_RESULT_BUSY = 4,
};

typedef struct McpeCompanionCommand {
    uint32_t magic;
    uint16_t abi_version;
    uint16_t struct_size;
    volatile uint32_t seq;
    uint32_t type;
    uint32_t source_kind;
    int32_t source_slot;
    uint32_t destination_kind;
    int32_t destination_slot;
    uint32_t amount;
    uint32_t recipe_network_id;
    char text[256];
} McpeCompanionCommand;

#endif
