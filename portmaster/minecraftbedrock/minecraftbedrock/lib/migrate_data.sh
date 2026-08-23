#!/bin/bash
# Transactional migration of user-owned data into the edition-neutral root.

mcpe_migration_privileged() {
  if [ -n "${ESUDO:-}" ]; then
    # ESUDO is supplied by PortMaster as a command plus scoped options.
    # shellcheck disable=SC2086
    $ESUDO "$@"
  else
    "$@"
  fi
}

mcpe_paths_same_directory() {
  local left right
  [ -d "$1" ] && [ -d "$2" ] || return 1
  left="$(stat -Lc '%d:%i' "$1" 2>/dev/null || true)"
  right="$(stat -Lc '%d:%i' "$2" 2>/dev/null || true)"
  [ -n "$left" ] && [ "$left" = "$right" ]
}

mcpe_path_is_mountpoint() {
  local src="$1"
  # ROCKNIX's mountpoint applet compares device IDs and misses same-device
  # bind mounts on exFAT. The kernel table remains authoritative.
  if [ -r /proc/self/mountinfo ] &&
     awk -v target="$src" '$5 == target { found=1 } END { exit !found }' \
       /proc/self/mountinfo 2>/dev/null; then
    return 0
  fi
  command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$src" 2>/dev/null
}

mcpe_detach_shared_path() {
  local src="$1"
  if mcpe_path_is_mountpoint "$src"; then
    mcpe_migration_privileged umount "$src" 2>/dev/null || return 1
  fi
  mcpe_is_empty_dir "$src" && rmdir "$src" 2>/dev/null || true
}

mcpe_attach_shared_path() { # source_path shared_path manifest new_transaction
  local src="$1" dst="$2" pending="$3" new_transaction="$4"
  if [ "$new_transaction" = 1 ]; then
    printf 'link=%s|%s\n' "$src" "$dst" >>"$pending" || return 1
  fi
  if ln -s "$dst" "$src" 2>/dev/null; then
    MCPE_MIGRATION_ACTIONS+=("link|$src|")
    return 0
  fi

  # exFAT and some network-backed ROM filesystems cannot create symlinks.
  # A bind mount gives the payload its compatibility path while keeping the
  # edition-neutral data root. Empty mountpoint directories survive a reboot;
  # the next launch simply reattaches them.
  command -v mount >/dev/null 2>&1 || {
    echo "shared-data migration: symlinks are unavailable and mount is missing: $src" >&2
    return 1
  }
  mkdir -p "$src" || return 1
  if [ "$new_transaction" = 1 ]; then
    printf 'bind=%s|%s\n' "$src" "$dst" >>"$pending" || return 1
  fi
  if ! mcpe_migration_privileged mount --bind "$dst" "$src"; then
    mcpe_is_empty_dir "$src" && rmdir "$src" 2>/dev/null || true
    echo "shared-data migration: could not bind $dst at $src" >&2
    return 1
  fi
  MCPE_MIGRATION_ACTIONS+=("bind|$src|$dst")
  echo "shared-data migration: using a bind mount for symlink-incompatible storage: $src"
}

mcpe_migration_rollback_actions() {
  local i action src dst
  for ((i=${#MCPE_MIGRATION_ACTIONS[@]}-1; i>=0; i--)); do
    IFS='|' read -r action src dst <<<"${MCPE_MIGRATION_ACTIONS[$i]}"
    case "$action" in
      bind) mcpe_detach_shared_path "$src" || true ;;
      link) [ -L "$src" ] && rm -f "$src" ;;
      move) [ -e "$dst" ] && [ ! -e "$src" ] && mv "$dst" "$src" ;;
      mkdir) mcpe_is_empty_dir "$src" && rmdir "$src" 2>/dev/null || true ;;
    esac
  done
}

