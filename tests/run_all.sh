#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
find portmaster/minecraftbedrock bottomscreen/release scripts tests tools/mcbedrock-get \
  tools/ondevice-downloader -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
python3 -m py_compile \
  portmaster/minecraftbedrock/minecraftbedrock/apkmeta.py \
  portmaster/minecraftbedrock/minecraftbedrock/apk_groups.py \
  portmaster/minecraftbedrock/minecraftbedrock/controller_diag.py \
  portmaster/minecraftbedrock/minecraftbedrock/release_select.py \
  portmaster/minecraftbedrock/minecraftbedrock/runtime_select.py \
  portmaster/minecraftbedrock/minecraftbedrock/version_env.py \
  portmaster/minecraftbedrock/minecraftbedrock/screenshot_watch.py \
  portmaster/minecraftbedrock/minecraftbedrock/failsafe_state.py \
  portmaster/minecraftbedrock/minecraftbedrock/migrate_version_metadata.py \
  portmaster/minecraftbedrock/minecraftbedrock/downloader/credentials.py \
  portmaster/minecraftbedrock/minecraftbedrock/downloader/deb_extract.py \
  portmaster/minecraftbedrock/minecraftbedrock/downloader/validate_download.py \
  bottomscreen/release/discover_rgds.py bottomscreen/release/input_state.py \
  bottomscreen/release/prepare_resources.py \
  bottomscreen/device/osk_supervisor.py \
  scripts/build_releases.py tools/mcbedrock-get/package_release.py \
  tools/mcbedrock-get/mcbedrock_get.py tools/mcbedrock-get/signin.py \
  tools/mcbedrock-get/wsl_backend.py tests/test_apkmeta.py tests/test_downloader.py \
  tests/test_prepare_resources.py tests/test_release_builder.py tests/test_docs.py \
  tests/test_portability_contracts.py tests/test_downloader_policy.py \
  tests/test_failsafe.py \
  tests/test_screenshot_watch.py \
  tests/test_cfw_contracts.py \
  tests/test_failsafes.py \
  scripts/check_downloader_policy.py
for patch in source_release/*.patch; do git apply --recount --numstat "$patch" >/dev/null; done
bash tests/test_migration.sh
bash tests/test_performance.sh
bash tests/test_platform.sh
bash tests/test_selftest_runs.sh
bash tests/test_launcher_early_exit.sh
bash tests/test_abi.sh
bash tests/test_failsafe_apply.sh
bash tests/test_audio.sh
bash tests/test_message.sh
bash tests/test_redaction.sh
bash tests/test_watchdog.sh
bash tests/test_update.sh
python3 tests/test_apkmeta.py
python3 tests/test_downloader.py
python3 tests/test_downloader_policy.py
python3 scripts/check_downloader_policy.py
python3 tests/test_version_selection.py
python3 tests/test_failsafe.py
python3 tests/test_failsafes.py
python3 tests/test_prepare_resources.py
python3 tests/test_screenshot_watch.py
python3 -m unittest discover -s tools/mcbedrock-get/tests -p 'test_*.py' -v
python3 tests/test_docs.py
python3 tests/test_portability_contracts.py
python3 tests/test_cfw_contracts.py
bash tests/test_terrain_loop.sh
bash tests/test_rgds_session.sh
python3 tests/test_release_builder.py
gcc -Wall -Wextra -Werror source_release/runtime/test_crusty_context_v1.c \
  -ldl -o /tmp/minecraftbedrock-test-context-v1
/tmp/minecraftbedrock-test-context-v1
cc -O2 -ffunction-sections -fdata-sections -Wall -Wextra -Werror -std=c11 \
  -o /tmp/minecraftbedrock-bottomd-companion \
  bottomscreen/bottomd/bottomd.c bottomscreen/bottomd/companion.c \
  bottomscreen/bottomd/draw.c bottomscreen/bottomd/gamepad.c bottomscreen/bottomd/keyfwd.c \
  bottomscreen/bottomd/pages.c \
  bottomscreen/bottomd/paneltouch.c bottomscreen/bottomd/screenflip.c \
  bottomscreen/bottomd/texture.c bottomscreen/bottomd/tiles.c bottomscreen/bottomd/touchfwd.c \
  bottomscreen/bottomd/worldinfo.c bottomscreen/bottomd/backend_ppm.c \
  bottomscreen/bottomd/backend_fbdev.c -lrt -lm -lpng -Wl,--gc-sections
grep -aq 'mcpe_companion' /tmp/minecraftbedrock-bottomd-companion
grep -aq 'INDEPENDENT CHAT' /tmp/minecraftbedrock-bottomd-companion
grep -aq 'mcpe-rgds-touchinject' /tmp/minecraftbedrock-bottomd-companion
! grep -aEq 'BOTTOMD_DEVHUD|/dev/input/event[0-9]|Goodix|mcpe_touch' \
  /tmp/minecraftbedrock-bottomd-companion
make -C bottomscreen/telemetry check
make -C bottomscreen/bottomd check check-daynight check-worldinfo \
  check-pages check-independent check-modes
echo "all host-side tests passed"
