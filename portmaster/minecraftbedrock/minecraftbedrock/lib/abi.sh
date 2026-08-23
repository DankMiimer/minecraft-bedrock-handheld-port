#!/bin/bash
# Architecture policy kept separate from runtime launch mechanics so every CFW
# fixture exercises the same decision code used on-device.

# Can this system load a client of the given ABI?
#
# The shipped binaries record their interpreter in PT_INTERP:
#   bin/mcpelauncher-client    -> /lib/ld-linux-aarch64.so.1
#   bin32/mcpelauncher-client  -> /lib/ld-linux-armhf.so.3
# so the only question that matters is whether that loader is on the device.
#
# This used to accept `uname -m` = aarch64 on its own, which is not the same
# question. dArkOS RE runs a 64-bit kernel over an armhf userland and reported
# "usable: 64=1" in the issue #1 log while having no aarch64 glibc at all. It
# was harmless there only because the installed version was 32-bit only; with
# an arm64 APK installed the launcher would have chosen a client the device
# cannot exec. A musl-only aarch64 system is the same story: the kernel matches
# and the glibc loader these binaries ask for is still absent.
#
# MCPE_PROBE_ROOT is honoured so the CFW fixtures can exercise this directly.
mcpe_loader_present() { # arm64|armhf
  local probe="${MCPE_PROBE_ROOT:-}" candidate
  case "$1" in
    arm64)
      for candidate in /lib/ld-linux-aarch64.so.1 /usr/lib/ld-linux-aarch64.so.1 \
                       /lib64/ld-linux-aarch64.so.1; do
        [ -e "$probe$candidate" ] && return 0
      done
      ;;
    armhf)
      for candidate in /lib/ld-linux-armhf.so.3 /usr/lib/ld-linux-armhf.so.3 \
                       /usr/lib32/ld-linux-armhf.so.3 \
                       /usr/arm-linux-gnueabihf/lib/ld-linux-armhf.so.3; do
        [ -e "$probe$candidate" ] && return 0
      done
      ;;
  esac
  return 1
}

mcpe_choose_default_abi() { # has64 has32 usable64 usable32 profile backend host_arch mem_kb
  local has64="$1" has32="$2" usable64="$3" usable32="$4"
  local profile="$5" backend="$6" host_arch="$7" mem_kb="$8"

  if [ "$has64" = 1 ] && [ "$usable64" = 1 ] &&
     [ "$has32" = 1 ] && [ "$usable32" = 1 ]; then
    # The armhf client is a direct-KMS compatibility path for RK3326/R36S,
    # not a generic low-memory mode. H700 uses the tested arm64 Weston/crusty
    # path even on 1-GB models; choosing by RAM alone broke MuOS RG35XX Pro.
    case "$profile:$host_arch" in
      rk3326:*|*:armv7*|*:armv8l|*:armhf) printf '%s\n' armhf; return 0 ;;
      h700:*|rgds:*) printf '%s\n' arm64; return 0 ;;
    esac
    case "$backend" in
      mali|wayland|x11) printf '%s\n' arm64; return 0 ;;
    esac
    case "$mem_kb" in ''|*[!0-9]*) mem_kb=0 ;; esac
    if [ "$backend" = kmsdrm ] && [ "$mem_kb" -gt 0 ] &&
       [ "$mem_kb" -lt 750000 ]; then
      printf '%s\n' armhf
    else
      printf '%s\n' arm64
    fi
  elif [ "$has32" = 1 ] && [ "$usable32" = 1 ]; then
    printf '%s\n' armhf
  elif [ "$has64" = 1 ] && [ "$usable64" = 1 ]; then
    printf '%s\n' arm64
  elif [ "$has32" = 1 ]; then
    printf '%s\n' armhf
  else
    printf '%s\n' arm64
  fi
}
