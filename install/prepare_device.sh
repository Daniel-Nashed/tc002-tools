#!/usr/bin/env bash
# Non-destructive device preparation: creates project directories and sets
# INSTALL_PREFIX to the mode Dropbear requires. Never touches ownership.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""

usage()
{
  cat <<'EOF'
Usage: prepare_device.sh [--device SERIAL] [--config FILE]

Creates INSTALL_PREFIX/bin and INSTALL_PREFIX/home/.ssh on the device
(idempotent), and sets INSTALL_PREFIX itself to mode 700 - Dropbear checks
parent-directory safety on the path down to authorized_keys and refuses
public-key auth if INSTALL_PREFIX is more permissive than that (see
docs/device_layout.md). Ownership of INSTALL_PREFIX is never changed, only
its mode.

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

set_prefix_mode()
{
  local listing perms_before

  listing="$(adb -s "$DEVICE" shell "ls -ld ${INSTALL_PREFIX}" | tr -d '\r')"
  perms_before="$(echo "$listing" | awk '{print $1}')"

  if [ -z "$perms_before" ]; then
    die "could not read permissions for ${INSTALL_PREFIX} (unexpected ls -ld output: ${listing})"
  fi

  if [ "$perms_before" = "drwx------" ]; then
    log "${INSTALL_PREFIX} is already mode 700 - OK"
    return
  fi

  log "${INSTALL_PREFIX} is currently ${perms_before}; setting to 700 (required for Dropbear pubkey auth - see docs/device_layout.md)"
  log "not changing ${INSTALL_PREFIX}'s ownership, only its mode"

  adb -s "$DEVICE" shell "chmod 700 ${INSTALL_PREFIX}"
  log "set ${INSTALL_PREFIX} to mode 700"
}

create_directories()
{
  adb -s "$DEVICE" shell "mkdir -p ${INSTALL_PREFIX}/bin ${INSTALL_PREFIX}/home/.ssh"
  log "ensured ${INSTALL_PREFIX}/bin and ${INSTALL_PREFIX}/home/.ssh exist"
}

set_known_permissions()
{
  adb -s "$DEVICE" shell "chown 0:0 ${INSTALL_PREFIX}/bin && chmod 755 ${INSTALL_PREFIX}/bin"
  adb -s "$DEVICE" shell "chown 0:0 ${INSTALL_PREFIX}/home && chmod 755 ${INSTALL_PREFIX}/home"
  adb -s "$DEVICE" shell "chown 0:0 ${INSTALL_PREFIX}/home/.ssh && chmod 700 ${INSTALL_PREFIX}/home/.ssh"
  log "set ownership/permissions on ${INSTALL_PREFIX}/bin, ${INSTALL_PREFIX}/home, ${INSTALL_PREFIX}/home/.ssh"
}

main()
{
  require_cmd adb

  set_prefix_mode
  create_directories
  set_known_permissions

  log "device preparation complete for ${DEVICE}"
}

main
