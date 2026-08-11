#define _GNU_SOURCE
#include "companion.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static McpeCompanionState *g_state;
static McpeCompanionCommand *g_cmd;
static uint32_t g_next_command = 1;
static char g_state_name[128];
static char g_cmd_name[128];

static void name_from_env(char *out, size_t size, const char *env,
                          const char *fallback)
{
    const char *value = getenv(env);
    snprintf(out, size, "%s", value && value[0] == '/' ? value : fallback);
}

static void *map_object(const char *name, size_t size, int write, int create)
{
    int flags = write ? O_RDWR : O_RDONLY;
    if (create) flags |= O_CREAT;
    int fd = shm_open(name, flags, 0644);
    if (fd < 0) return NULL;
    if (create && ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)size) {
        close(fd);
        return NULL;
    }
    void *mapped = mmap(NULL, size, write ? PROT_READ | PROT_WRITE : PROT_READ,
                        MAP_SHARED, fd, 0);
    close(fd);
    return mapped == MAP_FAILED ? NULL : mapped;
}

void companion_init(void)
{
    name_from_env(g_state_name, sizeof g_state_name,
                  "BOTTOMD_COMPANION_STATE_SHM", MCPE_COMPANION_STATE_SHM_DEFAULT);
    name_from_env(g_cmd_name, sizeof g_cmd_name,
                  "BOTTOMD_COMPANION_CMD_SHM", MCPE_COMPANION_CMD_SHM_DEFAULT);
}

static void ensure_state(void)
{
    if (!g_state)
        g_state = map_object(g_state_name, sizeof *g_state, 0, 0);
}

static void ensure_command(void)
{
    if (g_cmd) return;
    g_cmd = map_object(g_cmd_name, sizeof *g_cmd, 1, 1);
    if (!g_cmd) return;
    if (g_cmd->magic != MCPE_COMPANION_CMD_MAGIC ||
        g_cmd->abi_version != MCPE_COMPANION_ABI_VERSION ||
        g_cmd->struct_size != sizeof *g_cmd) {
        memset(g_cmd, 0, sizeof *g_cmd);
        g_cmd->magic = MCPE_COMPANION_CMD_MAGIC;
        g_cmd->abi_version = MCPE_COMPANION_ABI_VERSION;
        g_cmd->struct_size = sizeof *g_cmd;
    }
}

int companion_read(McpeCompanionState *out)
{
    ensure_state();
    if (!g_state || !out || g_state->magic != MCPE_COMPANION_STATE_MAGIC ||
        g_state->abi_version != MCPE_COMPANION_ABI_VERSION ||
        g_state->struct_size != sizeof *g_state)
        return 0;
    for (int attempt = 0; attempt < 4; ++attempt) {
        uint32_t before = __atomic_load_n(&g_state->seq, __ATOMIC_ACQUIRE);
        if (before & 1u) continue;
        memcpy(out, g_state, sizeof *out);
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        uint32_t after = __atomic_load_n(&g_state->seq, __ATOMIC_RELAXED);
        if (before == after && !(after & 1u)) return 1;
    }
    return 0;
}

uint64_t companion_send(uint32_t type, uint32_t source_kind,
                        int source_slot, uint32_t destination_kind,
                        int destination_slot, uint32_t amount,
                        uint32_t recipe_network_id, const char *text)
{
    ensure_command();
    if (!g_cmd) return 0;
    uint32_t sequence = g_next_command++;
    __atomic_store_n(&g_cmd->seq, sequence * 2u + 1u, __ATOMIC_RELEASE);
    g_cmd->type = type;
    g_cmd->source_kind = source_kind;
    g_cmd->source_slot = source_slot;
    g_cmd->destination_kind = destination_kind;
    g_cmd->destination_slot = destination_slot;
    g_cmd->amount = amount;
    g_cmd->recipe_network_id = recipe_network_id;
    snprintf(g_cmd->text, sizeof g_cmd->text, "%s", text ? text : "");
    __atomic_store_n(&g_cmd->seq, sequence * 2u, __ATOMIC_RELEASE);
    return sequence;
}

void companion_close(void)
{
    if (g_state) munmap(g_state, sizeof *g_state);
    if (g_cmd) munmap(g_cmd, sizeof *g_cmd);
    g_state = NULL;
    g_cmd = NULL;
}
