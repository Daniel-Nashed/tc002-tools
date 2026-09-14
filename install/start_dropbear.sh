#!/usr/bin/env bash
# Starts Dropbear on an already-provisioned device by running the
# on-device entry point (runtime/init.sh, deployed to
# INSTALL_PREFIX/bin/init.sh by install_dropbear.sh) over a single
# non-interactive "adb shell" call - see docs/manual_rollout.md for what
# init.sh itself does. init.sh is idempotent (refreshes nshbox's applet
# symlinks, then hands off to sshd.sh, which does nothing and exits 0 if
# Dropbear is already running), so this is always safe to re-run.
#
# Runs LAST in tc002_setup.sh, after every push/verify step - deploying
# files and starting the service they belong to are still logically
# separate steps (this script only does the latter), but tc002_setup.sh
# chains them so one command actually leaves you with a device you can
# SSH into, instead of a mandatory extra manual step every time.
#
# This only works at all because runtime/sshd.sh's backgrounded Dropbear
# invocation now redirects its own stdin from /dev/null - without that,
# the detached Dropbear daemon kept the adb shell session's own stdin
# open forever, and this "adb shell ..." call would simply never return
# (confirmed directly, 2026-09-13).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""

usage()
{
  cat <<'EOF'
Usage: start_dropbear.sh [--device SERIAL] [--config FILE]

Runs INSTALL_PREFIX/bin/init.sh on the device over "adb shell" - the
on-device entry point documented in docs/manual_rollout.md, run here
automatically as the last step of tc002_setup.sh. Idempotent: does
nothing (exits 0) if Dropbear is already running.

  --device SERIAL   ADB device serial (overrides DEVICE from config).
  --config FILE     Config file (default: config/tc002-tools.conf).
  -h, --help        Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --device)
      DEVICE_OVERRIDE="$2"
      shift 2
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

load_config "$CONFIG_FILE"

if [ -n "$DEVICE_OVERRIDE" ]; then
  DEVICE="$DEVICE_OVERRIDE"
fi

require_device

log "starting dropbear: running ${INSTALL_PREFIX}/bin/init.sh on ${DEVICE}"
adb -s "$DEVICE" shell "${INSTALL_PREFIX}/bin/init.sh"
