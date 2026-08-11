/* Exact-version, fail-closed Bedrock bridge for the independent RGDS UI.
 *
 * 1.21.51.01 is fully stripped.  Every hook and native call is guarded by the
 * APK's library SHA, exact object vtables and AArch64 prologues.  A mismatch
 * publishes a readable status and performs no write to libminecraftpe.
 * Inventory moves use Bedrock's own ItemStack copy/destruction and
 * Inventory::setItem paths for local prediction, then submit the matching
 * ItemStackRequest actions.  A guarded response hook confirms or rolls back
 * the prediction instead of leaving the client and server out of sync.
 */
#define _GNU_SOURCE
#include "companion_bridge.h"
#include "mcpe_companion_abi.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define TARGET_VERSION "1.21.51.01"
#define TARGET_SHA "45382be72491ec2cbe5dd4d1262989ad894b8fc611e5cbc16141d04171510927"

#define OFF_HUD_RTTI_NAME   0x02b79abdu
#define OFF_HUD_VTABLE      0x0dfcca40u
#define HUD_TICK_INDEX      3u
#define OFF_HUD_TICK        0x06d65410u
#define OFF_HUD_MODEL_PTR   0x000007f0u
#define OFF_MODEL_VTABLE    0x0df60188u
#define OFF_MODEL_GET_PLAYER_COMPONENT 0x068b41b0u
#define OFF_MODEL_GET_SELECTED_ITEM    0x068b42c0u

#define OFF_COMPONENT_PLAYER_INVENTORY 0x00000588u
#define OFF_PLAYER_INVENTORY_VTABLE    0x0e1fe500u
#define OFF_PLAYER_INVENTORY_SELECTED  0x00000010u
#define OFF_PLAYER_INVENTORY_CONTAINER 0x000000b8u
#define OFF_INVENTORY_VTABLE           0x0e1fe2e8u
#define OFF_INVENTORY_SET_ITEM         0x0aa412dcu
#define OFF_INVENTORY_SET_ITEM_IMPL    0x0aa412ecu
#define OFF_INVENTORY_BEGIN            0x00000150u
#define OFF_INVENTORY_END              0x00000158u
#define OFF_INVENTORY_CAPACITY         0x00000160u
#define INVENTORY_SLOT_COUNT           36u
#define ITEM_STACK_SIZE                0x98u
#define OFF_ITEM_STACK_VTABLE          0x0e2dec98u
#define OFF_ITEM_STACK_REFERENCE       0x00000008u
#define OFF_ITEM_STACK_AUX             0x00000022u
#define OFF_ITEM_STACK_NET_ID          0x00000080u

#define OFF_ITEM_STACK_IS_NULL         0x0b5b21b0u
#define OFF_ITEM_STACK_GET_COUNT       0x0b60ba38u
#define OFF_ITEM_STACK_COPY_CTOR       0x0b60e32cu
#define OFF_ITEM_STACK_DESTRUCTOR      0x0b5b2a38u
#define OFF_ITEM_STACK_EQUALS          0x0b60f47cu
#define OFF_ITEM_GET_FULL_NAME         0x0b600404u
#define OFF_HASHED_STRING_C_STR        0x0d7fcdf8u
#define OFF_ITEM_VTABLES_MIN           0x0e1d0000u
#define OFF_ITEM_VTABLES_MAX           0x0e400000u

/* Exact-version transaction adapter and diagnostic probe.  These three
 * transfer action vtables all dispatch their serializer through
 * ItemStackRequestActionTransferBase.  The hook logs both Bedrock-created and
 * companion-created actions immediately before their normal writer. */
#define OFF_NET_MANAGER_VTABLE         0x0e1e19e8u
#define OFF_ACTION_TAKE_VTABLE         0x0e1e1c50u
#define OFF_ACTION_PLACE_VTABLE        0x0e1e1c98u
#define OFF_ACTION_SWAP_VTABLE         0x0e1e1ce0u
#define ACTION_WRITE_INDEX             5u
#define OFF_ACTION_TRANSFER_WRITE      0x0a8c3644u
#define OFF_ACTION_TAKE_CTOR           0x0a8c40f0u
#define OFF_ACTION_PLACE_CTOR          0x0a8c4134u
#define OFF_ACTION_SWAP_CTOR           0x0a8c4178u
#define OFF_NET_BEGIN_REQUEST          0x0a8b97a8u
#define OFF_NET_END_REQUEST            0x0a8b9984u
#define OFF_NET_END_TAKE_REQUEST       0x0a8b9a90u
#define OFF_NET_TRY_SEND_BATCH         0x0a8ba38cu
#define OFF_NET_ADD_ACTION             0x0a8ba554u
#define OFF_NET_HANDLE_RESPONSE        0x0a8ba9dcu
#define OFF_REQUEST_DELETE             0x0a8d4580u
#define OFF_OPERATOR_NEW               0x0dd05ff0u
#define OFF_LOCAL_PLAYER_NET_MANAGER   0x00000a58u
#define OFF_MANAGER_ENABLED            0x00000008u
#define OFF_MANAGER_REQUEST            0x00000060u
#define OFF_MANAGER_BATCH              0x00000068u
#define ACTION_TRANSFER_SIZE           0x60u
#define OFF_ACTION_TYPE                0x08u
#define OFF_ACTION_DST_SERIALIZED      0x09u
#define OFF_ACTION_AMOUNT_SERIALIZED   0x0au
#define OFF_ACTION_AMOUNT              0x0bu
#define OFF_ACTION_SOURCE              0x10u
#define OFF_ACTION_DESTINATION         0x38u
#define SLOT_INFO_SIZE                 0x28u
#define OFF_SLOT_CONTAINER             0x00u
#define OFF_SLOT_DYNAMIC_ID            0x04u
#define OFF_SLOT_DYNAMIC_PRESENT       0x08u
#define OFF_SLOT_INDEX                 0x0cu
#define OFF_SLOT_NET_ID                0x10u
#define NET_ID_VARIANT_SIZE            0x18u
#define OFF_NET_ID_DISCRIMINATOR       0x10u
#define NET_ID_KIND_SERVER             0u
#define CONTAINER_COMBINED_HOTBAR_INVENTORY 12u
#define CONTAINER_HOTBAR               28u
#define CONTAINER_INVENTORY            29u
#define CONTAINER_CURSOR               59u
#define REQUEST_SCREEN_PRIMARY         0u
#define REQUEST_SCREEN_SECONDARY       1u
#define LOCAL_PLAYER_SCAN_BYTES        0x10000u
#define MAX_READABLE_RANGES            512u
#define MAX_LOGGED_TRANSFER_ACTIONS    16u
#define RESPONSE_ENTRY_SIZE            0x30u
#define MAX_RESPONSE_ENTRIES           64u
#define RESPONSE_RESULT_OK             0u
#define ABSOLUTE_HOOK_BYTES             16u
#define TRAMPOLINE_BYTES                32u

typedef uint32_t (*HudTickFn)(void *controller);
typedef void *(*ModelPointerFn)(void *model);
typedef int (*ItemStackPredicateFn)(void *stack);
typedef uint32_t (*ItemStackCountFn)(void *stack);
typedef void *(*ItemFullNameFn)(void *item);
typedef const char *(*HashedStringCStrFn)(void *name);
typedef void (*TransferWriteFn)(void *action, void *stream);
typedef void *(*OperatorNewFn)(size_t size);
typedef void *(*TransferCtorFn)(void *action, uint8_t amount,
                                const void *source, const void *destination);
typedef void *(*SwapCtorFn)(void *action, const void *source,
                            const void *destination);
typedef void (*BeginRequestFn)(void *manager, uint8_t screen);
typedef void (*EndRequestFn)(void *manager);
typedef void (*AddActionFn)(void *manager, void **action_holder);
typedef void (*TrySendBatchFn)(void *manager);
typedef void (*RequestDeleteFn)(void *holder, void *request);
typedef void (*DeletingDestructorFn)(void *object);
typedef void (*ItemStackCopyFn)(void *destination, const void *source);
typedef void (*ItemStackDestructorFn)(void *stack);
typedef int (*ItemStackEqualsFn)(const void *left, const void *right);
typedef void (*ContainerSetItemFn)(void *container, int slot,
                                   const void *stack);
typedef void (*HandleResponseFn)(void *manager, const void *responses);

typedef struct ReadableRange {
    uintptr_t begin;
    uintptr_t end;
} ReadableRange;

typedef struct ExactSlotInfo {
    uint64_t alignment;
    unsigned char remaining[SLOT_INFO_SIZE - sizeof(uint64_t)];
} ExactSlotInfo;

typedef struct PendingMove {
    McpeCompanionCommand command;
    uint32_t command_seq;
    volatile unsigned ready;
} PendingMove;

typedef struct MoveConfirmation {
    int active;
    uint32_t command_seq;
    int source_slot;
    int destination_slot;
    uint64_t deadline_ns;
    uint64_t matched_since_ns;
    uint32_t response_seq_at_submit;
    void *inventory;
    void *rollback_source;
    void *rollback_destination;
    McpeCompanionSlot expected_source;
    McpeCompanionSlot expected_destination;
} MoveConfirmation;

