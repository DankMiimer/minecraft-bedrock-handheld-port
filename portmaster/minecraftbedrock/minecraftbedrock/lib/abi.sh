#!/bin/bash
# Architecture policy kept separate from runtime launch mechanics so every CFW
# fixture exercises the same decision code used on-device.

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
