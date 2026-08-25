#!/bin/sh
# Everything a future change to this port needs to know about muOS, captured
# from the device rather than assumed.
s() { echo; echo "### $1"; }
have() { command -v "$1" >/dev/null 2>&1 && echo "$1=yes" || echo "$1=MISSING"; }

s IDENTITY
cat /etc/os-release
echo "model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null)"
echo "compatible=$(tr '\0' ' ' </proc/device-tree/compatible 2>/dev/null)"
echo "kernel=$(uname -r) arch=$(uname -m)"
echo "CFW_NAME=${CFW_NAME:-unset}"

s PORTMASTER
echo "stub=/roms/ports/PortMaster:"; ls /roms/ports/PortMaster 2>/dev/null
echo "control.txt:"; cat /roms/ports/PortMaster/control.txt 2>/dev/null | head -5
echo "real:"; ls /mnt/mmc/MUOS/PortMaster 2>/dev/null | head -20
echo "runtimes:"; ls /mnt/mmc/MUOS/PortMaster/runtimes 2>/dev/null
echo "libs:"; ls /mnt/mmc/MUOS/PortMaster/libs 2>/dev/null | head
echo "device_info:"; cat /mnt/mmc/MUOS/PortMaster/device_info.txt 2>/dev/null | head -12

s STORAGE
mount | grep -E ' / | /mnt/mmc| /mnt/union| /tmp | /run '
df -h 2>/dev/null | grep -E 'Filesystem|mmc|tmpfs|union' | head -8
echo "port entry dirs:"; ls -d /mnt/union/ROMS/Ports /mnt/mmc/ROMS/Ports /roms/ports 2>/dev/null

s FRONTEND
echo "supervisor+children:"; ps -o pid,ppid,args 2>/dev/null | grep -E 'frontend.sh|mux' | grep -v grep
echo "scripts:"; ls /opt/muos/script/mux/ 2>/dev/null | head -12
echo "fb0 holder:"; for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do ls -l /proc/$p/fd 2>/dev/null | grep -q /dev/fb0 && echo "$p $(tr '\0' ' ' </proc/$p/cmdline | cut -c1-50)"; done

s CONSOLE
cat /proc/consoles 2>/dev/null
echo "vtcon0=$(cat /sys/class/vtconsole/vtcon0/name 2>/dev/null)"
echo "tty1_writable=$([ -w /dev/tty1 ] && echo yes || echo no)"

s GRAPHICS
echo "dri:"; ls /dev/dri 2>/dev/null || echo "(none)"
echo "sys_class_drm=$(ls /sys/class/drm 2>/dev/null | wc -l)"
ls -la /dev/mali0 /dev/disp /dev/fb0 2>/dev/null
fbset 2>/dev/null | head -4
echo "libmali:"; ls /usr/lib/libmali* /usr/lib/libEGL* /usr/lib/libGLES* 2>/dev/null | head -6
echo "mesa:"; ls /usr/lib/dri 2>/dev/null | head -3 || echo "(no mesa)"
echo "Xwayland=$(command -v Xwayland || echo MISSING)"

s AUDIO
ls -la /run/pipewire-0 /run/pulse /run/pipewire 2>/dev/null
echo "client.conf=$([ -f /usr/share/pipewire/client.conf ] && echo present || echo absent)"
ls /dev/snd 2>/dev/null | head -5
echo "procs:"; ps -o args 2>/dev/null | grep -E 'pipewire|pulse' | grep -v grep | head -3

s INPUT
for e in /sys/class/input/event*; do
  n=$(cat "$e/device/name" 2>/dev/null); p=$(cat "$e/device/phys" 2>/dev/null)
  [ -n "$n" ] && echo "$(basename "$e"): name='$n' phys='$p'"
done
echo "js:"; ls /dev/input/js* 2>/dev/null || echo "(no js nodes)"

s ABI_AND_LIBS
ls -la /lib/ld-linux-aarch64.so.1 /lib/ld-linux-armhf.so.3 2>/dev/null
echo "libcom_err 64=$([ -e /usr/lib/libcom_err.so.2 ] && echo present || echo MISSING) 32=$([ -e /usr/lib32/libcom_err.so.2 ] && echo present || echo missing)"
echo "SDL2:"; ls /usr/lib/libSDL2* 2>/dev/null | head -3

s TOOLING
for t in python3 timeout nproc flock fbset unzip readelf pidof setsid killall convert fbv curl awk sed grep strings gdb; do have "$t"; done
echo "python3=$(python3 -V 2>&1)"
echo "busybox=$(busybox 2>&1 | head -1)"
echo "busybox_md5=$(md5sum /bin/busybox 2>/dev/null | cut -d' ' -f1)"
echo "busybox_static=$(ldd /bin/busybox 2>&1 | head -1)"

s KNOWN_BREAKAGE
printf 'date_ns=%s\n' "$(date +%s%3N 2>/dev/null)"
printf 'awk_plain='; printf 'a 1\n' | awk '{print $2}' 2>&1 | head -1
printf 'awk_regex='; printf 'a 1\n' | awk '/a/{print $2}' 2>&1 | head -1
printf 'awk_index='; printf 'a 1\n' | awk 'index($0,"a"){print $2}' 2>&1 | head -1
printf 'grep_regex='; printf 'a 1\n' | grep -E '^a' 2>&1 | head -1
printf 'sed_regex='; printf 'a 1\n' | sed -n 's/^a //p' 2>&1 | head -1
printf 'tar_z='; tar czf /dev/null /etc/hostname 2>&1 | head -1 || true

s CPU_MEM
grep -m1 -E 'Features' /proc/cpuinfo
echo "cores=$(grep -c ^processor /proc/cpuinfo)"
grep -E 'MemTotal|MemAvailable' /proc/meminfo
echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"

s PORT_STATE
cat /mnt/mmc/ports/minecraftbedrock/PORT_VERSION 2>/dev/null
ls /mnt/mmc/ports/minecraftbedrock-data/versions/ 2>/dev/null
ls /mnt/mmc/ports/minecraftbedrock/runtime/ 2>/dev/null
