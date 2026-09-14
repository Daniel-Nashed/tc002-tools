#!/usr/bin/env bash
# Pushes runtime/disable_adb.sh (the on-device ADB-retirement helper - see
# docs/recovery.md) to INSTALL_PREFIX/bin/disable_adb.sh. Deliberately NOT
# part of install/deploy.sh's automatic flow, and NOT wired into
# install_dropbear.sh either - installing this tool is its own separate,
# deliberate operator action, same as actually running it later is (see
# runtime/disable_adb.sh's own confirmation prompt). This script only
# PUSHES the file; it never invokes it, and never disables adbd itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""

usage()
{
  cat <<'EOF'
Usage: disable_adb.sh [--device SERIAL] [--config FILE]

Pushes runtime/disable_adb.sh to INSTALL_PREFIX/bin/disable_adb.sh. Does
NOT run it and does NOT disable adbd itself - that is a deliberate, manual
step the operator runs later, FROM THE DEVICE over an SSH session already
confirmed working (see docs/recovery.md and runtime/disable_adb.sh's own
confirmation prompt). Never called automatically by install/deploy.sh.

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

  local src="${REPO_ROOT}/runtime/disable_adb.sh"

  if [ ! -f "$src" ]; then
    die "not found: ${src}"
  fi

  adb -s "$DEVICE" push "$src" "${INSTALL_PREFIX}/bin/disable_adb.sh"
  adb -s "$DEVICE" shell "chmod 755 ${INSTALL_PREFIX}/bin/disable_adb.sh && chown 0:0 ${INSTALL_PREFIX}/bin/disable_adb.sh"

  log "installed ${INSTALL_PREFIX}/bin/disable_adb.sh"
  log "this only installs the tool - it does NOT disable adbd. Run it yourself later, from the device over SSH, when you are ready. See docs/recovery.md first."
}

main
