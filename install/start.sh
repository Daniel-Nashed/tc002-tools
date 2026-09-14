#!/usr/bin/env bash
# Brings the stack up on an ALREADY-PROVISIONED device: finds it
# (discover_device.sh, using this project's own tc002-discover - skipped
# only if --device is given; unlike deploy.sh's DEVICE_IP handling, this
# always re-discovers otherwise, deliberately - the whole point is picking
# up whatever IP DHCP handed the device this time, not reusing a
# possibly-stale one from before a reboot), then starts Dropbear
# (start_dropbear.sh - runs init.sh on the device over "adb shell",
# idempotent, does nothing if Dropbear is already running - see its own
# comments).
#
# Does NOT push or install anything - unlike deploy.sh, this assumes
# tc002_setup.sh has already provisioned the device at least once.
# Everything it needs is already on /data, which survives a reboot (only
# /tmp does not - see docs/platform.md); init.sh itself already refreshes
# nshbox's applet symlinks and re-applies /etc's overrides via
# setup_etc.sh on every run (see runtime/init.sh, runtime/sshd.sh), so
# nothing here needs to re-push those either. This is exactly the "device
# just rebooted, DHCP may have handed it a new IP, get SSH back up" case
# docs/manual_rollout.md previously had no single-command answer for -
# re-running the full tc002_setup.sh works too (idempotent) but
# unconditionally re-pushes every binary on every run, which this skips.
#
# Invoked as ./tc002_start.sh from the repo root - see that script's own
# comments.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE="${REPO_ROOT}/config/tc002-tools.conf"
DEVICE_OVERRIDE=""
IP_OVERRIDE=""

usage()
{
  cat <<'EOF'
Usage: start.sh [--device SERIAL] [--ip ADDRESS] [--config FILE]

Runs, in order: discover_device.sh (skipped if --device is given - finds
the TC002 with tc002-discover and writes DEVICE_IP into the config file;
--ip is passed straight through to it, skipping the broadcast search and
its own interactive prompt - see discover_device.sh --help), then
start_dropbear.sh (runs init.sh on the device over "adb shell", so you
can SSH in as soon as this command finishes).

Does not install or push anything. For a device that has never been
provisioned, use tc002_setup.sh instead. This is for bringing an
already-provisioned device's SSH access back up after a reboot (Dropbear
is not started at boot yet - see docs/manual_rollout.md), when the
device's IP may have changed.

  --device SERIAL   ADB device serial (overrides DEVICE from config;
                       skips discovery entirely).
  --ip ADDRESS       Device IP to use directly - passed through to
                       discover_device.sh, skipping its broadcast search.
                       Ignored if --device is also given.
  --config FILE      Config file (default: config/tc002-tools.conf).
  -h, --help          Show this help.
EOF
}

while [ $# -gt 0 ]
do
  case "$1" in
    --device)
      DEVICE_OVERRIDE="$2"
      shift 2
      ;;
    --ip)
      IP_OVERRIDE="$2"
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

COMMON_ARGS=(--config "$CONFIG_FILE")

if [ -n "$DEVICE_OVERRIDE" ]; then
  COMMON_ARGS+=(--device "$DEVICE_OVERRIDE")
fi

main()
{
  header "tc002_start.sh: finding the device and starting the stack"

  if [ -z "$DEVICE_OVERRIDE" ]; then
    header "start: discovering device"

    if [ -n "$IP_OVERRIDE" ]; then
      "${SCRIPT_DIR}/discover_device.sh" --config "$CONFIG_FILE" --ip "$IP_OVERRIDE"
    else
      "${SCRIPT_DIR}/discover_device.sh" --config "$CONFIG_FILE"
    fi
  fi

  header "start: starting dropbear"
  "${SCRIPT_DIR}/start_dropbear.sh" "${COMMON_ARGS[@]}"

  # Re-read the config file for this summary line only, same reasoning as
  # deploy.sh's identical block - discover_device.sh may have just written
  # a fresh DEVICE_IP.
  load_config "$CONFIG_FILE"
  if [ -n "$DEVICE_OVERRIDE" ]; then
    DEVICE="$DEVICE_OVERRIDE"
  fi

  header "start: complete"
  log "SSH is up:"
  log "  ssh -p ${SSH_PORT} root@${DEVICE_IP:-$DEVICE}"
  echo >&2
}

main
