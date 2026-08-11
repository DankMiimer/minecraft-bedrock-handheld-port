# Per-device controller mappings

The EGLUT/linux-gamepad backend does **not** read external SDL mapping
exports — it loads `gamecontrollerdb.txt` from the launcher data directory,
and its evdev button indices (`bN`) differ from SDL's. Copying an SDL line
from `/tmp/gamecontrollerdb.txt` produces wrong buttons.

`run_bedrock.sh` picks the first match of:

1. `controls/${DEVICE_NAME}.gamecontrollerdb.txt`
2. `controls/${CFW_NAME}.gamecontrollerdb.txt`
3. `controls/default.gamecontrollerdb.txt`

To contribute a mapping for a new device, launch with
`GAMEWINDOW_GAMEPAD_TRACE=1` and read the raw evdev indices from
`weston_launch.log`, then write a line following the existing
`rg34xxsp.gamecontrollerdb.txt` example.

TODO(v2): teach game-window/linux-gamepad to translate exported SDL mapping
strings, removing the need for these files.
