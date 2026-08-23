#!/bin/bash
# Startup watchdog.
#
# Issue #2 (RG35XX-H / Knulli): "the loading bar gets stuck and the console
# freezes". The only recovery is a power cycle, the frontend never comes back,
# and because the launcher log is truncated at the start of every run there is
# nothing left to report -- that issue's log field is empty for exactly this
# reason. The existing watchdog in weston_launch.sh only arms *after* the
# shutdown marker, so nothing was watching this at all.
#
# What counts as progress
# -----------------------
# The shipped clients are prebuilt and checksummed, so no new in-client marker
# could be added for this. The watchdog therefore works from what is already
# observable from outside the process:
#
#   * the client log growing,
#   * the process accumulating CPU time,
#   * the frame-metrics file growing, when the client is writing one.
#
# A frame-metrics row is the only *positive* proof the game reached a frame, so
# when it is available the watchdog disarms as soon as one appears and records
# the `first-frame` stage. It is opt-in (MCPE_MEASURE_FPS=1) because the client
# appends a row per frame for the whole session.
#
# Why a stall, not a deadline
# ---------------------------
# The default is stall detection, not an absolute startup deadline: a first
# launch on a cold, slow microSD card legitimately takes minutes, and killing a
# healthy-but-slow start would be a worse bug than the one being fixed. An
# absolute cap is available via MCPE_STARTUP_TIMEOUT but is off by default.
#
# A stall the watchdog cannot see is a client that spins on the CPU forever.
# That is deliberate: firing on "busy but not finishing" would need a real
# progress signal from inside the client, which is Phase 2's follow-up, not
# something to guess at from the outside.

mcpe_watchdog_pid=""

mcpe_proc_cpu_ticks() { # pid
  local stat
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  # utime and stime are fields 14 and 15, counted after the (comm) field,
  # which may itself contain spaces.
  printf '%s' "${stat#*) }" | awk '{print $12 + $13}'
}

mcpe_watchdog_hang_report() { # pid log outfile reason
  local pid="$1" log="$2" out="$3" reason="$4"
  {
    echo "=== Minecraft Bedrock startup hang report ==="
    echo "reason: $reason"
    echo "when: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
    echo "pid: $pid"
    echo "cfw: ${MCPE_CFW:-unknown} profile=${MCPE_HOST_PROFILE:-unknown}"
    echo "failsafe rung: ${MCPE_FAILSAFE_RUNG:-0}"
    echo
    echo "--- /proc/$pid/status ---"
    grep -E '^(Name|State|Threads|VmRSS|VmSize|voluntary|nonvoluntary)' \
      "/proc/$pid/status" 2>/dev/null || echo "unavailable"
    echo
    echo "--- kernel wait channel ---"
    cat "/proc/$pid/wchan" 2>/dev/null || echo "unavailable"
    echo
    echo "--- per-thread state ---"
    for task in "/proc/$pid/task"/*; do
      [ -d "$task" ] || continue
      printf '%s %s %s\n' "$(basename "$task")" \
        "$(sed -n 's/^State:[[:space:]]*//p' "$task/status" 2>/dev/null)" \
        "$(cat "$task/wchan" 2>/dev/null)"
    done 2>/dev/null | head -40
    echo
    echo "--- mapped objects (count by library) ---"
    awk '{print $6}' "/proc/$pid/maps" 2>/dev/null |
      grep -E '\.so|/versions/' | sort | uniq -c | sort -rn | head -20 ||
      echo "unavailable"
    echo
    echo "--- last 200 log lines ---"
    tail -n 200 "$log" 2>/dev/null || echo "no client log"
  } >"$out" 2>&1 || true
}

