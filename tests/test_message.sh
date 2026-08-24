#!/bin/bash
# The message ladder: which rung the launcher uses to tell a player something,
# and the PortMaster root resolution that decides whether the LOVE rung exists
# at all.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$ROOT/portmaster/minecraftbedrock/minecraftbedrock"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck disable=SC1091
source "$PAYLOAD/lib/common.sh"
# shellcheck disable=SC1091
source "$PAYLOAD/lib/message.sh"

# --- console visibility -------------------------------------------------------
# muOS: kernel console is the serial port and the only vtconsole is the dummy
# driver, so /dev/tty1 is writable and never reaches the panel. Captured from
# muOS 2601.0 JACARANDA on an RG34XX-SP (2026-08-24).
mkdir -p "$TMP/muos/proc" "$TMP/muos/sys/class/vtconsole/vtcon0"
printf 'ttyS0                -W- (EC    )  248:0\n' >"$TMP/muos/proc/consoles"
printf '(S) dummy device\n' >"$TMP/muos/sys/class/vtconsole/vtcon0/name"
MCPE_PROBE_ROOT="$TMP/muos" mcpe_console_is_visible &&
  fail "muOS has no framebuffer console; the tty rung must not be chosen"

# A framebuffer console bound to the panel is the case the tty rung was
# verified on, and it must keep winning.
mkdir -p "$TMP/fbcon/proc" "$TMP/fbcon/sys/class/vtconsole/vtcon0" \
         "$TMP/fbcon/sys/class/vtconsole/vtcon1"
printf 'ttyS0                -W- (EC    )  248:0\n' >"$TMP/fbcon/proc/consoles"
printf '(S) dummy device\n' >"$TMP/fbcon/sys/class/vtconsole/vtcon0/name"
printf '(M) frame buffer device\n' >"$TMP/fbcon/sys/class/vtconsole/vtcon1/name"
MCPE_PROBE_ROOT="$TMP/fbcon" mcpe_console_is_visible ||
  fail "a bound framebuffer console must still use the tty rung"

# A numbered VT as a kernel console is enough on its own.
mkdir -p "$TMP/vt/proc"
printf 'tty0                 -WU (EC    )    4:1\n' >"$TMP/vt/proc/consoles"
MCPE_PROBE_ROOT="$TMP/vt" mcpe_console_is_visible ||
  fail "a VT kernel console means the panel shows the console"

# --- PortMaster root resolution ----------------------------------------------
# muOS ships a stub holding only control.txt, which redirects at the real
# install. Taking the stub leaves the port with no runtimes and therefore no
# menu, which is what made "no version installed" unrecoverable on muOS.
mkdir -p "$TMP/stub" "$TMP/real/runtimes/love_11.5" "$TMP/real/libs"
: >"$TMP/real/funcs.txt"
: >"$TMP/real/device_info.txt"
printf 'export controlfolder="%s"\n' "$TMP/real" >"$TMP/stub/control.txt"
got="$(mcpe_resolve_pm_root "$TMP/stub")"
[ "$got" = "$TMP/real" ] ||
  fail "a stub that redirects at a fuller tree must resolve to it (got $got)"

# The opposite case the old code was protecting: a control.txt that rewrites
# controlfolder at a bare ROMs directory must not drag the port away from the
# tree that actually holds the runtimes.
mkdir -p "$TMP/rich/runtimes" "$TMP/rich/libs" "$TMP/bare"
: >"$TMP/rich/funcs.txt"
printf 'export controlfolder="%s"\n' "$TMP/bare" >"$TMP/rich/control.txt"
got="$(mcpe_resolve_pm_root "$TMP/rich")"
[ "$got" = "$TMP/rich" ] ||
  fail "a redirect at an emptier directory must be ignored (got $got)"

# A redirect that needs shell expansion cannot be trusted without running it.
mkdir -p "$TMP/vary"
printf 'export controlfolder="$SOMEWHERE/PortMaster"\n' >"$TMP/vary/control.txt"
got="$(mcpe_resolve_pm_root "$TMP/vary")"
[ "$got" = "$TMP/vary" ] ||
  fail "an unexpanded redirect must be refused (got $got)"

# --- the launcher resolves the same way --------------------------------------
# The launcher has to do this before lib/common.sh loads, so it carries its own
# copy of the scoring. Keep the two honest about scoring the same markers.
launcher="$ROOT/portmaster/minecraftbedrock/Minecraft Bedrock.sh"
for marker in runtimes libs funcs.txt device_info.txt PortMaster.sh; do
  grep -q "$marker" <(sed -n '/^mcpe_pm_payload_score()/,/^}/p' "$launcher") ||
    fail "launcher payload score is missing the $marker marker"
done
grep -q 'mcpe_pm_payload_score "$controlfolder"' "$launcher" ||
  fail "the launcher must compare the redirect against the directory it came from"

# --- interpreter health -------------------------------------------------------
# The check must pass on a working interpreter and name the modules the port
# actually needs, so a broken one is caught before a later script trips on it.
# If this fails, the machine running the suite is the broken one -- which is
# exactly what the check is for. The muOS reference device fails here because
# its ext4 root is corrupt and no python3 import that scans sys.path succeeds.
mcpe_python_health >/dev/null ||
  fail "this host's own python3 cannot import the standard library: $(mcpe_python_health 2>&1 | head -2)"
for module in json re zipfile hashlib; do
  sed -n '/^mcpe_python_health()/,/^}/p' "$PAYLOAD/lib/common.sh" |
    grep -q "$module" || fail "python health check does not import $module"
done
# A filesystem fault must be reported as a firmware problem, not a port problem.
hint="$(mcpe_python_health_hint "OSError: [Errno 74] Bad message: '/usr/lib/python3.11/site-packages'")"
case "$hint" in
  *e2fsck*) ;;
  *) fail "an EBADMSG import failure must point at the filesystem, not the port" ;;
esac

echo "message ladder tests passed"