static McpeCompanionState *g_state;
static McpeCompanionCommand *g_command;
static uintptr_t g_base;
static HudTickFn g_original_tick;
static uint32_t g_last_command_seq;
static int g_init;
static int g_install; /* 0 waiting, 1 installed, -1 refused */
static int g_logged_controller;
static int g_logged_player_probe;
static int g_logged_inventory;
static int g_logged_net_manager;
static unsigned g_net_manager_probe_attempts;
static unsigned g_logged_transfer_actions;
static int g_transaction_functions_validated;
static void *g_net_manager;
static TransferWriteFn g_original_transfer_write;
static HandleResponseFn g_original_handle_response;
static PendingMove g_pending_move;
static MoveConfirmation g_move_confirmation;
static volatile uint32_t g_response_seq;
static volatile uint32_t g_response_result;
static volatile int32_t g_response_request_id;
static void *g_cached_player_component;
static uint64_t g_last_hud_tick_ns;
static volatile uint32_t g_hud_tick_seq;
static uint32_t g_swap_hud_tick_seq;
static int g_native_move_context;
static uint64_t g_native_visual_release_ns;

static uint64_t now_ns(void)
{
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000000000ull + (uint64_t)time.tv_nsec;
}

static const char *shm_name(const char *environment, const char *fallback)
{
    const char *name = getenv(environment);
    return name && name[0] == '/' ? name : fallback;
}

static void *map_shared(const char *name, size_t size)
{
    int fd = shm_open(name, O_CREAT | O_RDWR, 0644);
    if (fd < 0) return NULL;
    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        return NULL;
    }
    void *mapped = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    return mapped == MAP_FAILED ? NULL : mapped;
}

static void state_begin(void)
{
    __atomic_add_fetch(&g_state->seq, 1, __ATOMIC_ACQUIRE);
}

static void state_end(void)
{
    __atomic_add_fetch(&g_state->seq, 1, __ATOMIC_RELEASE);
}

static void publish_status(const char *status, uint32_t capabilities)
{
    if (!g_state) return;
    state_begin();
    g_state->capabilities = capabilities;
    g_state->update_ns = now_ns();
    snprintf(g_state->bedrock_version, sizeof g_state->bedrock_version,
             "%s", getenv("MCPE_BEDROCK_VERSION_NAME") ?: "unknown");
    snprintf(g_state->bridge_status, sizeof g_state->bridge_status,
             "%s", status);
    state_end();
}

static void initialize(void)
{
    if (g_init) return;
    g_init = 1;
    const char *enabled = getenv("MCPE_COMPANION");
    if (enabled && enabled[0] == '0') return;
    g_state = map_shared(shm_name("MCPE_COMPANION_STATE_SHM",
                                 MCPE_COMPANION_STATE_SHM_DEFAULT),
                         sizeof *g_state);
    g_command = map_shared(shm_name("MCPE_COMPANION_CMD_SHM",
                                   MCPE_COMPANION_CMD_SHM_DEFAULT),
                           sizeof *g_command);
    if (!g_state || !g_command) return;
    memset(g_state, 0, sizeof *g_state);
    g_state->magic = MCPE_COMPANION_STATE_MAGIC;
    g_state->abi_version = MCPE_COMPANION_ABI_VERSION;
    g_state->struct_size = sizeof *g_state;
    g_state->selected_slot = -1;
    if (g_command->magic != MCPE_COMPANION_CMD_MAGIC ||
        g_command->abi_version != MCPE_COMPANION_ABI_VERSION ||
        g_command->struct_size != sizeof *g_command) {
        memset(g_command, 0, sizeof *g_command);
        g_command->magic = MCPE_COMPANION_CMD_MAGIC;
        g_command->abi_version = MCPE_COMPANION_ABI_VERSION;
        g_command->struct_size = sizeof *g_command;
    } else {
        uint32_t existing_command = __atomic_load_n(&g_command->seq,
                                                     __ATOMIC_ACQUIRE);
        if (!(existing_command & 1u))
            g_last_command_seq = existing_command;
    }
    publish_status("VALIDATING 1.21.51 NATIVE BRIDGE", 0);
}

static uintptr_t find_library_base(void)
{
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) return 0;
    char line[1024];
    uintptr_t base = 0;
    while (fgets(line, sizeof line, maps)) {
        unsigned long start, end, offset;
        char permissions[8];
        if (!strstr(line, "libminecraftpe.so")) continue;
        if (sscanf(line, "%lx-%lx %7s %lx", &start, &end, permissions,
                   &offset) == 4 && offset == 0) {
            base = (uintptr_t)start;
            break;
        }
    }
    fclose(maps);
    return base;
}

static int target_environment(void)
{
    const char *version = getenv("MCPE_BEDROCK_VERSION_NAME");
    const char *sha = getenv("MCPE_GAME_LIBRARY_SHA256");
    return version && sha && !strcmp(version, TARGET_VERSION) &&
           !strcmp(sha, TARGET_SHA);
}

static int plausible_pointer(const void *pointer)
{
    uintptr_t value = (uintptr_t)pointer;
    return value >= 0x10000u && !(value & (sizeof(void *) - 1u));
}

static size_t load_readable_ranges(ReadableRange *ranges, size_t capacity)
{
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) return 0;
    size_t count = 0;
    char line[1024];
    while (count < capacity && fgets(line, sizeof line, maps)) {
        unsigned long begin, end;
        char permissions[8];
        if (sscanf(line, "%lx-%lx %7s", &begin, &end, permissions) == 3 &&
            permissions[0] == 'r') {
            ranges[count].begin = (uintptr_t)begin;
            ranges[count].end = (uintptr_t)end;
            ++count;
        }
    }
    fclose(maps);
    return count;
}

static int range_is_readable(const ReadableRange *ranges, size_t count,
                             const void *pointer, size_t size)
{
    uintptr_t begin = (uintptr_t)pointer;
    if (!size || begin > UINTPTR_MAX - size) return 0;
    uintptr_t end = begin + size;
    for (size_t index = 0; index < count; ++index)
        if (begin >= ranges[index].begin && end <= ranges[index].end)
            return 1;
    return 0;
}

static void probe_net_manager(void *local_player)
{
    if (g_logged_net_manager || g_net_manager_probe_attempts++ ||
        !plausible_pointer(local_player))
        return;

    ReadableRange ranges[MAX_READABLE_RANGES];
    size_t count = load_readable_ranges(ranges, MAX_READABLE_RANGES);
    uintptr_t expected = g_base + OFF_NET_MANAGER_VTABLE;
    unsigned char *begin = local_player;
    size_t scan_size = LOCAL_PLAYER_SCAN_BYTES;
    while (scan_size >= sizeof(uintptr_t) &&
           !range_is_readable(ranges, count, begin, scan_size))
        scan_size -= sizeof(uintptr_t);

    for (size_t offset = 0; offset + sizeof(uintptr_t) <= scan_size;
         offset += sizeof(uintptr_t)) {
        uintptr_t value = *(uintptr_t *)(begin + offset);
        const char *kind = NULL;
        void *manager = NULL;
        if (value == expected) {
            kind = "embedded";
            manager = begin + offset;
        } else if (plausible_pointer((void *)value) &&
                   range_is_readable(ranges, count, (void *)value,
                                     sizeof(uintptr_t)) &&
                   *(uintptr_t *)value == expected) {
            kind = "pointer";
            manager = (void *)value;
        }
        if (!manager) continue;
        g_logged_net_manager = 1;
        if (!strcmp(kind, "pointer") &&
            offset == OFF_LOCAL_PLAYER_NET_MANAGER)
            g_net_manager = manager;
        void *request = *(void **)((unsigned char *)manager + 96u);
        void *batch = *(void **)((unsigned char *)manager + 104u);
        fprintf(stderr,
                "mcpe-companion: transaction-probe manager=%p local-player+0x%zx (%s) request=%p batch=%p\n",
                manager, offset, kind, request, batch);
        fflush(stderr);
        return;
    }

    g_logged_net_manager = 1;
    fprintf(stderr,
            "mcpe-companion: transaction-probe manager not found in local-player+0x%x\n",
            LOCAL_PLAYER_SCAN_BYTES);
    fflush(stderr);
}

static void *guarded_net_manager(void *local_player)
{
    if (!g_transaction_functions_validated ||
        !plausible_pointer(local_player))
        return NULL;
    void *manager = *(void **)((unsigned char *)local_player +
                               OFF_LOCAL_PLAYER_NET_MANAGER);
    if (!plausible_pointer(manager) ||
        *(uintptr_t *)manager != g_base + OFF_NET_MANAGER_VTABLE ||
        !*(uint8_t *)((unsigned char *)manager + OFF_MANAGER_ENABLED))
        return NULL;
    g_net_manager = manager;
    return manager;
}

static void bytes_to_hex(const unsigned char *source, size_t size,
                         char *destination, size_t destination_size)
{
    static const char digits[] = "0123456789abcdef";
    if (destination_size < size * 2u + 1u) {
        if (destination_size) destination[0] = 0;
        return;
    }
    for (size_t index = 0; index < size; ++index) {
        destination[index * 2u] = digits[source[index] >> 4u];
        destination[index * 2u + 1u] = digits[source[index] & 15u];
    }
    destination[size * 2u] = 0;
}

static const char *transfer_action_name(uintptr_t vtable)
{
    if (vtable == g_base + OFF_ACTION_TAKE_VTABLE) return "take";
    if (vtable == g_base + OFF_ACTION_PLACE_VTABLE) return "place";
    if (vtable == g_base + OFF_ACTION_SWAP_VTABLE) return "swap";
    return NULL;
}

