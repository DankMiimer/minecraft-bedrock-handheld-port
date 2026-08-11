# Crusty game-window context API v1

The H700 EGLUT path uses a small preload module which records the SDL window
and GL context returned while Crusty initializes. The launcher client calls:

```c
int crusty_gamewindow_context_v1(unsigned int api_version, int active);
```

- `api_version` must be `1`.
- `active != 0` binds the recorded window/context.
- `active == 0` releases the context from the recorded window.
- `0` means success; negative values are stable bridge errors.

The module obtains handles by interposing the exported SDL wrapper calls used
by Crusty. It never reads data at a fixed module offset and does not rewrite a
runtime binary. A Crusty launch must fail before starting the game when this
module is absent or has the wrong API. Native Mesa/Panfrost launches do not
load or require the module.
