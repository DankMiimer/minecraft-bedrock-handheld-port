# Handheld UI prototype 0.1.0

For the RG34XX-SP at native 720x480 with Bedrock
`1.21.51.01-972105101-arm64`. Keep launcher UI zoom Off and client density 1.
The source consists of original, small JSON overrides referencing the game's
own textures. No vanilla texture files or third-party pack code are bundled.

## Scope

Every factor is an integer, and every number is this build's own stock value
multiplied by it. The UI font is a bitmap font and item art is 16x16, so
fractional factors resample and look soft; see `docs/UI-SCALING.md`.

- Main menu: 2x throughout - 300-unit panels, 64-unit rows, 2x labels with
  doubled text bounds. Existing actions and focus navigation remain inherited.
- Pause menu: 2x - 56-unit main rows and 2x labels.
- Selected-item name: `common.item_text_label` at 2x with its border padding
  doubled to match, so the box grows with the text. The in-world item name
  popup shares that control and grows with it.
- Hotbar: 3x - 60x66 slots, 48x48 item bounds, matching selection border,
  durability bar and 3x count labels. The XP/hotbar layout moves upward to
  retain bottom clearance. 3x rather than 2x because item art is 16x16: 32 and
  48 are sharp and nothing between them is.
- Inventory: doubled Pocket cell, tab and panel geometry with 2x labels, plus a
  brighter selection outline. Percentages are kept so the layout still reflows
  at 720x480. Slot counts, collection bindings and actions are unchanged.
  Regenerate with `scripts/build_handheld_inventory.py` against this exact
  build's `vanilla/ui` directory; the generated files are shipped, so the
  device never needs that tool.

This does not enlarge the entire interface, and cannot. Health, hunger, armour
and bubbles are `"type": "custom"` native renderers: they ignored 1x, 1.5x and
16x container sizes in a simultaneous on-device experiment, and they carry only
visibility bindings, so they cannot be rebuilt as image controls either - no
health, hunger, absorption, armour or air binding name exists anywhere in this
version's UI tree. They keep their stock size, and their stock corner position,
at native resolution. Launcher UI zoom is the only shipping setting that
enlarges them. Ore UI is unchanged. Effects optimization and measured FPS gains
are outside this prototype.

## Enable or disable outside Minecraft

From the installed `minecraftbedrock` payload directory, after exiting the game:

```sh
python3 handheld_ui.py on
python3 handheld_ui.py status
python3 handheld_ui.py off
```

`on` verifies the version selected in `config/settings.cfg` and hashes its
native library. `--profile /absolute/path/to/profile` selects another profile.
The preference is stored in that profile's `handheld-ui.json`.

The normal Ports launch calls `sync` before starting either ABI. It activates
the pack only for the tested version, ABI and library fingerprint. Switching
to another build removes our activation entry; returning to the supported
build restores it if the preference is still On. Other pack entries and their
fields are retained. Changed activation files are backed up beneath the
profile's `handheld-ui-backups` directory. No worlds are modified by activation.

The pack is Off by default for new installations. An invalid activation file
causes an error rather than silently overwriting the player's pack state.

## Direct import

A `.mcpack` can also be built by zipping `manifest.json` and `ui/` at the archive
root. Direct Minecraft import does not include the launcher's exact-version
guard: its manifest minimum is only a minimum. The managed Ports path is the
recommended activation method for profiles shared across game versions.