static void hooked_transfer_write(void *action, void *stream)
{
    unsigned ordinal = __atomic_fetch_add(&g_logged_transfer_actions, 1u,
                                           __ATOMIC_RELAXED);
    if (ordinal < MAX_LOGGED_TRANSFER_ACTIONS && action) {
        unsigned char *bytes = action;
        uintptr_t vtable = *(uintptr_t *)action;
        const char *name = transfer_action_name(vtable);
        if (name) {
            unsigned char *source = bytes + OFF_ACTION_SOURCE;
            unsigned char *destination = bytes + OFF_ACTION_DESTINATION;
            char source_net[NET_ID_VARIANT_SIZE * 2u + 1u];
            char destination_net[NET_ID_VARIANT_SIZE * 2u + 1u];
            bytes_to_hex(source + OFF_SLOT_NET_ID, NET_ID_VARIANT_SIZE,
                         source_net, sizeof source_net);
            bytes_to_hex(destination + OFF_SLOT_NET_ID, NET_ID_VARIANT_SIZE,
                         destination_net, sizeof destination_net);
            fprintf(stderr,
                    "mcpe-companion: transaction-probe action#%u %s type=%u amount=%u dst-serialized=%u amount-serialized=%u "
                    "src={container=%u dynamic=%u:%u slot=%u net-kind=%u net-id=%u raw=%s} "
                    "dst={container=%u dynamic=%u:%u slot=%u net-kind=%u net-id=%u raw=%s}\n",
                    ordinal + 1u, name, bytes[OFF_ACTION_TYPE],
                    bytes[OFF_ACTION_AMOUNT], bytes[OFF_ACTION_DST_SERIALIZED],
                    bytes[OFF_ACTION_AMOUNT_SERIALIZED],
                    source[OFF_SLOT_CONTAINER],
                    source[OFF_SLOT_DYNAMIC_PRESENT],
                    *(uint32_t *)(source + OFF_SLOT_DYNAMIC_ID),
                    source[OFF_SLOT_INDEX],
                    *(uint32_t *)(source + OFF_SLOT_NET_ID +
                                  OFF_NET_ID_DISCRIMINATOR),
                    *(uint32_t *)(source + OFF_SLOT_NET_ID), source_net,
                    destination[OFF_SLOT_CONTAINER],
                    destination[OFF_SLOT_DYNAMIC_PRESENT],
                    *(uint32_t *)(destination + OFF_SLOT_DYNAMIC_ID),
                    destination[OFF_SLOT_INDEX],
                    *(uint32_t *)(destination + OFF_SLOT_NET_ID +
                                  OFF_NET_ID_DISCRIMINATOR),
                    *(uint32_t *)(destination + OFF_SLOT_NET_ID),
                    destination_net);
            fflush(stderr);
        }
    }
    if (g_original_transfer_write)
        g_original_transfer_write(action, stream);
}

static void hooked_item_stack_response(void *manager, const void *responses)
{
    uint32_t result = UINT32_MAX;
    int32_t request_id = -1;
    if (responses) {
        const unsigned char *begin = *(const unsigned char *const *)responses;
        const unsigned char *end =
            *(const unsigned char *const *)((const unsigned char *)responses +
                                             sizeof(void *));
        uintptr_t begin_value = (uintptr_t)begin;
        uintptr_t end_value = (uintptr_t)end;
        if (plausible_pointer(begin) && end_value >= begin_value &&
            end_value - begin_value <=
                MAX_RESPONSE_ENTRIES * RESPONSE_ENTRY_SIZE &&
            (end_value - begin_value) % RESPONSE_ENTRY_SIZE == 0u) {
            for (const unsigned char *entry = begin; entry < end;
                 entry += RESPONSE_ENTRY_SIZE) {
                result = entry[0];
                request_id = *(const int32_t *)(entry + 0x10u);
                fprintf(stderr,
                        "mcpe-companion: item-stack-response request=%d result=%u\n",
                        request_id, result);
            }
            fflush(stderr);
        }
    }

    if (g_original_handle_response)
        g_original_handle_response(manager, responses);

    if (result != UINT32_MAX) {
        __atomic_store_n(&g_response_request_id, request_id,
                         __ATOMIC_RELAXED);
        __atomic_store_n(&g_response_result, result, __ATOMIC_RELAXED);
        __atomic_add_fetch(&g_response_seq, 1u, __ATOMIC_RELEASE);
    }
}

/* AArch64 absolute jump: ldr x16, #8; br x16; .quad target.  The exact four
 * displaced instructions are copied to an executable trampoline followed by
 * the same absolute jump back to the original function at +16. */
