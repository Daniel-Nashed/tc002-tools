#!/usr/bin/env bash
# THE command to get SSH access back up on a device tc002_setup.sh has
# already provisioned at least once - e.g. after a reboot, since
# persistent startup is not implemented yet (see docs/manual_rollout.md).
# Finds the device (this project's own tc002-discover, unless --device is
# given - the IP may have changed since last time) and starts Dropbear
# over "adb shell". Does not install or push anything - use
# ./tc002_setup.sh instead for first-time provisioning (or a forced full
# reinstall), or ./tc002_update.sh to push newly-built tool binaries once
# SSH is already working.
#
# Usage:
#   ./tc002_start.sh                       # find the device and start the stack
#   ./tc002_start.sh --ip 192.168.1.50     # skip broadcast discovery, use this IP
#   ./tc002_start.sh --help                # see install/start.sh's own options
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/install/start.sh" "$@"