mcpe_recover_incomplete_migration() {
  local manifest="$1" state i line action src dst
  [ -f "$manifest" ] || return 0
  state="$(sed -n 's/^state=//p' "$manifest" | tail -1)"
  [ "$state" = migrating ] || return 0
  mapfile -t recovery_lines < <(grep -E '^(move|link|bind|mkdir)=' "$manifest" 2>/dev/null || true)
  for ((i=${#recovery_lines[@]}-1; i>=0; i--)); do
    line="${recovery_lines[$i]}"
    action="${line%%=*}"
    IFS='|' read -r src dst <<<"${line#*=}"
    case "$action" in
      bind) mcpe_detach_shared_path "$src" || true ;;
      link) [ -L "$src" ] && rm -f "$src" ;;
      move) [ -e "$dst" ] && [ ! -e "$src" ] && mv "$dst" "$src" ;;
      mkdir) mcpe_is_empty_dir "$src" && rmdir "$src" 2>/dev/null || true ;;
    esac
  done
  printf 'state=recovered\nrecovered=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" >>"$manifest"
  mv "$manifest" "${manifest%.pending}.recovered"
}

# Canonical identity comes from mcpe_resolve_cfw in common.sh, which this file
# is always loaded alongside. Unlike the CFW_NAME-only check it replaces, that
# resolver also accepts /etc/os-release, so a Knulli install whose PortMaster
# control files do not set CFW_NAME now takes the Knulli shared-data path it
# always should have. The merge below is preflighted and aborts on any
# collision, so adopting it on an existing install cannot overwrite user data.
mcpe_is_knulli() {
  mcpe_is_cfw knulli
}

# Knulli's EmulationStation recursively inventories every visible directory in
# roms/ports. An extracted Bedrock version contains tens of thousands of files,
# so keeping shared data in minecraftbedrock-data makes merely opening Ports
# take seconds. Knulli skips dot-directories, so adopt the historical hidden
# root used by this port on that CFW. The merge is preflighted and idempotent:
# disjoint files move, byte-identical duplicates collapse, and every other
# collision aborts before anything changes.
mcpe_knulli_merge_shared_roots() { # visible_root hidden_root
  local visible="$1" hidden="$2" src dst rel target_link source_link
  [ -d "$visible" ] || return 0
  mkdir -p "$hidden" || return 1

  while IFS= read -r -d '' src; do
    rel="${src#"$visible"/}"
    dst="$hidden/$rel"
    if [ -d "$src" ] && [ ! -L "$src" ]; then
      if { [ -e "$dst" ] || [ -L "$dst" ]; } &&
         { [ ! -d "$dst" ] || [ -L "$dst" ]; }; then
        echo "Knulli shared-data collision: directory $src conflicts with $dst" >&2
        return 1
      fi
    elif [ -f "$src" ] && [ ! -L "$src" ]; then
      if [ -e "$dst" ] || [ -L "$dst" ]; then
        if [ ! -f "$dst" ] || [ -L "$dst" ] || ! cmp -s "$src" "$dst"; then
          echo "Knulli shared-data collision: file $src differs from $dst" >&2
          return 1
        fi
      fi
    elif [ -L "$src" ]; then
      if [ -e "$dst" ] || [ -L "$dst" ]; then
        source_link="$(readlink "$src" 2>/dev/null || true)"
        target_link="$(readlink "$dst" 2>/dev/null || true)"
        if [ ! -L "$dst" ] || [ "$source_link" != "$target_link" ]; then
          echo "Knulli shared-data collision: link $src differs from $dst" >&2
          return 1
        fi
      fi
    elif [ -S "$src" ]; then
      case "$src" in
        */mcpelauncher/file_handler) ;;
        *)
          echo "Knulli shared-data migration does not support socket: $src" >&2
          return 1
          ;;
      esac
    else
      echo "Knulli shared-data migration does not support special file: $src" >&2
      return 1
    fi
  done < <(find "$visible" -mindepth 1 -print0 2>/dev/null)

  # Build directories first, then atomically move each non-duplicate node.
  while IFS= read -r -d '' src; do
    rel="${src#"$visible"/}"
    mkdir -p "$hidden/$rel" || return 1
  done < <(find "$visible" -mindepth 1 -type d ! -type l -print0 2>/dev/null)
  while IFS= read -r -d '' src; do
    rel="${src#"$visible"/}"
    dst="$hidden/$rel"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      rm -f "$src" || return 1
    else
      mkdir -p "$(dirname "$dst")" || return 1
      mv "$src" "$dst" || return 1
    fi
  done < <(find "$visible" -mindepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
  # mcpelauncher creates this local IPC socket for each running session. It is
  # stale by the next entry-script invocation and must never be treated as
  # persistent profile data or copied into the relocated tree.
  while IFS= read -r -d '' src; do
    case "$src" in
      */mcpelauncher/file_handler) rm -f "$src" || return 1 ;;
    esac
  done < <(find "$visible" -mindepth 1 -type s -print0 2>/dev/null)
  while IFS= read -r -d '' src; do
    rmdir "$src" 2>/dev/null || true
  done < <(find "$visible" -depth -type d -print0 2>/dev/null)
  [ ! -e "$visible" ] || {
    echo "Knulli shared-data migration left unexpected entries in $visible" >&2
    return 1
  }
}

