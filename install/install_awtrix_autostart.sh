#!/usr/bin/env bash
# Lays down runtime/awtrix_autostart.sh as
# /data/awtrix-ng/state/autostart - AWTRIX's own autostart hook, execed
# directly by AWTRIX at boot. This is the only way to start Dropbear
# automatically on a device that already runs AWTRIX: network ADB is gone
# by then (see install/discover_device.sh), so there is no way to reach the
# device at all after a reboot without it, short of USB and a manual
# "adb shell /data/bin/init.sh" every time (see docs/manual_rollout.md,
# "After a reboot").
#
# Only pushed if /data/awtrix-ng/state already exists on the device - a
# stock (non-AWTRIX) device has no such path at all, and this step should
# skip quietly there, not invent the directory (AWTRIX itself owns it).
# Checked via output text, not the shell exit code - "adb shell" on this
# device is documented elsewhere (see push_etc_override()'s own comments
# in common.sh) to report exit 0 from a "test" builtin regardless of the
# actual result, so every existence check in this project reads back a
# marker string instead of trusting $?.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""

AWTRIX_STATE_DIR="/data/awtrix-ng/state"

usage()
{
  cat <<'EOF'
Usage: install_awtrix_autostart.sh [--device SERIAL] [--config FILE]

Pushes runtime/awtrix_autostart.sh to
/data/awtrix-ng/state/autostart (mode 755 - AWTRIX execs it directly),
so Dropbear starts automatically the next time the device boots.
Skipped with a log line, not an error, if /data/awtrix-ng/state does not
exist on the device - a stock (non-AWTRIX) device has no such path, and
persistent startup there is not something this project can provide yet
(see docs/manual_rollout.md).

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

main()
{
  require_cmd adb

  local state_dir_check
  state_dir_check="$(adb -s "$DEVICE" shell "[ -d ${AWTRIX_STATE_DIR} ] && echo yes" 2>&1 | tr -d '\r')"

  if [ "$state_dir_check" != "yes" ]; then
    log "skipping AWTRIX autostart: ${AWTRIX_STATE_DIR} not found on the device (not an AWTRIX-flashed device, or AWTRIX has not run yet)"
    return
  fi

  install_binary "awtrix_autostart" "${REPO_ROOT}/runtime/awtrix_autostart.sh" "autostart" "$AWTRIX_STATE_DIR"

  log "AWTRIX will now run init.sh automatically at boot (${AWTRIX_STATE_DIR}/autostart)"
}

main
