# Per-device controller mappings

The EGLUT/linux-gamepad backend does **not** read external SDL mapping
exports — it loads `gamecontrollerdb.txt` from the launcher data directory,
and its evdev button indices (`bN`) differ from SDL's. Copying an SDL line
from `/tmp/gamecontrollerdb.txt` produces wrong buttons.

Files named `*.sdl.gamecontrollerdb.txt` are only for SDL/LOVE launcher UI
input and are deliberately excluded from the game database. RG34XXSP needs
both forms because the same physical A button is SDL raw `b3` but
linux-gamepad evdev index `b1`.

`run_bedrock.sh` concatenates the non-SDL files. The patched linux-gamepad
backend prefers an exact GUID-and-controller-name match. It falls back to a
GUID-only match only when that GUID has a single mapping. This matters on
handheld firmware whose GPIO pads all report the generic 0001/0001 GUID.

To contribute a mapping for a new device, launch with
`GAMEWINDOW_GAMEPAD_TRACE=1` and read the raw evdev indices from
`weston_launch.log`, then write a line following the existing
`rg34xxsp.gamecontrollerdb.txt` example.

The remaining long-term improvement is translating PortMaster's exported SDL
mapping into linux-gamepad's evdev index space, removing the need for these
device aliases entirely.