mcpe_prepare_knulli_shared_root() {
  local ports_root visible hidden item src temp target_link
  mcpe_is_knulli || return 0
  ports_root="$(dirname "$GAMEDIR")"
  visible="$ports_root/minecraftbedrock-data"
  hidden="$ports_root/.minecraftbedrock-data"
  # Knulli's long-lived ES process can retain the old manifest-derived visible
  # root in its environment after the one-time relocation. Treat precisely
  # that obsolete default as unset; a genuinely custom root still wins.
  if [ -n "${MCPE_SHARED_ROOT:-}" ]; then
    if [ "$MCPE_SHARED_ROOT" = "$visible" ]; then
      unset MCPE_SHARED_ROOT
    else
      return 0
    fi
  fi
  # mcpe_load_edition exports the manifest's ordinary visible dirname before
  # this helper runs; that value is a default, not a caller override.
  case "${MCPE_SHARED_DIRNAME:-}" in
    ""|minecraftbedrock-data) ;;
    *) return 0 ;;
  esac
  if [ -d "$visible" ] && [ ! -e "$hidden" ]; then
    mv "$visible" "$hidden" || return 1
  elif [ -d "$visible" ]; then
    mcpe_knulli_merge_shared_roots "$visible" "$hidden" || return 1
  fi

  # Retarget only links created by the previous visible-root migration. Any
  # unrelated link is left for the normal collision guard below to reject.
  for item in apk versions profiles backups; do
    src="$GAMEDIR/$item"
    [ -L "$src" ] || continue
    target_link="$(readlink "$src" 2>/dev/null || true)"
    [ "$target_link" = "$visible/$item" ] || continue
    temp="$src.knulli-new-$$"
    rm -f "$temp"
    ln -s "$hidden/$item" "$temp" || return 1
    rm -f "$src" || { rm -f "$temp"; return 1; }
    mv "$temp" "$src" || return 1
  done
  MCPE_SHARED_DIRNAME=.minecraftbedrock-data
  export MCPE_SHARED_DIRNAME
}

