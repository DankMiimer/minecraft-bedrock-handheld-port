# Contributing

Thanks for helping test the port. Please keep contributions public-safe:

- Do not upload Minecraft APKs, extracted game files, worlds, `versions/`,
  `profiles/`, or `libminecraftpe.so`.
- Do not link to APK mirrors or piracy sources.
- Redact account names, local IPs, and private server details from logs before
  posting them.
- Include device, firmware, Minecraft APK version, and the relevant log text
  when reporting bugs.
- Controller mapping reports are welcome; paste the generated mapping line
  from `minecraftbedrock/log.txt` and name the device/firmware.

The modified launcher source is published through the forks and patches listed
in `source_release/README.md`.

Changes to either Google Play downloader -- the on-device one in the port, or
the `tools/mcbedrock-get/` helper -- must keep it strictly open source, free of
hardcoded bypasses or cracked licences, and free of any third-party handling of
user credentials. Read `DOWNLOADER-POLICY.md` first and run
`python3 scripts/check_downloader_policy.py` before opening a pull request; CI
runs it too.
