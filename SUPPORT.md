# Support

Use GitHub issues for public bug reports and controller mapping reports.

## Known issues and fixes

- **No audio on muOS (game runs fine otherwise).** muOS Jacaranda runs
  PipeWire, which holds the ALSA device exclusively; older builds of this
  port fell back to raw ALSA and got "Device or resource busy". Fixed in
  1.4.1 (v1.4's fix was not effective): the launcher now routes the game's
  ALSA output through the system's ALSA→PipeWire plugin with a generated
  config (`ALSA_CONFIG_PATH`), verified on an RG34XX-SP running muOS 2601.
  If audio is still silent, launch once with `MCPE_ALSA_PIPEWIRE=0` (or
  `MCPE_SDL_AUDIODRIVER=alsa`) and attach `log.txt` to an issue.
- **UI looks slightly stretched or cut off on non-720x480 screens.** Fixed in
  1.4: the game window is now requested at the real panel size. Override with
  `MCPE_DISPLAY_WIDTH` / `MCPE_DISPLAY_HEIGHT` if your panel is detected
  wrong (check the `size=` line in `weston_launch.log`).

Include:

- device model
- firmware / OS version
- Minecraft APK version
- whether first-run extraction completed
- the redacted archive created by **Support bundle**, when available
- relevant lines from the edition's `logs/launcher.log`
- controller-test output when the problem involves input

For install problems, also state whether the source was one full APK or a
split set and whether the ABI was `arm64-v8a` or `armeabi-v7a`. Never include
the APK filenames if they contain account-specific information.

Do not include:

- APK files or links to APK files
- extracted game folders such as `versions/`
- `profiles/`, worlds, or account data
- `libminecraftpe.so`
- private server addresses, tokens, or account identifiers

If a report needs private game files to reproduce, it cannot be handled in a
public issue.
