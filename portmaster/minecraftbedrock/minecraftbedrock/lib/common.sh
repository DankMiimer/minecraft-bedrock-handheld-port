#!/bin/bash
# Shared, side-effect-light helpers for both Minecraft Bedrock editions.

mcpe_json_string() { # file key
  sed -n 's/^[[:space:]]*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

mcpe_load_edition() {
  local manifest="${1:-$GAMEDIR/edition.json}"
  [ -f "$manifest" ] || { echo "missing edition manifest: $manifest" >&2; return 1; }
  MCPE_EDITION_ID="$(mcpe_json_string "$manifest" id)"
  MCPE_EDITION_NAME="$(mcpe_json_string "$manifest" name)"
  MCPE_PAYLOAD_NAME="$(mcpe_json_string "$manifest" payload)"
  MCPE_DEFAULT_CHANNEL="$(mcpe_json_string "$manifest" channel)"
  MCPE_SHARED_DIRNAME="$(mcpe_json_string "$manifest" shared_data)"
  [ -n "$MCPE_EDITION_ID" ] && [ -n "$MCPE_PAYLOAD_NAME" ] || return 1
  export MCPE_EDITION_ID MCPE_EDITION_NAME MCPE_PAYLOAD_NAME
  export MCPE_DEFAULT_CHANNEL MCPE_SHARED_DIRNAME
}

mcpe_is_empty_dir() {
  [ -d "$1" ] || return 1
  [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

mcpe_safe_component() {
  case "$1" in ""|.|..|.*|*/*|*\\*|*$'\n'*|*$'\r'*) return 1 ;; esac
  return 0
}

mcpe_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | sed 's/^.*= //'
  else
    return 127
  fi
}

mcpe_fetch() { # url destination
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --connect-timeout 15 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$2" "$1"
  else
    return 127
  fi
}

mcpe_archive_is_safe() {
  unzip -Z1 "$1" 2>/dev/null | awk '
    BEGIN { bad=0 }
    /^\// || /^[A-Za-z]:/ { bad=1 }
    /(^|\/)\.\.($|\/)/ { bad=1 }
    /\\/ { bad=1 }
    END { exit bad }
  '
}

mcpe_select_utf8_locale() {
  # Minimal CFW images often export an en_US locale they did not actually
  # install. C/C++ filesystem conversion then fails on non-ASCII world names.
  # Keep a working UTF-8 locale when provided; otherwise select the first one
  # the host can instantiate without requiring locale generation or writes.
  local candidate charmap
  for candidate in "${LC_ALL:-}" "${LC_CTYPE:-}" "${LANG:-}" \
                   C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    [ -n "$candidate" ] || continue
    if command -v locale >/dev/null 2>&1; then
      charmap="$(LC_ALL="$candidate" locale charmap 2>/dev/null || true)"
      case "$(printf '%s' "$charmap" | tr '[:lower:]' '[:upper:]')" in
        UTF-8|UTF8) ;;
        *) continue ;;
      esac
    else
      case "$candidate" in C.UTF-8|C.utf8) ;; *) continue ;; esac
    fi
    export LANG="$candidate" LC_CTYPE="$candidate" LC_ALL="$candidate"
    MCPE_LOCALE_RESOLVED="$candidate"
    export MCPE_LOCALE_RESOLVED
    return 0
  done
  # Do not invent an unsupported locale. Byte-oriented C is safer than a
  # broken locale name and is recorded in diagnostics for the device report.
  export LANG=C LC_CTYPE=C LC_ALL=C MCPE_LOCALE_RESOLVED=C
}