static int install_absolute_hook(uint32_t *entry, const uint32_t expected[4],
                                 void *replacement, void **original)
{
#if defined(__aarch64__)
    if (!entry || !replacement || !original ||
        memcmp(entry, expected, ABSOLUTE_HOOK_BYTES) != 0)
        return 0;

    uint32_t *trampoline = mmap(NULL, TRAMPOLINE_BYTES,
                                PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (trampoline == MAP_FAILED) return 0;
    memcpy(trampoline, entry, ABSOLUTE_HOOK_BYTES);
    trampoline[4] = 0x58000050u; /* ldr x16, #8 */
    trampoline[5] = 0xd61f0200u; /* br x16 */
    uintptr_t resume = (uintptr_t)entry + ABSOLUTE_HOOK_BYTES;
    memcpy(&trampoline[6], &resume, sizeof resume);
    __builtin___clear_cache((char *)trampoline,
                            (char *)trampoline + TRAMPOLINE_BYTES);
    if (mprotect(trampoline, TRAMPOLINE_BYTES,
                 PROT_READ | PROT_EXEC) != 0) {
        munmap(trampoline, TRAMPOLINE_BYTES);
        return 0;
    }

    long page_size = sysconf(_SC_PAGESIZE);
    uintptr_t page = (uintptr_t)entry & ~((uintptr_t)page_size - 1u);
    if (mprotect((void *)page, (size_t)page_size,
                 PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        munmap(trampoline, TRAMPOLINE_BYTES);
        return 0;
    }
    entry[0] = 0x58000050u;
    entry[1] = 0xd61f0200u;
    uintptr_t target = (uintptr_t)replacement;
    memcpy(&entry[2], &target, sizeof target);
    __builtin___clear_cache((char *)entry,
                            (char *)entry + ABSOLUTE_HOOK_BYTES);
    if (mprotect((void *)page, (size_t)page_size,
                 PROT_READ | PROT_EXEC) != 0) {
        /* The hook is already active.  Keeping a writable executable mapping
         * would be worse than refusing transaction support, so fail closed. */
        *original = trampoline;
        return 0;
    }
    *original = trampoline;
    return 1;
#else
    (void)entry;
    (void)expected;
    (void)replacement;
    (void)original;
    return 0;
#endif
}

static unsigned char *slot_info_bytes(ExactSlotInfo *slot)
{
    return (unsigned char *)slot;
}

static int make_slot_info(ExactSlotInfo *slot, uint8_t container,
                          uint8_t index, const unsigned char *net_variant)
{
    unsigned char *bytes = slot_info_bytes(slot);
    memset(bytes, 0, SLOT_INFO_SIZE);
    bytes[OFF_SLOT_CONTAINER] = container;
    bytes[OFF_SLOT_INDEX] = index;
    if (net_variant)
        memcpy(bytes + OFF_SLOT_NET_ID, net_variant, NET_ID_VARIANT_SIZE);
    uint32_t kind = *(uint32_t *)(bytes + OFF_SLOT_NET_ID +
                                 OFF_NET_ID_DISCRIMINATOR);
    return kind == NET_ID_KIND_SERVER;
}

static uint32_t slot_server_net_id(const ExactSlotInfo *slot)
{
    return *(const uint32_t *)((const unsigned char *)slot +
                               OFF_SLOT_NET_ID);
}

static void destroy_unowned_action(void *action)
{
    if (!action) return;
    uintptr_t *vtable = *(uintptr_t **)action;
    if (!plausible_pointer(vtable)) return;
    DeletingDestructorFn destroy = (DeletingDestructorFn)vtable[1];
    if (destroy) destroy(action);
}

static void *end_take_request(void *manager)
{
#if defined(__aarch64__)
    void *result = NULL;
    register void *argument __asm__("x0") = manager;
    register void *sret __asm__("x8") = &result;
    register uintptr_t target __asm__("x16") =
        g_base + OFF_NET_END_TAKE_REQUEST;
    __asm__ volatile(
        "blr x16"
        : "+r"(argument), "+r"(sret), "+r"(target)
        :
        : "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x9", "x10",
          "x11", "x12", "x13", "x14", "x15", "x17", "x30", "cc",
          "memory");
    return result;
#else
    (void)manager;
    return NULL;
#endif
}

static void abort_active_request(void *manager)
{
    void *request = end_take_request(manager);
    if (!request) return;
    void *holder = NULL;
    RequestDeleteFn destroy = (RequestDeleteFn)(g_base + OFF_REQUEST_DELETE);
    destroy(&holder, request);
}

static int action_is_exact(void *action, uintptr_t expected_vtable)
{
    return plausible_pointer(action) &&
           *(uintptr_t *)action == g_base + expected_vtable;
}

static void *new_transfer_action(void)
{
    OperatorNewFn allocate = (OperatorNewFn)(g_base + OFF_OPERATOR_NEW);
    return allocate(ACTION_TRANSFER_SIZE);
}

static int add_owned_action(void *manager, void *action)
{
    void *holder = action;
    AddActionFn add = (AddActionFn)(g_base + OFF_NET_ADD_ACTION);
    add(manager, &holder);
    if (!holder) return 1;
    destroy_unowned_action(holder);
    return 0;
}

static int slot_address_valid(uint32_t kind, int slot)
{
    if (slot < 0 || slot >= (int)INVENTORY_SLOT_COUNT) return 0;
    if (kind == MCPE_SLOT_HOTBAR) return slot < 9;
    if (kind == MCPE_SLOT_INVENTORY) return slot >= 9;
    return 0;
}

static uint8_t slot_container(uint32_t kind)
{
    const char *mode = getenv("MCPE_COMPANION_CONTAINER_MODE");
    if (mode && !strcmp(mode, "combined"))
        return CONTAINER_COMBINED_HOTBAR_INVENTORY;
    if (mode && !strcmp(mode, "inventory-screen"))
        return kind == MCPE_SLOT_HOTBAR ? CONTAINER_HOTBAR :
                                          CONTAINER_INVENTORY;
    /* Exact 1.21.51 native inventory requests validate hotbar slots against
     * container 28 and main-inventory slots against combined container 12.
     * This is the server-confirmed production path; inventory-screen remains
     * available above only as a reversing diagnostic. */
    return kind == MCPE_SLOT_HOTBAR ? CONTAINER_HOTBAR :
                                      CONTAINER_COMBINED_HOTBAR_INVENTORY;
}

static uint8_t request_screen(void)
{
    const char *screen = getenv("MCPE_COMPANION_REQUEST_SCREEN");
    return screen && !strcmp(screen, "secondary") ?
           REQUEST_SCREEN_SECONDARY : REQUEST_SCREEN_PRIMARY;
}

static unsigned char *guarded_inventory_begin(void *player_component)
{
    if (!plausible_pointer(player_component)) return NULL;
    void *player_inventory = *(void **)((unsigned char *)player_component +
                                        OFF_COMPONENT_PLAYER_INVENTORY);
    if (!plausible_pointer(player_inventory) ||
        *(uintptr_t *)player_inventory !=
            g_base + OFF_PLAYER_INVENTORY_VTABLE)
        return NULL;
    void *inventory = *(void **)((unsigned char *)player_inventory +
                                 OFF_PLAYER_INVENTORY_CONTAINER);
    if (!plausible_pointer(inventory) ||
        *(uintptr_t *)inventory != g_base + OFF_INVENTORY_VTABLE)
        return NULL;
    unsigned char *begin = *(unsigned char **)((unsigned char *)inventory +
                                               OFF_INVENTORY_BEGIN);
    unsigned char *end = *(unsigned char **)((unsigned char *)inventory +
                                             OFF_INVENTORY_END);
    if (!plausible_pointer(begin) || end < begin ||
        (size_t)(end - begin) != INVENTORY_SLOT_COUNT * ITEM_STACK_SIZE)
        return NULL;
    return begin;
}

static void *copy_item_stack(const void *source)
{
    if (!source) return NULL;
    void *copy = malloc(ITEM_STACK_SIZE);
    if (!copy) return NULL;
    ItemStackCopyFn construct =
        (ItemStackCopyFn)(g_base + OFF_ITEM_STACK_COPY_CTOR);
    construct(copy, source);
    if (*(uintptr_t *)copy != g_base + OFF_ITEM_STACK_VTABLE) {
        free(copy);
        return NULL;
    }
    return copy;
}

static void destroy_item_stack_copy(void **copy)
{
    if (!copy || !*copy) return;
    ItemStackDestructorFn destroy =
        (ItemStackDestructorFn)(g_base + OFF_ITEM_STACK_DESTRUCTOR);
    destroy(*copy);
    free(*copy);
    *copy = NULL;
}

static int inventory_set_item(void *inventory, int slot, const void *stack)
{
    if (!plausible_pointer(inventory) || !stack || slot < 0 ||
        slot >= (int)INVENTORY_SLOT_COUNT ||
        *(uintptr_t *)inventory != g_base + OFF_INVENTORY_VTABLE ||
        *(uintptr_t *)stack != g_base + OFF_ITEM_STACK_VTABLE)
        return 0;
    uintptr_t *vtable = *(uintptr_t **)inventory;
    if (vtable[13] != g_base + OFF_INVENTORY_SET_ITEM ||
        vtable[14] != g_base + OFF_INVENTORY_SET_ITEM_IMPL)
        return 0;
    ContainerSetItemFn set_item = (ContainerSetItemFn)vtable[13];
    set_item(inventory, slot, stack);
    return 1;
}

static int stack_equals(const void *left, const void *right)
{
    ItemStackEqualsFn equals =
        (ItemStackEqualsFn)(g_base + OFF_ITEM_STACK_EQUALS);
    return left && right && equals(left, right);
}

static int set_inventory_pair(void *inventory, int source_slot,
                              int destination_slot, const void *source,
                              const void *destination)
{
    unsigned char *begin = *(unsigned char **)((unsigned char *)inventory +
                                                OFF_INVENTORY_BEGIN);
    if (!inventory_set_item(inventory, destination_slot, destination) ||
        !inventory_set_item(inventory, source_slot, source))
        return 0;
    const void *actual_source = begin +
        (size_t)source_slot * ITEM_STACK_SIZE;
    const void *actual_destination = begin +
        (size_t)destination_slot * ITEM_STACK_SIZE;
    return stack_equals(actual_source, source) &&
           stack_equals(actual_destination, destination);
}

static void release_move_snapshots(void)
{
    destroy_item_stack_copy(&g_move_confirmation.rollback_source);
    destroy_item_stack_copy(&g_move_confirmation.rollback_destination);
    g_move_confirmation.inventory = NULL;
}

static int rollback_move_prediction(void)
{
    if (!g_move_confirmation.inventory ||
        !g_move_confirmation.rollback_source ||
        !g_move_confirmation.rollback_destination)
        return 0;
    int restored = set_inventory_pair(
        g_move_confirmation.inventory,
        g_move_confirmation.source_slot,
        g_move_confirmation.destination_slot,
        g_move_confirmation.rollback_source,
        g_move_confirmation.rollback_destination);
    fprintf(stderr,
            "mcpe-companion: local inventory prediction rollback %s source=%d destination=%d\n",
            restored ? "complete" : "FAILED",
            g_move_confirmation.source_slot,
            g_move_confirmation.destination_slot);
    fflush(stderr);
    return restored;
}

static int slot_contents_match(const McpeCompanionSlot *actual,
                               const McpeCompanionSlot *expected)
{
    return actual->count == expected->count &&
           actual->aux == expected->aux &&
           !strcmp(actual->identifier, expected->identifier);
}

static void finish_move_confirmation(uint32_t result)
{
    uint64_t ack = g_move_confirmation.command_seq / 2u;
    if (g_state->command_ack <= ack) {
        g_state->command_ack = ack;
        g_state->command_result = result;
    }
    g_state->flags &= ~MCPE_CS_COMMAND_BUSY;
    if (result == MCPE_CMD_RESULT_OK)
        g_state->flags &= ~MCPE_CS_COMMAND_ERROR;
    else
        g_state->flags |= MCPE_CS_COMMAND_ERROR;
    release_move_snapshots();
    __atomic_store_n(&g_move_confirmation.active, 0, __ATOMIC_RELEASE);
}

static void check_move_confirmation(void *manager)
{
    if (!g_move_confirmation.active) return;
    uint64_t now = now_ns();
    const McpeCompanionSlot *source =
        &g_state->slots[g_move_confirmation.source_slot];
    const McpeCompanionSlot *destination =
        &g_state->slots[g_move_confirmation.destination_slot];
    uint32_t response_seq = __atomic_load_n(&g_response_seq,
                                             __ATOMIC_ACQUIRE);
    int response_received =
        response_seq != g_move_confirmation.response_seq_at_submit;
    uint32_t response_result = __atomic_load_n(&g_response_result,
                                                __ATOMIC_RELAXED);
    if (response_received && response_result != RESPONSE_RESULT_OK) {
        int32_t request_id = __atomic_load_n(&g_response_request_id,
                                             __ATOMIC_RELAXED);
        fprintf(stderr,
                "mcpe-companion: move rejected request=%d result=%u source=%d destination=%d\n",
                request_id, response_result,
                g_move_confirmation.source_slot,
                g_move_confirmation.destination_slot);
        rollback_move_prediction();
        finish_move_confirmation(MCPE_CMD_RESULT_INVALID);
        return;
    }

    int matched = response_received &&
                  slot_contents_match(source,
                                      &g_move_confirmation.expected_source) &&
                  slot_contents_match(destination,
                                      &g_move_confirmation.expected_destination);
    if (matched) {
        if (!g_move_confirmation.matched_since_ns)
            g_move_confirmation.matched_since_ns = now;
        if (manager &&
            now - g_move_confirmation.matched_since_ns >= 500000000ull &&
            !*(void **)((unsigned char *)manager + OFF_MANAGER_REQUEST) &&
            !*(void **)((unsigned char *)manager + OFF_MANAGER_BATCH)) {
            fprintf(stderr,
                    "mcpe-companion: move confirmed source=%d destination=%d\n",
                    g_move_confirmation.source_slot,
                    g_move_confirmation.destination_slot);
            fflush(stderr);
            finish_move_confirmation(MCPE_CMD_RESULT_OK);
        }
    } else {
        g_move_confirmation.matched_since_ns = 0;
    }
    if (g_move_confirmation.active && now >= g_move_confirmation.deadline_ns) {
        fprintf(stderr,
                "mcpe-companion: move confirmation timed out source=%d destination=%d\n",
                g_move_confirmation.source_slot,
                g_move_confirmation.destination_slot);
        fflush(stderr);
        rollback_move_prediction();
        finish_move_confirmation(MCPE_CMD_RESULT_INVALID);
    }
}

static void finish_pending_move(uint32_t command_seq, uint32_t result)
{
    uint64_t ack = command_seq / 2u;
    if (g_state->command_ack <= ack) {
        g_state->command_ack = ack;
        g_state->command_result = result;
    }
    g_state->flags &= ~MCPE_CS_COMMAND_BUSY;
    if (result == MCPE_CMD_RESULT_OK)
        g_state->flags &= ~MCPE_CS_COMMAND_ERROR;
    else
        g_state->flags |= MCPE_CS_COMMAND_ERROR;
}

static void destroy_action_list(void **actions, size_t count)
{
    for (size_t index = 0; index < count; ++index) {
        destroy_unowned_action(actions[index]);
        actions[index] = NULL;
    }
}

static int construct_transfer_action(void **out, uintptr_t constructor_offset,
                                     uintptr_t expected_vtable, uint8_t amount,
                                     const ExactSlotInfo *source,
                                     const ExactSlotInfo *destination)
{
    void *action = new_transfer_action();
    if (!action) return 0;
    TransferCtorFn construct = (TransferCtorFn)(g_base + constructor_offset);
    construct(action, amount, source, destination);
    if (!action_is_exact(action, expected_vtable)) {
        destroy_unowned_action(action);
        return 0;
    }
    *out = action;
    return 1;
}

static int construct_swap_action(void **out, const ExactSlotInfo *source,
                                 const ExactSlotInfo *destination)
{
    void *action = new_transfer_action();
    if (!action) return 0;
    SwapCtorFn construct = (SwapCtorFn)(g_base + OFF_ACTION_SWAP_CTOR);
    construct(action, source, destination);
    if (!action_is_exact(action, OFF_ACTION_SWAP_VTABLE)) {
        destroy_unowned_action(action);
        return 0;
    }
    *out = action;
    return 1;
}

static uint32_t execute_move(const PendingMove *pending,
                             void *player_component, void *manager)
{
    const McpeCompanionCommand *command = &pending->command;
    if (!g_transaction_functions_validated || !manager ||
        command->type != MCPE_CMD_MOVE_STACK ||
        !slot_address_valid(command->source_kind, command->source_slot) ||
        !slot_address_valid(command->destination_kind,
                            command->destination_slot) ||
        command->source_slot == command->destination_slot)
        return MCPE_CMD_RESULT_INVALID;

    if (*(void **)((unsigned char *)manager + OFF_MANAGER_REQUEST) ||
        *(void **)((unsigned char *)manager + OFF_MANAGER_BATCH))
        return MCPE_CMD_RESULT_BUSY;

    unsigned char *inventory = guarded_inventory_begin(player_component);
    if (!inventory) return MCPE_CMD_RESULT_INVALID;
    void *player_inventory = *(void **)((unsigned char *)player_component +
                                        OFF_COMPONENT_PLAYER_INVENTORY);
    void *inventory_object =
        *(void **)((unsigned char *)player_inventory +
                   OFF_PLAYER_INVENTORY_CONTAINER);
    unsigned char *source_stack = inventory +
        (size_t)command->source_slot * ITEM_STACK_SIZE;
    unsigned char *destination_stack = inventory +
        (size_t)command->destination_slot * ITEM_STACK_SIZE;
    if (*(uintptr_t *)source_stack != g_base + OFF_ITEM_STACK_VTABLE ||
        *(uintptr_t *)destination_stack != g_base + OFF_ITEM_STACK_VTABLE)
        return MCPE_CMD_RESULT_INVALID;

    ItemStackPredicateFn is_null = (ItemStackPredicateFn)(g_base +
                                                           OFF_ITEM_STACK_IS_NULL);
    ItemStackCountFn get_count = (ItemStackCountFn)(g_base +
                                                    OFF_ITEM_STACK_GET_COUNT);
    if (is_null(source_stack)) return MCPE_CMD_RESULT_INVALID;
    uint32_t source_count = get_count(source_stack);
    int destination_empty = is_null(destination_stack);
    uint32_t destination_count = destination_empty ? 0u :
                                 get_count(destination_stack);
    if (!source_count || source_count > UINT8_MAX ||
        (!destination_empty &&
         (!destination_count || destination_count > UINT8_MAX)) ||
        (command->amount && command->amount != source_count))
        return MCPE_CMD_RESULT_INVALID;

    ExactSlotInfo source, destination, cursor_empty, cursor_source;
    ExactSlotInfo source_empty, cursor_destination;
    unsigned char empty_variant[NET_ID_VARIANT_SIZE] = {0};
    if (!make_slot_info(&source, slot_container(command->source_kind),
                        (uint8_t)command->source_slot,
                        source_stack + OFF_ITEM_STACK_NET_ID) ||
        !make_slot_info(&destination,
                        slot_container(command->destination_kind),
                        (uint8_t)command->destination_slot,
                        destination_stack + OFF_ITEM_STACK_NET_ID) ||
        !make_slot_info(&cursor_empty, CONTAINER_CURSOR, 0,
                        empty_variant) ||
        !make_slot_info(&cursor_source, CONTAINER_CURSOR, 0,
                        source_stack + OFF_ITEM_STACK_NET_ID) ||
        !make_slot_info(&source_empty,
                        slot_container(command->source_kind),
                        (uint8_t)command->source_slot, empty_variant) ||
        (!destination_empty &&
         !make_slot_info(&cursor_destination, CONTAINER_CURSOR, 0,
                         destination_stack + OFF_ITEM_STACK_NET_ID)) ||
        !slot_server_net_id(&source) ||
        (!destination_empty && !slot_server_net_id(&destination)))
        return MCPE_CMD_RESULT_INVALID;

    void *actions[3] = {NULL, NULL, NULL};
    size_t action_count = destination_empty ? 2u : 3u;
    if (!construct_transfer_action(&actions[0], OFF_ACTION_TAKE_CTOR,
                                   OFF_ACTION_TAKE_VTABLE,
                                   (uint8_t)source_count, &source,
                                   &cursor_empty)) {
        destroy_action_list(actions, action_count);
        return MCPE_CMD_RESULT_INVALID;
    }
    if (destination_empty) {
        if (!construct_transfer_action(&actions[1], OFF_ACTION_PLACE_CTOR,
                                       OFF_ACTION_PLACE_VTABLE,
                                       (uint8_t)source_count, &cursor_source,
                                       &destination)) {
            destroy_action_list(actions, action_count);
            return MCPE_CMD_RESULT_INVALID;
        }
    } else {
        if (!construct_swap_action(&actions[1], &cursor_source,
                                   &destination) ||
            !construct_transfer_action(&actions[2], OFF_ACTION_PLACE_CTOR,
                                       OFF_ACTION_PLACE_VTABLE,
                                       (uint8_t)destination_count,
                                       &cursor_destination, &source_empty)) {
            destroy_action_list(actions, action_count);
            return MCPE_CMD_RESULT_INVALID;
        }
    }

    void *old_source_stack = copy_item_stack(source_stack);
    void *old_destination_stack = copy_item_stack(destination_stack);
    if (!old_source_stack || !old_destination_stack) {
        destroy_item_stack_copy(&old_source_stack);
        destroy_item_stack_copy(&old_destination_stack);
        destroy_action_list(actions, action_count);
        return MCPE_CMD_RESULT_INVALID;
    }

    McpeCompanionSlot old_source = g_state->slots[command->source_slot];
    McpeCompanionSlot old_destination =
        g_state->slots[command->destination_slot];
    BeginRequestFn begin = (BeginRequestFn)(g_base + OFF_NET_BEGIN_REQUEST);
    EndRequestFn end = (EndRequestFn)(g_base + OFF_NET_END_REQUEST);
    TrySendBatchFn send = (TrySendBatchFn)(g_base + OFF_NET_TRY_SEND_BATCH);
    begin(manager, request_screen());
    if (!*(void **)((unsigned char *)manager + OFF_MANAGER_REQUEST) ||
        *(void **)((unsigned char *)manager + OFF_MANAGER_BATCH)) {
        destroy_item_stack_copy(&old_source_stack);
        destroy_item_stack_copy(&old_destination_stack);
        destroy_action_list(actions, action_count);
        if (*(void **)((unsigned char *)manager + OFF_MANAGER_REQUEST))
            abort_active_request(manager);
        return MCPE_CMD_RESULT_BUSY;
    }

    /* Bedrock's response only carries slot/count/net-id reconciliation.  Its
     * normal UI updates the local containers first, while the request is
     * open.  Reproduce that exact prediction through Inventory::setItem:
     * destination receives the old source and source receives old destination
     * (the latter is the canonical empty ItemStack for a simple move). */
    if (!set_inventory_pair(inventory_object, command->source_slot,
                            command->destination_slot,
                            old_destination_stack, old_source_stack)) {
        set_inventory_pair(inventory_object, command->source_slot,
                           command->destination_slot,
                           old_source_stack, old_destination_stack);
        destroy_item_stack_copy(&old_source_stack);
        destroy_item_stack_copy(&old_destination_stack);
        destroy_action_list(actions, action_count);
        abort_active_request(manager);
        fprintf(stderr,
                "mcpe-companion: local inventory prediction failed; request aborted\n");
        fflush(stderr);
        return MCPE_CMD_RESULT_INVALID;
    }

    for (size_t index = 0; index < action_count; ++index) {
        void *action = actions[index];
        actions[index] = NULL;
        if (!add_owned_action(manager, action)) {
            destroy_action_list(actions, action_count);
            set_inventory_pair(inventory_object, command->source_slot,
                               command->destination_slot,
                               old_source_stack, old_destination_stack);
            destroy_item_stack_copy(&old_source_stack);
            destroy_item_stack_copy(&old_destination_stack);
            abort_active_request(manager);
            return MCPE_CMD_RESULT_INVALID;
        }
    }
    end(manager);
    if (*(void **)((unsigned char *)manager + OFF_MANAGER_REQUEST) ||
        !*(void **)((unsigned char *)manager + OFF_MANAGER_BATCH)) {
        if (*(void **)((unsigned char *)manager + OFF_MANAGER_REQUEST))
            abort_active_request(manager);
        set_inventory_pair(inventory_object, command->source_slot,
                           command->destination_slot,
                           old_source_stack, old_destination_stack);
        destroy_item_stack_copy(&old_source_stack);
        destroy_item_stack_copy(&old_destination_stack);
        return MCPE_CMD_RESULT_INVALID;
    }

    memset(&g_move_confirmation, 0, sizeof g_move_confirmation);
    g_move_confirmation.command_seq = pending->command_seq;
    g_move_confirmation.source_slot = command->source_slot;
    g_move_confirmation.destination_slot = command->destination_slot;
    g_move_confirmation.expected_source = old_destination;
    g_move_confirmation.expected_destination = old_source;
    g_move_confirmation.response_seq_at_submit =
        __atomic_load_n(&g_response_seq, __ATOMIC_ACQUIRE);
    g_move_confirmation.inventory = inventory_object;
    g_move_confirmation.rollback_source = old_source_stack;
    g_move_confirmation.rollback_destination = old_destination_stack;
    g_move_confirmation.deadline_ns = now_ns() + 5000000000ull;
    send(manager);
    __atomic_store_n(&g_move_confirmation.active, 1, __ATOMIC_RELEASE);
    fprintf(stderr,
            "mcpe-companion: move submitted with local prediction source=%u:%d destination=%u:%d count=%u swap=%u batch-pending=%u\n",
            command->source_kind, command->source_slot,
            command->destination_kind, command->destination_slot,
            source_count, destination_empty ? 0u : 1u,
            *(void **)((unsigned char *)manager + OFF_MANAGER_BATCH) ? 1u :
                                                                      0u);
    fflush(stderr);
    return MCPE_CMD_RESULT_NONE;
}

static int copy_item_identifier(void *stack, char *destination, size_t size)
{
    if (!stack || !destination || size < 2) return 0;
    void *reference = *(void **)((unsigned char *)stack +
                                 OFF_ITEM_STACK_REFERENCE);
    if (!plausible_pointer(reference)) return 0;
    void *item = *(void **)reference;
    if (!plausible_pointer(item)) return 0;
    uintptr_t item_vtable = *(uintptr_t *)item;
    if (item_vtable < g_base + OFF_ITEM_VTABLES_MIN ||
        item_vtable >= g_base + OFF_ITEM_VTABLES_MAX)
        return 0;

    ItemFullNameFn get_full_name = (ItemFullNameFn)(g_base +
                                                     OFF_ITEM_GET_FULL_NAME);
    HashedStringCStrFn get_c_str = (HashedStringCStrFn)(g_base +
                                                       OFF_HASHED_STRING_C_STR);
    void *full_name = get_full_name(item);
    const char *source = full_name ? get_c_str(full_name) : NULL;
    if (!source) return 0;
    size_t length = strnlen(source, size);
    if (!length || length >= size) return 0;
    int colon = 0;
    for (size_t i = 0; i < length; ++i) {
        unsigned char character = (unsigned char)source[i];
        if (character == ':') colon = 1;
        if (!((character >= 'a' && character <= 'z') ||
              (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') ||
              character == '_' || character == '-' || character == '.' ||
              character == '/' || character == ':'))
            return 0;
    }
    if (!colon) return 0;
    memcpy(destination, source, length + 1u);
    return 1;
}

static void make_display_name(const char *identifier, char *destination,
                              size_t size)
{
    const char *source = strchr(identifier, ':');
    source = source ? source + 1 : identifier;
    size_t output = 0;
    int capitalize = 1;
    while (*source && output + 1u < size) {
        char character = *source++;
        if (character == '_') {
            character = ' ';
            capitalize = 1;
        } else if (capitalize && character >= 'a' && character <= 'z') {
            character = (char)(character - 'a' + 'A');
            capitalize = 0;
        } else {
            capitalize = 0;
        }
        destination[output++] = character;
    }
    destination[output] = 0;
}

static int publish_inventory(void *player_component)
{
    if (!plausible_pointer(player_component)) return 0;
    void *player_inventory = *(void **)((unsigned char *)player_component +
                                        OFF_COMPONENT_PLAYER_INVENTORY);
    if (!plausible_pointer(player_inventory) ||
        *(uintptr_t *)player_inventory !=
            g_base + OFF_PLAYER_INVENTORY_VTABLE)
        return 0;
    void *inventory = *(void **)((unsigned char *)player_inventory +
                                 OFF_PLAYER_INVENTORY_CONTAINER);
    if (!plausible_pointer(inventory) ||
        *(uintptr_t *)inventory != g_base + OFF_INVENTORY_VTABLE)
        return 0;

    unsigned char *begin = *(unsigned char **)((unsigned char *)inventory +
                                               OFF_INVENTORY_BEGIN);
    unsigned char *end = *(unsigned char **)((unsigned char *)inventory +
                                             OFF_INVENTORY_END);
    unsigned char *capacity = *(unsigned char **)((unsigned char *)inventory +
                                                  OFF_INVENTORY_CAPACITY);
    if (!plausible_pointer(begin) || end < begin || capacity < end ||
        (size_t)(end - begin) != INVENTORY_SLOT_COUNT * ITEM_STACK_SIZE)
        return 0;

    ItemStackPredicateFn is_null = (ItemStackPredicateFn)(g_base +
                                                          OFF_ITEM_STACK_IS_NULL);
    ItemStackCountFn get_count = (ItemStackCountFn)(g_base +
                                                    OFF_ITEM_STACK_GET_COUNT);
    memset(g_state->slots, 0, sizeof g_state->slots);
    for (unsigned index = 0; index < INVENTORY_SLOT_COUNT; ++index) {
        void *stack = begin + index * ITEM_STACK_SIZE;
        if (*(uintptr_t *)stack != g_base + OFF_ITEM_STACK_VTABLE) return 0;
        McpeCompanionSlot *published = &g_state->slots[index];
        published->kind = index < 9u ? MCPE_SLOT_HOTBAR : MCPE_SLOT_INVENTORY;
        published->index = (uint8_t)index;
        if (is_null(stack)) continue;
        uint32_t count = get_count(stack);
        if (!count) continue;
        published->count = (uint8_t)(count > 255u ? 255u : count);
        published->aux = *(uint8_t *)((unsigned char *)stack +
                                      OFF_ITEM_STACK_AUX);
        if (!copy_item_identifier(stack, published->identifier,
                                  sizeof published->identifier))
            return 0;
        make_display_name(published->identifier, published->display_name,
                          sizeof published->display_name);
    }
    int selected = *(int *)((unsigned char *)player_inventory +
                            OFF_PLAYER_INVENTORY_SELECTED);
    g_state->selected_slot = selected >= 0 && selected < 9 ? selected : -1;
    g_state->slot_count = INVENTORY_SLOT_COUNT;
    return 1;
}

static uint32_t hooked_hud_tick(void *controller)
{
    uint32_t result = g_original_tick ? g_original_tick(controller) : 0;
    if (!g_state || !controller || !g_base) return result;

    g_last_hud_tick_ns = now_ns();
    __atomic_add_fetch(&g_hud_tick_seq, 1u, __ATOMIC_RELEASE);
    uintptr_t vtable = *(uintptr_t *)controller;
    void *model = *(void **)((unsigned char *)controller + OFF_HUD_MODEL_PTR);
    state_begin();
    g_state->update_ns = now_ns();
    g_state->capabilities = MCPE_CC_HOOK_VALIDATED;
    g_state->slot_count = 0;
    g_state->selected_slot = -1;
    if (vtable == g_base + OFF_HUD_VTABLE && model &&
        *(uintptr_t *)model == g_base + OFF_MODEL_VTABLE) {
        ModelPointerFn get_player_component = (ModelPointerFn)(g_base +
            OFF_MODEL_GET_PLAYER_COMPONENT);
        ModelPointerFn get_selected_item = (ModelPointerFn)(g_base +
            OFF_MODEL_GET_SELECTED_ITEM);
        void *player_component = get_player_component(model);
        void *local_player = player_component ?
            (unsigned char *)player_component + 8u : NULL;
        void *selected_item = get_selected_item(model);
        g_state->flags |= MCPE_CS_IN_GAME;
        if (publish_inventory(player_component)) {
            g_cached_player_component = player_component;
            probe_net_manager(local_player);
            g_state->capabilities |= MCPE_CC_INVENTORY_READ;
            void *manager = guarded_net_manager(local_player);
            check_move_confirmation(manager);
            if (manager) {
                g_state->capabilities |= MCPE_CC_INVENTORY_MOVE;
                snprintf(g_state->bridge_status,
                         sizeof g_state->bridge_status,
                         "1.21.51 INVENTORY LIVE - MOVES ENABLED");
            } else {
                snprintf(g_state->bridge_status,
                         sizeof g_state->bridge_status,
                         "1.21.51 INVENTORY LIVE - MOVES WAITING");
            }

            if (!g_logged_inventory) {
                fprintf(stderr,
                        "mcpe-companion: exact inventory guard validated, 36 slots published\n");
                fflush(stderr);
                g_logged_inventory = 1;
            }
        } else {
            snprintf(g_state->bridge_status, sizeof g_state->bridge_status,
                     "INVENTORY OBJECT GUARD FAILED - READ REFUSED");
        }
        if (!g_logged_controller) {
            fprintf(stderr,
                    "mcpe-companion: HUD controller=%p model=%p model-vtable=%p validated\n",
                    controller, model, (void *)*(uintptr_t *)model);
            fflush(stderr);
            g_logged_controller = 1;
        }
        if (!g_logged_player_probe && player_component && selected_item) {
            fprintf(stderr,
                    "mcpe-companion: player-component=%p local-player=%p selected-item=%p delta=0x%zx\n",
                    player_component,
                    local_player,
                    selected_item,
                    (size_t)((unsigned char *)selected_item -
                             (unsigned char *)player_component));
            fflush(stderr);
            g_logged_player_probe = 1;
        }
    } else {
        g_state->flags &= ~MCPE_CS_IN_GAME;
        snprintf(g_state->bridge_status, sizeof g_state->bridge_status,
                 "HUD OBJECT GUARD FAILED - BRIDGE READ ONLY");
    }
    state_end();
    return result;
}

/* The normal HUD controller stops ticking while Bedrock's inventory screen is
 * active, but eglSwapBuffers continues on the same game/render thread. Keep
 * the last fully guarded player component and process a queued bottom-screen
 * move only after the HUD has been absent for 100 ms. This deliberately
 * refuses to transact in ordinary gameplay, where the server has no main
 * inventory container registered. */
static void process_native_inventory_context(void)
{
    uint64_t now = now_ns();
    if (!g_cached_player_component || !g_last_hud_tick_ns ||
        now - g_last_hud_tick_ns < 100000000ull)
        return;

    void *local_player = (unsigned char *)g_cached_player_component + 8u;
    void *manager = guarded_net_manager(local_player);
    if (!manager || !guarded_inventory_begin(g_cached_player_component))
        return;

    if (__atomic_exchange_n(&g_pending_move.ready, 0,
                            __ATOMIC_ACQUIRE)) {
        uint32_t move_result;
        if (__atomic_load_n(&g_move_confirmation.active,
                            __ATOMIC_ACQUIRE))
            move_result = MCPE_CMD_RESULT_BUSY;
        else
            move_result = execute_move(&g_pending_move,
                                       g_cached_player_component, manager);
        if (move_result != MCPE_CMD_RESULT_NONE)
            finish_pending_move(g_pending_move.command_seq, move_result);
    }

    state_begin();
    g_state->update_ns = now;
    if (publish_inventory(g_cached_player_component))
        check_move_confirmation(manager);
    state_end();
}

static void install_hook(void)
{
    if (g_install) return;
    if (!target_environment()) {
        publish_status("UNSUPPORTED BEDROCK BUILD - NO NATIVE WRITES", 0);
        g_install = -1;
        return;
    }
    g_base = find_library_base();
    if (!g_base) return;

    const char *rtti = (const char *)(g_base + OFF_HUD_RTTI_NAME);
    uint32_t *prologue = (uint32_t *)(g_base + OFF_HUD_TICK);
    uint32_t *player_prologue = (uint32_t *)(g_base +
                                            OFF_MODEL_GET_PLAYER_COMPONENT);
    uint32_t *selected_prologue = (uint32_t *)(g_base +
                                              OFF_MODEL_GET_SELECTED_ITEM);
    uint32_t *null_prologue = (uint32_t *)(g_base +
                                          OFF_ITEM_STACK_IS_NULL);
    uint32_t *count_prologue = (uint32_t *)(g_base +
                                           OFF_ITEM_STACK_GET_COUNT);
    uint32_t *copy_prologue = (uint32_t *)(g_base +
                                          OFF_ITEM_STACK_COPY_CTOR);
    uint32_t *destructor_prologue = (uint32_t *)(g_base +
                                                OFF_ITEM_STACK_DESTRUCTOR);
    uint32_t *equals_prologue = (uint32_t *)(g_base +
                                            OFF_ITEM_STACK_EQUALS);
    uint32_t *name_prologue = (uint32_t *)(g_base +
                                          OFF_ITEM_GET_FULL_NAME);
    uint32_t *c_str_prologue = (uint32_t *)(g_base +
                                           OFF_HASHED_STRING_C_STR);
    uint32_t *transfer_write_prologue = (uint32_t *)(g_base +
                                                     OFF_ACTION_TRANSFER_WRITE);
    uint32_t *take_ctor_prologue = (uint32_t *)(g_base +
                                               OFF_ACTION_TAKE_CTOR);
    uint32_t *place_ctor_prologue = (uint32_t *)(g_base +
                                                OFF_ACTION_PLACE_CTOR);
    uint32_t *swap_ctor_prologue = (uint32_t *)(g_base +
                                               OFF_ACTION_SWAP_CTOR);
    uint32_t *begin_prologue = (uint32_t *)(g_base +
                                           OFF_NET_BEGIN_REQUEST);
    uint32_t *end_prologue = (uint32_t *)(g_base + OFF_NET_END_REQUEST);
    uint32_t *end_take_prologue = (uint32_t *)(g_base +
                                              OFF_NET_END_TAKE_REQUEST);
    uint32_t *send_prologue = (uint32_t *)(g_base +
                                          OFF_NET_TRY_SEND_BATCH);
    uint32_t *add_prologue = (uint32_t *)(g_base + OFF_NET_ADD_ACTION);
    uint32_t *response_prologue = (uint32_t *)(g_base +
                                              OFF_NET_HANDLE_RESPONSE);
    uint32_t *set_item_prologue = (uint32_t *)(g_base +
                                              OFF_INVENTORY_SET_ITEM);
    uint32_t *set_item_impl_prologue = (uint32_t *)(g_base +
                                                   OFF_INVENTORY_SET_ITEM_IMPL);
    uint32_t *delete_prologue = (uint32_t *)(g_base + OFF_REQUEST_DELETE);
    uint32_t *new_prologue = (uint32_t *)(g_base + OFF_OPERATOR_NEW);
    uintptr_t *slot = (uintptr_t *)(g_base + OFF_HUD_VTABLE +
                                    HUD_TICK_INDEX * sizeof(uintptr_t));
    uintptr_t *take_write = (uintptr_t *)(g_base + OFF_ACTION_TAKE_VTABLE +
                                         ACTION_WRITE_INDEX * sizeof(uintptr_t));
    uintptr_t *place_write = (uintptr_t *)(g_base + OFF_ACTION_PLACE_VTABLE +
                                          ACTION_WRITE_INDEX * sizeof(uintptr_t));
    uintptr_t *swap_write = (uintptr_t *)(g_base + OFF_ACTION_SWAP_VTABLE +
                                          ACTION_WRITE_INDEX * sizeof(uintptr_t));
    uintptr_t *inventory_vtable = (uintptr_t *)(g_base +
                                                OFF_INVENTORY_VTABLE);
    if (memcmp(rtti, "19HudScreenController", 21) ||
        prologue[0] != 0xd10183ffu || prologue[1] != 0xa9037bfdu ||
        player_prologue[0] != 0xd10143ffu ||
        player_prologue[1] != 0xa9027bfdu ||
        selected_prologue[0] != 0xd10143ffu ||
        selected_prologue[1] != 0xa9027bfdu ||
        null_prologue[0] != 0xa9be7bfdu ||
        null_prologue[1] != 0xf9000bf3u ||
        count_prologue[0] != 0xb9408000u ||
        count_prologue[1] != 0xd65f03c0u ||
        copy_prologue[0] != 0xa9bd7bfdu ||
        copy_prologue[1] != 0xf9000bf5u ||
        destructor_prologue[0] != 0xa9bd7bfdu ||
        destructor_prologue[1] != 0xf9000bf5u ||
        equals_prologue[0] != 0xa9be7bfdu ||
        equals_prologue[1] != 0xa9014ff4u ||
        name_prologue[0] != 0x91038000u ||
        name_prologue[1] != 0xd65f03c0u ||
        c_str_prologue[0] != 0x39402009u ||
        c_str_prologue[1] != 0x91002408u ||
        transfer_write_prologue[0] != 0xa9be7bfdu ||
        transfer_write_prologue[1] != 0xa9014ff4u ||
        take_ctor_prologue[0] != 0xa9be7bfdu ||
        take_ctor_prologue[1] != 0xf9000bf3u ||
        place_ctor_prologue[0] != 0xa9be7bfdu ||
        place_ctor_prologue[1] != 0xf9000bf3u ||
        swap_ctor_prologue[0] != 0xa9be7bfdu ||
        swap_ctor_prologue[1] != 0xf9000bf3u ||
        begin_prologue[0] != 0xd10183ffu ||
        begin_prologue[1] != 0xa9037bfdu ||
        end_prologue[0] != 0xd10143ffu ||
        end_prologue[1] != 0xa9027bfdu ||
        end_take_prologue[0] != 0xd10203ffu ||
        end_take_prologue[1] != 0xa9047bfdu ||
        send_prologue[0] != 0xd10243ffu ||
        send_prologue[1] != 0xa9057bfdu ||
        add_prologue[0] != 0xd10283ffu ||
        add_prologue[1] != 0xa9077bfdu ||
        response_prologue[0] != 0xd104c3ffu ||
        response_prologue[1] != 0xa90d7bfdu ||
        response_prologue[2] != 0x910343fdu ||
        response_prologue[3] != 0xa90e6ffcu ||
        set_item_prologue[0] != 0xf9400008u ||
        set_item_prologue[1] != 0x2a1f03e3u ||
        set_item_prologue[2] != 0xf9403904u ||
        set_item_prologue[3] != 0xd61f0080u ||
        set_item_impl_prologue[0] != 0xd10243ffu ||
        set_item_impl_prologue[1] != 0xa9047bfdu ||
        delete_prologue[0] != 0xb40002c1u ||
        delete_prologue[1] != 0xa9bd7bfdu ||
        new_prologue[0] != 0xf0003ed0u ||
        new_prologue[1] != 0xf9454e11u ||
        *slot != g_base + OFF_HUD_TICK ||
        *take_write != g_base + OFF_ACTION_TRANSFER_WRITE ||
        *place_write != g_base + OFF_ACTION_TRANSFER_WRITE ||
        *swap_write != g_base + OFF_ACTION_TRANSFER_WRITE ||
        inventory_vtable[13] != g_base + OFF_INVENTORY_SET_ITEM ||
        inventory_vtable[14] != g_base + OFF_INVENTORY_SET_ITEM_IMPL) {
        fprintf(stderr,
                "mcpe-companion: exact 1.21.51 guard mismatch base=%p hud=%p take=%p place=%p swap=%p\n",
                (void *)g_base, (void *)*slot, (void *)*take_write,
                (void *)*place_write, (void *)*swap_write);
        publish_status("1.21.51 SIGNATURE MISMATCH - HOOK REFUSED", 0);
        g_install = -1;
        return;
    }

    long page_size = sysconf(_SC_PAGESIZE);
    uintptr_t hud_page = (uintptr_t)slot & ~((uintptr_t)page_size - 1u);
    uintptr_t action_page = (uintptr_t)take_write &
                            ~((uintptr_t)page_size - 1u);
    if (mprotect((void *)hud_page, (size_t)page_size,
                 PROT_READ | PROT_WRITE) != 0) {
        publish_status("VTABLE PROTECTION CHANGE FAILED - HOOK REFUSED", 0);
        g_install = -1;
        return;
    }
    if (mprotect((void *)action_page, (size_t)page_size,
                 PROT_READ | PROT_WRITE) != 0) {
        mprotect((void *)hud_page, (size_t)page_size, PROT_READ);
        publish_status("ACTION PROBE PROTECTION FAILED - HOOK REFUSED", 0);
        g_install = -1;
        return;
    }
    g_original_tick = (HudTickFn)*slot;
    g_original_transfer_write = (TransferWriteFn)*take_write;
    __atomic_store_n(slot, (uintptr_t)&hooked_hud_tick, __ATOMIC_RELEASE);
    __atomic_store_n(take_write, (uintptr_t)&hooked_transfer_write,
                     __ATOMIC_RELEASE);
    __atomic_store_n(place_write, (uintptr_t)&hooked_transfer_write,
                     __ATOMIC_RELEASE);
    __atomic_store_n(swap_write, (uintptr_t)&hooked_transfer_write,
                     __ATOMIC_RELEASE);
    mprotect((void *)action_page, (size_t)page_size, PROT_READ);
    mprotect((void *)hud_page, (size_t)page_size, PROT_READ);
    static const uint32_t expected_response_prologue[4] = {
        0xd104c3ffu, 0xa90d7bfdu, 0x910343fdu, 0xa90e6ffcu
    };
    if (!install_absolute_hook(response_prologue,
                               expected_response_prologue,
                               (void *)&hooked_item_stack_response,
                               (void **)&g_original_handle_response)) {
        fprintf(stderr,
                "mcpe-companion: response hook installation failed; inventory writes disabled\n");
        fflush(stderr);
        publish_status("1.21.51 RESPONSE HOOK FAILED - MOVES DISABLED",
                       MCPE_CC_HOOK_VALIDATED | MCPE_CC_INVENTORY_READ);
        g_install = -1;
        return;
    }
    g_transaction_functions_validated = 1;
    g_install = 1;
    const char *container_mode = getenv("MCPE_COMPANION_CONTAINER_MODE");
    const char *request_screen_name = getenv("MCPE_COMPANION_REQUEST_SCREEN");
    fprintf(stderr,
            "mcpe-companion: exact 1.21.51 HUD, response, and predicted inventory transaction adapter installed base=%p container-mode=%s request-screen=%s\n",
            (void *)g_base,
            container_mode && container_mode[0] ? container_mode : "hybrid",
            request_screen_name && request_screen_name[0] ?
                request_screen_name : "primary");
    fflush(stderr);
    publish_status("1.21.51 HOOK INSTALLED - WAITING FOR HUD", MCPE_CC_HOOK_VALIDATED);
}

static void process_command(void)
{
    if (!g_state || !g_command ||
        g_command->magic != MCPE_COMPANION_CMD_MAGIC ||
        g_command->abi_version != MCPE_COMPANION_ABI_VERSION)
        return;
    uint32_t before = __atomic_load_n(&g_command->seq, __ATOMIC_ACQUIRE);
    if (!before || (before & 1u) || before == g_last_command_seq) return;
    McpeCompanionCommand command;
    memcpy(&command, g_command, sizeof command);
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    uint32_t after = __atomic_load_n(&g_command->seq, __ATOMIC_RELAXED);
    if (before != after || (after & 1u)) return;
    g_last_command_seq = after;

    state_begin();
    if (command.type == MCPE_CMD_REFRESH) {
        g_state->command_ack = after / 2u;
        g_state->command_result = MCPE_CMD_RESULT_OK;
        g_state->flags &= ~MCPE_CS_COMMAND_ERROR;
    } else if (command.type == MCPE_CMD_MOVE_STACK &&
               g_install == 1 && g_transaction_functions_validated &&
               (g_state->capabilities & MCPE_CC_INVENTORY_MOVE)) {
        if (__atomic_load_n(&g_pending_move.ready, __ATOMIC_ACQUIRE) ||
            __atomic_load_n(&g_move_confirmation.active,
                            __ATOMIC_ACQUIRE)) {
            g_state->command_ack = after / 2u;
            g_state->command_result = MCPE_CMD_RESULT_BUSY;
            g_state->flags |= MCPE_CS_COMMAND_ERROR;
        } else {
            g_pending_move.command = command;
            g_pending_move.command_seq = after;
            g_native_move_context = 1;
            g_native_visual_release_ns = 0;
            g_state->command_result = MCPE_CMD_RESULT_NONE;
            g_state->flags |= MCPE_CS_COMMAND_BUSY;
            g_state->flags &= ~MCPE_CS_COMMAND_ERROR;
            __atomic_store_n(&g_pending_move.ready, 1,
                             __ATOMIC_RELEASE);
        }
    } else {
        g_state->command_ack = after / 2u;
        g_state->command_result = MCPE_CMD_RESULT_UNSUPPORTED;
        g_state->flags |= MCPE_CS_COMMAND_ERROR;
    }
    g_state->update_ns = now_ns();
    state_end();
}

void mcpe_companion_frame(void)
{
    initialize();
    if (!g_state) return;
    install_hook();
    process_command();
    if (g_install == 1)
        process_native_inventory_context();
    if (g_install != 1) {
        state_begin();
        g_state->update_ns = now_ns();
        state_end();
    }
}

int mcpe_companion_top_frame_action(void)
{
    uint32_t sequence = __atomic_load_n(&g_hud_tick_seq, __ATOMIC_ACQUIRE);
    int hud_frame = sequence != g_swap_hud_tick_seq;
    g_swap_hud_tick_seq = sequence;
    if (g_native_move_context) {
        int complete =
            !__atomic_load_n(&g_pending_move.ready, __ATOMIC_ACQUIRE) &&
            !__atomic_load_n(&g_move_confirmation.active,
                             __ATOMIC_ACQUIRE) &&
            !(g_state && (g_state->flags & MCPE_CS_COMMAND_BUSY));
        uint64_t now = now_ns();
        if (complete && !g_native_visual_release_ns)
            /* bottomd sees the acknowledgement, releases E, and Bedrock
             * animates back to the HUD. Do not let those transitional HUD
             * ticks replace the cached gameplay frame or reveal one native
             * inventory frame. */
            g_native_visual_release_ns = now + 500000000ull;
        if (complete && hud_frame &&
            now >= g_native_visual_release_ns) {
            g_native_move_context = 0;
            g_native_visual_release_ns = 0;
            return 1;
        }
        return 2;
    }
    return hud_frame ? 1 : 0;
}
