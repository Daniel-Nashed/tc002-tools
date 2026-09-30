#!/usr/bin/env bash
# THE command to push updated tool binaries to a device that already has
# SSH working - e.g. after rebuilding nshbox/kilo/gzip. Pushes over
# SSH/SCP (not ADB), then runs "nshbox install -f" to refresh its applet
# symlinks. Does not touch discover_device.sh, prepare_device.sh,
# install_etc.sh, or install_dropbear.sh - none of that needs to run again
# for a plain binary update (see docs/manual_rollout.md's deployment-phase
# breakdown). Requires DEVICE_IP/SSH_PORT already set in the config and SSH
# already working (see tests/test_device_access.sh) - use ./tc002_setup.sh
# instead for first-time provisioning, or to force a full reinstall.
#
# Usage:
#   ./tc002_update.sh                       # update everything built
#   ./tc002_update.sh --config FILE         # see install/update_tools.sh's own options
#   ./tc002_update.sh --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/install/update_tools.sh" "$@"