mcpe_migrate_shared_data() {
  local ports_root item src dst pending target_link total_kb free_kb source_dev target_dev
  local migration_source_root legacy_standard current_has_data=0 legacy_has_data=0
  local new_transaction=0 cross_device_kb=0
  mcpe_prepare_knulli_shared_root || return 1
  ports_root="$(dirname "$GAMEDIR")"
  MCPE_SHARED_ROOT="${MCPE_SHARED_ROOT:-$ports_root/${MCPE_SHARED_DIRNAME:-minecraftbedrock-data}}"
  export MCPE_SHARED_ROOT
  mkdir -p "$GAMEDIR/config" || return 1
  pending="$GAMEDIR/config/migration.pending"
  MCPE_MIGRATION_ACTIONS=()

  # A power loss during the move phase is distinguishable from a completed
  # migration awaiting its first clean launch. Only the former is rolled back.
  mcpe_recover_incomplete_migration "$pending" || return 1

  # The dedicated RGDS edition is installed beside a legacy 1.x standard
  # payload. Adopt that old data when the new RGDS payload has none of its own,
  # and stop on ambiguity instead of combining two installations.
  migration_source_root="$GAMEDIR"
  legacy_standard="$ports_root/minecraftbedrock"
  if [ "${MCPE_EDITION_ID:-}" = minecraftbedrock.rgds ] &&
     [ "$legacy_standard" != "$GAMEDIR" ] && [ -d "$legacy_standard" ]; then
    for item in apk versions profiles backups; do
      [ -d "$GAMEDIR/$item" ] && [ ! -L "$GAMEDIR/$item" ] &&
        ! mcpe_is_empty_dir "$GAMEDIR/$item" && current_has_data=1
      [ -d "$legacy_standard/$item" ] && [ ! -L "$legacy_standard/$item" ] &&
        ! mcpe_is_empty_dir "$legacy_standard/$item" && legacy_has_data=1
    done
    if [ "$current_has_data" = 1 ] && [ "$legacy_has_data" = 1 ]; then
      echo "shared-data migration: both RGDS and legacy standard payloads contain data" >&2
      echo "No files were changed. Move one installation aside and relaunch." >&2
      return 1
    fi
    [ "$legacy_has_data" = 1 ] && migration_source_root="$legacy_standard"
  fi

  if [ ! -d "$MCPE_SHARED_ROOT" ]; then
    mkdir -p "$MCPE_SHARED_ROOT" || return 1
    MCPE_MIGRATION_ACTIONS+=("mkdir|$MCPE_SHARED_ROOT|")
  fi

  # Inventory and collision detection happen before the first move.
  total_kb=0
  target_dev="$(df -P "$MCPE_SHARED_ROOT" 2>/dev/null | awk 'NR==2 {print $1}')"
  for item in apk versions profiles backups; do
    src="$migration_source_root/$item"; dst="$MCPE_SHARED_ROOT/$item"
    mcpe_paths_same_directory "$src" "$dst" && continue
    if [ -e "$src" ] && [ ! -d "$src" ] && [ ! -L "$src" ]; then
      echo "shared-data migration: expected directory, found file: $src" >&2
      return 1
    fi
    if [ -d "$src" ] && [ ! -L "$src" ]; then
      total_kb=$((total_kb + $(du -sk "$src" 2>/dev/null | awk '{print $1+0}')))
      if [ -d "$dst" ] && ! mcpe_is_empty_dir "$src" && ! mcpe_is_empty_dir "$dst"; then
        echo "shared-data migration collision: both $src and $dst contain data" >&2
        echo "No files were overwritten. Move one set aside and relaunch." >&2
        return 1
      fi
      source_dev="$(df -P "$src" 2>/dev/null | awk 'NR==2 {print $1}')"
      [ -n "$source_dev" ] && [ -n "$target_dev" ] && [ "$source_dev" != "$target_dev" ] &&
        cross_device_kb=$((cross_device_kb + $(du -sk "$src" 2>/dev/null | awk '{print $1+0}')))
    fi
  done
  free_kb="$(df -Pk "$MCPE_SHARED_ROOT" 2>/dev/null | awk 'NR==2 {print $4+0}')"
  if [ "$cross_device_kb" -gt 0 ] && [ "$free_kb" -lt $((cross_device_kb + 1024)) ]; then
    echo "shared-data migration: insufficient free space ($free_kb KiB available, $cross_device_kb KiB required)" >&2
    return 1
  fi

  if [ ! -f "$pending" ]; then
    printf 'schema=1\nedition=%s\nsource_root=%s\nshared_root=%s\nstarted=%s\ninventory_kb=%s\nfree_kb=%s\nstate=migrating\n' \
      "$MCPE_EDITION_ID" "$migration_source_root" "$MCPE_SHARED_ROOT" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" \
      "$total_kb" "$free_kb" >"$pending" || return 1
    new_transaction=1
  fi

  for item in apk versions profiles backups; do
    src="$migration_source_root/$item"
    dst="$MCPE_SHARED_ROOT/$item"
    if [ -L "$src" ]; then
      target_link="$(readlink "$src" 2>/dev/null || true)"
      if [ "$target_link" != "$dst" ]; then
        echo "shared-data migration: $src points to unexpected target $target_link" >&2
        [ "$new_transaction" = 1 ] && printf 'state=rollback\n' >>"$pending"
        mcpe_migration_rollback_actions
        [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"
        return 1
      fi
      mkdir -p "$dst" || return 1
      continue
    fi
    # A bind mount from a previous launch is already the desired path.
    mcpe_paths_same_directory "$src" "$dst" && continue
    if [ -e "$src" ] && [ ! -d "$src" ]; then
      echo "shared-data migration: expected directory, found file: $src" >&2
      [ "$new_transaction" = 1 ] && printf 'state=rollback\n' >>"$pending"
      mcpe_migration_rollback_actions
      [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"
      return 1
    fi
    if [ -d "$src" ] && [ -d "$dst" ] && ! mcpe_is_empty_dir "$src" && ! mcpe_is_empty_dir "$dst"; then
      echo "shared-data migration collision appeared after preflight" >&2
      [ "$new_transaction" = 1 ] && printf 'state=rollback\n' >>"$pending"
      mcpe_migration_rollback_actions
      [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"
      return 1
    fi
    if [ -d "$src" ] && ! mcpe_is_empty_dir "$src"; then
      if [ -d "$dst" ]; then rmdir "$dst" 2>/dev/null || true; fi
      [ "$new_transaction" = 1 ] && printf 'move=%s|%s\n' "$src" "$dst" >>"$pending"
      mv "$src" "$dst" || { mcpe_migration_rollback_actions; [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"; return 1; }
      MCPE_MIGRATION_ACTIONS+=("move|$src|$dst")
    else
      if [ ! -d "$dst" ]; then
        [ "$new_transaction" = 1 ] && printf 'mkdir=%s|\n' "$dst" >>"$pending"
        mkdir -p "$dst" || { mcpe_migration_rollback_actions; [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"; return 1; }
        MCPE_MIGRATION_ACTIONS+=("mkdir|$dst|")
      fi
      [ -d "$src" ] && rmdir "$src" 2>/dev/null || true
    fi
    mcpe_attach_shared_path "$src" "$dst" "$pending" "$new_transaction" || {
      mcpe_migration_rollback_actions
      [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"
      return 1
    }
  done

  if [ "$migration_source_root" != "$GAMEDIR" ]; then
    for item in apk versions profiles backups; do
      src="$GAMEDIR/$item"
      dst="$MCPE_SHARED_ROOT/$item"
      if [ -L "$src" ]; then
        [ "$(readlink "$src" 2>/dev/null || true)" = "$dst" ] || {
          echo "shared-data migration: RGDS compatibility link has an unexpected target: $src" >&2
          mcpe_migration_rollback_actions
          [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"
          return 1
        }
        continue
      fi
      mcpe_paths_same_directory "$src" "$dst" && continue
      [ -d "$src" ] && mcpe_is_empty_dir "$src" && rmdir "$src" 2>/dev/null || true
      if [ -e "$src" ]; then
        echo "shared-data migration: RGDS compatibility path is not empty: $src" >&2
        mcpe_migration_rollback_actions
        [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"
        return 1
      fi
      mcpe_attach_shared_path "$src" "$dst" "$pending" "$new_transaction" || {
        mcpe_migration_rollback_actions
        [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"
        return 1
      }
    done
  fi

  [ "$new_transaction" = 1 ] && printf 'state=ready\n' >>"$pending"
  export MCPE_MIGRATION_PENDING=1
  return 0
}

mcpe_mark_migration_success() {
  local pending="$GAMEDIR/config/migration.pending"
  [ -f "$pending" ] || return 0
  printf 'completed=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" >>"$pending"
  mv "$pending" "$GAMEDIR/config/migration.completed"
  export MCPE_MIGRATION_PENDING=0
}