# The client is started behind westonwrap on the 64-bit path, so the pid the
# launch pipeline reports is not the client's. Resolve it by name, exactly as
# the existing shutdown watchdog does.
mcpe_watchdog_body() { # supervisor_pid log
  local supervisor="$1" log="$2" pid="" report="$GAMEDIR/logs/hang-report.txt"
  local stall_limit="${MCPE_STALL_SECONDS:-90}"
  local deadline="${MCPE_STARTUP_TIMEOUT:-0}"
  local metrics="${MCPE_FRAME_METRICS:-}"
  local elapsed=0 stalled=0 hung=0 windowed=0
  local last_log=-1 last_cpu=-1 last_metrics=-1
  local now_log now_cpu now_metrics victim

  case "$stall_limit" in ''|*[!0-9]*) stall_limit=90 ;; esac
  case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac

  while kill -0 "$supervisor" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ -z "$pid" ]; then
      pid="$(pidof mcpelauncher-client 2>/dev/null | awk '{print $1}')"
      continue
    fi
    kill -0 "$pid" 2>/dev/null || return 0

    # A frame-metrics row is the only positive proof the game reached a frame.
    now_metrics=0
    if [ -n "$metrics" ] && [ -s "$metrics" ]; then
      now_metrics="$(wc -c <"$metrics" 2>/dev/null || echo 0)"
      if [ "$(wc -l <"$metrics" 2>/dev/null || echo 0)" -gt 1 ]; then
        mcpe_stage first-frame
        echo "Startup watchdog: first frame after ${elapsed}s; disarmed."
        return 0
      fi
    fi

    if [ "$windowed" = 0 ] && grep -q 'Creating window' "$log" 2>/dev/null; then
      windowed=1
      mcpe_stage window
    fi

    now_log="$(wc -c <"$log" 2>/dev/null || echo 0)"
    now_cpu="$(mcpe_proc_cpu_ticks "$pid" 2>/dev/null || echo 0)"
    if [ "$now_log" != "$last_log" ] || [ "$now_cpu" != "$last_cpu" ] ||
       [ "$now_metrics" != "$last_metrics" ]; then
      stalled=0
      last_log="$now_log"; last_cpu="$now_cpu"; last_metrics="$now_metrics"
    else
      stalled=$((stalled + 1))
    fi

    if [ "$stall_limit" -gt 0 ] && [ "$stalled" -ge "$stall_limit" ]; then
      echo "Startup watchdog: no log, CPU or frame progress for ${stalled}s."
      mcpe_watchdog_hang_report "$pid" "$log" "$report" \
        "no progress for ${stalled}s during startup"
      hung=1
    elif [ "$deadline" -gt 0 ] && [ "$elapsed" -ge "$deadline" ]; then
      echo "Startup watchdog: startup deadline of ${deadline}s reached."
      mcpe_watchdog_hang_report "$pid" "$log" "$report" \
        "startup deadline of ${deadline}s reached"
      hung=1
    fi

    if [ "$hung" = 1 ]; then
      echo "Startup watchdog: terminating the client so the frontend can be restored."
      echo "Startup watchdog: wrote $report"
      for victim in $(pidof mcpelauncher-client 2>/dev/null); do
        kill "$victim" 2>/dev/null || true
      done
      sleep 5
      for victim in $(pidof mcpelauncher-client 2>/dev/null); do
        kill -9 "$victim" 2>/dev/null || true
      done
      return 1
    fi
  done
  return 0
}

# Usage: mcpe_watchdog_start <supervisor_pid> <client_log>
mcpe_watchdog_start() {
  local stall_limit="${MCPE_STALL_SECONDS:-90}"
  case "$stall_limit" in ''|*[!0-9]*) stall_limit=90 ;; esac
  if [ "$stall_limit" -le 0 ] && [ "${MCPE_STARTUP_TIMEOUT:-0}" = 0 ]; then
    echo "Startup watchdog: disabled by configuration."
    return 0
  fi
  mcpe_watchdog_body "$1" "$2" &
  mcpe_watchdog_pid=$!
}

mcpe_watchdog_stop() {
  [ -n "${mcpe_watchdog_pid:-}" ] || return 0
  kill "$mcpe_watchdog_pid" 2>/dev/null || true
  wait "$mcpe_watchdog_pid" 2>/dev/null || true
  mcpe_watchdog_pid=""
}
