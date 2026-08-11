#!/bin/bash
# Transactional migration of user-owned data into the edition-neutral root.

mcpe_migration_rollback_actions() {
  local i action src dst
  for ((i=${#MCPE_MIGRATION_ACTIONS[@]}-1; i>=0; i--)); do
    IFS='|' read -r action src dst <<<"${MCPE_MIGRATION_ACTIONS[$i]}"
    case "$action" in
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
  mapfile -t recovery_lines < <(grep -E '^(move|link|mkdir)=' "$manifest" 2>/dev/null || true)
  for ((i=${#recovery_lines[@]}-1; i>=0; i--)); do
    line="${recovery_lines[$i]}"
    action="${line%%=*}"
    IFS='|' read -r src dst <<<"${line#*=}"
    case "$action" in
      link) [ -L "$src" ] && rm -f "$src" ;;
      move) [ -e "$dst" ] && [ ! -e "$src" ] && mv "$dst" "$src" ;;
      mkdir) mcpe_is_empty_dir "$src" && rmdir "$src" 2>/dev/null || true ;;
    esac
  done
  printf 'state=recovered\nrecovered=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" >>"$manifest"
  mv "$manifest" "${manifest%.pending}.recovered"
}

mcpe_migrate_shared_data() {
  local ports_root item src dst pending target_link total_kb free_kb source_dev target_dev
  local migration_source_root legacy_standard current_has_data=0 legacy_has_data=0
  local new_transaction=0 cross_device_kb=0
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
    [ "$new_transaction" = 1 ] && printf 'link=%s|%s\n' "$src" "$dst" >>"$pending"
    ln -s "$dst" "$src" || { mcpe_migration_rollback_actions; [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"; return 1; }
    MCPE_MIGRATION_ACTIONS+=("link|$src|")
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
      [ -d "$src" ] && mcpe_is_empty_dir "$src" && rmdir "$src" 2>/dev/null || true
      if [ -e "$src" ]; then
        echo "shared-data migration: RGDS compatibility path is not empty: $src" >&2
        mcpe_migration_rollback_actions
        [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"
        return 1
      fi
      [ "$new_transaction" = 1 ] && printf 'link=%s|%s\n' "$src" "$dst" >>"$pending"
      ln -s "$dst" "$src" || {
        mcpe_migration_rollback_actions
        [ "$new_transaction" = 1 ] && mv "$pending" "$GAMEDIR/config/migration.failed"
        return 1
      }
      MCPE_MIGRATION_ACTIONS+=("link|$src|")
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
