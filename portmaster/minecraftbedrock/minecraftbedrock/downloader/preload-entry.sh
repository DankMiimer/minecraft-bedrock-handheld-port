#!/bin/bash
# Westonwrap injects Crusty's graphics preload into its child. Preserve it for
# Qt, but remove it before starting the shell coordinator and its utilities.
set -u
export MCPE_GUI_PRELOAD="${LD_PRELOAD:-}"
unset LD_PRELOAD
exec bash "${MCPE_DOWNLOADER_SCRIPT_DIR:?missing downloader path}/gui-session.sh"
